#!/usr/bin/env python3
"""Apply Electron's patch series to a tree built from Chromium's release tarball.

LOCAL WORKAROUND. It exists because this recipe builds from Google's release
tarball rather than a gclient checkout. Electron's own
script/apply_all_patches.py runs `git am` inside every target, so every target
has to be a git repository, and the tarball tree has no .git anywhere. This
script reads the same patches/config.json and each patch directory's
`.patches` list, and applies each patch in order with `git apply`. `git apply`
works outside a repository and handles the same git diff features `git am`
does: renames, mode changes and binary hunks.

One deliberate difference. The -lite tarball leaves out tests and iOS/Android
resources, so a patch that modifies or deletes a file the tree doesn't have is
applied with that path excluded instead of failing. This is the same rule
chromium-150.0.7871.222-250.patch was filtered by. Files a patch creates are
never excluded, a hunk against a file that exists still has to apply exactly,
and every exclusion is printed.

usage: electron-apply-patches.py <src>   (<src> holds electron/, v8/, ...)
"""
import json
import os
import subprocess
import sys


def absent_paths(patch, repo):
    """Paths the patch modifies or deletes that don't exist under repo."""
    lines = open(patch, encoding="utf-8", errors="surrogateescape").read().split("\n")
    absent = []
    for i, line in enumerate(lines):
        if not line.startswith("diff --git a/"):
            continue
        old = line[len("diff --git a/"):].rsplit(" b/", 1)[0]
        header = lines[i + 1:i + 4]
        if any(h.startswith("new file mode") for h in header):
            continue
        if not os.path.lexists(os.path.join(repo, old)):
            absent.append(old)
    return absent


def main():
    src = os.path.abspath(sys.argv[1])
    # Never let git discover a repository above the build tree: `git apply`
    # inside a work tree resolves paths against that tree's top level.
    env = dict(os.environ, GIT_CEILING_DIRECTORIES=os.path.dirname(src))
    config = json.load(open(os.path.join(src, "electron/patches/config.json")))
    applied = excluded = 0
    for target in config:
        repo = src if target["repo"] == "src" else os.path.join(src, target["repo"][len("src/"):])
        pdir = os.path.join(src, target["patch_dir"][len("src/"):])
        names = [n.strip() for n in open(os.path.join(pdir, ".patches")) if n.strip()]
        if not os.path.isdir(repo):
            # squirrel.mac, ReactiveObjC (macOS), engflow-reclient-configs
            # (Google remote execution): not part of a Linux build tree.
            print("  skipping %d patches for %s: not in this tree" % (len(names), target["repo"]))
            continue
        for name in names:
            patch = os.path.join(pdir, name)
            absent = absent_paths(patch, repo)
            cmd = ["git", "apply", "-p1"] + ["--exclude=" + a for a in absent] + [patch]
            r = subprocess.run(cmd, cwd=repo, env=env, capture_output=True, text=True)
            if r.returncode:
                sys.stderr.write("FAILED %s/%s in %s:\n%s" % (
                    os.path.basename(pdir), name, target["repo"], r.stderr))
                return 1
            applied += 1
            if absent:
                excluded += len(absent)
                print("  %s/%s: excluded, not in the tarball: %s" % (
                    os.path.basename(pdir), name, " ".join(absent)))
    print("  applied %d Electron patches (%d file diffs excluded as absent)" % (applied, excluded))
    return 0


if __name__ == "__main__":
    sys.exit(main())
