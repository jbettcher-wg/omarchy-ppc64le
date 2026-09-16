#!/usr/bin/env python3
"""
recipe-sync -- where each package we shipped stands against Arch POWER and Arch.

Read-only. It reads every repo database under repo/, our build scripts in the
packaging tree, the archpower checkout (origin/master, as a comparison only --
it is an import source, not something bq builds from) and Arch's GitLab tags,
and writes a report. It never writes into a recipe tree, the repo db or a package:
versions that need `makepkg --printsrcinfo` are computed in a temporary copy of
the recipe under /var/tmp, and nothing is ever written back as a .SRCINFO. The
only write to the archpower checkout is `git fetch origin` (remote-tracking
refs); pass --no-fetch to skip even that.

Usage
-----
  tools/recipe-sync.py report [--out FILE] [--no-fetch] [--max-age HOURS]
                              [--jobs N] [--net-jobs N] [--only A,B,...]

  --out FILE     write the TSV to FILE and the summary to stdout
                 (default: TSV on stdout, summary on stderr)
  --no-fetch     do not `git fetch origin` in the archpower checkout first
  --max-age H    reuse cached GitLab / nvchecker answers younger than H hours
                 (default 12; 0 refetches everything)
  --jobs N       concurrent makepkg --printsrcinfo runs (default 32)
  --net-jobs N   concurrent GitLab / nvchecker requests (default 8, max 8)
  --gitlab-rate N  GitLab requests started per minute (default 45; Arch
                 GitLab answers HTTP 429 past 60 unauthenticated git requests
                 a minute, so an uncached full run takes about 20 minutes)
  --no-upstream  skip the nvchecker pass (upstream column stays empty)
  --only A,B     restrict the report to these pkgbases
  --only-file F  restrict it to the pkgbases listed in F, one per line
  --nv-jobs N    concurrent nvchecker runs (default 4)
  --nv-rate N    nvchecker runs started per minute for non-GitHub sources
                 (default 20)
  --github-rate N  nvchecker runs started per hour for source = "github"
                 (default 50; GitHub's REST API allows about 60 an hour
                 unauthenticated). source = "git" uses git ls-remote, which
                 does not go through that API, so it takes the faster lane.
                 This tool never reads, asks for or passes an API token; to
                 check authenticated, put a keyfile in your own nvchecker
                 configuration and run nvchecker yourself.

  Example:
    tools/recipe-sync.py report --out /var/tmp/recipe-sync-report.tsv

Columns (TSV)
-------------
  pkgbase    %BASE% from the repo db
  source     where "ours" came from: packaging (the packaging tree, the only
             tree bq builds from), gitlab-only (it is not in the packaging
             tree), none (not on GitLab either)
  shipped    newest version across every repo database in repo/, which is the
             never-downgrade floor. The p9 -> ppc64le rename keeps two live at
             once (omarchy-power9.db.tar.gz and the partial
             omarchy-ppc64le.db.tar.zst), and reading only one makes packages
             we did ship look as though they never shipped; older entries are
             listed in the note
  ours       recipe version from the source above -- the recipe bq would
             build. The packaging tree is indexed by pkgbase at any depth with
             the shared closure.discover_recipes, the same way bq's DirSource
             resolves it, and a directory that moves while the report runs is
             re-resolved rather than failing. A pkgbase claimed by more than
             one directory is reported in the note, never silently resolved to
             the first
  archpower  the recipe for this pkgbase in archpower origin/master, at any
             depth: <pkgbase>/, <category>/<pkgbase>/ (kf6/, xorg/, qt6/,
             python/ ...), tde/<group>/<pkgbase>/, kernels/<arch>/<pkgbase>/
             and the leftover SVN <category>/<pkgbase>/trunk/. A directory
             holding a PKGBUILD is a recipe and is never descended into, so
             cscope/trunk/ beside cscope/ is not a second claim; the genuine
             collisions (gnome-common, malcontent, linux-ps3) are noted
  arch       Arch GitLab's current release: the newest (by vercmp) of the
             <pkgver>-<pkgrel> tags on HEAD; if HEAD is an untagged
             post-release commit, the version in HEAD's .SRCINFO; only if that
             cannot be read, the vercmp-newest tag of all. The vercmp-newest
             tag alone is wrong for repos with old or staging tags (kicad
             20130518-3, qt6-base 6.12.0beta4-1)
  upstream   nvchecker's newest upstream release, checked with the
             .nvchecker.toml from our recipe, the archpower working tree,
             archpower origin/master or Arch GitLab at HEAD, run on a
             temporary copy. Empty when there is no .nvchecker.toml, the
             source is "manual", or the source rate-limited us; the note then
             says which
  bucket     current | upstream-newer | ours-newer | diverged | unknown
  note       why, which side is newer, and flags (recipe-ahead-of-shipped)

Versions come from .SRCINFO when it agrees with the PKGBUILD's literal
pkgver/pkgrel/epoch; otherwise (no .SRCINFO, a stale one, or a computed pkgver
such as bash's ${_basever}.${_patchlevel}) from makepkg --printsrcinfo. Every
ordering uses pacman's vercmp (alpm_pkg_vercmp via libalpm, the function the
vercmp binary wraps; the binary itself if libalpm cannot be loaded).

Caches live under /var/tmp/recipe-sync-cache/: gitlab/ and nvchecker/ expire
after --max-age, srcinfo/ is keyed by recipe content and never goes stale.
"""

import io
import os
import re
import sys
import json
import time
import ctypes
import shutil
import hashlib
import tarfile
import argparse
import tempfile
import threading
import subprocess
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from closure import discover_recipes  # noqa: E402  (shared recipe discovery)

HOME = os.path.expanduser("~")
OMARCHY = os.path.join(HOME, "Development/omarchy-ppc64le")
# The one local source of build scripts -- what bq would actually build.
PACKAGING = os.environ.get(
    "OMARCHY_PACKAGING",
    os.path.join(HOME, "Development/omarchy-ppc64le-packaging"))
# Read-only comparison input only: the archpower checkout is no longer a build
# source, but origin/master is still how we see Arch POWER moving ahead of us.
ARCHPOWER = os.path.join(HOME, "Development/repo/archpower")
REPO = os.path.join(OMARCHY, "repo")
CACHE = "/var/tmp/recipe-sync-cache"
GITLAB = "https://gitlab.archlinux.org/archlinux/packaging/packages/%s.git"
MAX_FILE = 1 << 20          # recipe files larger than this are sources, not recipe
GIT_ENV = {**os.environ, "GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "",
           "SSH_ASKPASS": "", "LC_ALL": "C"}
BUCKETS = ("current", "upstream-newer", "ours-newer", "diverged", "unknown")


# ---------------------------------------------------------------- vercmp

class Vercmp:
    """pacman's version comparison. libalpm's alpm_pkg_vercmp is what the
    vercmp binary calls; loading it avoids ~50k forks for tag ordering. It is
    checked against the binary at start-up and dropped if they ever disagree."""

    PROBES = [("1.0-1", "1.0-2"), ("2.1.28-5.1", "2.1.28-5.3"),
              ("2:3.31.1-1", "3.32.0-1"), ("r5.43d1457-2", "6.30.0-1"),
              ("1.0a-1", "1.0-1"), ("6.29.0-1", "6.29.0-1"), ("1.0-24.1", "1.0-24")]

    def __init__(self):
        self.fn = None
        try:
            lib = ctypes.CDLL("libalpm.so")
            fn = lib.alpm_pkg_vercmp
            fn.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
            fn.restype = ctypes.c_int
            self.fn = fn
            if any(self._lib(a, b) != self._bin(a, b) for a, b in self.PROBES):
                self.fn = None
        except (OSError, AttributeError):
            self.fn = None

    @staticmethod
    def _sign(n):
        return (n > 0) - (n < 0)

    def _lib(self, a, b):
        return self._sign(self.fn(a.encode(), b.encode()))

    def _bin(self, a, b):
        r = subprocess.run(["vercmp", a, b], capture_output=True, text=True,
                           timeout=30)
        return self._sign(int(r.stdout.strip()))

    def __call__(self, a, b):
        return self._lib(a, b) if self.fn else self._bin(a, b)

    def newest(self, versions):
        best = None
        for v in versions:
            if best is None or self(v, best) > 0:
                best = v
        return best

    @property
    def backend(self):
        return "libalpm alpm_pkg_vercmp" if self.fn else "vercmp binary"


# ---------------------------------------------------------------- repo db

DB_NAME = re.compile(r".+\.db\.tar\.(gz|xz|zst|bz2)$")


def repo_dbs():
    """Every live repo database in the pool.

    The p9 -> ppc64le rename means two sit side by side
    (omarchy-power9.db.tar.gz, 1,355 entries, and omarchy-ppc64le.db.tar.zst,
    212). Reading only the first one found makes packages we did ship --
    kconfig, kio, libxcb, rust, gcc -- look as though they never shipped, and
    the never-downgrade floor has to be the newest across the whole pool."""
    out = []
    try:
        names = sorted(os.listdir(REPO))
    except OSError:
        return out
    for name in names:
        p = os.path.join(REPO, name)
        if DB_NAME.fullmatch(name) and os.path.isfile(p) and not os.path.islink(p):
            out.append(p)
    return out


def load_pool(dbs):
    """(pkgbase -> [(db, pkgname, version)], [(db, entry count)]) merged over
    every repo database in the pool."""
    merged, counts = {}, []
    for path in dbs:
        name, n = os.path.basename(path), 0
        for base, entries in load_db(path).items():
            merged.setdefault(base, []).extend((name, p, v) for p, v in entries)
            n += len(entries)
        counts.append((name, n))
    return merged, counts


def load_db(path):
    """pkgbase -> [(pkgname, version)] from one published repo database."""
    out = {}
    with tarfile.open(path) as t:
        for m in t:
            if not m.isfile() or not m.name.endswith("/desc"):
                continue
            fields, key = {}, None
            for ln in t.extractfile(m).read().decode("utf-8", "replace").splitlines():
                if len(ln) > 2 and ln.startswith("%") and ln.endswith("%"):
                    key = ln[1:-1]
                    fields[key] = []
                elif key and ln.strip():
                    fields[key].append(ln.strip())
            name = (fields.get("NAME") or [None])[0]
            ver = (fields.get("VERSION") or [None])[0]
            if not name or not ver:
                continue
            base = (fields.get("BASE") or [name])[0]
            out.setdefault(base, []).append((name, ver))
    return out


# ---------------------------------------------------------------- recipes

ASSIGN = re.compile(r"^(pkgver|pkgrel|epoch)=(.*)$")
INDENTED = re.compile(r"^\s+(pkgver|pkgrel|epoch)\+?=")
LITERAL = re.compile(r"^[A-Za-z0-9._+~]+$")
SRCINFO_KV = re.compile(r"^(pkgver|pkgrel|epoch)\s*=\s*(.*)$")


def literal_vars(pkgbuild):
    """pkgver/pkgrel/epoch as written in the PKGBUILD: the literal value, or
    None when it is computed, conditional or assigned more than once."""
    seen, out = {}, {}
    for ln in pkgbuild.splitlines():
        m = ASSIGN.match(ln.rstrip())
        if m:
            v = m.group(2).strip()
            if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                v = v[1:-1]
            seen.setdefault(m.group(1), []).append(v)
        elif INDENTED.match(ln):
            seen.setdefault(INDENTED.match(ln).group(1), []).extend([None, None])
    for k, vs in seen.items():
        out[k] = vs[0] if len(vs) == 1 and vs[0] and LITERAL.match(vs[0]) else None
    return out


def srcinfo_vars(text):
    """pkgver/pkgrel/epoch from the pkgbase section of a .SRCINFO."""
    v = {}
    for ln in text.splitlines():
        s = ln.strip()
        if s.startswith("pkgname ="):
            break
        m = SRCINFO_KV.match(s)
        if m and m.group(1) not in v:
            v[m.group(1)] = m.group(2).strip()
    return v if v.get("pkgver") and v.get("pkgrel") else None


def fmtver(v):
    e = v.get("epoch") or ""
    return ("%s:" % e if e and e != "0" else "") + "%s-%s" % (v["pkgver"], v["pkgrel"])


def consistent(lit, si):
    if lit.get("pkgver") is None or lit.get("pkgrel") is None:
        return False
    if lit["pkgver"] != si["pkgver"] or lit["pkgrel"] != si["pkgrel"]:
        return False
    le = lit.get("epoch", "0") if "epoch" in lit else "0"
    if le is None:
        return False
    return (le or "0") == (si.get("epoch") or "0")


def cache_read(path, max_age=None):
    try:
        with open(path) as f:
            d = json.load(f)
        if max_age is not None and time.time() - d.get("ts", 0) > max_age:
            return None
        return d
    except (OSError, ValueError):
        return None


def cache_write(path, d):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    d = dict(d, ts=time.time())
    tmp = "%s.%d.%d.tmp" % (path, os.getpid(), threading.get_ident())
    with open(tmp, "w") as f:
        json.dump(d, f)
    os.replace(tmp, path)


_TREE_IDX = {"maps": {}, "lock": threading.Lock()}


def tree_dirs(root, pkgbase, rescan=False):
    """Every directory in a recipe tree claiming this pkgbase, at any depth.

    closure.discover_recipes is the shared implementation, which bq's
    DirSource and closure.py also use: a directory containing a PKGBUILD is a
    recipe and is never descended into, a trailing trunk/ names its parent,
    and a pkgbase claimed by more than one directory comes back with all of
    them. Reporting the collision is the point; picking the first silently is
    the bug this removes. Re-scanning picks up a recipe that moves while the
    report runs."""
    with _TREE_IDX["lock"]:
        if rescan or root not in _TREE_IDX["maps"]:
            _TREE_IDX["maps"][root] = dict(discover_recipes(root))
        return list(_TREE_IDX["maps"][root].get(pkgbase) or ())


def packaging_dirs(pkgbase, rescan=False):
    return tree_dirs(PACKAGING, pkgbase, rescan)


def archpower_dirs(pkgbase, rescan=False):
    return tree_dirs(ARCHPOWER, pkgbase, rescan)


def dir_files(path):
    """Top-level recipe files of a working-tree directory, sources skipped."""
    files = {}
    try:
        entries = list(os.scandir(path))
    except OSError:
        return files
    for e in entries:
        try:
            if not e.is_file() or e.stat().st_size > MAX_FILE:
                continue
            if ".pkg.tar" in e.name or e.name.endswith(".log"):
                continue
            with open(e.path, "rb") as f:
                files[e.name] = f.read()
        except OSError:
            continue
    return files


def tree_files(sha):
    """Top-level recipe files of a git tree object in the archpower checkout."""
    r = subprocess.run(["git", "-C", ARCHPOWER, "archive", "--format=tar", sha],
                       capture_output=True, timeout=120, env=GIT_ENV)
    if r.returncode != 0:
        raise RuntimeError("git archive %s failed" % sha[:12])
    files = {}
    with tarfile.open(fileobj=io.BytesIO(r.stdout)) as t:
        for m in t:
            if m.isfile() and "/" not in m.name.strip("/") and m.size <= MAX_FILE:
                files[m.name.strip("/")] = t.extractfile(m).read()
    return files


def recipe_version(files, key=None):
    """(version, method, error) for one recipe's files."""
    if "PKGBUILD" not in files:
        return None, None, "no PKGBUILD"
    pb = files["PKGBUILD"].decode("utf-8", "replace")
    if ".SRCINFO" in files:
        si = srcinfo_vars(files[".SRCINFO"].decode("utf-8", "replace"))
        if si and consistent(literal_vars(pb), si):
            return fmtver(si), "srcinfo", None
    if key is None:
        h = hashlib.sha256()
        for n in sorted(files):
            if n != ".SRCINFO":
                h.update(n.encode() + b"\0" + files[n] + b"\0")
        key = h.hexdigest()
    cpath = os.path.join(CACHE, "srcinfo", key + ".json")
    c = cache_read(cpath)
    if c:
        return c["version"], "makepkg", None
    tmp = tempfile.mkdtemp(prefix="recipe-sync.", dir="/var/tmp")
    try:
        for n, data in files.items():
            if n != ".SRCINFO":
                with open(os.path.join(tmp, n), "wb") as f:
                    f.write(data)
        r = subprocess.run(["makepkg", "--printsrcinfo"], cwd=tmp,
                           capture_output=True, text=True, timeout=300,
                           env=GIT_ENV, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return None, "makepkg", "makepkg --printsrcinfo timed out"
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    si = srcinfo_vars(r.stdout) if r.returncode == 0 else None
    if not si:
        err = [l for l in r.stderr.splitlines() if l.strip()]
        msg = re.sub(r"\x1b\[[0-9;]*m", "", err[-1] if err else "no pkgver")
        return None, "makepkg", "makepkg --printsrcinfo: " + msg.strip()
    cache_write(cpath, {"version": fmtver(si)})
    return fmtver(si), "makepkg", None


def cached_tree_version(sha):
    cpath = os.path.join(CACHE, "srcinfo", "tree-" + sha + ".json")
    c = cache_read(cpath)
    if c:
        return c["version"], "cache", None
    try:
        files = tree_files(sha)
    except (RuntimeError, subprocess.TimeoutExpired, tarfile.TarError) as e:
        return None, None, str(e)
    v, how, err = recipe_version(files)
    if v:
        cache_write(cpath, {"version": v})
    return v, how, err


# ---------------------------------------------------------------- archpower

def fetch_archpower():
    try:
        r = subprocess.run(["git", "-C", ARCHPOWER, "fetch", "origin"],
                           capture_output=True, text=True, timeout=600,
                           env=GIT_ENV, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return "git fetch origin timed out; using existing origin/master"
    if r.returncode != 0:
        err = [l for l in r.stderr.splitlines() if l.strip()]
        return "git fetch origin failed (%s); using existing origin/master" % (
            err[-1] if err else r.returncode)
    return "fetched"


def origin_trees():
    """pkgbase -> [(path, tree sha)] of recipe directories in origin/master.

    archpower is mostly flat, but groups ~190 of our pkgbases under category
    directories (kf6/kconfig, xorg/libx11, qt6/qt6-base, python/python,
    go/go ...). Top-level recipes sort first; a name in two places
    (gnome-common, malcontent) keeps both, and the report notes it."""
    def git(*a):
        r = subprocess.run(["git", "-C", ARCHPOWER] + list(a), capture_output=True,
                           text=True, timeout=120, env=GIT_ENV)
        if r.returncode != 0:
            raise SystemExit("recipe-sync: cannot read archpower origin/master")
        return r.stdout.splitlines()

    shas = {}
    for ln in git("ls-tree", "-r", "-d", "origin/master"):
        meta, _, path = ln.partition("\t")
        f = meta.split()
        if len(f) == 3:
            shas[path] = f[2]
    dirs = [p[:-len("/PKGBUILD")] for p in
            git("ls-tree", "-r", "--name-only", "origin/master")
            if p.endswith("/PKGBUILD")]
    have = set(dirs)
    out = {}
    for d in dirs:
        parts = d.split("/")
        # Same rule as closure.discover_recipes: a directory containing a
        # PKGBUILD is a recipe and is never descended into, so cscope/trunk
        # under cscope/ and python/python-pycparser/python-cffi are not second
        # directories claiming a pkgbase that already resolved.
        if any("/".join(parts[:i]) in have for i in range(1, len(parts))):
            continue
        base = parts[-2] if parts[-1] == "trunk" and len(parts) > 1 else parts[-1]
        if d in shas:
            out.setdefault(base, []).append((d, shas[d]))
    for v in out.values():
        v.sort(key=lambda x: (x[0].count("/"), x[0]))
    return out


def origin_date():
    r = subprocess.run(["git", "-C", ARCHPOWER, "log", "-1", "--format=%h %cI",
                        "origin/master"], capture_output=True, text=True,
                       timeout=60, env=GIT_ENV)
    return r.stdout.strip()


# ---------------------------------------------------------------- Arch GitLab

def gitlab_path(name):
    """Arch's pkgbase -> GitLab project path rule (devtools
    gitlab_project_name_to_path): gtk+ -> gtkplus, dvd+rw -> dvd-rw."""
    n = re.sub(r"([a-zA-Z0-9]+)\+([a-zA-Z]+)", r"\1-\2", name)
    n = n.replace("+", "plus")
    n = re.sub(r"[^a-zA-Z0-9_\-.]", "-", n)
    n = re.sub(r"[_\-]{2,}", "-", n)
    return "unix-tree" if n == "tree" else n


TAG = re.compile(r"^(?:(\d+)-)?([^-/:]+)-(\d+(?:\.\d+)?)$")
ABSENT = re.compile(r"could not read Username|terminal prompts disabled|"
                    r"not found|error: 404", re.I)


class RateLimit:
    """Arch GitLab throttles unauthenticated git-over-HTTP
    (throttle_unauthenticated_git_http: 60 requests a minute, HTTP 429 past
    that). A first full run at 8 concurrent requests got 429 for 639 of 940
    pkgbases. Space request starts out, and when a 429 comes back anyway, hold
    every worker until the window has reset."""

    def __init__(self, per_minute):
        self.gap = 60.0 / max(1.0, per_minute)
        self.lock = threading.Lock()
        self.next = 0.0

    def wait(self):
        with self.lock:
            now = time.monotonic()
            start = max(now, self.next)
            self.next = start + self.gap
        if start > now:
            time.sleep(start - now)

    def pause(self, seconds):
        with self.lock:
            self.next = max(self.next, time.monotonic() + seconds)


GITLAB_SCHEMA = 2
GITLAB_ATTEMPTS = 6


def gitlab_tags(pkgbase, max_age, limiter):
    """One `git ls-remote` per pkgbase: all tags, and which of them sit on
    HEAD (Arch's current release)."""
    cpath = os.path.join(CACHE, "gitlab", pkgbase + ".json")
    c = cache_read(cpath, max_age)
    if c and c.get("v") == GITLAB_SCHEMA:
        return c
    url = GITLAB % gitlab_path(pkgbase)
    for _ in range(GITLAB_ATTEMPTS):
        limiter.wait()
        try:
            r = subprocess.run(["git", "ls-remote", url],
                               capture_output=True, text=True, timeout=60,
                               env=GIT_ENV, stdin=subprocess.DEVNULL)
        except subprocess.TimeoutExpired:
            return {"status": "error", "error": "GitLab ls-remote timed out"}
        if r.returncode == 0:
            head, direct, peeled = None, {}, {}
            for ln in r.stdout.splitlines():
                sha, _, ref = ln.partition("\t")
                if ref == "HEAD":
                    head = sha
                elif ref.startswith("refs/tags/"):
                    name = ref[len("refs/tags/"):]
                    if name.endswith("^{}"):
                        peeled[name[:-3]] = sha
                    else:
                        direct[name] = sha
            tags = sorted(direct)
            head_tags = [t for t in tags if head and peeled.get(t, direct[t]) == head]
            res = {"status": "ok", "v": GITLAB_SCHEMA, "tags": tags,
                   "head_tags": head_tags}
            break
        if "error: 429" in r.stderr:
            limiter.pause(61)
            continue
        if ABSENT.search(r.stderr):
            res = {"status": "absent", "v": GITLAB_SCHEMA}
            break
        err = [l for l in r.stderr.splitlines() if l.strip()]
        return {"status": "error",
                "error": "GitLab ls-remote: " + (err[-1] if err else str(r.returncode))}
    else:
        return {"status": "error", "error": "GitLab ls-remote: HTTP 429 after "
                "%d attempts" % GITLAB_ATTEMPTS}
    cache_write(cpath, res)
    return res


GITLAB_RAW = ("https://gitlab.archlinux.org/archlinux/packaging/packages/%s"
              "/-/raw/HEAD/%s")


def gitlab_raw(pkgbase, filename, max_age, limiter):
    """One file from Arch GitLab at HEAD. Returns (text, error); (None, None)
    when Arch simply does not ship that file."""
    cpath = os.path.join(CACHE, "gitlab-raw",
                         "%s%s.json" % (pkgbase, filename))
    c = cache_read(cpath, max_age)
    if c:
        return c.get("text"), None
    url = GITLAB_RAW % (gitlab_path(pkgbase), filename)
    for _ in range(GITLAB_ATTEMPTS):
        limiter.wait()
        try:
            with urllib.request.urlopen(url, timeout=30) as resp:
                text = resp.read().decode("utf-8", "replace")
            break
        except urllib.error.HTTPError as e:
            if e.code == 429:
                limiter.pause(61)
                continue
            if e.code == 404:
                cache_write(cpath, {"text": None})
                return None, None
            return None, "%s: HTTP %d" % (filename, e.code)
        except (urllib.error.URLError, OSError) as e:
            return None, "%s: %s" % (filename, e)
    else:
        return None, "%s: HTTP 429 after %d attempts" % (filename, GITLAB_ATTEMPTS)
    cache_write(cpath, {"text": text})
    return text, None


def gitlab_head_version(pkgbase, max_age, limiter):
    """Version in the .SRCINFO at HEAD, for repos whose HEAD carries no tag
    (a post-release commit such as a REUSE or nvchecker change). The
    vercmp-newest tag is not a substitute: kicad's is 20130518-3 and
    modemmanager's 20100109-1. Returns (version, error)."""
    text, err = gitlab_raw(pkgbase, ".SRCINFO", max_age, limiter)
    if err:
        return None, err
    if not text:
        return None, "HEAD has no .SRCINFO"
    si = srcinfo_vars(text)
    if not si:
        return None, "HEAD .SRCINFO has no pkgver/pkgrel"
    return fmtver(si), None


def tag_version(tag):
    m = TAG.match(tag)
    if not m:
        return None
    e, v, rel = m.groups()
    return ("%s:" % e if e else "") + "%s-%s" % (v, rel)


# ---------------------------------------------------------------- nvchecker

NV_SOURCE = re.compile(r"^\s*source\s*=\s*['\"]?([A-Za-z_]+)", re.M)
NV_TABLE = re.compile(r"^\s*\[([^\]]+)\]", re.M)
NV_LIMITED = re.compile(r"rate limit|ratelimit|HTTP 403|403 Forbidden|429", re.I)


def nvchecker_toml(pkgbase, ours_dir, ours_label, trees, max_age, limiter):
    """The .nvchecker.toml to check this pkgbase with, and where it came
    from: our own recipe, the archpower working tree, archpower
    origin/master (category directories included), or Arch GitLab at HEAD."""
    local, apwt = packaging_dirs(pkgbase), archpower_dirs(pkgbase)
    for d, label in ((ours_dir, ours_label or "ours"),
                     (local[0] if local else None, "packaging"),
                     (apwt[0] if apwt else None, "archpower")):
        if not d:
            continue
        try:
            with open(os.path.join(d, ".nvchecker.toml"), encoding="utf-8",
                      errors="replace") as f:
                return f.read(), label, None
        except OSError:
            continue  # absent, or moved out from under us
    for _, sha in trees.get(pkgbase, []):
        r = subprocess.run(["git", "-C", ARCHPOWER, "show",
                            "%s:.nvchecker.toml" % sha], capture_output=True,
                           text=True, timeout=60, env=GIT_ENV)
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout, "archpower-origin", None
    text, err = gitlab_raw(pkgbase, ".nvchecker.toml", max_age, limiter)
    if err:
        return None, None, err
    if text:
        return text, "arch-gitlab", None
    return None, None, "no .nvchecker.toml in our recipe, archpower or Arch"


def strip_nv_config(text):
    """Drop a [__config__] table. It can point nvchecker at a keyfile of API
    tokens; this tool never reads, asks for or passes tokens. A user who
    wants authenticated checks puts the keyfile in their own nvchecker
    configuration and runs nvchecker directly."""
    tables, out, drop = list(NV_TABLE.finditer(text)), [], False
    if not tables:
        return text, False
    dropped = False
    pos = 0
    for i, m in enumerate(tables):
        end = tables[i + 1].start() if i + 1 < len(tables) else len(text)
        if m.group(1).strip() == "__config__":
            out.append(text[pos:m.start()])
            dropped = True
        else:
            out.append(text[pos:end])
        pos = end
    return "".join(out), dropped


def nvchecker_version(pkgbase, toml_text, max_age, limiters):
    """(version, reason, source kind). nvchecker is run on a temporary copy
    of the config; nothing is written into a recipe tree."""
    m = NV_SOURCE.search(toml_text)
    kind = m.group(1) if m else "?"
    key = hashlib.sha256(("%s\0%s" % (pkgbase, toml_text)).encode()).hexdigest()
    cpath = os.path.join(CACHE, "nvchecker", key + ".json")
    c = cache_read(cpath, max_age)
    if c:
        return c.get("version"), c.get("reason"), kind
    if kind == "manual":
        return None, "nvchecker source is manual (no upstream check)", kind
    cfg, dropped = strip_nv_config(toml_text)
    # GitHub's REST API allows ~60 unauthenticated requests an hour; the git
    # and gitlab sources do not go through it, so they get the faster lane.
    limiters["github" if kind == "github" else "other"].wait()
    tmp = tempfile.mkdtemp(prefix="recipe-sync-nv.", dir="/var/tmp")
    try:
        path = os.path.join(tmp, "nvchecker.toml")
        with open(path, "w") as f:
            f.write(cfg)
        r = subprocess.run(["nvchecker", "-c", path, "--logger", "json"],
                           capture_output=True, text=True, timeout=180,
                           stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return None, "nvchecker timed out", kind
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    found, errs = {}, []
    for ln in (r.stdout + "\n" + r.stderr).splitlines():
        try:
            d = json.loads(ln)
        except ValueError:
            if ln.strip():
                errs.append(ln.strip())
            continue
        if d.get("version"):
            found[d.get("name") or pkgbase] = d["version"]
        if d.get("level") in ("error", "critical"):
            errs.append("%s: %s" % (d.get("event", "error"),
                                    d.get("error") or d.get("exc_info") or ""))
    # Arch names the table after the pkgname, which is not always the pkgbase
    # (libsasl's is cyrus-sasl): take that entry when there is only one.
    if pkgbase in found:
        ver = found[pkgbase]
    elif len(found) == 1:
        ver = next(iter(found.values()))
    else:
        ver = None
        if found:
            errs.append("several results: " + ", ".join(sorted(found)))
    reason = None
    if ver is None:
        detail = "; ".join(errs)[:200] or "nvchecker returned no version"
        if NV_LIMITED.search(detail):
            reason = ("%s rate-limited: %s (a token in your own nvchecker "
                      "keyfile would lift this)" % (kind, detail[:120]))
        else:
            reason = "nvchecker (%s): %s" % (kind, detail)
    if dropped:
        reason = ((reason + "; ") if reason else "") + "[__config__] ignored"
    if ver is not None:
        cache_write(cpath, {"version": ver, "reason": reason})
    return ver, reason, kind


# ---------------------------------------------------------------- classify

def classify(vc, shipped, ours, ap, arch, source, errors):
    notes = []
    if ours and vc(ours, shipped) > 0:
        notes.append("recipe-ahead-of-shipped")
    if errors:
        return "unknown", errors + notes
    known = [(n, v) for n, v in (("archpower", ap), ("arch", arch)) if v]
    if not known:
        return "unknown", ["not in archpower origin or on Arch GitLab; nothing "
                           "to compare against"] + notes
    newer = ["%s %s" % (n, v) for n, v in known if vc(v, shipped) > 0]
    newer_note = ["newer: " + ", ".join(newer)] if newer else []
    matches_upstream = lambda x: any(vc(x, v) == 0 for _, v in known)
    if ours:
        c = vc(ours, shipped)
        if c > 0 and not matches_upstream(ours):
            # Recipe bumped past shipped to a version neither side has.
            return "diverged", ["unbuilt local change: %s recipe %s matches "
                                "neither archpower nor arch" % (source, ours)] + \
                newer_note + notes
        if c < 0:
            if not matches_upstream(shipped):
                # Shipped from a recipe no tree carries any more.
                return "diverged", ["shipped matches neither archpower nor arch "
                                    "and %s recipe %s is older" % (source, ours)] + \
                    newer_note + notes
            notes.append("%s recipe %s older than shipped (a rebuild from it "
                         "would downgrade)" % (source, ours))
    if newer:
        return "upstream-newer", ["newer: " + ", ".join(newer)] + notes
    if any(vc(v, shipped) == 0 for _, v in known):
        return "current", notes
    return "ours-newer", notes


def split_ver(v):
    epoch, rest = v.split(":", 1) if ":" in v else ("0", v)
    pkgver, _, rel = rest.rpartition("-")
    return int(epoch) if epoch.isdigit() else 0, pkgver, rel


def gap_key(shipped, target):
    """Rank how far apart two versions are (for the summary only; ordering is
    vercmp's). Epoch > earlier pkgver component > numeric delta > pkgrel."""
    e1, v1, r1 = split_ver(shipped)
    e2, v2, r2 = split_ver(target)
    if e1 != e2:
        return (3, 0, e2 - e1)
    a, b = re.findall(r"\d+|[A-Za-z]+", v1), re.findall(r"\d+|[A-Za-z]+", v2)
    for i, (x, y) in enumerate(zip(a, b)):
        if x != y:
            d = int(y) - int(x) if x.isdigit() and y.isdigit() else 1
            return (2, -i, d)
    if len(a) != len(b):
        return (2, -min(len(a), len(b)), 1)
    try:
        return (1, 0, float(r2) - float(r1))
    except ValueError:
        return (1, 0, 0)


# ---------------------------------------------------------------- report

def clean(s):
    return re.sub(r"[\t\r\n]+", " ", s or "")


def cmd_report(args):
    vc = Vercmp()
    dbs = repo_dbs()
    if not dbs:
        raise SystemExit("recipe-sync: no repo database under %s" % REPO)
    db, pool = load_pool(dbs)
    bases = sorted(db)
    if args.only_file:
        names = [l.split("#")[0].strip() for l in open(args.only_file)]
        args.only = ",".join(n for n in names if n)
    if args.only:
        want = set(args.only.split(","))
        bases = [b for b in bases if b in want]
        missing = want - set(bases)
        if missing:
            print("recipe-sync: not in the repo db: %s" % ", ".join(sorted(missing)),
                  file=sys.stderr)

    fetch = "skipped (--no-fetch)" if args.no_fetch else fetch_archpower()
    trees = origin_trees()
    have_nv = shutil.which("nvchecker") is not None and not args.no_upstream
    max_age = args.max_age * 3600

    def ours_job(b):
        # One tree now: whatever the packaging tree holds for this pkgbase is
        # what bq would build. The archpower working tree is deliberately NOT
        # a fallback any more -- it is an import source, and reading it here
        # would report a version no builder would actually produce.
        #
        # Two passes: if the recipe directory moves between the scan and the
        # read, re-scan and take the new path instead of failing.
        for attempt in (0, 1):
            dirs = packaging_dirs(b, rescan=attempt == 1)
            if not dirs:
                break
            files = dir_files(dirs[0])
            if files.get("PKGBUILD"):
                return ("packaging", dirs[0]) + recipe_version(files) + (dirs,)
        return (None, None, None, None, None, [])

    def origin_job(b):
        if b not in trees:
            return None, None, None
        return cached_tree_version(trees[b][0][1])

    net_jobs = max(1, min(8, args.net_jobs))
    with ThreadPoolExecutor(max_workers=args.jobs) as cpu, \
            ThreadPoolExecutor(max_workers=net_jobs) as net:
        f_ours = {b: cpu.submit(ours_job, b) for b in bases}
        f_orig = {b: cpu.submit(origin_job, b) for b in bases}
        limiter = RateLimit(args.gitlab_rate)
        f_lab = {b: net.submit(gitlab_tags, b, max_age, limiter) for b in bases}
        ours = {b: f.result() for b, f in f_ours.items()}
        orig = {b: f.result() for b, f in f_orig.items()}
        lab = {b: f.result() for b, f in f_lab.items()}
        f_head = {b: net.submit(gitlab_head_version, b, max_age, limiter)
                  for b in bases
                  if lab[b]["status"] == "ok" and not lab[b]["head_tags"]}
        head = {b: f.result() for b, f in f_head.items()}

        nv = {}
        if have_nv:
            limiters = {"github": RateLimit(args.github_rate / 60.0),
                        "other": RateLimit(args.nv_rate)}

            def nv_job(b):
                text, where, err = nvchecker_toml(b, ours[b][1], ours[b][0],
                                                  trees, max_age, limiter)
                if not text:
                    return None, err, None, None
                v, reason, kind = nvchecker_version(b, text, max_age, limiters)
                return v, reason, kind, where

            with ThreadPoolExecutor(max_workers=args.nv_jobs) as nvpool:
                f_nv = {b: nvpool.submit(nv_job, b) for b in bases}
                nv = {b: f.result() for b, f in f_nv.items()}

    rows = []
    for b in bases:
        errors, notes = [], []
        versions = sorted({v for _, _, v in db[b]})
        shipped = vc.newest(versions)
        if len(versions) > 1:
            stale = sorted({"%s %s in %s" % (n, v, d)
                            for d, n, v in db[b] if v != shipped})
            notes.append("older entries: " + ", ".join(stale))

        src, _, o_ver, _, o_err, o_dirs = ours[b]
        if o_err:
            errors.append("ours (%s): %s" % (src, o_err))
        if len(o_dirs) > 1:
            notes.append("%d directories claim this pkgbase: %s; ours uses %s"
                         % (len(o_dirs),
                            ", ".join(os.path.relpath(x, PACKAGING)
                                      for x in o_dirs),
                            os.path.relpath(o_dirs[0], PACKAGING)))

        a_ver, _, a_err = orig[b]
        if a_err:
            errors.append("archpower origin: " + a_err)
        paths = [p for p, _ in trees.get(b, [])]
        if paths and "/" in paths[0]:
            notes.append("archpower recipe at %s" % paths[0])
        if len(paths) > 1:
            notes.append("archpower has %s; archpower column uses %s"
                         % (" and ".join(paths), paths[0]))

        g = lab[b]
        arch = None
        if g["status"] == "ok":
            tagged = [v for v in map(tag_version, g["tags"]) if v]
            top = vc.newest(tagged)
            at_head = vc.newest([v for v in map(tag_version, g["head_tags"]) if v])
            if top is None:
                errors.append("Arch GitLab: %d tags, none parse as "
                              "<pkgver>-<pkgrel>" % len(g["tags"]))
            elif at_head is not None:
                arch = at_head
                if vc(top, at_head) != 0:
                    notes.append("Arch HEAD is tag %s; older tag %s sorts higher "
                                 "by vercmp" % (at_head, top))
            else:
                hv, herr = head.get(b, (None, "not fetched"))
                if hv:
                    arch = hv
                    if not any(vc(hv, t) == 0 for t in tagged):
                        notes.append("Arch HEAD .SRCINFO %s has no release tag" % hv)
                    elif vc(top, hv) != 0:
                        notes.append("Arch HEAD untagged, its .SRCINFO is %s; older "
                                     "tag %s sorts higher by vercmp" % (hv, top))
                else:
                    arch = top
                    notes.append("Arch HEAD untagged and %s; arch is the "
                                 "vercmp-newest tag" % herr)
        elif g["status"] == "error":
            errors.append(g["error"])

        if src is None:
            src = "gitlab-only" if g["status"] == "ok" else "none"
        if src == "archpower" and o_ver and a_ver and vc(o_ver, a_ver) != 0:
            notes.append("archpower working tree %s differs from origin %s"
                         % (o_ver, a_ver))

        upstream = ""
        if b in nv:
            uv, ureason, ukind, uwhere = nv[b]
            upstream = uv or ""
            if uv:
                # Upstream releases carry no pkgrel, so compare pkgver only.
                if vc(uv, split_ver(shipped)[1]) > 0:
                    notes.append("behind upstream %s (%s via %s)"
                                 % (uv, ukind, uwhere))
            elif ureason:
                notes.append("upstream unchecked: " + ureason)

        bucket, cnotes = classify(vc, shipped, o_ver, a_ver, arch, src, errors)
        rows.append({"pkgbase": b, "source": src, "shipped": shipped,
                     "ours": o_ver or "", "archpower": a_ver or "",
                     "arch": arch or "", "upstream": upstream,
                     "bucket": bucket, "note": "; ".join(cnotes + notes)})

    cols = ["pkgbase", "source", "shipped", "ours", "archpower", "arch",
            "upstream", "bucket", "note"]
    tsv = "\t".join(cols) + "\n" + "".join(
        "\t".join(clean(r[c]) for c in cols) + "\n" for r in rows)
    if args.out:
        with open(args.out, "w") as f:
            f.write(tsv)
        summary_fh = sys.stdout
    else:
        sys.stdout.write(tsv)
        summary_fh = sys.stderr

    summary(rows, vc, fetch, have_nv, pool, summary_fh)


def summary(rows, vc, fetch, have_nv, pool, fh):
    p = lambda *a: print(*a, file=fh)
    counts = {k: 0 for k in BUCKETS}
    for r in rows:
        counts[r["bucket"]] += 1
    p("recipe-sync report: %d pkgbases" % len(rows))
    p("  repo pool: %s" % ", ".join("%s (%d)" % (n, c) for n, c in pool))
    p("  archpower: %s; origin/master %s" % (fetch, origin_date()))
    p("  vercmp: %s" % vc.backend)
    p("  upstream: %s" % ("nvchecker" if have_nv else
                          "nvchecker not installed; column left empty"))
    p("")
    p("buckets")
    for k in BUCKETS:
        p("  %-15s %5d" % (k, counts[k]))
    ahead = [r for r in rows if "recipe-ahead-of-shipped" in r["note"]]
    p("  %-15s %5d  (flag, overlaps the buckets)" % ("recipe-ahead", len(ahead)))
    p("  arch column: %d where an older tag sorts higher by vercmp than the "
      "current release; %d untagged HEAD .SRCINFO versions; %d fell back to "
      "the vercmp-newest tag"
      % (sum("sorts higher by vercmp" in r["note"] for r in rows),
         sum("has no release tag" in r["note"] for r in rows),
         sum("arch is the vercmp-newest tag" in r["note"] for r in rows)))

    up = [r for r in rows if r["bucket"] == "upstream-newer"]

    def target(r):
        c = [v for v in (r["archpower"], r["arch"]) if v]
        return vc.newest(c)

    p("")
    p("Policy: be ahead of Arch POWER, or at worst at parity, and never")
    p("downgrade for parity. Anything below is a package to move forward.")
    p("")
    p("largest upstream-newer gaps (epoch > leading pkgver component > delta > pkgrel)")
    ranked = sorted(up, key=lambda r: gap_key(r["shipped"], target(r)), reverse=True)
    for r in ranked[:20]:
        t = target(r)
        side = "+".join(n for n in ("archpower", "arch")
                        if r[n] and vc(r[n], r["shipped"]) > 0 and vc(r[n], t) == 0)
        p("  %-28s %-24s -> %-24s (%s)" % (r["pkgbase"], r["shipped"], t, side))

    shadow = [r for r in up if r["archpower"] and vc(r["archpower"], r["shipped"]) > 0]
    p("")
    p("shadowing [base]: archpower newer than shipped (%d)" % len(shadow))
    for r in shadow:
        p("  %-28s %-24s <  archpower %s" % (r["pkgbase"], r["shipped"], r["archpower"]))

    if ahead:
        p("")
        p("recipe-ahead-of-shipped (%d)" % len(ahead))
        for r in ahead:
            p("  %-28s shipped %-22s %s recipe %s" % (r["pkgbase"], r["shipped"],
                                                     r["source"], r["ours"]))

    mine = [r for r in rows if r["bucket"] == "ours-newer"]
    if mine:
        p("")
        p("ahead of Arch POWER and Arch (%d) -- fine to keep, and candidates "
          "to offer upstream" % len(mine))
        for r in mine:
            p("  %-28s ours %-22s archpower %-16s arch %s"
              % (r["pkgbase"], r["shipped"], r["archpower"] or "-",
                 r["arch"] or "-"))

    older = [r for r in rows if "would downgrade" in r["note"]]
    if older:
        p("")
        p("recipes older than what we ship (%d) -- do not rebuild these from "
          "that recipe; forward-port instead" % len(older))
        for r in older:
            p("  %-28s shipped %-22s recipe %s" % (r["pkgbase"], r["shipped"],
                                                   r["ours"]))

    checked = [r for r in rows if r["upstream"]]
    behind_up = [r for r in rows if "behind upstream" in r["note"]]
    unchecked = [r for r in rows if not r["upstream"]
                 and "upstream unchecked" in r["note"]]
    if checked or unchecked:
        p("")
        p("upstream: %d of %d checked; %d behind upstream" %
          (len(checked), len(rows), len(behind_up)))
        for r in behind_up:
            p("  %-28s shipped %-22s upstream %s"
              % (r["pkgbase"], r["shipped"], r["upstream"]))
        if unchecked:
            why = {}
            for r in unchecked:
                m = re.search(r"upstream unchecked: ([^;]*)", r["note"])
                key = (m.group(1) if m else "?")[:60]
                why.setdefault(key, []).append(r["pkgbase"])
            p("  not checked:")
            for key, names in sorted(why.items(), key=lambda kv: -len(kv[1])):
                p("    %-58s %d  %s" % (key, len(names),
                                        " ".join(sorted(names))[:60]))

    unk = [r for r in rows if r["bucket"] == "unknown"]
    if unk:
        p("")
        p("unknown (%d)" % len(unk))
        for r in unk:
            p("  %-28s %s" % (r["pkgbase"], r["note"]))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0].strip())
    sub = ap.add_subparsers(dest="cmd", required=True)
    rp = sub.add_parser("report", help="write the version report")
    rp.add_argument("--out")
    rp.add_argument("--no-fetch", action="store_true")
    rp.add_argument("--max-age", type=float, default=12)
    rp.add_argument("--jobs", type=int, default=32)
    rp.add_argument("--net-jobs", type=int, default=8)
    rp.add_argument("--gitlab-rate", type=float, default=45)
    rp.add_argument("--nv-jobs", type=int, default=4)
    rp.add_argument("--nv-rate", type=float, default=20)
    rp.add_argument("--github-rate", type=float, default=50)
    rp.add_argument("--no-upstream", action="store_true")
    rp.add_argument("--only")
    rp.add_argument("--only-file")
    args = ap.parse_args()
    if args.cmd == "report":
        cmd_report(args)


if __name__ == "__main__":
    main()
