#!/usr/bin/env python3
"""
bq -- the Omarchy ppc64le build queue.

One engine, several front ends.  The thing that makes a mass rebuild hard is
not running makepkg; it is everything around it:

  * makepkg builds exactly one package and will not order a set for you,
  * build dependencies have to appear without root and without touching the
    live system,
  * a 674-to-858 package run *will* be interrupted,
  * and a failure log is useless unless it is sorted into the handful of
    reasons a package actually fails on POWER.

So the queue owns order, isolation, cleanup, resumption and triage, and calls
makepkg for the one job makepkg is good at.

The recipe source is pluggable, because the AUR triage tool is this same
engine with a different front end:

    local      omarchy-ppc64le/packages/<pkgbase>/       (our own recipes)
    archpower  ~/Development/repo/archpower/<pkgbase>/   (read-only input)
    gitlab     gitlab.archlinux.org/archlinux/packaging/packages/<pkgbase>
    aur        aur.archlinux.org/<pkgbase>.git

The AUR source additionally rewrites `arch=()` and regenerates `.SRCINFO`.
That is not a nicety: libalpm enforces the architecture guard itself, so
`yay`/`paru` cannot be flagged past it -- the recipe has to be edited before
makepkg ever sees it.

Subcommands
-----------
  plan     resolve build order for a set of targets, write queue.json
  build    build the queue, in order, resumably
  status   what has been built, what failed, and why
  triage   emit the failure work queue grouped by failure class

Nothing here writes to /etc, installs into the live system, or builds inside a
source checkout.  See RULES.md.
"""

import os
import re
import sys
import json
import time
import shutil
import argparse
import subprocess
from collections import defaultdict

HOME = os.path.expanduser("~")
OMARCHY = os.path.join(HOME, "Development/omarchy-ppc64le")
ARCHPOWER = os.path.join(HOME, "Development/repo/archpower")
TOOLS = os.path.join(OMARCHY, "tools")
REPO = os.path.join(OMARCHY, "repo")

# Build under /tmp by default.  /tmp here is a 221 GiB tmpfs on a 440 GiB
# machine, which is ideal for the ~850 small-to-medium packages and wrong for
# chromium/llvm/gcc -- pass --buildroot to put those on the NVMe instead.
# Never $HOME: an earlier run left 25 GiB there.
BUILDROOT = os.environ.get("BQ_BUILDROOT", "/tmp/omarchy-bq")
STATE = os.path.join(OMARCHY, ".bq-state.json")
CARCH = "powerpc64le"

sys.path.insert(0, TOOLS)


# ==========================================================================
# recipe sources
# ==========================================================================

class Source:
    name = "?"

    def available(self, pkgbase):
        raise NotImplementedError

    def materialise(self, pkgbase, dest):
        """Put a buildable recipe directory at `dest`.  Returns True/False."""
        raise NotImplementedError


class DirSource(Source):
    """A recipe tree already on disk.  Always copied out, never built in
    place -- building in a checkout is what leaves src/, pkg/ and stray
    tarballs scattered through it and makes the next `git pull` awkward.
    The archpower tree is strictly read-only input."""

    def __init__(self, name, root):
        self.name = name
        self.root = root

    def available(self, pkgbase):
        return os.path.isfile(os.path.join(self.root, pkgbase, "PKGBUILD"))

    def materialise(self, pkgbase, dest):
        src = os.path.join(self.root, pkgbase)
        if not self.available(pkgbase):
            return False
        os.makedirs(dest, exist_ok=True)
        for entry in os.listdir(src):
            # Skip anything that is build output rather than recipe.
            if entry in (".git", "src", "pkg", "logs"):
                continue
            if entry.endswith((".pkg.tar.zst", ".pkg.tar.xz", ".log")):
                continue
            s = os.path.join(src, entry)
            d = os.path.join(dest, entry)
            if os.path.isdir(s):
                shutil.copytree(s, d, dirs_exist_ok=True, symlinks=True)
            else:
                shutil.copy2(s, d)
        return True


class GitSource(Source):
    def __init__(self, name, urlfmt, rewrite_arch=False):
        self.name = name
        self.urlfmt = urlfmt
        self.rewrite_arch = rewrite_arch

    def available(self, pkgbase):
        return True  # only findable by trying

    def materialise(self, pkgbase, dest):
        url = self.urlfmt % pkgbase
        tmp = dest + ".git-tmp"
        shutil.rmtree(tmp, ignore_errors=True)
        r = subprocess.run(["git", "clone", "-q", "--depth", "1", url, tmp],
                           capture_output=True, text=True, timeout=600)
        if r.returncode != 0 or not os.path.isfile(os.path.join(tmp, "PKGBUILD")):
            shutil.rmtree(tmp, ignore_errors=True)
            return False
        shutil.rmtree(os.path.join(tmp, ".git"), ignore_errors=True)
        os.makedirs(dest, exist_ok=True)
        for entry in os.listdir(tmp):
            s, d = os.path.join(tmp, entry), os.path.join(dest, entry)
            if os.path.isdir(s):
                shutil.copytree(s, d, dirs_exist_ok=True, symlinks=True)
            else:
                shutil.copy2(s, d)
        shutil.rmtree(tmp, ignore_errors=True)
        if self.rewrite_arch:
            add_arch(os.path.join(dest, "PKGBUILD"))
            regen_srcinfo(dest)
        return True


def add_arch(pkgbuild, carch=CARCH):
    """Add our architecture to arch=() if it is not already there.

    libalpm refuses a package whose arch=() does not list the host, and there
    is no makepkg flag that overrides it -- which is why an AUR helper cannot
    simply be told to try.  `arch=(any)` is left alone; it already matches.
    """
    try:
        body = open(pkgbuild, encoding="utf-8", errors="replace").read()
    except OSError:
        return False
    m = re.search(r"^arch=\(([^)]*)\)", body, re.M)
    if not m:
        return False
    inner = m.group(1)
    if carch in inner.split() or "any" in inner.split():
        return False
    new = "arch=(%s %s)" % (inner.strip(), carch)
    body = body[:m.start()] + new + body[m.end():]
    open(pkgbuild, "w", encoding="utf-8").write(body)
    return True


def regen_srcinfo(dest):
    """makepkg --printsrcinfo, so the .SRCINFO matches the rewritten arch=().
    Helpers read .SRCINFO, not the PKGBUILD, so a stale one re-imposes the
    guard we just removed."""
    try:
        r = subprocess.run(["makepkg", "--printsrcinfo"], cwd=dest,
                           capture_output=True, text=True, timeout=120)
        if r.returncode == 0 and r.stdout.strip():
            open(os.path.join(dest, ".SRCINFO"), "w").write(r.stdout)
            return True
    except Exception:
        pass
    return False


SOURCES = {
    "local":     DirSource("local", os.path.join(OMARCHY, "packages")),
    "archpower": DirSource("archpower", ARCHPOWER),
    "gitlab":    GitSource("gitlab",
                           "https://gitlab.archlinux.org/archlinux/packaging/packages/%s.git"),
    "aur":       GitSource("aur", "https://aur.archlinux.org/%s.git",
                           rewrite_arch=True),
}


# ==========================================================================
# recipe metadata + ordering
# ==========================================================================

# Tarjan lives in closure.py; the two tools share one graph implementation
# rather than each growing its own.
from closure import tarjan  # noqa: E402

VERSTRIP = re.compile(r"[<>=]+.*$")


def depname(s):
    return VERSTRIP.sub("", s.split(":")[0].strip()).strip()


def read_recipe(recipedir):
    """pkgnames, provides, and *build-time* deps for one recipe directory."""
    si = os.path.join(recipedir, ".SRCINFO")
    if os.path.isfile(si):
        info = _from_srcinfo(si)
        if info["pkgname"]:
            return info
    return _from_pkgbuild(os.path.join(recipedir, "PKGBUILD"))


def _from_srcinfo(path):
    out = {"pkgbase": None, "pkgname": [], "provides": [], "depends": [],
           "makedepends": [], "checkdepends": [], "arch": []}
    for line in open(path, errors="replace"):
        line = line.strip()
        if not line or "=" not in line or line.startswith("#"):
            continue
        k, v = (x.strip() for x in line.split("=", 1))
        if not v:
            continue
        if "_" in k:
            stem, _, suf = k.rpartition("_")
            if stem in ("depends", "makedepends", "checkdepends", "provides",
                        "optdepends", "source", "sha256sums"):
                if suf != CARCH:
                    continue
                k = stem
        if k == "pkgbase":
            out["pkgbase"] = v
        elif k == "pkgname":
            out["pkgname"].append(v)
        elif k in ("provides", "depends", "makedepends", "checkdepends"):
            out[k].append(depname(v))
        elif k == "arch":
            out["arch"].append(v)
    if out["pkgbase"] is None and out["pkgname"]:
        out["pkgbase"] = out["pkgname"][0]
    return out


PKGBUILD_DUMP = r'''
CARCH=%s; CHOST=powerpc64le-unknown-linux-gnu
srcdir=/nonexistent; pkgdir=/nonexistent; startdir=$(dirname "$1")
source "$1" >/dev/null 2>&1 || exit 1
printf 'pkgbase\t%%s\n' "${pkgbase:-${pkgname[0]}}"
for v in "${pkgname[@]}";      do printf 'pkgname\t%%s\n' "$v"; done
for v in "${arch[@]}";         do printf 'arch\t%%s\n' "$v"; done
for v in "${provides[@]}";     do printf 'provides\t%%s\n' "$v"; done
for v in "${depends[@]}";      do printf 'depends\t%%s\n' "$v"; done
for v in "${makedepends[@]}";  do printf 'makedepends\t%%s\n' "$v"; done
for v in "${checkdepends[@]}"; do printf 'checkdepends\t%%s\n' "$v"; done
''' % CARCH


def _from_pkgbuild(path):
    out = {"pkgbase": None, "pkgname": [], "provides": [], "depends": [],
           "makedepends": [], "checkdepends": [], "arch": []}
    if not os.path.isfile(path):
        return out
    try:
        r = subprocess.run(["bash", "-c", PKGBUILD_DUMP, "_", path],
                           capture_output=True, text=True, timeout=60)
    except Exception:
        return out
    for line in r.stdout.splitlines():
        if "\t" not in line:
            continue
        k, v = line.split("\t", 1)
        v = v.strip()
        if not v:
            continue
        if k == "pkgbase":
            out["pkgbase"] = v
        elif k in ("pkgname", "arch"):
            out[k].append(v)
        else:
            out[k].append(depname(v))
    if out["pkgbase"] is None and out["pkgname"]:
        out["pkgbase"] = out["pkgname"][0]
    return out


def find_source(pkgbase, order):
    for sname in order:
        s = SOURCES[sname]
        if isinstance(s, DirSource) and s.available(pkgbase):
            return s
    # git sources cannot be probed cheaply; they are tried at materialise time
    for sname in order:
        if isinstance(SOURCES[sname], GitSource):
            return SOURCES[sname]
    return None


def satisfied_on_host(names):
    """Which of these the live system already provides.  Read-only, no root."""
    names = sorted({n for n in names if n})
    if not names:
        return set()
    out = set()
    for i in range(0, len(names), 400):          # keep the argv sane
        chunk = names[i:i + 400]
        try:
            r = subprocess.run(["pacman", "-T"] + chunk, capture_output=True,
                               text=True, timeout=300)
        except Exception:
            continue
        unmet = {x for x in r.stdout.split() if x}
        out.update(set(chunk) - unmet)
    return out


def resolve_order(targets, source_order, assume_installed=True):
    """Topologically sort targets by build-time dependency.

    makepkg will not do this.  Edges are drawn only *between targets* -- a
    dependency that Arch POWER already ships is a precondition, not a queue
    entry, so it constrains nothing about our ordering.

    The same argument applies one level in, and it is what makes the order
    useful rather than merely correct.  Across a whole distro's makedepends the
    graph is not a DAG at all: glibc, gcc, binutils, bash and ~400 others form
    one strongly-connected bootstrap core, because everything build-depends on
    the toolchain and the toolchain build-depends on everything.  But every one
    of those is *already installed on this host*, so it is a precondition too.
    Dropping edges to deps the host already satisfies collapses the bootstrap
    core and leaves an order that says something real about the packages we
    actually have to build.

    Pass assume_installed=False for a true from-scratch bootstrap ordering.
    """
    recipes = {}          # pkgbase -> recipe info
    provided_by = {}      # pkgname/provides -> pkgbase
    stage = os.path.join(BUILDROOT, "_meta")
    os.makedirs(stage, exist_ok=True)

    for t in targets:
        src = find_source(t, source_order)
        if src is None:
            continue
        d = os.path.join(stage, t)
        if not os.path.isdir(d) or not os.path.isfile(os.path.join(d, "PKGBUILD")):
            shutil.rmtree(d, ignore_errors=True)
            if not src.materialise(t, d):
                continue
        info = read_recipe(d)
        if not info["pkgname"]:
            continue
        info["source"] = src.name
        recipes[t] = info
        for n in info["pkgname"] + info["provides"]:
            provided_by.setdefault(n, t)

    present = set()
    if assume_installed:
        alldep = set()
        for info in recipes.values():
            alldep.update(info["depends"] + info["makedepends"]
                          + info["checkdepends"])
        present = satisfied_on_host(alldep)

    edges = {t: set() for t in recipes}
    for t, info in recipes.items():
        alldeps = info["depends"] + info["makedepends"] + info["checkdepends"]
        for d in alldeps:
            if d in present:
                continue          # already on the host: a precondition, not an edge
            owner = provided_by.get(d)
            if owner and owner != t:
                edges[t].add(owner)

    rdeps = defaultdict(set)
    for t, es in edges.items():
        for e in es:
            rdeps[e].add(t)

    def drain(ordered):
        ready = sorted(n for n in edges if not edges[n] and n not in ordered)
        while ready:
            n = ready.pop(0)
            if n in ordered:
                continue
            ordered.append(n)
            for r in sorted(rdeps[n]):
                edges[r].discard(n)
                if not edges[r] and r not in ordered and r not in ready:
                    ready.append(r)
                    ready.sort()
        return ordered

    ordered = drain([])

    # Whatever is left is either in a real cycle or merely downstream of one.
    # The distinction matters: at full scale a naive "everything not yet
    # ordered is cyclic" reported 595 of 622 packages as circular, which would
    # have silently degraded the queue to alphabetical order. Tarjan finds the
    # genuine strongly-connected components; each is cut at one member and the
    # drain resumes, so everything downstream of a cycle still gets a real
    # topological position.
    #
    # Bootstrap cycles are normal in a distro's makedepends (gcc needs gcc).
    # They are harmless here because the host already has those installed --
    # the ordering only has to be right for packages we do not have yet.
    real_cycles = []
    while True:
        stuck = [n for n in edges if n not in ordered]
        if not stuck:
            break
        comps = [c for c in tarjan({n: edges[n] & set(stuck) for n in stuck})
                 if len(c) > 1]
        if not comps:
            # no cycle left, yet something is unordered: cut the lowest name
            ordered.append(sorted(stuck)[0])
            edges[sorted(stuck)[0]] = set()
            ordered = drain(ordered)
            continue
        for c in comps:
            c = sorted(c)
            real_cycles.append(c)
            edges[c[0]] -= set(c)
        ordered = drain(ordered)

    return ordered, recipes, real_cycles


# ==========================================================================
# failure classification
# ==========================================================================
#
# A build log is only useful once it has been sorted into the handful of
# reasons a package actually fails on POWER.  Each class carries the fix, so
# the output is a work queue rather than a pile of logs.

CLASSES = [
    # Checked first: an undefined symbol reported *against a library in /usr* is
    # the distro's ABI mismatch, not our package's bug, and must not be filed
    # under anything else.  Found immediately: Arch POWER's libheif 1.23.1-1
    # wants de265_get_security_limits, which its own libde265 1.0.18-1 does not
    # export, so every package that links libheif fails to link.
    ("broken-system-dep",
     r"/usr/lib(64)?/lib[^:\s]+\.so[^:\s]*: undefined reference to",
     "A library already installed on the system has an unresolved symbol. "
     "This is an Arch POWER packaging bug, not ours -- build the missing "
     "provider first, or report it upstream."),

    ("prebuilt-binary-only",
     r"(x86[-_]64\.(tar|zip|AppImage)|linux-amd64|_amd64\.deb|"
     r"ELF 64-bit LSB .*x86-64|no such file or directory.*x86_64)",
     "Upstream ships an x86-64 binary, not source. Needs a from-source recipe, "
     "a FEX wrapper, or dropping."),

    ("march-native",
     r"(-march=native|unrecognized command[- ]line option '-march=|"
     r"bad value .*for -march=)",
     "PowerPC has no -march=. Substitute -mcpu=power9 (and -mtune=power9)."),

    ("float16-unavailable",
     r"(_Float16 is not supported on this target|"
     r"__fp16|cannot use type '_Float16')",
     "_Float16 is unavailable on ppc64le GCC. Guard the use, or build the "
     "generic path."),

    ("phantom-arch-macro",
     r"(__ppc64le__|__PPC64LE__)",
     "No compiler defines __ppc64le__ or __PPC64LE__, so this check can never "
     "fire. Real macros: __PPC64__, __powerpc64__, __LITTLE_ENDIAN__, "
     "_CALL_ELF == 2."),

    ("x86-asm",
     r"(emmintrin\.h|immintrin\.h|xmmintrin\.h|smmintrin\.h|tmmintrin\.h|"
     r"nmmintrin\.h|__m128|__m256|_mm_[a-z]|cpuid|impossible constraint in 'asm'|"
     r"unknown register name '%[er][a-d]x'|SSE2|AVX2?)",
     "Genuine x86 assembly or intrinsics. Needs a generic fallback, a VSX "
     "port, or the SIMD path disabled."),

    ("arch-gate",
     r"(is not available for the '.*' architecture|ERROR: .*architecture.*not "
     r"supported|arch=.*does not contain)",
     "arch=() does not list powerpc64le. Add it -- this is usually the only "
     "change needed."),

    ("missing-dep",
     r"(target not found|could not satisfy dependencies|Missing dependencies|"
     r"unable to find required package|No package '.*' found|"
     # meson and cmake phrase this their own ways, and neither resembles
     # pacman's wording -- both were classified `unknown` until they were seen.
     r"Could NOT find [A-Za-z0-9_+-]+|"
     r"ERROR: Dependency \"[^\"]+\" not found|"
     r"Run-time dependency [^\n]* found: NO|"
     r"Program [^\n]* found: NO)",
     "A build dependency is not present. Build it first, or add it to the "
     "queue."),

    ("checksum",
     r"(FAILED \(unknown public key|One or more files did not pass the "
     r"validity check|integrity checks .* differ)",
     "Source integrity failure. Refresh sums or import the signing key."),

    ("elf-pathguard",
     r"elf-pathguard: FAIL",
     "Shipped ELF records a build-tree path. Fix the recipe's rpath handling; "
     "do not ship it."),

    ("test-failure",
     r"(FAILED tests|Tests failed|check\(\) failed|[0-9]+ of [0-9]+ tests failed)",
     "check() failed. Triage separately -- often endianness in a test fixture, "
     "not the package."),
]


def classify(logpath):
    try:
        body = open(logpath, errors="replace").read()
    except OSError:
        return "unknown", "No log.", ""
    tail = body[-400000:]
    for name, pat, fix in CLASSES:
        m = re.search(pat, tail, re.I)
        if m:
            ln = tail[:m.start()].count("\n")
            line = tail.splitlines()[ln] if ln < len(tail.splitlines()) else ""
            return name, fix, line.strip()[:200]
    return "unknown", "Not matched by any known class -- read the log.", \
        "\n".join(tail.strip().splitlines()[-3:])[:200]


# ==========================================================================
# state
# ==========================================================================

def load_state():
    if os.path.isfile(STATE):
        try:
            return json.load(open(STATE))
        except Exception:
            pass
    return {"packages": {}, "queue": [], "started": None}


def save_state(st):
    tmp = STATE + ".tmp"
    json.dump(st, open(tmp, "w"), indent=2, sort_keys=True)
    os.replace(tmp, STATE)


# ==========================================================================
# the build itself
# ==========================================================================

def write_makepkg_conf(path, pkgdest, srcdest, logdest):
    """A makepkg.conf that inherits the system one and overrides only what the
    mass rebuild needs.

    !debug is the headline: debug packages measured 590 MiB against 338 MiB of
    real packages -- 1.75x -- and nothing in this queue is being debugged.
    """
    os.makedirs(pkgdest, exist_ok=True)
    os.makedirs(srcdest, exist_ok=True)
    os.makedirs(logdest, exist_ok=True)
    with open(path, "w") as fh:
        fh.write(
            "# generated by bq -- do not edit; see tools/bq.py\n"
            "source /etc/makepkg.conf\n"
            'PKGDEST="%s"\n'
            'SRCDEST="%s"\n'
            'LOGDEST="%s"\n'
            "# Drop debug packages for the mass rebuild: 1.75x the size of the\n"
            "# real packages, for symbols nobody is going to read.\n"
            "OPTIONS=(${OPTIONS[@]/debug/!debug})\n"
            "OPTIONS+=(!debug)\n"
            % (pkgdest, srcdest, logdest))


def bwrap_prefix(sysroot):
    """Stack a read-only overlay of our staged packages over /usr, unprivileged.

    This is how build dependencies appear without root and without touching the
    live system.  Environment variables alone are not enough -- plenty of
    builds hardcode /usr paths (obs-studio wants /usr/include/mbedtls3, valac
    and graphviz bake /usr into their binaries) -- so the staged tree has to
    show up *at the path it will eventually be installed to*.

    Order matters: the LAST --overlay-src is the topmost layer, so the live
    /usr goes first and the sysroot on top.  The other way round, a staged
    package that also exists in /usr is shadowed by the system copy, which is
    the opposite of the point.
    """
    if not shutil.which("bwrap") or not os.path.isdir(os.path.join(sysroot, "usr")):
        return []
    return ["bwrap", "--dev-bind", "/", "/",
            "--overlay-src", "/usr",
            "--overlay-src", os.path.join(sysroot, "usr"),
            "--ro-overlay", "/usr"]


def build_env(sysroot, bwrapped):
    e = dict(os.environ)
    e["LANG"] = e["LC_ALL"] = "C.UTF-8"
    su = os.path.join(sysroot, "usr")
    def pre(var, val):
        e[var] = val + (":" + e[var] if e.get(var) else "")
    pre("PKG_CONFIG_PATH", "%s/lib/pkgconfig:%s/share/pkgconfig" % (su, su))
    # Under the overlay the sysroot is already visible at /usr, so listing /usr
    # first makes CMake return paths that are still correct after install.
    # Without the overlay we have no choice but to point at the sysroot, and
    # elf-pathguard is what catches it if one of those paths gets baked in.
    pre("CMAKE_PREFIX_PATH", "/usr:" + su if bwrapped else su)
    pre("CPPFLAGS", "-I%s/include" % su)
    pre("LDFLAGS", "-L%s/lib -Wl,-rpath-link,%s/lib" % (su, su))
    pre("LIBRARY_PATH", "%s/lib" % su)
    pre("C_INCLUDE_PATH", "%s/include" % su)
    pre("CPLUS_INCLUDE_PATH", "%s/include" % su)
    pre("LD_LIBRARY_PATH", "%s/lib" % su)
    e["XDG_DATA_DIRS"] = "%s/share:/usr/share" % su
    e["PATH"] = "%s/bin:%s" % (su, e["PATH"])
    e["ELF_PATHGUARD"] = os.path.join(TOOLS, "elf-pathguard.sh")
    return e


def rehydrate_sysroot(st, order, args):
    """Re-stage everything this queue has already built into the sysroot.

    Resumption is not just "skip what is done".  The sysroot lives under the
    buildroot and a resumed run starts with an empty one, so a package whose
    dependency was built before the interruption would no longer find it --
    the queue would be resumable in bookkeeping and broken in fact.  Restaging
    from the repo is cheap (tar extraction) and makes a resumed run identical
    to an uninterrupted one.
    """
    done = [t for t in order if st["packages"].get(t, {}).get("status") == "ok"]
    if not done:
        return
    names, staged = [], set(st.get("staged", []))
    for t in done:
        for f in st["packages"][t].get("packages", []):
            if "-debug-" in f:
                continue
            # strip -<pkgver>-<pkgrel>-<arch>.pkg.tar.zst
            n = re.sub(r"-[^-]+-[^-]+-[^-]+\.pkg\.tar\.\w+$", "", f)
            if n:
                names.append(n)
    if names:
        sysroot_add(names, args.sysroot)
        staged.update(names)
        st["staged"] = sorted(staged)
        print("bq: restaged %d packages into %s" % (len(names), args.sysroot))


def preflight_deps(recipedir, staged):
    """Name the build dependencies the machine does not have, before building.

    `pacman -T` is read-only, needs no root, and answers exactly this question
    against the live local database.  Packages this run has already staged into
    the sysroot are satisfied too, and pacman cannot see those, so they are
    subtracted here.

    Without this, a missing makedepend surfaces halfway through a build as
    whatever meson or cmake chose to say about it -- `Could NOT find libSRTP`,
    `Dependency "bash-completion" not found` -- which is both slower and much
    harder to act on than a name.
    """
    info = read_recipe(recipedir)
    deps = sorted(set(info["depends"] + info["makedepends"] + info["checkdepends"]))
    deps = [d for d in deps if d and d not in staged]
    if not deps:
        return []
    try:
        r = subprocess.run(["pacman", "-T"] + deps, capture_output=True,
                           text=True, timeout=180)
    except Exception:
        return []
    return [d for d in r.stdout.split() if d and d not in staged]


def sysroot_add(names, sysroot):
    subprocess.run([os.path.join(TOOLS, "sysroot-add.sh")] + list(names),
                   capture_output=True, text=True, timeout=900,
                   env={**os.environ, "SYSROOT": sysroot})


def disk_free_gib(path):
    st = os.statvfs(path)
    return st.f_bavail * st.f_frsize / 2**30


def build_one(pkgbase, recipe_src, args, st):
    work = os.path.join(BUILDROOT, "build", pkgbase)
    logdir = os.path.join(BUILDROOT, "logs")
    os.makedirs(logdir, exist_ok=True)
    log = os.path.join(logdir, pkgbase + ".log")

    free = disk_free_gib(BUILDROOT)
    if free < args.min_free:
        return {"status": "deferred", "class": "disk",
                "detail": "only %.1f GiB free at %s" % (free, BUILDROOT)}

    shutil.rmtree(work, ignore_errors=True)
    src = SOURCES[recipe_src] if recipe_src in SOURCES else \
        find_source(pkgbase, args.sources.split(","))
    if src is None or not src.materialise(pkgbase, work):
        return {"status": "failed", "class": "no-recipe",
                "detail": "no recipe found in: " + args.sources}

    # An arch=() that omits us is a pre-build failure with a one-line fix; say
    # so instead of letting makepkg produce a confusing error.
    info = read_recipe(work)
    if info["arch"] and CARCH not in info["arch"] and "any" not in info["arch"]:
        if args.fix_arch:
            add_arch(os.path.join(work, "PKGBUILD"))
            regen_srcinfo(work)
        else:
            return {"status": "failed", "class": "arch-gate",
                    "detail": "arch=(%s)" % " ".join(info["arch"])}

    missing = preflight_deps(work, st.get("staged", []))
    if missing and args.strict_deps:
        return {"status": "failed", "class": "missing-dep",
                "detail": "not installed: " + " ".join(missing),
                "missing_deps": missing}

    conf = os.path.join(BUILDROOT, "makepkg.conf")
    write_makepkg_conf(conf, args.pkgdest or REPO,
                       os.path.join(BUILDROOT, "srcdest"), logdir)

    sysroot = args.sysroot
    pre = bwrap_prefix(sysroot)
    env = build_env(sysroot, bool(pre))

    cmd = pre + ["makepkg", "--config", conf, "-d", "--noconfirm",
                 "--needed", "--nocheck", "--log"]
    if args.force:
        cmd.append("-f")

    t0 = time.time()
    with open(log, "w") as fh:
        fh.write("$ %s\n(cwd %s)\n\n" % (" ".join(cmd), work))
        fh.flush()
        try:
            rc = subprocess.run(cmd, cwd=work, stdout=fh, stderr=subprocess.STDOUT,
                                env=env, timeout=args.timeout).returncode
        except subprocess.TimeoutExpired:
            fh.write("\n*** bq: timed out after %ds\n" % args.timeout)
            rc = 124
    dur = time.time() - t0

    result = {"seconds": round(dur, 1), "log": log}

    # elf-pathguard on every package built, whether or not the recipe adopted
    # the package() snippet.  Enforced here it runs after makepkg has already
    # written the archive, so a rejection has to quarantine rather than merely
    # report.
    guard = os.path.join(TOOLS, "elf-pathguard.sh")
    pkgdirs = []
    pkgroot = os.path.join(work, "pkg")
    if os.path.isdir(pkgroot):
        make_traversable(pkgroot)
        try:
            pkgdirs = [os.path.join(pkgroot, d) for d in sorted(os.listdir(pkgroot))
                       if os.path.isdir(os.path.join(pkgroot, d))]
        except OSError as e:
            with open(log, "a") as fh:
                fh.write("\nbq: cannot scan %s: %s\n" % (pkgroot, e))
    if rc == 0 and os.access(guard, os.X_OK) and pkgdirs:
        g = subprocess.run([guard] + pkgdirs, capture_output=True, text=True,
                           timeout=1800)
        with open(log, "a") as fh:
            fh.write("\n--- elf-pathguard ---\n" + g.stdout + g.stderr)
        if g.returncode != 0:
            rc = 90
            quarantine = os.path.join(BUILDROOT, "rejected")
            os.makedirs(quarantine, exist_ok=True)
            pl = subprocess.run(["makepkg", "--config", conf, "--packagelist"],
                                cwd=work, capture_output=True, text=True,
                                env=env, timeout=120)
            for f in pl.stdout.split():
                if os.path.isfile(f):
                    shutil.move(f, os.path.join(quarantine, os.path.basename(f)))

    built = []
    if rc == 0:
        pl = subprocess.run(["makepkg", "--config", conf, "--packagelist"],
                            cwd=work, capture_output=True, text=True,
                            env=env, timeout=120)
        built = [os.path.basename(f) for f in pl.stdout.split()
                 if os.path.isfile(f)]
        result["packages"] = built
        # Stage into the sysroot so the next package in the queue can link
        # against it, and fold it into the repo db.
        rinfo = read_recipe(work)
        names = list(rinfo["pkgname"])
        if names:
            sysroot_add(names, sysroot)
            staged = set(st.get("staged", []))
            staged.update(names)
            staged.update(rinfo["provides"])
            st["staged"] = sorted(staged)
        dest = args.pkgdest or REPO
        newfiles = [os.path.join(dest, b) for b in built
                    if "-debug-" not in b and os.path.isfile(os.path.join(dest, b))]
        if newfiles and args.repo_db:
            subprocess.run(["repo-add", "-q", "-n", "-R",
                            os.path.join(dest, args.repo_db)] + newfiles,
                           capture_output=True, text=True, timeout=600)

    # Clean as we go.  makepkg -c would drop src/ and pkg/; dropping the whole
    # per-package work directory is strictly more thorough and costs nothing,
    # because the recipe was copied in and the downloads live in the shared
    # SRCDEST.  Peak disk is therefore one package's build tree, not the sum:
    # naive accumulation across this queue would be ~130 GiB.
    peak = dir_size_gib(work)
    result["peak_gib"] = round(peak, 2)
    if not args.keep:
        subprocess.run(["makepkg", "--config", conf, "-c", "--noconfirm"],
                       cwd=work, capture_output=True, timeout=600, env=env)
        make_traversable(work)
        shutil.rmtree(work, ignore_errors=True)

    if missing:
        result["missing_deps"] = missing
    if rc == 0:
        result["status"] = "ok"
    else:
        cls, fix, line = classify(log)
        # The preflight already named them; that beats whatever the build
        # system said about it.
        if missing and cls in ("unknown", "missing-dep"):
            cls = "missing-dep"
            line = "not installed: " + " ".join(missing)
        if rc == 90:
            cls, fix = "elf-pathguard", dict((c[0], c[2]) for c in CLASSES)["elf-pathguard"]
        if rc == 124:
            cls, fix = "timeout", "Exceeded --timeout; re-run with a longer one."
        result.update(status="failed", rc=rc, **{"class": cls},
                      detail=line, fix=fix)
    return result


def make_traversable(path):
    """Restore our own read/traverse bits under `path`.

    package() runs under fakeroot, where a recipe can leave $pkgdir with modes
    that the real uid cannot read -- grim's does.  We own every inode here, so
    this is always permitted; without it both the pathguard scan and the
    cleanup fail with EACCES.
    """
    subprocess.run(["chmod", "-R", "u+rwX", path],
                   capture_output=True, timeout=600)


def dir_size_gib(path):
    total = 0
    for root, dirs, files in os.walk(path, onerror=lambda e: None):
        for f in files:
            try:
                total += os.lstat(os.path.join(root, f)).st_size
            except OSError:
                pass
    return total / 2**30


# ==========================================================================
# subcommands
# ==========================================================================

def cmd_plan(args):
    targets = read_targets(args)
    order, recipes, stuck = resolve_order(targets, args.sources.split(","),
                                         assume_installed=not args.full_bootstrap)
    missing = [t for t in targets if t not in recipes]
    q = {"order": order, "cycles": stuck, "missing_recipe": sorted(missing),
         "sources": {t: recipes[t].get("source") for t in order},
         "generated": time.strftime("%Y-%m-%dT%H:%M:%S")}
    out = args.out or os.path.join(BUILDROOT, "queue.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    json.dump(q, open(out, "w"), indent=2)
    st = load_state()
    st["queue"] = order
    save_state(st)
    print("planned %d packages -> %s" % (len(order), out))
    if stuck:
        print("  %d genuine dependency cycle(s), each cut at its first member:"
              % len(stuck))
        for c in stuck[:8]:
            shown = " <-> ".join(c[:6]) + (" <-> +%d more" % (len(c) - 6)
                                           if len(c) > 6 else "")
            print("      [%d] %s" % (len(c), shown))
    if missing:
        print("  %d with no recipe in [%s]: %s"
              % (len(missing), args.sources, " ".join(sorted(missing)[:10])))
    for i, t in enumerate(order, 1):
        print("%4d  %-34s %s" % (i, t, recipes[t].get("source", "?")))
    return 0


def read_targets(args):
    ts = []
    if args.targets_file:
        for line in open(args.targets_file):
            line = line.split("#")[0].strip()
            if line:
                ts.append(line.split()[0])
    ts.extend(args.targets)
    seen, out = set(), []
    for t in ts:
        if t not in seen:
            seen.add(t)
            out.append(t)
    return out


def cmd_build(args):
    qf = args.queue or os.path.join(BUILDROOT, "queue.json")
    if args.targets or args.targets_file:
        targets = read_targets(args)
        order, recipes, stuck = resolve_order(
            targets, args.sources.split(","),
            assume_installed=not getattr(args, "full_bootstrap", False))
        srcmap = {t: recipes[t].get("source") for t in order}
    elif os.path.isfile(qf):
        q = json.load(open(qf))
        order, srcmap = q["order"], q.get("sources", {})
    else:
        print("nothing to build: pass targets or run `bq plan` first", file=sys.stderr)
        return 2

    st = load_state()
    st.setdefault("packages", {})
    st["started"] = st.get("started") or time.strftime("%Y-%m-%dT%H:%M:%S")

    todo = []
    for t in order:
        prev = st["packages"].get(t, {})
        if prev.get("status") == "ok" and not args.rebuild:
            continue
        if prev.get("status") == "failed" and not (args.retry_failed or args.rebuild):
            continue
        todo.append(t)
    if args.limit:
        todo = todo[:args.limit]

    print("bq: %d/%d to build (buildroot %s, %.0f GiB free)"
          % (len(todo), len(order), BUILDROOT, disk_free_gib(BUILDROOT)))
    os.makedirs(args.sysroot, exist_ok=True)
    rehydrate_sysroot(st, order, args)
    save_state(st)

    ok = fail = 0
    peak = 0.0
    for i, t in enumerate(todo, 1):
        print("[%d/%d] %s ... " % (i, len(todo), t), end="", flush=True)
        try:
            r = build_one(t, srcmap.get(t), args, st)
        except Exception as exc:
            # An 858-package run cannot end because bq itself tripped over one
            # recipe.  Record it as a failure class of its own and carry on.
            import traceback
            r = {"status": "failed", "class": "bq-error",
                 "detail": "%s: %s" % (type(exc).__name__, exc),
                 "traceback": traceback.format_exc()[-2000:], "seconds": 0}
        r["when"] = time.strftime("%Y-%m-%dT%H:%M:%S")
        st["packages"][t] = r
        save_state(st)            # after every package: the run is resumable
        peak = max(peak, r.get("peak_gib", 0))
        if r["status"] == "ok":
            ok += 1
            print("ok  %.0fs  %s" % (r["seconds"], " ".join(r.get("packages", []))[:90]))
        else:
            fail += 1
            print("FAIL [%s] %.0fs  %s" % (r.get("class"), r.get("seconds", 0),
                                           r.get("detail", "")[:90]))
            if args.stop_on_fail:
                break
    print("\nbq: %d ok, %d failed, peak build tree %.2f GiB" % (ok, fail, peak))
    return 0 if fail == 0 else 1


def cmd_status(args):
    st = load_state()
    by = defaultdict(list)
    for n, r in sorted(st["packages"].items()):
        by[r.get("status", "?")].append(n)
    total = sum(len(v) for v in by.values())
    print("bq state: %d packages recorded (queue length %d)"
          % (total, len(st.get("queue", []))))
    for k in sorted(by):
        print("  %-10s %d" % (k, len(by[k])))
    secs = sum(r.get("seconds", 0) for r in st["packages"].values())
    print("  total build time: %.1f h" % (secs / 3600))
    if args.verbose:
        for n, r in sorted(st["packages"].items(), key=lambda x: -x[1].get("seconds", 0)):
            print("  %-30s %-8s %7.0fs %s" % (n, r.get("status"),
                                              r.get("seconds", 0), r.get("class", "")))
    return 0


def cmd_triage(args):
    st = load_state()
    groups = defaultdict(list)
    for n, r in sorted(st["packages"].items()):
        if r.get("status") == "failed":
            groups[r.get("class", "unknown")].append((n, r))

    fixes = {c[0]: c[2] for c in CLASSES}
    fixes.update({"no-recipe": "No recipe in any configured source.",
                  "timeout": "Exceeded --timeout.",
                  "disk": "Deferred for disk space.",
                  "unknown": "Unmatched -- read the log.",
                  "broken-system-dep": "An installed library has an unresolved "
                                       "symbol -- an Arch POWER bug, not ours.",
                  "bq-error": "bq itself failed on this recipe -- a queue bug, "
                              "not a package bug. See the recorded traceback."})

    lines = ["# bq work queue",
             "",
             "Generated %s from `.bq-state.json`. Grouped by failure class, "
             "because on POWER the class *is* the fix." % time.strftime("%Y-%m-%d %H:%M"),
             ""]
    order = [c[0] for c in CLASSES] + ["arch-gate", "no-recipe", "timeout",
                                       "disk", "bq-error", "unknown"]
    seen = set()
    for cls in order + sorted(groups):
        if cls in seen or cls not in groups:
            continue
        seen.add(cls)
        items = groups[cls]
        lines.append("## %s (%d)" % (cls, len(items)))
        lines.append("")
        lines.append(fixes.get(cls, ""))
        lines.append("")
        for n, r in items:
            lines.append("- **%s** — `%s`" % (n, (r.get("detail") or "").replace("`", "'")[:160]))
            lines.append("  - log: `%s`" % r.get("log", "?"))
        lines.append("")
    text = "\n".join(lines)
    out = args.out or os.path.join(OMARCHY, "docs/build-queue-triage.md")
    open(out, "w").write(text)
    json.dump({k: [n for n, _ in v] for k, v in groups.items()},
              open(os.path.splitext(out)[0] + ".json", "w"), indent=2)
    print(text if args.verbose else
          "wrote %s (%d classes, %d failures)"
          % (out, len(groups), sum(len(v) for v in groups.values())))
    return 0


def main():
    global BUILDROOT
    ap = argparse.ArgumentParser(prog="bq", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--buildroot", default=BUILDROOT)
    sub = ap.add_subparsers(dest="cmd", required=True)

    def common(p):
        p.add_argument("targets", nargs="*")
        p.add_argument("-f", "--targets-file")
        p.add_argument("--sources", default="local,archpower,gitlab",
                       help="recipe source priority (local,archpower,gitlab,aur)")

    p = sub.add_parser("plan", help="resolve build order")
    common(p)
    p.add_argument("-o", "--out")
    p.add_argument("--full-bootstrap", action="store_true",
                   help="order as if nothing were installed (from-scratch "
                        "bootstrap); by default deps the host already has are "
                        "treated as preconditions, not ordering constraints")
    p.set_defaults(fn=cmd_plan)

    p = sub.add_parser("build", help="build the queue in order")
    common(p)
    p.add_argument("-q", "--queue")
    p.add_argument("-n", "--limit", type=int)
    p.add_argument("--sysroot", default=None,
                   help="staging root for build deps (default <buildroot>/sysroot)")
    p.add_argument("--timeout", type=int, default=14400)
    p.add_argument("--min-free", type=float, default=20.0,
                   help="defer a package if the buildroot has less than this many GiB")
    p.add_argument("--retry-failed", action="store_true")
    p.add_argument("--rebuild", action="store_true")
    p.add_argument("--force", action="store_true")
    p.add_argument("--keep", action="store_true", help="do not clean build trees")
    p.add_argument("--stop-on-fail", action="store_true")
    p.add_argument("--fix-arch", action="store_true",
                   help="add powerpc64le to arch=() instead of failing")
    p.add_argument("--strict-deps", action="store_true",
                   help="skip a package whose declared build deps are absent, "
                        "rather than letting the build discover it")
    p.add_argument("--pkgdest", default=None,
                   help="where built packages go (default the Omarchy repo). "
                        "/etc/makepkg.conf points PKGDEST at the Omarchy repo, "
                        "so anything not part of that closure must set this.")
    p.add_argument("--full-bootstrap", action="store_true")
    p.add_argument("--repo-db", default="omarchy-ppc64le.db.tar.zst",
                   help="repo database to add into; empty to skip repo-add")
    p.set_defaults(fn=cmd_build)

    p = sub.add_parser("status", help="what has been built")
    p.add_argument("-v", "--verbose", action="store_true")
    p.set_defaults(fn=cmd_status)

    p = sub.add_parser("triage", help="emit the failure work queue")
    p.add_argument("-o", "--out")
    p.add_argument("-v", "--verbose", action="store_true")
    p.set_defaults(fn=cmd_triage)

    args = ap.parse_args()
    BUILDROOT = args.buildroot
    if getattr(args, "sysroot", None) is None and hasattr(args, "sysroot"):
        args.sysroot = os.path.join(BUILDROOT, "sysroot")
    if os.path.realpath(BUILDROOT).startswith(os.path.join(HOME, "Development")) \
            and "omarchy-ppc64le" not in BUILDROOT:
        print("bq: refusing to build inside a source checkout", file=sys.stderr)
        return 2
    os.makedirs(BUILDROOT, exist_ok=True)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
