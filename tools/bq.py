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

There is **one** local source of build scripts:

    packaging  omarchy-ppc64le-packaging/**/<pkgbase>/   ($OMARCHY_PACKAGING)

It is searched *recursively* and keyed by pkgbase, because the tree keeps most
recipes under category directories (kf6/, xorg/, python/, plasma/ and
twenty-odd more) and only ~1,900 of its ~4,570 pkgbases at the top level.

Arch POWER and Arch are sources we *import from*, not trees consulted at build
time.  `tools/fetch.sh` brings a new build script into the packaging tree, in
the right category, where it is reviewed and committed.  That is deliberate:
when three trees could each supply a recipe, the versions drifted silently
between builders -- the POWER8 box took KF6 6.30 from GitLab while the POWER9
box had built 6.29 from a tree, and 41 packages failed.

The git sources remain registered but are **not** in the default --sources, so
they are reachable only when asked for explicitly:

    gitlab     gitlab.archlinux.org/archlinux/packaging/packages/<pkgbase>
    aur        aur.archlinux.org/<pkgbase>.git   (the AUR triage front end)

Selection within a source is still by version, and a recipe older than the
version our repo database already ships is never selected without
--allow-downgrade.

The AUR source additionally rewrites `arch=()` and regenerates `.SRCINFO`.
That is not a nicety: libalpm enforces the architecture guard itself, so
`yay`/`paru` cannot be flagged past it -- the recipe has to be edited before
makepkg ever sees it.

Subcommands
-----------
  plan     resolve build order for a set of targets, write queue.json
  build    build the queue, in order, resumably; -j builds independent
           packages concurrently
  status   what has been built, what failed, and why
  triage   emit the failure work queue grouped by failure class

`build -j N` exists because most of a package's wall time is not compiling.
configure probes one feature at a time, autoreconf is serial, the final link is
one process, and so are strip and the zstd of the archive; on 176 threads the
box idles through all of it.  The queue already knows which packages depend on
each other, so the ones that do not can overlap.  Concurrency is off by default
(-j1 is byte-for-byte the old behaviour); see the "concurrency" section below
for how the sysroot, MAKEFLAGS and the state file are made safe under it.

Nothing here writes to /etc, installs into the live system, or builds inside a
source checkout.  See RULES.md.
"""

import os
import re
import sys
import json
import time
import fcntl
import shutil
import tarfile
import tempfile
import argparse
import functools
import threading
import subprocess
from collections import defaultdict

HOME = os.path.expanduser("~")
OMARCHY = os.path.join(HOME, "Development/omarchy-ppc64le")
# The one local source of build scripts.  A builder clones
# https://github.com/jbettcher-wg/omarchy-ppc64le-packaging and points
# OMARCHY_PACKAGING at it; the default is where a normal checkout lands, so a
# builder that follows the README needs no configuration at all.
PACKAGING = os.environ.get(
    "OMARCHY_PACKAGING",
    os.path.join(HOME, "Development/omarchy-ppc64le-packaging"))
TOOLS = os.path.join(OMARCHY, "tools")
# Where built packages land, and where sysroot-add/stage-deps look for "ours".
# BQ_REPO points a side build at its own package pool: a cross-target build
# (say the whole ROCm stack for someone else's POWER8 + gfx1030 box) must not
# read this repo's packages as its own dependencies -- it would link the
# queue's second entry against the first entry's POWER9/gfx1100 copy from
# repo/ -- and must not drop its output in repo/ either, where the filenames
# collide with ours.  Unset, everything behaves exactly as before.
# sysroot-add.sh and stage-deps.sh read the same variable.
REPO = os.environ.get("BQ_REPO", os.path.join(OMARCHY, "repo"))

# Build under /var/tmp by default (NVMe disk). Building under /tmp uses tmpfs
# RAM and exhausts memory/inodes on large package closures.
BUILDROOT = os.environ.get("BQ_BUILDROOT", "/var/tmp/omarchy-bq")
# Concurrent bq runs (a side build alongside a long queue) otherwise share one
# state file AND one temp path; the second os.replace() then fails with
# FileNotFoundError because the first already renamed the temp away, killing
# the run. BQ_STATE lets a side run isolate itself entirely.
STATE = os.environ.get("BQ_STATE", os.path.join(OMARCHY, ".bq-state.json"))
CARCH = "powerpc64le"

# The system makepkg.conf the generated buildroot config inherits.  It is a
# variable because the build host's /etc is not always the ppc64le one: under
# the POWERarm aarch64 sleeve, / is an aarch64 rootfs whose /etc/makepkg.conf
# carries CARCH=aarch64 and CFLAGS=-march=armv8-a, while the ppc64le config
# sits under the native root.  Sourcing the wrong one hands every package in
# the queue the wrong architecture's flags.  Drop-ins follow it: makepkg reads
# them from <config>.d, so the generated config globs
# <BQ_SYSTEM_MAKEPKG_CONF>.d/*.conf rather than a hardcoded /etc path.
SYSTEM_MAKEPKG_CONF = os.environ.get("BQ_SYSTEM_MAKEPKG_CONF",
                                     "/etc/makepkg.conf")

sys.path.insert(0, TOOLS)


# ==========================================================================
# concurrency
# ==========================================================================
#
# `bq build -j N` runs N packages at once.  The reason is not that makepkg is
# slow at compiling -- it is that a package spends a large fraction of its wall
# time doing something that cannot use 176 threads: ./configure probing one
# feature at a time, autoreconf, a single-threaded final link, `cargo` resolving,
# a test suite, `strip`, and zstd-compressing the archive.  Serially, the box
# idles through all of it.
#
# Four things have to be right for that to be safe, and each is handled at the
# place named:
#
#   order        Packages that depend on each other must not overlap, and a
#                package must not start before the sysroot can contain what it
#                needs.  resolve_order() already computes the edges; it now
#                returns them, cmd_plan() records them in queue.json, and
#                schedule_blockers() turns them into a wait-set.  A dependent is
#                released when its blocker *finishes*, pass or fail -- which is
#                exactly what the serial loop does when a package fails and it
#                moves on to the next one.
#
#   sysroot      Shared mutable state, and the hard part.  See Slot.
#
#   parallelism  MAKEFLAGS is divided, not duplicated: see CpuPool.  N jobs at
#                the system's -j144 would be 144N processes.
#
#   state file   .bq-state.json is written after every package so a run is
#                resumable.  Every mutation of `st` now happens under
#                _STATE_LOCK, and repo-add -- which takes its own .lck and fails
#                outright if a second one is running -- under _REPODB_LOCK plus
#                an flock, because a *second bq process* can be running too.
#
# --rebuild, --force and --retry-failed are untouched by any of this.

_STATE_LOCK = threading.RLock()     # every st[...] mutation + save_state()
_REPODB_LOCK = threading.Lock()     # repo-add, in this process
_PRINT_LOCK = threading.Lock()      # interleaved progress lines


def emit(line):
    with _PRINT_LOCK:
        sys.stdout.write(line + "\n")
        sys.stdout.flush()


def log(line):
    """Diagnostics go to stderr so stdout stays the queue listing."""
    with _PRINT_LOCK:
        sys.stderr.write(line + "\n")
        sys.stderr.flush()


def record(st, pkgbase, result):
    with _STATE_LOCK:
        st["packages"][pkgbase] = result
        save_state(st)


def note_staged(st, names):
    if not names:
        return
    with _STATE_LOCK:
        staged = set(st.get("staged", []))
        staged.update(n for n in names if n)
        st["staged"] = sorted(staged)


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

    def version_of(self, pkgbase):
        """The version this source would build, if it can be known without
        fetching.  A git source cannot, and says so."""
        return None

    def relpath_of(self, pkgbase):
        return None

    def ambiguous(self):
        return {}


class DirSource(Source):
    """A recipe tree already on disk.  Always copied out, never built in
    place -- building in a checkout is what leaves src/, pkg/ and stray
    tarballs scattered through it and makes the next `git pull` awkward.

    The tree is indexed once, recursively, by pkgbase.  It used to be probed
    as <root>/<pkgbase>/PKGBUILD, which found only the recipes a tree happens
    to keep at its top level -- and ~2,650 of the packaging tree's pkgbases
    live one and two levels down under kf6/, xorg/, python/, plasma/ and the
    rest.  Those ~180 that we actually queue were reported absent and quietly
    fetched from Arch's GitLab instead, which is how the POWER8 builder came to
    build KDE Frameworks 6.30 against our 6.29 and fail 41 packages."""

    def __init__(self, name, root):
        self.name = name
        self.root = root
        self._index = None
        self._ambiguous = None
        self._index_lock = threading.Lock()

    def _build_index(self):
        # Built into locals and published last, under a lock. This used to
        # assign `self._index = {}` BEFORE walking the tree, so with -j N every
        # slot but the first saw a non-None index, returned at once, and looked
        # its pkgbase up in a dict that was still empty: `no-recipe` in 0s for
        # all of them while the one slot doing the walk (or the last one
        # scheduled) succeeded. `plan` is single-threaded and -j 1 is serial,
        # so neither ever hit it.
        if self._index is not None:
            return
        with self._index_lock:
            if self._index is not None:
                return
            index, ambiguous = {}, {}
            for base, dirs in discover_recipes(self.root).items():
                if len(dirs) == 1:
                    index[base] = dirs[0]
                else:
                    # Two directories claim one pkgbase.  Never pick one: picking
                    # silently is the entire failure mode this indexing exists to
                    # remove, so record it and let the caller refuse.
                    ambiguous[base] = sorted(dirs)
            self._ambiguous = ambiguous
            self._index = index

    def index(self):
        self._build_index()
        return self._index

    def ambiguous(self):
        self._build_index()
        return self._ambiguous

    def path_of(self, pkgbase):
        return self.index().get(pkgbase)

    def relpath_of(self, pkgbase):
        d = self.path_of(pkgbase)
        return os.path.relpath(d, self.root) if d else None

    def version_of(self, pkgbase):
        return recipe_version(self.path_of(pkgbase))

    def available(self, pkgbase):
        return self.path_of(pkgbase) is not None

    def materialise(self, pkgbase, dest):
        src = self.path_of(pkgbase)
        if src is None:
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


_GITLAB_PINS = None


def gitlab_pins():
    """pkgbase -> the version to fetch from Arch's GitLab instead of its newest
    recipe.

    The gitlab source used to shallow-clone whatever Arch had that day. The
    POWER9 builder took KF6 6.29 on 2026-09-06; the POWER8 builder cloned the
    same repos on 09-14, got 6.30 (which needs ECM 6.30) and failed 41 builds,
    and silently built newer docker, gvfs, libadwaita and more. BQ_GITLAB_PINS
    names a file of "pkgbase version" lines -- the versions our repo shipped --
    so every builder fetches the same recipe and version bumps are deliberate.
    """
    global _GITLAB_PINS
    if _GITLAB_PINS is None:
        _GITLAB_PINS = {}
        path = os.environ.get("BQ_GITLAB_PINS")
        if path:
            for line in open(path):
                f = line.split()
                if len(f) >= 2 and not f[0].startswith("#"):
                    _GITLAB_PINS[f[0]] = f[1]
    return _GITLAB_PINS


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
        # A pkgbase that does not exist upstream answers 404, and git then
        # asks for a username -- which in an unattended 600-package run means
        # it blocks until the timeout. Fail fast instead.
        env = {**os.environ, "GIT_TERMINAL_PROMPT": "0",
               "GIT_ASKPASS": "", "SSH_ASKPASS": ""}
        cmd = ["git", "clone", "-q", "--depth", "1"]
        pin = gitlab_pins().get(pkgbase) if self.name == "gitlab" else None
        tag = None
        if pin:
            # Arch tags every release <pkgver>-<pkgrel>; an epoch's colon
            # becomes a dash (freerdp 2:3.31.1-1 -> 2-3.31.1-1).
            tag = pin.replace(":", "-")
            cmd += ["--branch", tag]
        r = subprocess.run(cmd + [url, tmp],
                           capture_output=True, text=True, timeout=600, env=env)
        if r.returncode != 0 or not os.path.isfile(os.path.join(tmp, "PKGBUILD")):
            if tag:
                # Never fall back to the newest recipe for a pinned package:
                # that is exactly the silent drift the pin exists to stop.
                print("bq: gitlab %s: pinned tag %s not fetched" % (pkgbase, tag),
                      file=sys.stderr)
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
    # PKGBUILDs quote these as often as not -- fzf ships arch=('x86_64') --
    # and an unstripped comparison never matches a quoted entry, so add_arch
    # appended an architecture that was already listed and makepkg rejected
    # the recipe with "arch can not contain duplicate values".
    have = [t.strip("'\"") for t in inner.split()]
    if carch in have or "any" in have:
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
                           capture_output=True, text=True, timeout=900)
        if r.returncode == 0 and r.stdout.strip():
            open(os.path.join(dest, ".SRCINFO"), "w").write(r.stdout)
            return True
    except Exception:
        pass
    return False


# One local source.  The git sources stay registered -- the AUR triage tool is
# this same engine with a different front end, and an explicit
# `--sources packaging,gitlab` is still how a one-off import gets tested -- but
# neither is in DEFAULT_SOURCES, so a normal build cannot silently fall through
# to a tree we do not curate.
SOURCES = {
    "packaging": DirSource("packaging", PACKAGING),
    "gitlab":    GitSource("gitlab",
                           "https://gitlab.archlinux.org/archlinux/packaging/packages/%s.git"),
    "aur":       GitSource("aur", "https://aur.archlinux.org/%s.git",
                           rewrite_arch=True),
}

DEFAULT_SOURCES = "packaging"


# ==========================================================================
# recipe metadata + ordering
# ==========================================================================

# Tarjan lives in closure.py; the two tools share one graph implementation
# rather than each growing its own.  discover_recipes is there for the same
# reason: closure.py, bq and recipe-sync must agree on what a recipe tree
# contains, or they disagree about which packages exist.
from closure import tarjan, discover_recipes  # noqa: E402

VERSTRIP = re.compile(r"[<>=]+.*$")


def depname(s):
    return VERSTRIP.sub("", s.split(":")[0].strip()).strip()


def read_recipe(recipedir):
    """pkgnames, provides, and *build-time* deps for one recipe directory."""
    si = os.path.join(recipedir, ".SRCINFO")
    if os.path.isfile(si):
        info = _from_srcinfo(si)
        # Arch POWER's tree carries Arch's own .SRCINFO beside a PKGBUILD it has
        # edited, and does not regenerate it: acl's PKGBUILD says
        # arch=(x86_64 powerpc64le ...) while its .SRCINFO still says only
        # x86_64. Trusting that sent valid recipes to the arch gate at 0s (acl,
        # bison, cfitsio ... on the POWER8 builder) -- and a stale arch list
        # means the dependency lists in it are just as suspect. A .SRCINFO that
        # does not name this architecture is stale for our purposes: read the
        # PKGBUILD instead, which is what makepkg will actually build.
        if info["pkgname"] and (not info["arch"] or CARCH in info["arch"]
                                or "any" in info["arch"]):
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


_PKGBASE = None


def pkgbase_of(name):
    """Map a package name to its pkgbase.

    The closure is a list of *package names*; recipe repositories are keyed by
    *pkgbase*.  Most of the time they are equal, and when they are not the
    difference is invisible until a fetch 404s -- `adwaita-cursors` is built by
    `adwaita-icon-theme`, and there is no adwaita-cursors.git to clone.  The
    sync DB records the mapping in %BASE%, so use it.
    """
    global _PKGBASE
    if _PKGBASE is None:
        _PKGBASE = {}
        try:
            from closure import load_sync
            for n, p in load_sync().items():
                _PKGBASE[n] = p.base
        except Exception:
            pass
    return _PKGBASE.get(name, name)


_LITERAL_VER = re.compile(r"^[A-Za-z0-9._+~]+$")
_VER_ASSIGN = re.compile(r"^(pkgver|pkgrel|epoch)=(.*?)\s*(?:#.*)?$")


def _literal_versions(pkgbuild):
    """pkgver/pkgrel/epoch exactly as written, for the ones that are a plain
    literal assigned exactly once.  A VCS recipe computes pkgver in pkgver(),
    and a recipe that assigns one twice is conditional; both are reported
    unknown rather than guessed at, because a wrong version here would either
    skip a real update or trip the never-downgrade guard on a phantom."""
    try:
        body = open(pkgbuild, encoding="utf-8", errors="replace").read()
    except OSError:
        return {}
    seen, out = defaultdict(int), {}
    for ln in body.splitlines():
        m = _VER_ASSIGN.match(ln)
        if not m:
            continue                      # indented => inside a function
        seen[m.group(1)] += 1
        out[m.group(1)] = m.group(2).strip().strip("'\"")
    for k, n in list(seen.items()):
        if n > 1 or not _LITERAL_VER.match(out.get(k, "")):
            out.pop(k, None)
    return out


_SRCINFO_VER_CACHE = {}


def _srcinfo_versions(recipedir):
    """pkgver/pkgrel/epoch from a .SRCINFO, as a complete set or not at all."""
    si = os.path.join(recipedir, ".SRCINFO")
    if not os.path.isfile(si):
        return {}
    out = {}
    for ln in open(si, encoding="utf-8", errors="replace"):
        k, _, val = ln.partition("=")
        k, val = k.strip(), val.strip()
        if k in ("pkgver", "pkgrel", "epoch") and val and k not in out:
            out[k] = val
    return out


def _printsrcinfo_versions(recipedir):
    """Ask makepkg what the recipe actually computes, in a throwaway copy.

    A recipe whose pkgver is computed (qt6's pkgver=${_pkgver/-/}) has no
    literal to read, and its .SRCINFO is only as fresh as the last person to
    regenerate one.  Sourcing is the only way to get the real answer, so do it
    on a copy: nothing is written back beside the recipe, the same rule
    recipe-sync.py follows."""
    if recipedir in _SRCINFO_VER_CACHE:
        return _SRCINFO_VER_CACHE[recipedir]
    out = {}
    tmp = None
    try:
        tmp = tempfile.mkdtemp(prefix="bq-srcinfo.", dir=BUILDROOT
                               if os.path.isdir(BUILDROOT) else None)
        dest = os.path.join(tmp, os.path.basename(recipedir))
        shutil.copytree(recipedir, dest, symlinks=True)
        # A stale .SRCINFO in the copy is what we are trying to get away from.
        try:
            os.unlink(os.path.join(dest, ".SRCINFO"))
        except OSError:
            pass
        r = subprocess.run(["makepkg", "--config", SYSTEM_MAKEPKG_CONF,
                            "--printsrcinfo"], cwd=dest, capture_output=True,
                           text=True, timeout=120)
        if r.returncode == 0:
            for ln in (r.stdout or "").splitlines():
                k, _, val = ln.partition("=")
                k, val = k.strip(), val.strip()
                if k in ("pkgver", "pkgrel", "epoch") and val and k not in out:
                    out[k] = val
    except Exception:
        out = {}
    finally:
        if tmp:
            shutil.rmtree(tmp, ignore_errors=True)
    _SRCINFO_VER_CACHE[recipedir] = out
    return out


def recipe_version(recipedir):
    """epoch:pkgver-pkgrel for a recipe directory, or None if it cannot be
    determined.

    The PKGBUILD is authoritative.  Where it does not spell the version out --
    a computed pkgver -- ask makepkg rather than reading the .SRCINFO beside
    it, because Arch POWER edits a PKGBUILD and leaves Arch's .SRCINFO
    un-regenerated, so the .SRCINFO can name a version nothing will build.

    The three sources are never mixed.  They used to be: the fallback filled
    only the keys the PKGBUILD had not supplied, so qt6-declarative -- literal
    pkgrel=2, computed pkgver, .SRCINFO left at 6.11.1-3 -- resolved to
    6.11.1-2, a version in neither file.  Being below the 6.11.2-2 in the pool,
    it tripped the never-downgrade guard and the package silently left the
    queue as missing_recipe.  Thirty-three recipes in the 2026-09-23 baseline
    rebuild were in that state, most of qt6 among them."""
    if not recipedir:
        return None
    v = _literal_versions(os.path.join(recipedir, "PKGBUILD"))
    if "pkgver" not in v or "pkgrel" not in v:
        v = _printsrcinfo_versions(recipedir) or _srcinfo_versions(recipedir)
    if "pkgver" not in v:
        return None
    ver = "%s-%s" % (v["pkgver"], v.get("pkgrel", "1"))
    return "%s:%s" % (v["epoch"], ver) if v.get("epoch") else ver


_VERCMP_CACHE = {}


def vercmp(a, b):
    """pacman's own version comparison: negative, zero or positive.

    Not a string or tuple compare.  The cases in this tree that break a naive
    one are all real: epochs (freerdp 2:3.31.1-1), fractional pkgrels that
    Arch POWER uses for its rebuilds (libsasl 2.1.28-5.1 against 2.1.28-5.3),
    and gcc's +r346+g4e03491b401d snapshot versions."""
    if a == b:
        return 0
    if not a or not b:
        return 0
    key = (a, b)
    if key not in _VERCMP_CACHE:
        try:
            r = subprocess.run(["vercmp", a, b], capture_output=True,
                               text=True, timeout=60)
            _VERCMP_CACHE[key] = int((r.stdout or "0").strip() or 0)
        except Exception:
            _VERCMP_CACHE[key] = 0
    return _VERCMP_CACHE[key]


_SHIPPED = None


def shipped_versions():
    """pkgbase -> the newest version our repo database already ships.

    This is the floor for recipe selection.  The standing rule is that we do
    not downgrade for parity -- we want to be ahead of, or at worst level
    with, Arch POWER -- so a recipe that would take a package backwards is
    refused rather than quietly queued."""
    global _SHIPPED
    if _SHIPPED is not None:
        return _SHIPPED
    _SHIPPED = {}
    # Every repo database in the pool, merged, newest version per pkgbase --
    # not the first one that opens.  repo/ holds two, and they are different
    # kinds of thing: the *published* omarchy-power9.db.tar.gz, and
    # bq-staging.db.tar.zst, which is bq's own working database (--repo-db)
    # for packages built but not published yet.  Both are a floor -- a package
    # is shipped whether it went out in the published db or is sitting here
    # staged -- so both are read.  Reading either one alone gives a floor with
    # holes in it, and a hole in the floor is a silent downgrade: kconfig, kio,
    # libxcb, rust and gcc all read as "never shipped" against the smaller db.
    #
    # The staging db is deliberately NOT named for a pool.  It used to be
    # called omarchy-ppc64le.db.tar.zst, which now names the *baseline package
    # pool* (repo-ppc64le/, published as [omarchy-ppc64le]) -- two unrelated
    # things under one name.  Nothing here treats bq-staging as published:
    # repo-publish.sh and repo-r2-sync.sh both act on $REPO_NAME.db.tar.gz.
    env = os.environ.get("BQ_REPO_DB")
    if env:
        cands = [env]
    else:
        cands = []
        try:
            for fn in sorted(os.listdir(REPO)):
                # the live databases only -- not .bak.<stamp>, .old or .bqlck
                if re.match(r"^[A-Za-z0-9._+-]+\.db\.tar\.(zst|gz|xz)$", fn):
                    cands.append(os.path.join(REPO, fn))
        except OSError:
            pass
    for path in cands:
        if not path or not os.path.isfile(path):
            continue
        try:
            with tarfile.open(path) as t:
                for m in t:
                    if not m.isfile() or not m.name.endswith("/desc"):
                        continue
                    fields, key = defaultdict(list), None
                    body = t.extractfile(m).read().decode("utf-8", "replace")
                    for ln in body.splitlines():
                        if len(ln) > 2 and ln.startswith("%") and ln.endswith("%"):
                            key = ln[1:-1]
                        elif key and ln.strip():
                            fields[key].append(ln.strip())
                    name = (fields.get("NAME") or [None])[0]
                    ver = (fields.get("VERSION") or [None])[0]
                    if not name or not ver:
                        continue
                    base = (fields.get("BASE") or [name])[0]
                    if base not in _SHIPPED or vercmp(ver, _SHIPPED[base]) > 0:
                        _SHIPPED[base] = ver
        except Exception as e:
            log("bq: could not read repo db %s: %s" % (path, e))
            continue
    return _SHIPPED


_RESOLVED = {}
_RESOLVE_LOCK = threading.Lock()


def resolve_recipe(pkgbase, order, allow_downgrade=False):
    """Pick one recipe for a pkgbase, and say out loud where it came from.

    Selection is by *version*, not by fixed source order.  Source order used
    to decide it, which meant an Arch POWER recipe shadowed a newer one of
    ours (or the reverse) purely because of where it sat in --sources.  Now
    the newest recipe wins and the packaging tree breaks a tie, so our patched
    copy is preferred over an upstream one at the same version.

    Two things are refused rather than guessed:
      * a pkgbase that two directories in one tree both claim, and
      * a recipe older than what our repo database already ships.

    Returns (Source or None, recipe directory or None, version or None), and
    logs the decision so a fall-through to GitLab is never silent again.
    """
    key = (pkgbase, tuple(order), bool(allow_downgrade))
    with _RESOLVE_LOCK:
        if key in _RESOLVED:
            sname, path, ver = _RESOLVED[key]
            return (SOURCES[sname] if sname else None), path, ver

    shipped = shipped_versions().get(pkgbase)
    cands = []
    for i, sname in enumerate(order):
        s = SOURCES.get(sname)
        if not isinstance(s, DirSource):
            continue
        amb = s.ambiguous().get(pkgbase)
        if amb:
            log("bq: recipe %s: AMBIGUOUS in %s -- %s -- refusing this source"
                % (pkgbase, sname,
                   ", ".join(os.path.relpath(d, s.root) for d in amb)))
            continue
        d = s.path_of(pkgbase)
        if d is not None:
            # tie-break 0 for the packaging tree, then the order the caller gave
            cands.append((s.version_of(pkgbase),
                          0 if sname == "packaging" else i + 1, sname, d))

    def _cmp(a, b):
        va, vb = a[0], b[0]
        if va and vb:
            c = vercmp(vb, va)              # newest first
            if c:
                return c
        elif va != vb:
            return -1 if va else 1          # a known version beats an unknown
        return a[1] - b[1]

    cands.sort(key=functools.cmp_to_key(_cmp))

    chosen = None
    for ver, _tb, sname, d in cands:
        if (shipped and ver and not allow_downgrade
                and vercmp(ver, shipped) < 0):
            log("bq: recipe %s: REFUSED %s %s (%s) -- older than the %s we "
                "ship; --allow-downgrade overrides"
                % (pkgbase, sname, ver,
                   os.path.relpath(d, SOURCES[sname].root), shipped))
            continue
        chosen = (sname, d, ver)
        break

    if chosen is None:
        # git sources cannot be probed cheaply; they are tried at materialise
        # time.  Reaching one is a real event -- it means no tree we control
        # supplied this recipe -- so it gets a line of its own.
        for sname in order:
            if isinstance(SOURCES.get(sname), GitSource):
                why = ("no directory recipe" if not cands else
                       "every directory recipe was older than the %s we ship"
                       % shipped)
                log("bq: recipe %-30s -> %-9s (%s)" % (pkgbase, sname, why))
                chosen = (sname, None, None)
                break

    if chosen is None:
        log("bq: recipe %s: no source in [%s]" % (pkgbase, ",".join(order)))
        chosen = (None, None, None)
    elif chosen[1]:
        sname, d, ver = chosen
        log("bq: recipe %-30s -> %-9s %-40s %s"
            % (pkgbase, sname, os.path.relpath(d, SOURCES[sname].root),
               ver or "?"))

    with _RESOLVE_LOCK:
        _RESOLVED[key] = chosen
    sname, path, ver = chosen
    return (SOURCES[sname] if sname else None), path, ver


def find_source(pkgbase, order, allow_downgrade=False):
    src, _path, _ver = resolve_recipe(pkgbase, order, allow_downgrade)
    return src


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


def resolve_order(targets, source_order, assume_installed=True,
                  allow_downgrade=False):
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
        base = pkgbase_of(t)
        src, rpath, rver = resolve_recipe(base, source_order, allow_downgrade)
        if src is None:
            continue
        d = os.path.join(stage, base)
        if not os.path.isdir(d) or not os.path.isfile(os.path.join(d, "PKGBUILD")):
            shutil.rmtree(d, ignore_errors=True)
            if not src.materialise(base, d):
                continue
        info = read_recipe(d)
        if not info["pkgname"]:
            continue
        info["source"] = src.name
        # Where the recipe actually came from, carried into queue.json: with a
        # nested tree "archpower" alone no longer says which recipe was read.
        info["recipe_path"] = rpath and os.path.relpath(rpath, src.root)
        info["version"] = rver
        # Key the queue by pkgbase: one build produces every split package, so
        # listing them separately would build the same recipe several times.
        recipes[base] = info
        for n in info["pkgname"] + info["provides"]:
            provided_by.setdefault(n, base)

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

    # Snapshot before draining: drain() and the cycle cutter below both mutate
    # `edges` down to nothing, and `bq build -j` needs the real graph to know
    # which packages may overlap.
    deps = {t: set(es) for t, es in edges.items()}

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

    return ordered, recipes, real_cycles, provided_by, deps


def schedule_blockers(order, deps, todo):
    """Which of `todo` each entry of `todo` must wait for.

    The scheduler cannot simply use `deps`: resolve_order() cuts genuine
    dependency cycles to produce an order at all, so `deps` can contain edges
    that point *forward* in the order.  Waiting on those would deadlock, and
    honouring them is not even correct-by-serial-standards -- the serial loop
    builds in `order`, so a dependency positioned later was not available to it
    either.  Keeping only the edges that point backwards in `order` therefore
    makes the parallel run see exactly the same sysroot contents the serial run
    saw, and is acyclic by construction because it is a subset of a total order.

    Dependencies that are not in `todo` are already built and sitting in repo/,
    where stage-deps finds them; they constrain nothing.
    """
    pos = {t: i for i, t in enumerate(order)}
    pending = set(todo)
    return {t: {d for d in deps.get(t, ())
                if d in pending and pos.get(d, len(pos)) < pos.get(t, 0)}
            for t in todo}


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

    ("pkg-pathguard",
     r"pkg-pathguard: .* installs outside the standard roots",
     "Package installs to an absolute sysroot path instead of $pkgdir -- a "
     "build system took a directory from a .pc whose prefix still pointed at "
     "the sysroot. Fix the recipe's DESTDIR/prefix handling; do not ship it."),

    ("test-failure",
     r"(FAILED tests|Tests failed|check\(\) failed|[0-9]+ of [0-9]+ tests failed)",
     "check() failed. Triage separately -- often endianness in a test fixture, "
     "not the package."),
]


def _elf_pathguard_fix(line):
    """The fix for an elf-pathguard FAIL line depends on what it caught."""
    if "in a file other builds read" in line:
        return ("A .pc, *-config, CMake or Makefile fragment records a build-tree "
                "or sysroot path, and downstream builds read it. This is not an "
                "rpath problem: find what consumes the variable, then scrub it in "
                "package() -- e.g. qt6-base's QT_SOURCE_TREE, which "
                "Qt6BuildInternalsConfig.cmake prepends to CMAKE_MODULE_PATH "
                "whenever the path exists.")
    if "in shebang" in line or "interpreter outside /usr" in line:
        return ("A script's #! line points into the build tree. Fix the "
                "interpreter the build substitutes (usually a python/perl "
                "path taken from the sysroot) in the recipe; do not ship it.")
    return None      # an ELF finding: the class's rpath advice is right


# Per-guard refinements of the canned CLASSES fix text, keyed by guard name.
# Each takes the guard's FAIL line and returns a fix, or None to keep the
# canned one.
GUARD_FIXES = {"elf-pathguard": _elf_pathguard_fix}


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
    # Per-pid temp: a shared ".tmp" makes concurrent runs race, and the loser
    # dies on os.replace() of a file the winner already renamed.
    tmp = "%s.tmp.%d" % (STATE, os.getpid())
    json.dump(st, open(tmp, "w"), indent=2, sort_keys=True)
    os.replace(tmp, STATE)


# ==========================================================================
# the build itself
# ==========================================================================

def write_makepkg_conf(path, pkgdest, srcdest, logdest, make_jobs=None,
                       ccache=False):
    """A makepkg.conf that inherits the system one and overrides only what the
    mass rebuild needs.

    !debug is the headline: debug packages measured 590 MiB against 338 MiB of
    real packages -- 1.75x -- and nothing in this queue is being debugged.

    make_jobs overrides /etc/makepkg.conf's MAKEFLAGS for one concurrency slot.
    It has to be written here rather than exported, because makepkg *sets*
    MAKEFLAGS from the config file and would overwrite an inherited one.
    """
    if not os.path.isfile(SYSTEM_MAKEPKG_CONF):
        sys.exit("bq: system makepkg.conf not found: %s\n"
                 "    set BQ_SYSTEM_MAKEPKG_CONF to the ppc64le one."
                 % SYSTEM_MAKEPKG_CONF)
    os.makedirs(pkgdest, exist_ok=True)
    os.makedirs(srcdest, exist_ok=True)
    os.makedirs(logdest, exist_ok=True)
    with open(path, "w") as fh:
        fh.write(
            "# generated by bq -- do not edit; see tools/bq.py\n"
            "source %s\n"
            "# makepkg reads drop-ins from <config>.d, i.e. beside THIS file --\n"
            "# not beside the system makepkg.conf we just sourced. Without these\n"
            "# two lines its .d/*.conf never applied to a bq build, so\n"
            "# rust.conf's RUSTFLAGS (-C target-cpu=pwr9) was silently missing from\n"
            "# every Rust package in the repo, and fortran.conf likewise. Found\n"
            "# 2026-09-11 while packaging rust 1.98.1: the shipped compiler had\n"
            "# 495,742 POWER9-only instructions, the repo's other Rust binaries none.\n"
            "for _d in %s.d/*.conf; do\n"
            "  [ -r \"$_d\" ] && source \"$_d\"\n"
            "done\n"
            "unset _d\n"
            'PKGDEST="%s"\n'
            'SRCDEST="%s"\n'
            'LOGDEST="%s"\n'
            "# Drop debug packages for the mass rebuild: 1.75x the size of the\n"
            "# real packages, for symbols nobody is going to read.\n"
            "# makepkg takes the last occurrence, so appending is enough. Do not\n"
            "# rewrite the array: ${OPTIONS[@]/debug/!debug} turns an existing\n"
            "# !debug into !!debug and makepkg errors on every single build.\n"
            "OPTIONS+=(!debug)\n"
            % (SYSTEM_MAKEPKG_CONF, SYSTEM_MAKEPKG_CONF,
               pkgdest, srcdest, logdest))
        if ccache:
            # /etc/makepkg.conf ships BUILDENV=(… !ccache …) and must not be
            # edited, so turn it on here.  This works because makepkg's
            # in_opt_array() walks the array *backwards* and returns on the
            # first hit, so the last occurrence wins -- exactly the mechanism
            # OPTIONS+=(!debug) above relies on.  Verified rather than assumed:
            # a build with this line moves ccache's own hit/miss counters, and
            # without it they stay at zero.
            #
            # What makepkg then does is prepend /usr/lib/ccache/bin to PATH,
            # where cc/gcc/g++/clang are symlinks to ccache.  That directory is
            # on the host /usr, which the bwrap overlay stacks *under* the
            # sysroot, so it stays visible -- and because it is only a PATH
            # entry, ccache still resolves the real compiler through the
            # overlay and will pick a staged gcc over the host one if a package
            # staged one.
            fh.write("BUILDENV+=(ccache)\n")
        if make_jobs:
            # Written AFTER the sourcing above, so it beats the system config's
            # -j144 and any drop-in.  NINJAFLAGS is set for the recipes that
            # honour it; the taskset pin in Slot.wrap() is what actually holds
            # the line for the ones that do not.
            fh.write(
                '# bq -j: this slot\'s share of the machine.\n'
                'MAKEFLAGS="-j%d"\n'
                'NINJAFLAGS="-j%d"\n'
                'export CARGO_BUILD_JOBS=%d\n' % (make_jobs, make_jobs, make_jobs))


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

    `sysroot` may be a list, for -j: several sysroot layers stack in the same
    bottom-to-top order.  See Slot.
    """
    layers = [sysroot] if isinstance(sysroot, str) else list(sysroot)
    # The topmost layer is the one this build stages into. On a fresh buildroot
    # with an empty package pool nothing has been staged yet, so its usr/ does
    # not exist -- and a missing usr/ used to mean no overlay at all: the build
    # ran bare, with the -isystem/-L fallback in build_env(). Found on the POWER8
    # builder (repo-ppc64le starts empty): 7zip got "-isystem A:-isystem B" and
    # failed, alsa-lib's configure could not link, bash baked the sysroot into
    # Makefile.inc. An empty upper layer is a valid overlay source; create it.
    if layers:
        os.makedirs(os.path.join(layers[-1], "usr"), exist_ok=True)
    layers = [l for l in layers if os.path.isdir(os.path.join(l, "usr"))]
    if not shutil.which("bwrap") or not layers:
        return []
    cmd = ["bwrap", "--dev-bind", "/", "/", "--overlay-src", "/usr"]
    for l in layers:
        cmd += ["--overlay-src", os.path.join(l, "usr")]
    cmd += ["--ro-overlay", "/usr"]
    # The whole ROCm stack installs under /opt/rocm, not /usr, and every
    # package in it finds the previous one by that absolute path (hsa-rocr
    # runs /opt/rocm/lib/llvm/bin/clang, rocminfo and hip-runtime do
    # find_package against /opt/rocm/lib/cmake).  sysroot-add extracts the
    # staged opt/ tree just fine; without this second overlay it was simply
    # never visible, and rocminfo would have linked the host's 6.2.4 hsa-rocr
    # instead of the 7.2.4 built two queue entries earlier.  Same layering
    # rule as /usr: live /opt below, staged /opt on top.
    opt = [l for l in layers if os.path.isdir(os.path.join(l, "opt"))]
    if opt:
        cmd += ["--overlay-src", "/opt"]
        for l in opt:
            cmd += ["--overlay-src", os.path.join(l, "opt")]
        cmd += ["--ro-overlay", "/opt"]
    return cmd


def build_env(sysroot, bwrapped):
    e = dict(os.environ)
    e["LANG"] = e["LC_ALL"] = "C.UTF-8"
    # perl's scripts (pod2man, pod2text, ...) live in /usr/bin/{site,vendor,
    # core}_perl, which only /etc/profile.d/perlbin.sh adds to PATH. A queue
    # started from a non-login shell (ssh host 'cmd', setsid, systemd) never
    # sources it, and ffmpeg's doc build died on "pod2man: command not found"
    # on the POWER8 builder while the login shell on the POWER9 host was fine.
    _path = e.get("PATH", "/usr/local/bin:/usr/bin").split(":")
    e["PATH"] = ":".join(_path + [d for d in ("/usr/bin/site_perl", "/usr/bin/vendor_perl",
                                              "/usr/bin/core_perl") if d not in _path])
    layers = [sysroot] if isinstance(sysroot, str) else list(sysroot)
    sus = [os.path.join(l, "usr") for l in layers]   # bottom layer first
    su = sus[-1]                                     # topmost
    def pre(var, val):
        # CPPFLAGS/LDFLAGS are word lists; everything else here is a ':' path
        # list. Joining flags with ':' turned two layers' "-isystem A" and
        # "-isystem B" into "-isystem A:-isystem B", so B reached cc as a bare
        # "linker input file".
        sep = " " if var in ("CPPFLAGS", "CFLAGS", "CXXFLAGS", "LDFLAGS") else ":"
        e[var] = val + (sep + e[var] if e.get(var) else "")
    # Same split as CMAKE_PREFIX_PATH below. Under the overlay the staged .pc
    # files are already at /usr/lib/pkgconfig, and pointing at the raw sysroot
    # instead makes pkg-config answer every query with -I<sysroot>/usr/include
    # and -L<sysroot>/usr/lib. Those land in the generated Makefiles, get baked
    # into the .pc and *-config scripts a package installs, and -- because a
    # plain -I is not a system directory -- turn warnings inside glibc's own
    # headers into errors for anything built -pedantic -Werror (xmlsec).
    pre("PKG_CONFIG_PATH",
        "/usr/lib/pkgconfig:/usr/share/pkgconfig" if bwrapped
        else ":".join("%s/lib/pkgconfig:%s/share/pkgconfig" % (s, s)
                      for s in reversed(sus)))
    # Under the overlay the sysroot is already visible at /usr, so listing /usr
    # first makes CMake return paths that are still correct after install.
    # Without the overlay we have no choice but to point at the sysroot, and
    # elf-pathguard is what catches it if one of those paths gets baked in.
    pre("CMAKE_PREFIX_PATH",
        "/usr:" + su if bwrapped else ":".join(reversed(sus)))
    # Same reasoning as CMAKE_PREFIX_PATH above: under the overlay the sysroot
    # IS /usr, so these are redundant -- and worse, they get baked into what
    # gets shipped. perl records -Wl,-rpath-link,<sysroot>/lib as a RUNPATH on
    # its DBM modules (elf-pathguard rejects the package), and configure-style
    # scripts persist the -I: curl-config --configure and bash's
    # /usr/lib/bash/Makefile.inc both echo CPPFLAGS=-I<sysroot>/include at
    # runtime. Only set them when there is no overlay to make the sysroot
    # visible.
    if not bwrapped:
        # Bottom layer first: pre() prepends, so the topmost sysroot layer ends
        # up leftmost and wins, matching the overlay's stacking order.
        for su in sus:
            # -isystem, not -I: with -I the staged headers are ordinary user
            # headers, so warnings inside them are reported and any package built
            # -pedantic -Werror dies on glibc's own #include_next (xmlsec did).
            # C_INCLUDE_PATH below is already -isystem semantics; this just stops
            # the -I from overriding that.
            pre("CPPFLAGS", "-isystem %s/include" % su)
            # A .pc with a bare "Cflags: -I${includedir}" (libxslt has one) expands
            # to -I<sysroot>/usr/include, and that plain -I outranks the -isystem
            # above -- the staged headers go back to being user headers and any
            # package built -pedantic -Werror dies inside glibc. These two vars are
            # pkg-config's own mechanism for "this is a system dir, drop the flag";
            # they default to /usr/include and /usr/lib, so name those too.
            pre("PKG_CONFIG_SYSTEM_INCLUDE_PATH", "%s/include:/usr/include" % su)
            pre("PKG_CONFIG_SYSTEM_LIBRARY_PATH", "%s/lib:/usr/lib" % su)
            pre("LDFLAGS", "-L%s/lib -Wl,-rpath-link,%s/lib" % (su, su))
            pre("LIBRARY_PATH", "%s/lib" % su)
            pre("C_INCLUDE_PATH", "%s/include" % su)
            pre("CPLUS_INCLUDE_PATH", "%s/include" % su)
            pre("LD_LIBRARY_PATH", "%s/lib" % su)
        su = sus[-1]
    # Under the overlay the sysroot IS /usr, and pointing at its raw path takes
    # you back OUT of the merge. A "#!/usr/bin/env python3" script then resolves
    # to <sysroot>/usr/bin/python3, whose sys.prefix is the sysroot, so its
    # site-packages holds only staged packages -- no host setuptools, hence
    # "No module named distutils" in g-ir-scanner and "No module named build"
    # in yt-dlp, while the very same interpreter works fine as /usr/bin/python3.
    if not bwrapped:
        e["XDG_DATA_DIRS"] = ":".join(["%s/share" % s for s in reversed(sus)]
                                      + ["/usr/share"])
        e["PATH"] = ":".join(["%s/bin" % s for s in reversed(sus)] + [e["PATH"]])
    e["ELF_PATHGUARD"] = os.path.join(TOOLS, "elf-pathguard.sh")
    # Inside bwrap's user namespace the real chown(uid 0) returns EINVAL
    # because the id is not mapped, and fakeroot propagates that instead of
    # just recording the ownership it is pretending to set.  Any package()
    # that runs `cp -a` or `install -o` then dies with "failed to preserve
    # ownership: Invalid argument" -- alsa-ucm-conf and boost both did.
    # Telling fakeroot not to attempt the real call is exactly right here:
    # we are staging a package tree, not changing anything on the system.
    e["FAKEROOTDONTTRYCHOWN"] = "1"
    # Compiler and toolchain scratch files follow TMPDIR: GCC's LTO partitions,
    # `go build`'s work directories, rustc, and every `mktemp` a recipe runs.
    # Unset, they all land in /tmp -- a RAM-backed tmpfs here, shared with the
    # desktop -- whatever --buildroot says.  Put them beside the build tree,
    # so --buildroot /var/tmp/... really does move a large build off tmpfs.
    e["TMPDIR"] = os.path.join(BUILDROOT, "tmp")
    os.makedirs(e["TMPDIR"], exist_ok=True)
    e.update(_CCACHE_ENV)
    return e


# Filled in by cmd_build once, from ccache_env(args); build_env() is called
# from several places and none of them has `args`.
_CCACHE_ENV = {}


# ==========================================================================
# build slots -- one per concurrent package
# ==========================================================================

class Slot:
    """One concurrency slot: its own sysroot layer, makepkg.conf and CPU set.

    **The sysroot.**  It is shared mutable state, and there were three ways to
    make it safe:

      per-job sysroot      Simple, and far too expensive here: rehydrate_sysroot
                           stages *everything already in repo/* -- 1,400 packages,
                           9 GiB -- and duplicating that per slot is 9 GiB of
                           tmpfs and several minutes of tar per slot, paid before
                           a single package builds.

      a lock around
      stage_deps()         Cheap, and not actually sufficient.  It serialises the
                           writers, but the overlay's lowerdir is still being
                           written to while another slot's build has it mounted.
                           Overlayfs calls that undefined; in practice it is
                           stale dentries and ESTALE, i.e. exactly the class of
                           intermittent failure that is impossible to debug from
                           a build log.

      layered              What this does.  bwrap already stacks overlay layers,
                           so there is no reason to have only one: a single
                           *shared base* holds everything rehydrate_sysroot
                           stages, is written once before any job starts, and is
                           never touched again while the run is in flight; each
                           slot gets a small private layer on top that only that
                           slot ever writes, and only in stage_deps() *before*
                           its own bwrap starts.  No lock is needed because there
                           is no sharing, and no lowerdir mutates under a mount.

    The base stays immutable for the whole run, which is why a package must not
    start before its dependencies have *finished*: the mechanism that makes a
    just-built dependency visible is stage_deps() reading repo/ into the slot
    layer, and repo/ only gains the artifact when the dependency's build ends.
    That is what schedule_blockers() enforces.

    **MAKEFLAGS and CPUs.**  N slots inheriting the system's -j144 would be
    144N processes, so the budget is divided rather than duplicated -- see
    CpuPool, which also explains why the division is made at dispatch time
    rather than fixed per slot.  Each job is additionally pinned to its CPUs
    with taskset, which is not belt-and-braces decoration: MAKEFLAGS only
    reaches make.  ninja, cargo, rustc's codegen threads, GCC's LTO partitioner
    and `xargs -P` all size themselves from sched_getaffinity() and would each
    take the whole machine.  Verified on this host: `taskset -c 0-7 nproc`
    answers 8.

    `cpus` and `make_jobs` are therefore set on the slot at dispatch, not in the
    constructor; build_one() writes make_jobs into that slot's makepkg.conf and
    wraps every child in taskset.
    """

    def __init__(self, idx, base, args):
        self.idx = idx
        self.cpus = None                      # list[int] or None; set per job
        self.make_jobs = 0                    # set per job
        self.staged = set()                   # for preflight_deps, per layer
        if args.jobs > 1:
            self.layer = "%s.slot%d" % (base, idx)
            os.makedirs(self.layer, exist_ok=True)
            self.layers = [base, self.layer]
        else:
            # Serial runs keep the single sysroot they have always had, so a
            # resumed or interleaved serial run behaves exactly as before.
            self.layer = base
            self.layers = [base]
        self.conf = os.path.join(BUILDROOT, "makepkg.conf"
                                 if args.jobs == 1 else
                                 "makepkg.conf.slot%d" % idx)
        # makepkg loads drop-ins only from "$MAKEPKG_CONF.d" -- the config's
        # own name plus .d. A serial run's makepkg.conf finds the buildroot's
        # makepkg.conf.d (where build-ppc64le.sh installs 00-power8.conf); a
        # slot's makepkg.conf.slotN looked for makepkg.conf.slotN.d, found
        # nothing, and every -j>1 POWER8 run silently lost the drop-in: no
        # _power8, so rust shipped a pwr9 libstd. Point each slot at the same
        # directory.
        dropins = os.path.join(BUILDROOT, "makepkg.conf.d")
        if args.jobs > 1 and os.path.isdir(dropins):
            link = self.conf + ".d"
            if os.path.islink(link) or not os.path.exists(link):
                if os.path.islink(link):
                    os.unlink(link)
                os.symlink("makepkg.conf.d", link)

    def wrap(self, cmd):
        if not self.cpus:
            return cmd
        return ["taskset", "-c", cpuspec(self.cpus)] + cmd

    def label(self):
        return "slot%d/-j%d" % (self.idx, self.make_jobs)


def cpuspec(cpus):
    """Compress a sorted cpu list to taskset's range syntax."""
    out, i = [], 0
    while i < len(cpus):
        j = i
        while j + 1 < len(cpus) and cpus[j + 1] == cpus[j] + 1:
            j += 1
        out.append(str(cpus[i]) if j == i else "%d-%d" % (cpus[i], cpus[j]))
        i = j + 1
    return ",".join(out)


class CpuPool:
    """Hands CPUs to jobs when they start and takes them back when they end.

    The obvious thing -- cut the machine into N fixed slices, one per slot --
    was the first implementation, and it wastes the machine at the tail of a
    queue.  Measured on a 10-package queue at -j4: 178 s against 291 s serial,
    but for the last 100 s of that only embree was still building, holding 44
    threads while 132 sat idle behind an affinity mask they were not allowed to
    cross -- embree took 47 s on the whole machine and 159 s on a quarter of it.

    So the split happens at dispatch instead.  A job takes the free CPUs divided
    by the number of jobs about to start alongside it: a quarter of the machine
    each when four are queued, and the whole machine for the last package
    standing.  Same queue, same box: 93 s against 307 s serial, 3.3x.  Nothing
    in flight ever has its share taken away -- makepkg's -j is fixed once the
    build starts, so growing a running job is not possible anyway.

    The allocation is contiguous, which on POWER9 SMT4 keeps whole cores
    together while the pool is unfragmented (176 threads / 4 is 44, exactly 11
    cores).  It is not forced to be: a job straddling a core boundary costs a
    little SMT contention, and forcing alignment would cost whole idle cores.
    """

    def __init__(self, args):
        try:
            self.all = sorted(os.sched_getaffinity(0))
        except AttributeError:
            self.all = list(range(os.cpu_count() or 1))
        self.free = list(self.all)
        self.budget = args.job_budget or len(self.all)
        self.force_jobs = args.make_jobs
        self.nominal = max(1, args.jobs)
        self.pinning = bool(args.cpu_affinity) and self.nominal > 1
        self.lock = threading.Lock()

    def take(self, sharers):
        """Claim a share of the free CPUs for one job.

        `sharers` is how many jobs are about to start together; one of them is
        this one.  Returns None when pinning is off, which is also the serial
        case -- a lone job should see the machine it is actually running on.
        """
        if not self.pinning:
            return None
        with self.lock:
            n = max(1, len(self.free) // max(1, sharers))
            got, self.free = self.free[:n], self.free[n:]
            return got

    def give(self, cpus):
        if not cpus:
            return
        with self.lock:
            self.free = sorted(set(self.free) | set(cpus))

    def jobs_for(self, cpus):
        """The -j that goes with that CPU allocation."""
        if self.force_jobs:
            return self.force_jobs
        if cpus is None:
            # Unpinned: there is no allocation to scale from, so fall back to an
            # even split of the budget.  MAKEFLAGS still has to be divided --
            # that is the whole point -- even when nothing is holding ninja to
            # it.
            return max(2, self.budget // self.nominal)
        return max(2, round(len(cpus) * self.budget / max(1, len(self.all))))


def make_slots(args, base):
    return [Slot(i, base, args) for i in range(max(1, args.jobs))]


# ==========================================================================
# ccache
# ==========================================================================
#
# The compiler cache is worth having here for a reason specific to this repo:
# a large share of the rebuilds are of *identical source*.  The packager sweep
# rebuilt fifteen recipes purely to change a metadata string; a soname bump
# rebuilds a dependent whose own code did not move; --force after a failed
# guard recompiles everything that already compiled.  ccache turns all of those
# from full cost into near-nothing.
#
# It is enabled by default and switched off with --no-ccache.
#
# Two settings are deliberate rather than defaulted:
#
#   compiler_check=content   The default is `mtime`, which identifies a
#                            compiler by path, size and modification time.  In
#                            a tree where the sysroot can stack a *different*
#                            gcc over the host one at the same path, that is
#                            the wrong identity to hash.  `content` hashes the
#                            compiler binary itself.  It costs one hash of a
#                            ~1 MiB executable per invocation and removes the
#                            whole class.
#
#   base_dir unset           Leaving it unset means absolute paths go into the
#                            hash, so a build under a different --buildroot
#                            misses instead of hitting.  That is the safe
#                            direction, and the alternative -- rewriting
#                            absolute paths to relative so they hit -- is the
#                            classic source of "ccache handed me the wrong
#                            object" reports.  bq's buildroot is stable within
#                            a machine, so there is little to win and a
#                            correctness property to lose.
#
# What ccache does NOT cover:
#
#   rustc          `/usr/lib/ccache/bin` has no rustc symlink and ccache does
#                  not speak Rust, so rust packages (marksman, rust itself)
#                  get neither the benefit nor the risk.  sccache would be a
#                  separate exercise.
#
#   recipes that   Some upstreams turn it off themselves and are right to.
#   turn it off    foot's `pgo/pgo.sh` does `export CCACHE_DISABLE=1` on line
#                  82, because profile-generate/profile-use and a compiler
#                  cache do not mix.  A foot build under bq therefore shows a
#                  0% hit rate and that is correct, not a wiring failure --
#                  which is exactly why the summary line below reports the hit
#                  rate rather than reporting that ccache was "enabled".

def ccache_env(args):
    if not args.ccache:
        return {}
    e = {"CCACHE_DIR": args.ccache_dir,
         # Set here rather than left to ~/.config/ccache/ccache.conf: bq must
         # not depend on a config file it does not write.  That is the same
         # lesson as the makepkg.conf.d drop-ins, which were silently not
         # applying to any bq build for weeks.
         "CCACHE_MAXSIZE": args.ccache_size,
         "CCACHE_COMPILERCHECK": "content",
         # ccache preprocesses into $XDG_RUNTIME_DIR/ccache-tmp by default --
         # /run/user/<uid>, a 45 GiB tmpfs that also holds the desktop
         # session's sockets.  zig 0.16's bootstrap compiles a generated 222 MiB
         # zig2.c; its preprocessed .i reached 48 GiB there, filled the tmpfs
         # and left cc1 spinning (2026-09-13).  Keep it in the buildroot.
         "CCACHE_TEMPDIR": os.path.join(BUILDROOT, "ccache-tmp")}
    os.makedirs(args.ccache_dir, exist_ok=True)
    os.makedirs(e["CCACHE_TEMPDIR"], exist_ok=True)
    return e


def ccache_counters():
    """{stat: int} from `ccache --print-stats`, or {} if ccache is not there.

    _CCACHE_ENV is load-bearing, not tidiness: without it this reads whatever
    CCACHE_DIR the *caller's* shell implies -- ~/.cache/ccache -- while the
    builds write to the one bq configured, so a run against an alternate
    --ccache-dir reported "no compilations went through it" while the cache was
    filling up perfectly well.
    """
    try:
        r = subprocess.run(["ccache", "--print-stats"], capture_output=True,
                           text=True, timeout=60,
                           env={**os.environ, **_CCACHE_ENV})
    except Exception:
        return {}
    out = {}
    for line in r.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) == 2:
            try:
                out[parts[0]] = int(parts[1])
            except ValueError:
                pass
    return out


def ccache_delta(before, after):
    """A one-line hit/miss summary for the run, or None."""
    if not before or not after:
        return None
    hit = ((after.get("direct_cache_hit", 0) - before.get("direct_cache_hit", 0))
           + (after.get("preprocessed_cache_hit", 0)
              - before.get("preprocessed_cache_hit", 0)))
    miss = after.get("cache_miss", 0) - before.get("cache_miss", 0)
    total = hit + miss
    if total <= 0:
        return None
    return ("ccache: %d/%d hits (%.1f%%), %d misses, cache now %.1f GiB"
            % (hit, total, 100.0 * hit / total, miss,
               after.get("cache_size_kibibyte", 0) / 2**20))


def mem_available_gib():
    try:
        for line in open("/proc/meminfo"):
            if line.startswith("MemAvailable:"):
                return int(line.split()[1]) / 2**20
    except OSError:
        pass
    return float("inf")


def rehydrate_sysroot(st, order, args):
    """Re-stage everything this queue has already built, and everything in
    repo/, into the sysroot.

    Resumption is not just "skip what is done".  The sysroot lives under the
    buildroot and a resumed run starts with an empty one, so a package whose
    dependency was built before the interruption would no longer find it --
    the queue would be resumable in bookkeeping and broken in fact.  Restaging
    from the repo is cheap (tar extraction) and makes a resumed run identical
    to an uninterrupted one.

    This used to return early when no package of *this run's* queue was
    already `ok`, which skipped the repo/ restage below as well -- so a fresh
    BQ_STATE, and any run whose targets were all new, built against only what
    stage-deps pulled in, with the host's copy of everything else even where
    repo/ carries a deliberate rebuild.  Found 2026-09-13; that was every
    targeted bq run that day.  The repo/ restage must not depend on the queue.
    """
    done = [t for t in order if st["packages"].get(t, {}).get("status") == "ok"]
    names, staged = [], set(st.get("staged", []))
    for t in done:
        for f in st["packages"][t].get("packages", []):
            if "-debug-" in f:
                continue
            # strip -<pkgver>-<pkgrel>-<arch>.pkg.tar.zst
            n = re.sub(r"-[^-]+-[^-]+-[^-]+\.pkg\.tar\.\w+$", "", f)
            if n:
                names.append(n)
    # Everything already sitting in repo/, not just what this queue built.
    # Those are deliberate rebuilds and they have to outrank the system copy
    # even when nothing in the queue names them directly: glycin depends on
    # libheif, libheif is linked against a libde265 exporting
    # de265_get_security_limits, and the installed 1.0.18 does not have it.
    # libde265 is therefore a transitive dependency no PKGBUILD mentions, so
    # stage-deps never saw it and the link failed on a symbol our own
    # repo/libde265-1.1.2 has exported all along.
    repo_names = set()
    try:
        for f in os.listdir(REPO):
            if not f.endswith((".pkg.tar.zst", ".pkg.tar.xz")) or "-debug-" in f:
                continue
            n = re.sub(r"-[^-]+-[^-]+-[^-]+\.pkg\.tar\.\w+$", "", f)
            if n:
                repo_names.add(n)
    except OSError:
        pass
    names = sorted(set(names) | repo_names)

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


def stage_deps(pkgbase, recipedir, sysroot, log, lowers=()):
    """Fetch this package's depends/makedepends/checkdepends into the sysroot.

    Without this a missing makedepend only surfaced as whatever meson or cmake
    chose to say about it, halfway through the build.

    `lowers` are the sysroot layers beneath `sysroot` (the shared base under a
    -j slot).  sysroot-add.sh needs them to decide opaque directories: an
    opaque mark in the slot would hide the base's copy too.
    """
    try:
        r = subprocess.run(
            [os.path.join(TOOLS, "stage-deps.sh"), pkgbase, recipedir],
            capture_output=True, text=True, timeout=2400,
            env={**os.environ, "SYSROOT": sysroot, "BUILDROOT": BUILDROOT,
                 "SYSROOT_LOWER": ":".join(lowers)})
        out = r.stdout + r.stderr
    except Exception as exc:
        out = "stage-deps failed to run: %s: %s\n" % (type(exc).__name__, exc)
    try:
        with open(log, "a") as fh:
            fh.write("\n--- stage-deps ---\n" + out)
    except OSError:
        pass
    # What stage-deps could genuinely not supply.  This, not preflight's
    # pacman -T, is the honest basis for a missing-dep verdict: staged
    # packages live in the sysroot and are invisible to pacman -T, so
    # preflight now reports almost everything as "missing".
    absent = []
    for ln in out.splitlines():
        if "not in Arch POWER and not yet built:" in ln:
            absent = ln.split(":", 1)[1].split()
    return absent


def sysroot_add(names, sysroot, lowers=()):
    subprocess.run([os.path.join(TOOLS, "sysroot-add.sh")] + list(names),
                   capture_output=True, text=True, timeout=900,
                   env={**os.environ, "SYSROOT": sysroot,
                        "SYSROOT_LOWER": ":".join(lowers)})


def disk_free_gib(path):
    st = os.statvfs(path)
    return st.f_bavail * st.f_frsize / 2**30


class repo_db_lock:
    """flock on a file beside the repo db, held across the repo-add.

    Named after the database it guards, which is not decoration: `.gitignore`
    already excludes `repo/*.db*`, so the lock file lands inside that pattern
    instead of showing up as untracked clutter in a repo whose whole point is
    that the recipes are tracked and the output is not.
    """

    def __init__(self, dest, db):
        self.path = os.path.join(dest, (db or "repo") + ".bqlck")

    def __enter__(self):
        self.fh = open(self.path, "a+")
        fcntl.flock(self.fh, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        fcntl.flock(self.fh, fcntl.LOCK_UN)
        self.fh.close()
        return False


def build_one(pkgbase, recipe_src, args, st, slot):
    work = os.path.join(BUILDROOT, "build", pkgbase)
    logdir = os.path.join(BUILDROOT, "logs")
    os.makedirs(logdir, exist_ok=True)
    log = os.path.join(logdir, pkgbase + ".log")

    free = disk_free_gib(BUILDROOT)
    if free < args.min_free:
        return {"status": "deferred", "class": "disk",
                "detail": "only %.1f GiB free at %s" % (free, BUILDROOT)}

    shutil.rmtree(work, ignore_errors=True)
    pkgbase = pkgbase_of(pkgbase)
    src = SOURCES[recipe_src] if recipe_src in SOURCES else \
        find_source(pkgbase, args.sources.split(","),
                    getattr(args, "allow_downgrade", False))
    if src is None or not src.materialise(pkgbase, work):
        return {"status": "failed", "class": "no-recipe",
                "detail": "no recipe found in: " + args.sources}

    # An arch=() that omits us is a pre-build failure with a one-line fix; say
    # so instead of letting makepkg produce a confusing error.
    info = read_recipe(work)
    if args.fix_arch:
        # Judge the gate on the PKGBUILD, because that is the file makepkg
        # reads.  read_recipe prefers .SRCINFO, and the two can disagree: fmt
        # ships arch=(powerpc espresso) alongside a .SRCINFO naming five
        # architectures including ours, so the gate looked satisfied and
        # makepkg then refused the build outright.  add_arch already returns
        # False when the architecture is present, so this stays a no-op for
        # every recipe that is already correct.
        if add_arch(os.path.join(work, "PKGBUILD")):
            regen_srcinfo(work)
    elif info["arch"] and CARCH not in info["arch"] and "any" not in info["arch"]:
        return {"status": "failed", "class": "arch-gate",
                "detail": "arch=(%s)" % " ".join(info["arch"])}

    # Per slot, not run-wide: with -j each slot has its own sysroot layer, so
    # "already staged" is only true of the layer this package will build against.
    # A run-wide set would suppress a genuine missing-dep under --strict-deps.
    missing = preflight_deps(work, slot.staged)
    if missing and args.strict_deps:
        return {"status": "failed", "class": "missing-dep",
                "detail": "not installed: " + " ".join(missing),
                "missing_deps": missing}

    conf = slot.conf
    write_makepkg_conf(conf, args.pkgdest or REPO,
                       os.path.join(BUILDROOT, "srcdest"), logdir,
                       make_jobs=slot.make_jobs, ccache=args.ccache)

    sysroot = slot.layer            # where new deps get staged
    layers = slot.layers            # what the build actually sees
    pre = bwrap_prefix(layers)
    env = build_env(layers, bool(pre))

    # Already built by an earlier run?  Plain makepkg fails with "A package has
    # already been built" and -f would rebuild it; at queue scale neither is
    # right, because ~120 packages are already in the repo and rebuilding them
    # would eat the night without adding coverage.  Mark ok, but still stage
    # the package so later queue entries can link against it.  --force wins.
    if not args.force:
        _pl = subprocess.run(["makepkg", "--config", conf, "--packagelist"],
                             cwd=work, capture_output=True, text=True,
                             env=env, timeout=900)
        _want = [f for f in _pl.stdout.split() if "-debug-" not in f]
        if _want and all(os.path.isfile(f) for f in _want):
            _ri = read_recipe(work)
            _names = list(_ri["pkgname"])
            if _names:
                sysroot_add(_names, sysroot, layers[:-1])
                slot.staged.update(_names)
                slot.staged.update(_ri["provides"])
                note_staged(st, _names + _ri["provides"])
            return {"status": "ok", "class": "existing", "seconds": 0.0,
                    "reused": True,
                    "packages": [os.path.basename(f) for f in _want]}

    # Truncate here, before stage-deps appends: the makepkg run below used to
    # open this log with "w", which threw away the staging report just when it
    # was needed for triage.
    open(log, "w").close()

    # Stage depends+makedepends+checkdepends into the sysroot.  bq never called
    # stage-deps.sh at all: preflight_deps() only *reported* what was missing,
    # so bluez went in without `ell libical` and bolt without `asciidoc` even
    # though all three are packaged in Arch POWER.
    unstaged = stage_deps(pkgbase, work, sysroot, log, layers[:-1])

    # Recompute AFTER staging. bwrap_prefix() returns [] when <sysroot>/usr does
    # not exist, and on a fresh buildroot stage_deps() is what creates it -- so
    # the values computed above are from before the sysroot existed, and the
    # FIRST package of every fresh buildroot would build with no overlay and the
    # -I/-L fallback instead. That is why perl leaked a sysroot RUNPATH as a lone
    # [1/1] and yt-dlp could not see its staged python modules as [1/2] while
    # zbar got further as [2/2].
    pre = bwrap_prefix(layers)
    env = build_env(layers, bool(pre))

    # taskset outermost: it must be inherited by bwrap and by everything under
    # it.  An affinity set inside the sandbox would not apply to bwrap's own
    # setup, and setting it per-makepkg would miss the guards below.
    cmd = slot.wrap(pre + ["makepkg", "--config", conf, "-d", "--noconfirm",
                           "--needed", "--nocheck", "--log", "--skippgpcheck"])
    if args.force:
        cmd.append("-f")

    t0 = time.time()
    with open(log, "a") as fh:
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
    # Two guards, same hook. elf-pathguard reads what is *inside* the files --
    # ELF RUNPATHs, shebangs, the text of *-config scripts. pkg-pathguard reads
    # *where the files are*, which is a different failure and was invisible for
    # months: ten packages installed to an absolute sysroot path taken from a .pc
    # file instead of $pkgdir. grim shipped /home/<user>/... , which makes
    # pacstrap create the home directory, which makes the installer's later
    # `useradd -m` decline to copy /etc/skel, which leaves a new account with no
    # shell or desktop config and nothing anywhere reporting an error.
    guards = [os.path.join(TOOLS, "elf-pathguard.sh"),
              os.path.join(TOOLS, "pkg-pathguard.sh")]
    guard = guards[0]
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
    failed_guard = None
    if rc == 0 and pkgdirs:
        for _g in guards:
            if not os.access(_g, os.X_OK):
                continue
            # SYSROOT is load-bearing for elf-pathguard: without it the guard
            # cannot know which absolute path is the staging tree, so its
            # content check silently does nothing. xorg-xwayland shipped
            # "<sysroot>/usr/bin" as XKB_BIN_DIRECTORY and passed clean, and
            # Xwayland aborted at startup on the installed system because that
            # xkbcomp does not exist there.
            # The *base* sysroot, not this slot's layer.  elf-pathguard
            # substring-matches SYSROOT against file contents, and the slot
            # layers are named "<base>.slotN" -- so passing the base catches a
            # leaked path from either, while passing the layer would miss the
            # base.
            g = subprocess.run(slot.wrap([_g] + pkgdirs),
                               capture_output=True, text=True,
                               timeout=1800,
                               env={**os.environ, "SYSROOT": args.sysroot,
                                    "BUILDROOT": BUILDROOT})
            with open(log, "a") as fh:
                fh.write("\n--- %s ---\n" % os.path.basename(_g)
                         + g.stdout + g.stderr)
            if g.returncode != 0:
                failed_guard = os.path.basename(_g)
                break
        if failed_guard:
            rc = 90
            result["guard"] = failed_guard.replace(".sh", "")
            quarantine = os.path.join(BUILDROOT, "rejected")
            os.makedirs(quarantine, exist_ok=True)
            pl = subprocess.run(["makepkg", "--config", conf, "--packagelist"],
                                cwd=work, capture_output=True, text=True,
                                env=env, timeout=900)
            for f in pl.stdout.split():
                if os.path.isfile(f):
                    shutil.move(f, os.path.join(quarantine, os.path.basename(f)))

    built = []
    if rc == 0:
        pl = subprocess.run(["makepkg", "--config", conf, "--packagelist"],
                            cwd=work, capture_output=True, text=True,
                            env=env, timeout=900)
        built = [os.path.basename(f) for f in pl.stdout.split()
                 if os.path.isfile(f)]
        result["packages"] = built
        # Stage into the sysroot so the next package in the queue can link
        # against it, and fold it into the repo db.
        rinfo = read_recipe(work)
        names = list(rinfo["pkgname"])
        if names:
            sysroot_add(names, sysroot, layers[:-1])
            slot.staged.update(names)
            slot.staged.update(rinfo["provides"])
            note_staged(st, names + rinfo["provides"])
        dest = args.pkgdest or REPO
        newfiles = [os.path.join(dest, b) for b in built
                    if "-debug-" not in b and os.path.isfile(os.path.join(dest, b))]
        if newfiles and args.repo_db:
            # repo-add takes a <db>.lck of its own and *aborts* rather than
            # waits if one already exists, so two slots finishing together
            # would silently lose one package's db entry.  The threading lock
            # covers this process; the flock covers a second bq process sharing
            # the same repo (which BQ_REPO exists to allow).
            with _REPODB_LOCK, repo_db_lock(dest, args.repo_db):
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
    # rc 124 is the --timeout path. Removing the tree there threw away work
    # that was nearly finished -- chromium timed out at 55,804 of 55,835
    # objects -- and the rmtree deleted the ThinLTO cache directory out from
    # under a still-running clang++, so the link aborted with "can't create
    # cache directory thinlto-cache" instead of merely stopping. Keep the tree
    # on timeout so a retry can makepkg -R (repackage) or -e (skip build).
    if not args.keep and rc != 124:
        subprocess.run(["makepkg", "--config", conf, "-c", "--noconfirm"],
                       cwd=work, capture_output=True, timeout=600, env=env)
        make_traversable(work)
        shutil.rmtree(work, ignore_errors=True)

    if missing:
        result["missing_deps"] = missing
    if unstaged:
        result["unstaged_deps"] = unstaged
    if rc == 0:
        result["status"] = "ok"
    else:
        cls, fix, line = classify(log)
        # Only call it missing-dep when staging genuinely could not supply
        # the dependency.  Overriding on preflight's list instead mislabelled
        # real build failures: audit's libtool relink error was reported as
        # "not installed: apparmor" when apparmor had in fact been staged.
        if unstaged and cls in ("unknown", "missing-dep"):
            cls = "missing-dep"
            line = "not in Arch POWER and not yet built: " + " ".join(unstaged)
        if rc == 90:
            # Which guard rejected it is recorded on the result by build_one;
            # falling back to elf-pathguard keeps older state files readable.
            _g = result.get("guard", "elf-pathguard")
            cls, fix = _g, dict((c[0], c[2]) for c in CLASSES).get(
                _g, "A post-build guard rejected this package.")
            # The class's canned fix talks about ELF rpaths, but elf-pathguard
            # also rejects text files, and for those that advice points the
            # wrong way: qt6-base 6.11.2-4 was refused for a path in a CMake
            # script and told to fix its rpath handling.  Take the detail from
            # the guard's own FAIL line, which names the file, and pick the fix
            # by what kind of file it is.  classify() alone can land on an
            # unrelated earlier line (a cmake "Could NOT find ...").
            try:
                _body = open(log, errors="replace").read()
            except OSError:
                _body = ""
            _m = re.search(r"^%s: FAIL [^\n]*$" % re.escape(_g), _body, re.M)
            if _m:
                line = _m.group(0)[:200]
                fix = GUARD_FIXES.get(_g, lambda l: fix)(line) or fix
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
    order, recipes, stuck, provided_by, deps = resolve_order(
        targets, args.sources.split(","),
        assume_installed=not args.full_bootstrap,
        allow_downgrade=args.allow_downgrade)
    # A target with no recipe of its own is not missing if some recipe already
    # in the queue produces it as a split package -- gexiv2-common comes out of
    # gexiv2, libnautilus-extension out of nautilus. Reporting those as missing
    # would send someone looking for repositories that do not exist.
    missing = sorted(b for b in ({pkgbase_of(t) for t in targets} - set(recipes))
                     if b not in provided_by)
    q = {"order": order, "cycles": stuck, "missing_recipe": sorted(missing),
         "sources": {t: recipes[t].get("source") for t in order},
         # Which recipe, not just which tree.  With a nested layout "archpower"
         # names 4,400 directories, so the queue records the path and the
         # version it resolved to and a later build can be held to them.
         "paths": {t: recipes[t].get("recipe_path") for t in order},
         "versions": {t: recipes[t].get("version") for t in order},
         # The edges, not just the order: `bq build -j` needs to know which
         # packages may overlap, and re-deriving them from a bare order is
         # impossible.  A queue.json written before this existed still works --
         # cmd_build re-resolves in that case.
         "deps": {t: sorted(deps.get(t, ())) for t in order},
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
    print("%4s  %-32s %-9s %-40s %s"
          % ("#", "pkgbase", "source", "recipe", "version"))
    for i, t in enumerate(order, 1):
        r = recipes[t]
        print("%4d  %-32s %-9s %-40s %s"
              % (i, t, r.get("source", "?"), r.get("recipe_path") or "-",
                 r.get("version") or "-"))
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
    deps = {}
    if args.targets or args.targets_file:
        targets = read_targets(args)
        order, recipes, stuck, _, deps = resolve_order(
            targets, args.sources.split(","),
            assume_installed=not getattr(args, "full_bootstrap", False),
            allow_downgrade=args.allow_downgrade)
        srcmap = {t: recipes[t].get("source") for t in order}
    elif os.path.isfile(qf):
        q = json.load(open(qf))
        order, srcmap = q["order"], q.get("sources", {})
        deps = q.get("deps") or {}
        if args.jobs > 1 and not deps:
            # A queue.json from before `deps` was recorded.  Re-resolving from
            # the order gives the same graph -- the recipes are cached in
            # <buildroot>/_meta -- and running -j without it would build
            # dependents alongside their dependencies.
            _o, _r, _c, _p, deps = resolve_order(
                order, args.sources.split(","),
                assume_installed=not getattr(args, "full_bootstrap", False),
                allow_downgrade=args.allow_downgrade)
    else:
        print("nothing to build: pass targets or run `bq plan` first", file=sys.stderr)
        return 2

    st = load_state()
    st.setdefault("packages", {})
    st["started"] = st.get("started") or time.strftime("%Y-%m-%dT%H:%M:%S")

    excluded = {x.strip() for x in getattr(args, "exclude", "").split(",") if x.strip()}
    todo = []
    for t in order:
        if t in excluded:
            continue
        prev = st["packages"].get(t, {})
        if prev.get("status") == "ok" and not args.rebuild:
            continue
        if prev.get("status") == "failed" and not (args.retry_failed or args.rebuild):
            continue
        todo.append(t)
    if args.limit:
        todo = todo[:args.limit]

    # emit(), not print(): stdout is a file in every real run, so it is block
    # buffered, and the header would otherwise sit unseen behind the flushing
    # progress lines for as long as rehydrate_sysroot takes -- which on a full
    # repo is 1,300 packages of tar.
    emit("bq: %d/%d to build (buildroot %s, %.0f GiB free)"
         % (len(todo), len(order), BUILDROOT, disk_free_gib(BUILDROOT)))
    global _CCACHE_ENV
    _CCACHE_ENV = ccache_env(args)
    cc_before = {}
    if args.ccache:
        cc_before = ccache_counters()
        emit("bq: ccache on, %s (%s max, %.0f GiB free on that filesystem)"
             % (args.ccache_dir, args.ccache_size,
                disk_free_gib(args.ccache_dir)))
    os.makedirs(args.sysroot, exist_ok=True)
    # Before any job starts.  With -j this is what freezes the shared base
    # sysroot layer: nothing writes to it again for the rest of the run.
    rehydrate_sysroot(st, order, args)
    save_state(st)

    slots = make_slots(args, args.sysroot)
    # Every slot sees the base layer, so whatever rehydrate_sysroot just put
    # there is staged as far as each of them is concerned.  Without this seed a
    # --strict-deps run at -j would fail the first package in each slot for
    # dependencies that are sitting right there in the base.
    for _s in slots:
        _s.staged.update(st.get("staged", []))
    pool = CpuPool(args)
    if args.jobs == 1:
        # A serial run keeps /etc/makepkg.conf's own MAKEFLAGS unless the
        # operator asked for something else, so -j1 stays byte-for-byte the
        # behaviour it had before concurrency existed.
        slots[0].cpus = None
        slots[0].make_jobs = args.make_jobs or (args.job_budget or 0)
    else:
        emit("bq: %d concurrent jobs over %d cpus, budget -j%d%s"
             % (args.jobs, len(pool.all), pool.budget,
                "" if pool.pinning else " (unpinned)"))
    t_start = time.time()
    counters = {"ok": 0, "fail": 0, "peak": 0.0, "n": 0, "stop": False}

    def run_one(t, slot):
        """Build one package.  Returns the result dict; never raises."""
        try:
            r = build_one(t, srcmap.get(t), args, st, slot)
        except Exception as exc:
            # An 858-package run cannot end because bq itself tripped over one
            # recipe.  Record it as a failure class of its own and carry on.
            import traceback
            r = {"status": "failed", "class": "bq-error",
                 "detail": "%s: %s" % (type(exc).__name__, exc),
                 "traceback": traceback.format_exc()[-2000:], "seconds": 0}
        r["when"] = time.strftime("%Y-%m-%dT%H:%M:%S")
        # Record the width the package was built at.  Without it `seconds` is
        # not comparable between a -j1 run and a -j4 one, and `bq status -v`
        # would quietly mix them.
        if slot.make_jobs:
            r["make_jobs"] = slot.make_jobs
        if slot.cpus:
            r["cpus"] = len(slot.cpus)
        record(st, t, r)          # after every package: the run is resumable
        with _STATE_LOCK:
            counters["n"] += 1
            counters["peak"] = max(counters["peak"], r.get("peak_gib", 0))
            if r["status"] == "ok":
                counters["ok"] += 1
            else:
                counters["fail"] += 1
                if args.stop_on_fail:
                    counters["stop"] = True
            i = counters["n"]
        if r["status"] == "ok":
            tail = "ok  %.0fs  %s" % (r["seconds"],
                                      " ".join(r.get("packages", []))[:90])
        else:
            tail = "FAIL [%s] %.0fs  %s" % (r.get("class"), r.get("seconds", 0),
                                            r.get("detail", "")[:90])
        if args.jobs == 1:
            # Serial output is byte-for-byte what it always was.
            with _PRINT_LOCK:
                sys.stdout.write(tail + "\n")
                sys.stdout.flush()
        else:
            emit("[%d/%d] %-34s %s" % (i, len(todo), t, tail))
        return r

    if args.jobs == 1:
        for i, t in enumerate(todo, 1):
            print("[%d/%d] %s ... " % (i, len(todo), t), end="", flush=True)
            run_one(t, slots[0])
            if counters["stop"]:
                break
    else:
        run_parallel(todo, order, deps, slots, pool, args, run_one, counters)

    print("\nbq: %d ok, %d failed, peak build tree %.2f GiB, wall %.0fs"
          % (counters["ok"], counters["fail"], counters["peak"],
             time.time() - t_start))
    if args.ccache:
        # The hit rate is the only honest evidence that the shim was actually
        # invoked -- a PATH that looks right proves nothing.
        line = ccache_delta(cc_before, ccache_counters())
        print(line if line else
              "ccache: no compilations went through it this run")
    return 0 if counters["fail"] == 0 else 1


def run_parallel(todo, order, deps, slots, pool, args, run_one, counters):
    """Dispatch `todo` across `slots`, respecting the dependency graph.

    A package becomes runnable when every blocker of it has *finished*, pass or
    fail.  Releasing on failure rather than on success is deliberate and is what
    keeps this equivalent to the serial loop: serially, a failed package does not
    stop the queue, and its dependents are attempted anyway (and usually fail
    with missing-dep, which is information the triage pass wants).

    Admission control on top of readiness:

      disk    build_one() already defers a package when the buildroot is below
              --min-free, and that stays.  But with jobs in flight the right
              answer is to *wait* rather than mark a perfectly good package
              deferred -- a slot finishing frees its build tree.  So: hold back
              while something is running, and only fall through to build_one's
              deferral when the machine is otherwise idle and the space still is
              not there, which is the same verdict the serial run would give.

      memory  Compile parallelism is bounded by the job budget, but link steps
              are not: chromium, llvm and qt6-webengine each want many GiB in a
              single ld/lld process, and three of those landing together is how
              a 446 GiB machine still runs out.  Same wait-don't-defer rule.
    """
    blockers = schedule_blockers(order, deps, todo)
    remaining = {t: set(b) for t, b in blockers.items()}
    dependents = defaultdict(set)
    for t, bs in remaining.items():
        for b in bs:
            dependents[b].add(t)

    order_pos = {t: i for i, t in enumerate(order)}
    pending = sorted(todo, key=lambda t: order_pos.get(t, 0))
    free_slots = list(slots)
    running = {}                                  # Future -> (pkg, slot)

    import concurrent.futures as cf

    def dispatch(exe, slot, t, sharers, note=""):
        # `sharers` is how many jobs are about to be running side by side,
        # counting this one.  That, not the nominal -j, is what the free CPUs
        # get divided by: a quarter of the machine each at the head of a long
        # queue, and the whole machine for the last package standing.
        slot.cpus = pool.take(sharers)
        slot.make_jobs = pool.jobs_for(slot.cpus)
        emit("[--/%d] %-34s start (%s on cpu %s)%s"
             % (len(todo), t, slot.label(),
                cpuspec(slot.cpus) if slot.cpus else "any", note))
        running[exe.submit(run_one, t, slot)] = (t, slot)

    with cf.ThreadPoolExecutor(max_workers=len(slots)) as exe:
        while pending or running:
            # --stop-on-fail: let the in-flight jobs finish rather than
            # abandoning half-written package trees, then dispatch nothing more.
            if counters["stop"]:
                pending = []
            while free_slots and pending:
                ready = [t for t in pending if not remaining[t]]
                if not ready:
                    break                       # blocked; wait for a finisher
                if running and not admissible(args):
                    break                       # hold back, do not defer
                t = ready[0]
                pending.remove(t)
                slot = free_slots.pop(0)
                dispatch(exe, slot, t,
                         1 + min(len(free_slots), len(ready) - 1))

            if not running:
                if not pending:
                    break
                # Nothing dispatched and nothing running.  Either every
                # remaining package is blocked -- impossible, schedule_blockers()
                # only keeps backward edges -- or admission control is holding
                # everything back on an idle machine.  Take the head anyway and
                # let build_one() give the same verdict the serial run would.
                t = pending.pop(0)
                slot = free_slots.pop(0)
                dispatch(exe, slot, t, 1, note="  [admitted on an idle machine]")

            done, _ = cf.wait(list(running), return_when=cf.FIRST_COMPLETED)
            for fut in done:
                t, slot = running.pop(fut)
                pool.give(slot.cpus)
                slot.cpus = None
                free_slots.append(slot)
                for d in dependents.get(t, ()):
                    remaining[d].discard(t)


def admissible(args):
    """Is there room for one more concurrent build right now?"""
    if disk_free_gib(BUILDROOT) < args.min_free:
        return False
    if args.min_mem and mem_available_gib() < args.min_mem:
        return False
    return True


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
        p.add_argument("--sources", default=DEFAULT_SOURCES,
                       help="recipe sources to consider, and the tie-break "
                            "order among them (default: packaging, the only "
                            "local tree). gitlab and aur are import sources -- "
                            "naming one here builds straight from upstream "
                            "without the recipe ever entering the packaging "
                            "tree, so prefer tools/fetch.sh. Selection is by "
                            "version first, not by this order")
        p.add_argument("--allow-downgrade", action="store_true",
                       help="select a recipe even when it is older than the "
                            "version our repo database already ships. Refused "
                            "by default: we do not downgrade for parity")

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
    p.add_argument("-j", "--jobs", default="1", metavar="N",
                   help="build N packages concurrently (default 1, i.e. the "
                        "serial behaviour). 'auto' picks one job per 44 threads "
                        "-- 11 POWER9 cores each, four jobs on this box. "
                        "Dependent packages never overlap; see Slot.")
    p.add_argument("--job-budget", type=int, default=0, metavar="N",
                   help="total make/ninja parallelism to divide between jobs "
                        "(default: every CPU this process may run on). Each job "
                        "gets budget/jobs, overriding /etc/makepkg.conf's "
                        "MAKEFLAGS -- N jobs inheriting -j144 would be 144N "
                        "processes.")
    p.add_argument("--make-jobs", type=int, default=0, metavar="N",
                   help="force each job's -j to exactly N, instead of dividing "
                        "--job-budget")
    p.add_argument("--no-cpu-affinity", dest="cpu_affinity",
                   action="store_false", default=True,
                   help="do not pin each job to its own CPUs. MAKEFLAGS only "
                        "reaches make; ninja, cargo and LTO size themselves "
                        "from sched_getaffinity(), so without the pin they each "
                        "take the whole machine.")
    p.add_argument("--no-ccache", dest="ccache", action="store_false",
                   default=True,
                   help="do not enable ccache. /etc/makepkg.conf has !ccache "
                        "and is not ours to edit, so bq turns it on in its own "
                        "generated config instead. Rust is not covered: there "
                        "is no rustc shim and ccache does not speak Rust.")
    p.add_argument("--ccache-dir",
                   default=os.environ.get(
                       "BQ_CCACHE_DIR",
                       os.path.join(HOME, ".cache/ccache")),
                   help="where the compiler cache lives (default "
                        "~/.cache/ccache, which is ccache's own default). "
                        "Redirect it if that filesystem is short of space -- "
                        "bq reports the free space it sees at start-up.")
    p.add_argument("--ccache-size", default=os.environ.get("BQ_CCACHE_SIZE",
                                                           "100G"),
                   help="ccache max size (default 100G). Set here rather than "
                        "left to ~/.config/ccache/ccache.conf, so a bq run does "
                        "not depend on a config file bq does not write.")
    p.add_argument("--min-mem", type=float, default=16.0, metavar="GIB",
                   help="with -j, do not start another package while less than "
                        "this much memory is available. Link steps, not "
                        "compiles, are what a job budget does not bound.")
    p.add_argument("--sysroot", default=None,
                   help="staging root for build deps (default <buildroot>/sysroot)")
    p.add_argument("--timeout", type=int, default=14400)
    p.add_argument("--min-free", type=float, default=20.0,
                   help="defer a package if the buildroot has less than this many GiB")
    p.add_argument("--retry-failed", action="store_true")
    p.add_argument("--rebuild", action="store_true")
    p.add_argument("--force", action="store_true")
    p.add_argument("--exclude", default="",
                   help="comma-separated pkgbases to skip entirely")
    p.add_argument("--keep", action="store_true", help="do not clean build trees")
    p.add_argument("--stop-on-fail", action="store_true")
    p.add_argument("--fix-arch", action="store_true",
                   help="add powerpc64le to arch=() instead of failing")
    p.add_argument("--strict-deps", action="store_true",
                   help="skip a package whose declared build deps are absent, "
                        "rather than letting the build discover it")
    p.add_argument("--pkgdest", default=None,
                   help="where built packages go (default the Omarchy repo). "
                        "bq writes PKGDEST into its own generated makepkg.conf, "
                        "so this does not depend on the system one -- and the "
                        "system one should stay unset, or every hand-run makepkg "
                        "and every yay AUR build lands in the repo too.")
    p.add_argument("--full-bootstrap", action="store_true")
    p.add_argument("--repo-db", default="bq-staging.db.tar.zst",
                   help="repo database to add into; empty to skip repo-add. "
                        "This is bq's own staging database, not a published "
                        "pool db -- publishing is tools/repo-publish.sh")
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
    if hasattr(args, "jobs"):
        try:
            avail = len(os.sched_getaffinity(0))
        except AttributeError:
            avail = os.cpu_count() or 1
        if str(args.jobs).lower() == "auto":
            # 44 threads is 11 POWER9 cores, which is enough that a big package
            # still compiles fast and small enough that four of them fill the
            # machine.  Below 8 threads, splitting costs more than it buys.
            args.jobs = max(1, avail // 44)
        else:
            args.jobs = max(1, int(args.jobs))
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
