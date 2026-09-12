#!/usr/bin/env python3
"""Compare two directories of built packages by their *contents*.

"Both runs succeeded" is not evidence that two builds produced the same thing,
and neither is comparing the .pkg.tar.zst files byte for byte -- those differ
for reasons that say nothing about the build (builddate in .PKGINFO, the
installed-package list in .BUILDINFO, zstd framing).

So: unpack each archive, and compare the payload as a set of
(path, type, mode, symlink target, sha256) tuples.  That is the thing that ends
up on a user's disk.  The three metadata members are excluded by name and
listed separately, because a difference in them is expected and a difference
outside them is not.

    tools/pkg-treediff.py DIR_A DIR_B
    tools/pkg-treediff.py DIR_A DIR_B --self-test   # break it on purpose

Exit status is 0 only when every package present in both directories has an
identical payload.
"""

import os
import sys
import stat
import shutil
import hashlib
import argparse
import tempfile
import subprocess
from collections import defaultdict

SKIP = {".PKGINFO", ".BUILDINFO", ".MTREE", ".INSTALL", ".CHANGELOG"}


def pkgname(fname):
    """chromium-151.0.7922.108-2-powerpc64le.pkg.tar.zst -> chromium"""
    base = fname
    for suf in (".pkg.tar.zst", ".pkg.tar.xz"):
        if base.endswith(suf):
            base = base[:-len(suf)]
            break
    parts = base.rsplit("-", 3)
    return parts[0] if len(parts) == 4 else base


def fingerprint(archive, tmp):
    """{relpath: (kind, mode, sha256-or-linktarget)} for one package archive."""
    root = tempfile.mkdtemp(dir=tmp)
    subprocess.run(["bsdtar", "-xf", archive, "-C", root],
                   capture_output=True, check=False)
    out = {}
    for dirpath, dirnames, filenames in os.walk(root):
        for n in sorted(dirnames + filenames):
            full = os.path.join(dirpath, n)
            rel = os.path.relpath(full, root)
            if rel in SKIP:
                continue
            st = os.lstat(full)
            mode = stat.S_IMODE(st.st_mode)
            if stat.S_ISLNK(st.st_mode):
                out[rel] = ("link", mode, os.readlink(full))
            elif stat.S_ISDIR(st.st_mode):
                out[rel] = ("dir", mode, "")
            else:
                h = hashlib.sha256()
                with open(full, "rb") as fh:
                    for chunk in iter(lambda: fh.read(1 << 20), b""):
                        h.update(chunk)
                out[rel] = ("file", mode, h.hexdigest())
    shutil.rmtree(root, ignore_errors=True)
    return out


def collect(d):
    by = defaultdict(list)
    for f in sorted(os.listdir(d)):
        if f.endswith((".pkg.tar.zst", ".pkg.tar.xz")) and "-debug-" not in f:
            by[pkgname(f)].append(os.path.join(d, f))
    return {k: sorted(v)[-1] for k, v in by.items()}


def compare(a, b, corrupt=None, limit=8):
    tmp = tempfile.mkdtemp(prefix="pkg-treediff-")
    try:
        A, B = collect(a), collect(b)
        both = sorted(set(A) & set(B))
        only_a = sorted(set(A) - set(B))
        only_b = sorted(set(B) - set(A))
        print("%d packages in both, %d only in A, %d only in B"
              % (len(both), len(only_a), len(only_b)))
        for n in only_a:
            print("  only in A: %s" % n)
        for n in only_b:
            print("  only in B: %s" % n)

        bad = 0
        for n in both:
            fa = fingerprint(A[n], tmp)
            fb = fingerprint(B[n], tmp)
            if corrupt and n == corrupt:
                # --self-test: flip one byte of one hash, to prove this
                # comparison can actually report a difference.
                k = sorted(k for k, v in fb.items() if v[0] == "file")[0]
                kind, mode, h = fb[k]
                fb[k] = (kind, mode, "0" * 64)
                print("  [self-test] corrupted %s:%s" % (n, k))
            if fa == fb:
                print("  %-40s identical  (%d entries)" % (n, len(fa)))
                continue
            bad += 1
            diff = sorted(set(fa) ^ set(B and fb))
            changed = sorted(k for k in set(fa) & set(fb) if fa[k] != fb[k])
            print("  %-40s DIFFERS  %d only-one-side, %d changed"
                  % (n, len(diff), len(changed)))
            for k in (diff + changed)[:limit]:
                print("      %s" % k)
            if len(diff) + len(changed) > limit:
                print("      ... +%d more" % (len(diff) + len(changed) - limit))
        print()
        if only_a or only_b:
            print("MISMATCH: the two runs did not produce the same package set")
            return 1
        if bad:
            print("MISMATCH: %d of %d packages differ" % (bad, len(both)))
            return 1
        print("IDENTICAL: all %d packages have byte-identical payloads" % len(both))
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("a")
    ap.add_argument("b")
    ap.add_argument("--self-test", metavar="PKG",
                    help="corrupt one file's hash in PKG before comparing, to "
                         "confirm this tool reports a difference when there is "
                         "one. Must exit non-zero.")
    args = ap.parse_args()
    return compare(args.a, args.b, corrupt=args.self_test)


if __name__ == "__main__":
    sys.exit(main())
