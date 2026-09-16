#!/usr/bin/env python3
"""
closure.py -- compute the complete bare-install dependency closure for an
Omarchy ppc64le system, across two package universes at once:

  1. the Arch POWER sync DB (what the distro already has), and
  2. the packaging tree (what we have to build ourselves) --
     omarchy-ppc64le-packaging, walked recursively and keyed by pkgbase.
     Most of its recipes sit under category directories (kf6/, xorg/,
     python/, ...), so a flat listing of it misses thousands.

`pacman -Sp` alone cannot do this: it stops at the first name that is not in a
sync repo, which is precisely the set we care about.  So the sync DBs are
parsed directly, the local recipes are parsed from .SRCINFO (or a sourced
PKGBUILD as a fallback), and the closure is walked over the union.

Output: an ordered manifest (dependencies before dependents) that doubles as
the ISO's offline mirror list.
"""

import os
import re
import sys
import json
import tarfile
import subprocess
from collections import defaultdict

SYNCDIR = "/var/lib/pacman/sync"
OMARCHY = os.path.expanduser("~/Development/omarchy-ppc64le")
# The one local source of build scripts; see tools/bq.py.
PACKAGING = os.environ.get(
    "OMARCHY_PACKAGING",
    os.path.expanduser("~/Development/omarchy-ppc64le-packaging"))
CARCH = "powerpc64le"

VERSTRIP = re.compile(r"[<>=]+.*$")


def depname(s):
    """Strip a version constraint and any description from a depends entry."""
    s = s.split(":")[0].strip()
    return VERSTRIP.sub("", s).strip()


# --------------------------------------------------------------------------
# 1. the sync DBs
# --------------------------------------------------------------------------

class Pkg:
    __slots__ = ("name", "base", "version", "provides", "depends", "groups",
                 "csize", "isize", "repo", "origin")

    def __init__(self, name):
        self.name = name
        self.base = name
        self.version = ""
        self.provides = []
        self.depends = []
        self.groups = []
        self.csize = 0
        self.isize = 0
        self.repo = ""
        self.origin = "sync"


def load_sync():
    pkgs = {}
    for fn in sorted(os.listdir(SYNCDIR)):
        if not fn.endswith(".db"):
            continue
        repo = fn[:-3]
        with tarfile.open(os.path.join(SYNCDIR, fn)) as tf:
            for m in tf:
                if not m.isfile() or os.path.basename(m.name) != "desc":
                    continue
                body = tf.extractfile(m).read().decode("utf-8", "replace")
                p = parse_desc(body)
                if p is None:
                    continue
                p.repo = repo
                # first repo in pacman.conf order wins
                if p.name not in pkgs:
                    pkgs[p.name] = p
    return pkgs


def parse_desc(body):
    fields = defaultdict(list)
    key = None
    for line in body.splitlines():
        if line.startswith("%") and line.endswith("%"):
            key = line.strip("%")
        elif line.strip() == "":
            key = None
        elif key:
            fields[key].append(line.strip())
    if "NAME" not in fields:
        return None
    p = Pkg(fields["NAME"][0])
    p.base = fields.get("BASE", [p.name])[0]
    p.version = fields.get("VERSION", [""])[0]
    p.provides = [depname(x) for x in fields.get("PROVIDES", [])]
    p.depends = [depname(x) for x in fields.get("DEPENDS", [])]
    p.groups = fields.get("GROUPS", [])
    p.csize = int(fields.get("CSIZE", ["0"])[0] or 0)
    p.isize = int(fields.get("ISIZE", ["0"])[0] or 0)
    return p


# --------------------------------------------------------------------------
# 2. the local recipe trees
# --------------------------------------------------------------------------

def parse_srcinfo(path):
    """Return {pkgname: {'provides': [...], 'depends': [...], 'base': str}}."""
    out = {}
    base = None
    gdep, gprov = [], []
    cur = None
    cdep, cprov = [], []

    def flush():
        if cur:
            out[cur] = {"provides": list(gprov) + cprov,
                        "depends": list(gdep) + cdep,
                        "base": base}

    with open(path, "r", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                continue
            k, v = line.split("=", 1)
            k, v = k.strip(), v.strip()
            if not v:
                continue
            # architecture-suffixed keys: keep generic and our CARCH
            if "_" in k:
                stem, _, suf = k.rpartition("_")
                if stem in ("depends", "makedepends", "provides",
                            "checkdepends", "optdepends") and suf not in (CARCH,):
                    continue
                if stem in ("depends", "provides") and suf == CARCH:
                    k = stem
            if k == "pkgbase":
                flush()
                base = v
                cur = None
                gdep, gprov = [], []
            elif k == "pkgname":
                flush()
                cur = v
                cdep, cprov = [], []
            elif k == "depends":
                (cdep if cur else gdep).append(depname(v))
            elif k == "provides":
                (cprov if cur else gprov).append(depname(v))
    flush()
    return out


def parse_pkgbuild(path):
    """Fallback: source the PKGBUILD in a subshell and dump the arrays."""
    script = r'''
set -a
CARCH=%s; CHOST=powerpc64le-unknown-linux-gnu
srcdir=/nonexistent; pkgdir=/nonexistent; startdir=$(dirname "$1")
source "$1" >/dev/null 2>&1
printf 'PKGBASE\t%%s\n' "${pkgbase:-${pkgname[0]}}"
for n in "${pkgname[@]}"; do printf 'PKGNAME\t%%s\n' "$n"; done
for d in "${depends[@]}"; do printf 'DEPENDS\t%%s\n' "$d"; done
for d in "${provides[@]}"; do printf 'PROVIDES\t%%s\n' "$d"; done
for d in "${makedepends[@]}"; do printf 'MAKEDEPENDS\t%%s\n' "$d"; done
''' % CARCH
    try:
        r = subprocess.run(["bash", "-c", script, "_", path],
                           capture_output=True, text=True, timeout=30)
    except Exception:
        return {}
    base, names, dep, prov, mdep = None, [], [], [], []
    for line in r.stdout.splitlines():
        if "\t" not in line:
            continue
        k, v = line.split("\t", 1)
        v = depname(v)
        if not v:
            continue
        if k == "PKGBASE":
            base = v
        elif k == "PKGNAME":
            names.append(v)
        elif k == "DEPENDS":
            dep.append(v)
        elif k == "PROVIDES":
            prov.append(v)
        elif k == "MAKEDEPENDS":
            mdep.append(v)
    if not names:
        return {}
    return {n: {"provides": prov, "depends": dep, "base": base or names[0],
                "makedepends": mdep} for n in names}


def load_built(repodir, origin):
    """Read .PKGINFO out of every package we have already built.  This is the
    authoritative source for a local package's provides/depends -- far better
    than guessing from a PKGBUILD, which can set them inside package_()."""
    pkgs = {}
    if not os.path.isdir(repodir):
        return pkgs
    for fn in sorted(os.listdir(repodir)):
        if not fn.endswith(".pkg.tar.zst") or "-debug-" in fn:
            continue
        path = os.path.join(repodir, fn)
        try:
            r = subprocess.run(["bsdtar", "-xOqf", path, ".PKGINFO"],
                               capture_output=True, text=True, timeout=60)
        except Exception:
            continue
        name = base = ver = None
        prov, dep = [], []
        size = 0
        for line in r.stdout.splitlines():
            if " = " not in line:
                continue
            k, v = line.split(" = ", 1)
            if k == "pkgname":
                name = v
            elif k == "pkgbase":
                base = v
            elif k == "pkgver":
                ver = v
            elif k == "provides":
                prov.append(depname(v))
            elif k == "depend":
                dep.append(depname(v))
            elif k == "size":
                size = int(v or 0)
        if not name:
            continue
        p = Pkg(name)
        p.base = base or name
        p.version = ver or ""
        p.provides = prov
        p.depends = dep
        p.isize = size
        p.csize = os.path.getsize(path)
        p.origin = origin
        p.repo = "omarchy-ppc64le"
        pkgs[name] = p
    return pkgs


# Directories that live *inside* a recipe directory and are not recipes:
# makepkg's working trees, VCS mirrors cloned next to the recipe, and git
# metadata. Descending into them would turn a PKGBUILD shipped inside some
# project's own source tree into a phantom second recipe for a pkgbase.
PRUNE_DIRS = {".git", ".github", "src", "pkg", "logs", "__pycache__", "keys"}
MAX_RECIPE_DEPTH = 4


def discover_recipes(root):
    """pkgbase -> [recipe directory, ...] for an entire recipe tree.

    bq, closure.py and recipe-sync all need the same answer to "what recipes
    does this tree contain", and all three used to answer it with a flat
    listdir of <root>/<pkgbase>. Arch POWER keeps ~1800 pkgbases at its top
    level and ~2500 more one level down under kf6/, xorg/, python/, perl/,
    plasma/ and twenty-odd other category directories, so the flat answer was
    wrong for more than half the tree.

    A directory that contains a PKGBUILD *is* a recipe and is never descended
    into. That one rule is what keeps Arch POWER's leftover SVN layout
    (cscope/PKGBUILD beside cscope/trunk/PKGBUILD) and oddities like
    python/python-pycparser/python-cffi from each looking like a second
    directory claiming a pkgbase that already resolved.

    Genuine collisions are returned as they are, with every directory listed,
    rather than resolved here: only the caller knows whether picking one is
    acceptable, and picking one silently is the bug this function exists to
    make impossible.
    """
    found = defaultdict(list)
    if not os.path.isdir(root):
        return found

    def walk(d, depth):
        try:
            entries = sorted(os.scandir(d), key=lambda e: e.name)
        except OSError:
            return
        if any(e.is_file() and e.name == "PKGBUILD" for e in entries):
            base = os.path.basename(d)
            if base == "trunk":             # old SVN layout: not a pkgbase
                base = os.path.basename(os.path.dirname(d))
            found[base].append(d)
            return
        if depth >= MAX_RECIPE_DEPTH:
            return
        for e in entries:
            if e.is_dir(follow_symlinks=False) and e.name not in PRUNE_DIRS:
                walk(e.path, depth + 1)

    walk(root, 0)
    return found


def load_tree(root, origin):
    """Scan a recipe tree of {.SRCINFO,PKGBUILD} directories, at any depth."""
    pkgs = {}
    found = discover_recipes(root)
    for d in sorted(found):
        dirs = found[d]
        if len(dirs) > 1:
            print("closure: %s: %d directories claim this pkgbase: %s"
                  % (d, len(dirs),
                     ", ".join(os.path.relpath(x, root) for x in dirs)),
                  file=sys.stderr)
        pdir = dirs[0]
        si = os.path.join(pdir, ".SRCINFO")
        pb = os.path.join(pdir, "PKGBUILD")
        info = {}
        if os.path.isfile(si):
            try:
                info = parse_srcinfo(si)
            except Exception:
                info = {}
        if not info and os.path.isfile(pb):
            info = parse_pkgbuild(pb)
        for name, d2 in info.items():
            if name in pkgs:
                continue
            p = Pkg(name)
            p.base = d2.get("base") or d
            p.provides = d2.get("provides", [])
            p.depends = d2.get("depends", [])
            p.origin = origin
            p.repo = origin
            pkgs[name] = p
    return pkgs


# --------------------------------------------------------------------------
# 3. closure
# --------------------------------------------------------------------------

def build_index(*universes):
    """name/provides -> Pkg, earlier universes win."""
    byname, byprov = {}, {}
    for u in universes:
        for n, p in u.items():
            byname.setdefault(n, p)
    for u in universes:
        for n, p in u.items():
            for pr in p.provides:
                byprov.setdefault(pr, p)
    return byname, byprov


def resolve(name, byname, byprov):
    return byname.get(name) or byprov.get(name)


def closure(targets, byname, byprov):
    seen, missing, order = {}, set(), []
    stack = list(targets)
    while stack:
        n = stack.pop()
        p = resolve(n, byname, byprov)
        if p is None:
            missing.add(n)
            continue
        if p.name in seen:
            continue
        seen[p.name] = p
        for d in p.depends:
            if d not in seen:
                stack.append(d)
    return seen, missing


def toposort(seen, byname, byprov):
    """Kahn's algorithm; ties broken by name for a reproducible manifest."""
    edges = {n: set() for n in seen}
    rdeps = defaultdict(set)
    for n, p in seen.items():
        for d in p.depends:
            t = resolve(d, byname, byprov)
            if t is not None and t.name in seen and t.name != n:
                edges[n].add(t.name)
                rdeps[t.name].add(n)
    ready = sorted(n for n in edges if not edges[n])
    out = []
    while ready:
        n = ready.pop(0)
        out.append(n)
        for r in sorted(rdeps[n]):
            edges[r].discard(n)
            if not edges[r]:
                ready.append(r)
                ready.sort()
    stuck = [n for n in edges if n not in out]
    # Only report genuine strongly-connected components.  Everything else in
    # `stuck` is merely downstream of a cycle and orders fine once it is cut.
    sccs = tarjan({n: edges[n] for n in stuck})
    real = [sorted(c) for c in sccs if len(c) > 1]
    # Cut each SCC at its alphabetically-first member and re-run, so the
    # manifest stays a total order rather than a truncated one.
    for c in real:
        edges[c[0]] = {e for e in edges[c[0]] if e not in set(c)}
    if real:
        ready = sorted(n for n in stuck if not edges[n])
        while ready:
            n = ready.pop(0)
            if n in out:
                continue
            out.append(n)
            for r in sorted(rdeps[n]):
                edges[r].discard(n)
                if not edges[r] and r not in out:
                    ready.append(r)
                    ready.sort()
    out.extend(sorted(n for n in edges if n not in out))
    return out, real


def tarjan(graph):
    """Iterative Tarjan SCC -- the graph is ~800 nodes but recursion in a
    build tool is a liability, so this stays explicit."""
    index = {}
    low = {}
    onstack = {}
    stack = []
    result = []
    counter = [0]
    for root in sorted(graph):
        if root in index:
            continue
        work = [(root, iter(sorted(graph.get(root, ()))))]
        index[root] = low[root] = counter[0]
        counter[0] += 1
        stack.append(root)
        onstack[root] = True
        while work:
            node, it = work[-1]
            advanced = False
            for nxt in it:
                if nxt not in graph:
                    continue
                if nxt not in index:
                    index[nxt] = low[nxt] = counter[0]
                    counter[0] += 1
                    stack.append(nxt)
                    onstack[nxt] = True
                    work.append((nxt, iter(sorted(graph.get(nxt, ())))))
                    advanced = True
                    break
                elif onstack.get(nxt):
                    low[node] = min(low[node], index[nxt])
            if advanced:
                continue
            work.pop()
            if work:
                low[work[-1][0]] = min(low[work[-1][0]], low[node])
            if low[node] == index[node]:
                comp = []
                while True:
                    w = stack.pop()
                    onstack[w] = False
                    comp.append(w)
                    if w == node:
                        break
                result.append(comp)
    return result


# --------------------------------------------------------------------------

def main():
    sync = load_sync()
    built = load_built(os.path.join(OMARCHY, "repo"), "omarchy-built")
    packaging = load_tree(PACKAGING, "packaging")

    # Resolution priority: Arch POWER sync DB first (it is what an install
    # actually pulls), then our own built recipes, then the packaging tree
    # (recipes for things the sync DB has not published yet).
    byname, byprov = build_index(sync, built, packaging)

    # ---- targets
    groups = defaultdict(list)
    for p in sync.values():
        for g in p.groups:
            groups[g].append(p.name)

    # In Arch (and Arch POWER) `base` and `base-devel` are metapackages, not
    # groups -- `pacman -Sg base` returns nothing.  Take them as packages and
    # additionally fold in any same-named group, so this stays correct if the
    # distro ever moves back.
    targets = set()
    for g in ("base", "base-devel"):
        targets.add(g)
        targets.update(groups.get(g, []))
    gcount = {g: len(groups.get(g, [])) for g in ("base", "base-devel")}

    omfile = os.path.join(OMARCHY, "upstream/omarchy/install/omarchy-base.packages")
    omarchy_targets = []
    if os.path.isfile(omfile):
        for line in open(omfile):
            line = line.split("#")[0].strip()
            if line:
                omarchy_targets.append(line)
    targets.update(omarchy_targets)

    seen, missing = closure(targets, byname, byprov)
    order, cycles = toposort(seen, byname, byprov)

    # ---- stats
    by_origin = defaultdict(list)
    for n in order:
        by_origin[seen[n].origin].append(n)
    csize = sum(seen[n].csize for n in order)
    isize = sum(seen[n].isize for n in order)

    om_resolvable = [t for t in omarchy_targets if resolve(t, byname, byprov)]
    om_missing = [t for t in omarchy_targets if not resolve(t, byname, byprov)]

    report = {
        "total": len(order),
        "by_origin": {k: len(v) for k, v in by_origin.items()},
        "csize_bytes": csize,
        "isize_bytes": isize,
        "csize_gib": round(csize / 2**30, 2),
        "isize_gib": round(isize / 2**30, 2),
        "group_base": gcount["base"],
        "group_base_devel": gcount["base-devel"],
        "omarchy_targets": len(omarchy_targets),
        "omarchy_resolvable": len(om_resolvable),
        "omarchy_unresolvable": sorted(om_missing),
        "unresolved_deps": sorted(missing),
        "cycles": sorted(cycles),
        "to_build": sorted(by_origin["omarchy-built"] + by_origin["packaging"]),
        "already_built": sorted(by_origin["omarchy-built"]),
        "still_to_build": sorted(by_origin["packaging"]),
    }

    outdir = sys.argv[1] if len(sys.argv) > 1 else "/tmp/closure-out"
    os.makedirs(outdir, exist_ok=True)
    with open(os.path.join(outdir, "manifest.txt"), "w") as fh:
        for n in order:
            p = seen[n]
            fh.write("%s\t%s\t%s\t%s\n" % (n, p.version or "-", p.repo, p.origin))
    with open(os.path.join(outdir, "manifest-names.txt"), "w") as fh:
        fh.write("\n".join(order) + "\n")
    with open(os.path.join(outdir, "report.json"), "w") as fh:
        json.dump(report, fh, indent=2)

    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
