#!/usr/bin/env python3
"""repo-gaps.py -- what our repo still cannot satisfy.

Reports dependencies declared by packages in repo/ that nothing in either our
repo or Arch POWER provides. These are hard blockers: `pacman -S <dependant>`
fails outright, and if the dependant is in the install manifest, pacstrap fails.

This is deliberately a *metadata* check and catches only undeclared-name gaps.
It does NOT catch a package linking a soname nothing ships any more -- that
needs the runtime ldd sweep, which is what found libnuma, the incomplete
qt6-declarative, and the libfmt.so.11/libabsl 2601 breakage.

Which pool it reads is selectable, because the distribution publishes two:

  REPO=repo-ppc64le REPO_NAME=omarchy-ppc64le tools/repo-gaps.py   # baseline
  tools/repo-gaps.py                                               # POWER9 pool

The default is the POWER9 pool, which is where this script has always looked.
"""
import tarfile, collections, re, glob, os, sys

REPO = os.environ.get("REPO", "repo")
REPO_NAME = os.environ.get("REPO_NAME", "omarchy-power9")

def entries(db):
    cur = collections.defaultdict(lambda: collections.defaultdict(list))
    with tarfile.open(db) as t:
        for m in t:
            if not m.name.endswith("/desc"):
                continue
            d, key = m.name.split("/")[0], None
            for ln in t.extractfile(m).read().decode("utf-8", "replace").splitlines():
                if ln.startswith("%") and ln.endswith("%"):
                    key = ln.strip("%")
                elif ln.strip() and key:
                    cur[d][key].append(ln.strip())
    for d, f in cur.items():
        if "NAME" in f:
            yield f["NAME"][0], f

prov = collections.defaultdict(set)
deps = collections.defaultdict(list)
ours = set()

sources = [(os.path.join(REPO, REPO_NAME + ".db.tar.gz"), True)]
# A pool with no database yet is the normal state of a pool that has been built
# but not published. Say so, rather than dying inside tarfile.
if not os.path.isfile(sources[0][0]):
    raise SystemExit(
        "repo-gaps: no database at %s\n"
        "  The pool has not been published yet. Publish it with\n"
        "    REPO=%s REPO_NAME=%s tools/repo-publish.sh --commit"
        % (sources[0][0], REPO, REPO_NAME))
sources += [(d, False) for d in sorted(glob.glob("/var/lib/pacman/sync/*.db"))]

for db, mine in sources:
    for n, f in entries(db):
        if mine:
            ours.add(n)
        prov[n].add(n)
        for p in f.get("PROVIDES", []):
            prov[p.split("=")[0]].add(n)
        if mine:
            for d in f.get("DEPENDS", []):
                deps[re.split(r"[<>=]", d)[0]].append(n)

manifest = set()
try:
    for ln in open("installer/share/omp-base.packages"):
        ln = ln.split("#")[0].strip()
        if ln:
            manifest.add(ln)
except OSError:
    pass

missing = sorted(d for d in deps if d not in prov)
print("repo packages: %d   manifest names: %d" % (len(ours), len(manifest)))
print()
print("UNSATISFIABLE DEPENDENCIES (%d)" % len(missing))
for d in missing:
    dependants = sorted(set(deps[d]))
    blocks = [x for x in dependants if x in manifest]
    flag = "  *** IN MANIFEST: %s" % ", ".join(blocks) if blocks else ""
    print("  %-22s needed by %s%s" % (d, ", ".join(dependants)[:58], flag))
