#!/usr/bin/env python3
"""
recipe-sync -- where each package we shipped stands against Arch POWER and Arch.

Read-only. It reads repo/omarchy-power9.db, our recipes under packages/, the
archpower checkout (working tree and origin/master) and Arch's GitLab tags, and
writes a report. It never writes into a recipe tree, the repo db or a package:
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
  --only A,B     restrict the report to these pkgbases

  Example:
    tools/recipe-sync.py report --out /var/tmp/recipe-sync-report.tsv

Columns (TSV)
-------------
  pkgbase    %BASE% from the repo db
  source     where "ours" came from: local (packages/), archpower (the
             working tree), gitlab-only (neither tree has it), none (not on
             GitLab either)
  shipped    version in omarchy-power9.db (newest, if entries disagree)
  ours       recipe version from the source above
  archpower  archpower origin/master:<pkgbase>/PKGBUILD, or
             <category>/<pkgbase>/PKGBUILD (kf6/, xorg/, qt6/, python/ ...)
             when there is no top-level recipe. "ours" does not follow the
             nesting, because bq's archpower source does not.
  arch       Arch GitLab's current release: the newest (by vercmp) of the
             <pkgver>-<pkgrel> tags on HEAD; if HEAD is an untagged
             post-release commit, the version in HEAD's .SRCINFO; only if that
             cannot be read, the vercmp-newest tag of all. The vercmp-newest
             tag alone is wrong for repos with old or staging tags (kicad
             20130518-3, qt6-base 6.12.0beta4-1)
  upstream   nvchecker result (empty when nvchecker is not installed)
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

HOME = os.path.expanduser("~")
OMARCHY = os.path.join(HOME, "Development/omarchy-ppc64le")
LOCAL = os.path.join(OMARCHY, "packages")
ARCHPOWER = os.path.join(HOME, "Development/repo/archpower")
DB = os.path.join(OMARCHY, "repo/omarchy-power9.db.tar.gz")
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

def load_db(path):
    """pkgbase -> [(pkgname, version)] from the published repo database."""
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
    out = {}
    for path in git("ls-tree", "-r", "--name-only", "origin/master"):
        parts = path.split("/")
        if parts[-1] == "PKGBUILD" and len(parts) in (2, 3):
            d = "/".join(parts[:-1])
            if d in shas:
                out.setdefault(parts[-2], []).append((d, shas[d]))
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
              "/-/raw/HEAD/.SRCINFO")


def gitlab_head_version(pkgbase, max_age, limiter):
    """Version in the .SRCINFO at HEAD, for repos whose HEAD carries no tag
    (a post-release commit such as a REUSE or nvchecker change). The
    vercmp-newest tag is not a substitute: kicad's is 20130518-3 and
    modemmanager's 20100109-1. Returns (version, error)."""
    cpath = os.path.join(CACHE, "gitlab-head", pkgbase + ".json")
    c = cache_read(cpath, max_age)
    if c:
        return c.get("version"), None
    url = GITLAB_RAW % gitlab_path(pkgbase)
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
            return None, "HEAD .SRCINFO: HTTP %d" % e.code
        except (urllib.error.URLError, OSError) as e:
            return None, "HEAD .SRCINFO: %s" % e
    else:
        return None, "HEAD .SRCINFO: HTTP 429 after %d attempts" % GITLAB_ATTEMPTS
    si = srcinfo_vars(text)
    if not si:
        return None, "HEAD .SRCINFO has no pkgver/pkgrel"
    cache_write(cpath, {"version": fmtver(si)})
    return fmtver(si), None


def tag_version(tag):
    m = TAG.match(tag)
    if not m:
        return None
    e, v, rel = m.groups()
    return ("%s:" % e if e else "") + "%s-%s" % (v, rel)


# ---------------------------------------------------------------- nvchecker

def nvchecker_version(pkgbase, recipedir, max_age):
    toml = os.path.join(recipedir, ".nvchecker.toml")
    if not os.path.isfile(toml):
        return None, None
    data = open(toml, "rb").read()
    key = hashlib.sha256(data).hexdigest()
    cpath = os.path.join(CACHE, "nvchecker", key + ".json")
    c = cache_read(cpath, max_age)
    if c:
        return c.get("version"), None
    try:
        r = subprocess.run(["nvchecker", "-c", toml, "--logger", "json"],
                           capture_output=True, text=True, timeout=120,
                           stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return None, "nvchecker timed out"
    ver = None
    for ln in (r.stdout + "\n" + r.stderr).splitlines():
        try:
            d = json.loads(ln)
        except ValueError:
            continue
        if d.get("name") == pkgbase and d.get("version"):
            ver = d["version"]
    if ver is None:
        return None, "nvchecker gave no version"
    cache_write(cpath, {"version": ver})
    return ver, None


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
    db = load_db(DB)
    bases = sorted(db)
    if args.only:
        want = set(args.only.split(","))
        bases = [b for b in bases if b in want]
        missing = want - set(bases)
        if missing:
            print("recipe-sync: not in the repo db: %s" % ", ".join(sorted(missing)),
                  file=sys.stderr)

    fetch = "skipped (--no-fetch)" if args.no_fetch else fetch_archpower()
    trees = origin_trees()
    have_nv = shutil.which("nvchecker") is not None
    max_age = args.max_age * 3600

    def ours_job(b):
        for src, root in (("local", LOCAL), ("archpower", ARCHPOWER)):
            d = os.path.join(root, b)
            if os.path.isfile(os.path.join(d, "PKGBUILD")):
                return (src, d) + recipe_version(dir_files(d))
        return (None, None, None, None, None)

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
        f_nv = {}
        if have_nv:
            for b in bases:
                if ours[b][1]:
                    f_nv[b] = net.submit(nvchecker_version, b, ours[b][1], max_age)
        orig = {b: f.result() for b, f in f_orig.items()}
        lab = {b: f.result() for b, f in f_lab.items()}
        f_head = {b: net.submit(gitlab_head_version, b, max_age, limiter)
                  for b in bases
                  if lab[b]["status"] == "ok" and not lab[b]["head_tags"]}
        head = {b: f.result() for b, f in f_head.items()}
        nv = {b: f.result() for b, f in f_nv.items()}

    rows = []
    for b in bases:
        errors, notes = [], []
        versions = sorted({v for _, v in db[b]})
        shipped = vc.newest(versions)
        if len(versions) > 1:
            stale = sorted({"%s %s" % (n, v) for n, v in db[b] if v != shipped})
            notes.append("db entries disagree (also %s)" % ", ".join(stale))

        src, _, o_ver, _, o_err = ours[b]
        if o_err:
            errors.append("ours (%s): %s" % (src, o_err))

        a_ver, _, a_err = orig[b]
        if a_err:
            errors.append("archpower origin: " + a_err)
        paths = [p for p, _ in trees.get(b, [])]
        if paths and "/" in paths[0]:
            # bq's archpower source reads only <pkgbase>/PKGBUILD, so a nested
            # recipe is never what it builds; ours stays with local/gitlab.
            notes.append("archpower recipe is nested at %s (bq reads only "
                         "top-level archpower recipes)" % paths[0])
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
            upstream = nv[b][0] or ""
            if nv[b][1]:
                notes.append(nv[b][1])

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

    summary(rows, vc, fetch, have_nv, summary_fh)


def summary(rows, vc, fetch, have_nv, fh):
    p = lambda *a: print(*a, file=fh)
    counts = {k: 0 for k in BUCKETS}
    for r in rows:
        counts[r["bucket"]] += 1
    p("recipe-sync report: %d pkgbases" % len(rows))
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
    rp.add_argument("--only")
    args = ap.parse_args()
    if args.cmd == "report":
        cmd_report(args)


if __name__ == "__main__":
    main()
