#!/usr/bin/env python3
"""soname-gaps.py -- packages stranded by a soname bump in our overlay.

The failure this exists for
---------------------------
Our repo is listed first in pacman.conf, so where we ship a package that Arch
POWER also ships, ours wins. When ours is newer *and* bumped a soname, every
package still depending on the old one becomes unsatisfiable -- including Arch
POWER packages we never touched, which is what makes this a distribution
problem rather than a local one.

Three instances on 2026-09-10 alone, each found only when a build failed:

  mgard      needs libprotobuf.so=34.1.0-64   we ship protobuf 35
             -> `pacman -Sp adios2` cannot resolve, so vtk could not be built
  libass     needs libunibreak.so=6-64        we ship libunibreak 7
             -> anything linking libass fails on `undefined reference to
                init_linebreak`; the symbol exists, the soname does not
  vtk/ioss   needs fmt < 12.2                 we ship fmt 12.2.0
             -> `fmt::localtime is not a member of fmt`

Why repo-gaps.py does not catch these
-------------------------------------
It reads DEPENDS from our packages only, and it splits provides and depends on
"=" before comparing -- so `libprotobuf.so=34.1.0-64` looks satisfied by a
provider offering `libprotobuf.so=35.1.0-64`. Both halves have to change: keep
the version, and check Arch POWER's packages too.

What this does
--------------
Resolves each package NAME to the entry pacman would actually pick (our repo
beats base, matching pacman.conf order), collects the versioned sonames those
winners provide, then reports any versioned soname dependency -- from any
package, ours or theirs -- that no winner satisfies.

Which pool it reads is selectable, because the distribution publishes two:

  REPO=repo-ppc64le REPO_NAME=omarchy-ppc64le tools/soname-gaps.py  # baseline
  tools/soname-gaps.py                                              # POWER9 pool

The default is the POWER9 pool, which is where this script has always looked.
"""
import tarfile, collections, glob, os, sys

REPO = os.environ.get("REPO", "repo")
REPO_NAME = os.environ.get("REPO_NAME", "omarchy-power9")

# pacman.conf order. Ours first: that is the whole point.
REPO_ORDER = [REPO_NAME, "base", "base-any", "core", "extra"]


def entries(path, repo):
    cur = collections.defaultdict(lambda: collections.defaultdict(list))
    try:
        with tarfile.open(path) as t:
            for m in t:
                if not m.name.endswith("/desc"):
                    continue
                d, key = m.name.split("/")[0], None
                fh = t.extractfile(m)
                if fh is None:
                    continue
                for ln in fh.read().decode("utf-8", "replace").splitlines():
                    if ln.startswith("%") and ln.endswith("%"):
                        key = ln.strip("%")
                    elif ln.strip() and key:
                        cur[d][key].append(ln.strip())
    except (OSError, tarfile.TarError) as e:
        print("warning: cannot read %s: %s" % (path, e), file=sys.stderr)
        return
    for f in cur.values():
        if "NAME" in f:
            yield f["NAME"][0], repo, f


def rank(repo):
    return REPO_ORDER.index(repo) if repo in REPO_ORDER else len(REPO_ORDER)


def main():
    sources = [(os.path.join(REPO, REPO_NAME + ".db.tar.gz"), REPO_NAME)]
    # A pool with no database yet is the normal state of a pool that has been
    # built but not published. Without this the run "succeeds" having read
    # nothing of ours, which reads as "no stranded packages".
    if not os.path.isfile(sources[0][0]):
        raise SystemExit(
            "soname-gaps: no database at %s\n"
            "  The pool has not been published yet. Publish it with\n"
            "    REPO=%s REPO_NAME=%s tools/repo-publish.sh --commit"
            % (sources[0][0], REPO, REPO_NAME))
    for d in sorted(glob.glob("/var/lib/pacman/sync/*.db")):
        sources.append((d, os.path.basename(d)[:-3]))

    # winner per package name, by repo priority
    winner = {}
    for path, repo in sources:
        for name, r, f in entries(path, repo):
            if name not in winner or rank(r) < rank(winner[name][0]):
                winner[name] = (r, f)

    # versioned sonames the winners actually provide: "libfoo.so" -> {"6-64", ...}
    provided = collections.defaultdict(set)
    for name, (repo, f) in winner.items():
        provided[name].add(None)                       # the bare package name
        for p in f.get("PROVIDES", []):
            base, _, ver = p.partition("=")
            provided[base].add(ver or None)

    # every versioned soname dependency, from every winner
    broken = []
    for name, (repo, f) in sorted(winner.items()):
        for d in f.get("DEPENDS", []):
            base, _, ver = d.partition("=")
            if not ver or ".so" not in base:
                continue                                # only versioned sonames
            have = provided.get(base)
            if have is None:
                broken.append((base, ver, name, repo, "no provider at all"))
            elif ver not in have:
                real = sorted(v for v in have if v)
                broken.append((base, ver, name, repo,
                               "provided: " + (", ".join(real) or "unversioned")))

    print("packages considered: %d   (ours: %d)"
          % (len(winner), sum(1 for _, (r, _f) in winner.items()
                              if r == REPO_NAME)))
    print()
    if not broken:
        print("no stranded soname dependencies")
        return 0
    manifest = set()
    try:
        for ln in open("installer/share/p9-base.packages"):
            ln = ln.split("#")[0].strip()
            if ln:
                manifest.add(ln)
    except OSError:
        pass

    # group by the package that is broken, not by the soname
    bypkg = collections.defaultdict(list)
    for base, ver, name, repo, why in broken:
        bypkg[(name, repo)].append((base, ver, why))

    print("STRANDED PACKAGES (%d, over %d dependencies)" % (len(bypkg), len(broken)))
    for (name, repo), items in sorted(bypkg.items()):
        mark = "*" if repo != REPO_NAME else "!"
        tag = "  *** IN MANIFEST" if name in manifest else ""
        print("  %s %s (%s)%s" % (mark, name, repo, tag))
        for base, ver, why in sorted(items):
            print("      wants %-26s %s" % (base + "=" + ver, why))
    print()
    print("  * an Arch POWER package our overlay stranded -- rebuild it into our")
    print("    repo against the current soname.")
    print("  ! one of ours, stranded by another of ours -- rebuild it too.")
    print()
    print("  Anything marked IN MANIFEST breaks pacstrap and so breaks the ISO.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
