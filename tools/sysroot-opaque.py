#!/usr/bin/env python3
"""
sysroot-opaque -- hide stale host files under a staged package's own directories.

bq stacks the sysroot over the live /usr with an overlay (see bwrap_prefix in
tools/bq.py).  An overlay merges directories: a staged file replaces the host
file at the same path, but a host file the staged package does NOT ship stays
visible.  When a repo package is a newer build of something the host has
installed, every file the new version dropped leaks into the build.

Found 2026-09-13 with go: repo go 1.27.1 staged over host go 1.26.5 left 165
files of 1.26.5 visible under /usr/lib/go, and every Go build died compiling
internal/strconv ("uint64pow10 redeclared").

Overlayfs has a per-directory switch for exactly this: an *opaque* directory
hides everything below it in lower layers.  bwrap mounts its overlay with
`userxattr`, so an unprivileged `user.overlay.opaque=y` on a sysroot directory
works (verified on this host; `trusted.overlay.opaque` is refused without root).

Which directories.  A directory is marked only if, in every layer below it, all
of its contents belong to the package being replaced:

  trigger    The staged package P replaces a host-installed package: same
             pkgname, or named in P's `replaces` / `conflicts`.  Call those O.
  host       No installed package outside O owns any path at or under the
             directory (pacman's local db, read-only).  That is what keeps
             /usr, /usr/lib, /usr/include and every other shared directory
             merged: some other package always owns something there.
  sysroot    No lower sysroot layer (with -j, the shared base under a slot)
             has anything under the directory that P itself does not ship,
             because opaque would hide those too.
  never      A fixed list of shared roots is refused outright, as a second
             line of defence against a host db that happens to be thin.

The shallowest eligible directories are marked and nothing below them is
visited.  Files on disk that no package owns (caches, generated files) under a
marked directory are hidden too; that is the point.

Usage:
  sysroot-opaque.py --sysroot DIR [--lower DIR ...] PKGFILE...
  sysroot-opaque.py --dry-run --all          # report for everything in repo/
"""

import os
import re
import sys
import glob
import argparse
import subprocess
from concurrent.futures import ThreadPoolExecutor

REPO = os.environ.get(
    "BQ_REPO", os.path.expanduser("~/Development/omarchy-ppc64le/repo"))
XATTR = "user.overlay.opaque"
# The only trees bq's bwrap_prefix() mounts as overlays. Marks anywhere else
# (etc/, var/) would do nothing.
OVERLAID = ("usr/", "opt/")

# Shared roots. The host-ownership check already excludes these in practice;
# this list is defence in depth, never the mechanism.
NEVER = re.compile(r"""^(
    usr | opt | etc | var | usr/local | usr/src |
    usr/(bin|sbin|lib|lib32|lib64|libexec|include|share) |
    usr/lib/(pkgconfig|cmake|systemd|sysusers\.d|tmpfiles\.d|udev|modules|
             firmware|girepository-1\.0|python3\.[0-9]+|python3\.[0-9]+/site-packages|
             perl5|perl5/[^/]+|dri|gio|gio/modules|gtk-[0-9.]+|qt6|qt6/plugins|
             qt6/qml|x86_64-linux-gnu|powerpc64le-linux-gnu) |
    usr/share/(pkgconfig|doc|man|man/[^/]+|info|licenses|locale|locale/[^/]+|
               locale/[^/]+/LC_MESSAGES|applications|icons|icons/[^/]+|
               icons/[^/]+/[^/]+|icons/[^/]+/[^/]+/[^/]+|mime|mime/packages|
               glib-2\.0|glib-2\.0/schemas|dbus-1|dbus-1/[^/]+|fonts|
               bash-completion|bash-completion/completions|zsh|zsh/site-functions|
               fish|fish/vendor_completions\.d|vim|vim/vimfiles|metainfo|
               gir-1\.0|vala|vala/vapi|aclocal|cmake|polkit-1|polkit-1/[^/]+|
               xsessions|wayland-sessions|thumbnailers|help|help/[^/]+)
)$""", re.X)


def name_of(dep):
    return re.split(r"[<>=]", dep, maxsplit=1)[0].strip()


def load_host(dbpath="/var/lib/pacman/local"):
    """name -> set(paths without trailing slash), from pacman's local db."""
    owned = {}
    for d in glob.glob(os.path.join(dbpath, "*/")):
        try:
            desc = open(d + "desc", errors="replace").read().split("\n")
            name = desc[desc.index("%NAME%") + 1]
            lines = open(d + "files", errors="replace").read().split("\n")
        except (OSError, ValueError):
            continue
        paths, on = set(), False
        for ln in lines:
            if ln == "%FILES%":
                on = True
                continue
            if ln.startswith("%"):
                on = False
                continue
            if on and ln:
                paths.add(ln.rstrip("/"))
        owned[name] = paths
    return owned


def pkg_meta(pkgfile):
    """(pkgname, replaces+conflicts names, dirs, files) of one archive."""
    info = subprocess.run(["bsdtar", "-qxOf", pkgfile, ".PKGINFO"],
                          capture_output=True, text=True).stdout
    name, claims = None, set()
    for ln in info.splitlines():
        k, _, v = ln.partition(" = ")
        if k == "pkgname":
            name = v.strip()
        elif k in ("replaces", "conflicts"):
            claims.add(name_of(v))
    listing = subprocess.run(["bsdtar", "-tf", pkgfile],
                             capture_output=True, text=True).stdout.splitlines()
    dirs, files = set(), set()
    for p in listing:
        if not p or p.startswith("."):
            continue
        if p.endswith("/"):
            dirs.add(p.rstrip("/"))
        else:
            files.add(p)
            parts = p.split("/")[:-1]
            for i in range(1, len(parts) + 1):
                dirs.add("/".join(parts[:i]))
    return name, claims, dirs, files


class HostIndex:
    """Which installed packages own something at or under a directory."""

    def __init__(self, owned):
        self.owned = owned
        self.under = {}                      # dir -> set(pkg)
        for pkg, paths in owned.items():
            for p in paths:
                parts = p.split("/")
                for i in range(1, len(parts) + 1):
                    self.under.setdefault("/".join(parts[:i]), set()).add(pkg)

    def owners(self, d):
        return self.under.get(d, set())


def lower_extras(d, lowers, pfiles):
    """Does any lower sysroot layer hold something under d that P lacks?"""
    for low in lowers:
        base = os.path.join(low, d)
        if not os.path.isdir(base):
            continue
        for root, dnames, fnames in os.walk(base):
            for f in fnames:
                rel = os.path.relpath(os.path.join(root, f), low)
                if rel not in pfiles:
                    return rel
    return None


def plan(pkgfile, host, lowers=()):
    """Directories to mark opaque for one staged package, with the reason."""
    name, claims, dirs, files = pkg_meta(pkgfile)
    replaced = {n for n in ({name} | claims) if n in host.owned}
    if not replaced:
        return name, replaced, [], "no host-installed package it replaces"
    marks = []
    for d in sorted(dirs, key=lambda x: (x.count("/"), x)):
        if not d.startswith(OVERLAID):
            continue                         # bq overlays only /usr and /opt
        if any(d == m or d.startswith(m + "/") for m in marks):
            continue                         # already hidden by an ancestor
        if NEVER.match(d):
            continue
        owners = host.owners(d)
        if not owners or owners - replaced:
            continue                         # new dir, or shared on the host
        if lower_extras(d, lowers, files):
            continue                         # would hide another staged package
        marks.append(d)
    return name, replaced, marks, ""


def apply(sysroot, marks):
    done = []
    for d in marks:
        path = os.path.join(sysroot, d)
        if not os.path.isdir(path):
            continue
        try:
            os.setxattr(path, XATTR, b"y")
            done.append(d)
        except OSError as e:
            print("sysroot-opaque: cannot mark %s: %s" % (path, e), file=sys.stderr)
    return done


def newest_repo_files():
    newest = {}
    for f in sorted(os.listdir(REPO),
                    key=lambda f: os.path.getmtime(os.path.join(REPO, f))):
        if f.endswith(".pkg.tar.zst") and "-debug-" not in f:
            n = re.sub(r"-[^-]+-[^-]+-[^-]+\.pkg\.tar\.\w+$", "", f)
            newest[n] = os.path.join(REPO, f)
    return newest


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sysroot")
    ap.add_argument("--lower", action="append", default=[])
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--dbpath", default="/var/lib/pacman/local",
                    help="pacman local db describing the lower /usr (tests "
                         "point this at a synthetic db)")
    ap.add_argument("pkgfiles", nargs="*")
    a = ap.parse_args()

    host = HostIndex(load_host(a.dbpath))
    files = list(newest_repo_files().values()) if a.all else a.pkgfiles
    with ThreadPoolExecutor(32) as ex:
        plans = list(ex.map(lambda f: plan(f, host, a.lower), files))

    total = 0
    for name, replaced, marks, why in sorted(plans):
        if not marks:
            continue
        total += len(marks)
        if a.dry_run:
            print("%-32s over %-28s %s" % (name, ",".join(sorted(replaced)),
                                            " ".join(marks)))
        else:
            for d in apply(a.sysroot, marks):
                print("sysroot opaque: /%s (%s over host %s)"
                      % (d, name, ",".join(sorted(replaced))))
    if a.dry_run:
        print("%d packages, %d with a host package they replace, %d dirs marked"
              % (len(plans), sum(1 for p in plans if p[1]), total))


if __name__ == "__main__":
    main()
