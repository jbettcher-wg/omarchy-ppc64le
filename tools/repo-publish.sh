#!/bin/bash
# repo-publish.sh -- regenerate the *deployed* repo database from repo/.
#
# There are two databases in repo/ and they are not the same thing:
#
#   omarchy-ppc64le.db.tar.zst   bq's build database. bq repo-adds every package
#                                it builds here, and tools/pacman-build.conf +
#                                prime-dbpath.sh use it to make fresh packages
#                                visible to later builds inside the sandbox.
#
#   omarchy-power9.db.tar.gz     the deployed database. This is what
#                                /etc/pacman.conf's [omarchy-power9] serves,
#                                what installer/p9-install writes into the
#                                target, and what iso/build.sh requires. It is
#                                NOT updated by bq.
#
# So packages built today are installable by path but invisible to pacman until
# this runs. That gap is why iso/build.sh carries a "run repo-add first" check.
#
# Usage:
#   tools/repo-publish.sh            # dry run: report what would change
#   tools/repo-publish.sh --commit   # rewrite the deployed db
#   REPO=<dir> REPO_NAME=<name> ...   # another pool, e.g. repo-power8 / omarchy-power8
set -uo pipefail

REPO=${REPO:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)/repo}
# The database name follows the repo, so the POWER8 pool publishes as
# REPO=.../repo-power8 REPO_NAME=omarchy-power8 tools/repo-publish.sh --commit
REPO_NAME=${REPO_NAME:-omarchy-power9}
DB=$REPO/$REPO_NAME.db.tar.gz
COMMIT=0
[ "${1:-}" = "--commit" ] && COMMIT=1

[ -d "$REPO" ] || { echo "no repo at $REPO" >&2; exit 2; }
cd "$REPO" || exit 2

# Pick the newest build of each pkgname. pkgver may not contain '-', so the last
# three dash-separated fields are always <pkgver>-<pkgrel>-<arch>; whatever
# precedes them is the name, dashes and all.
declare -A best bestfile
for f in *.pkg.tar.zst *.pkg.tar.xz; do
  [ -e "$f" ] || continue
  base=${f%.pkg.tar.*}
  arch=${base##*-}; rest=${base%-*}
  rel=${rest##*-};  rest=${rest%-*}
  ver=${rest##*-};  name=${rest%-*}
  [ -n "$name" ] || continue
  cur=${best[$name]:-}
  if [ -z "$cur" ] || [ "$(vercmp "$ver-$rel" "$cur")" -gt 0 ]; then
    best[$name]=$ver-$rel
    bestfile[$name]=$f
  fi
done

total=$(ls -1 *.pkg.tar.zst *.pkg.tar.xz 2>/dev/null | wc -l)
newest=${#bestfile[@]}
echo "packages on disk : $total"
echo "distinct names   : $newest"
echo "superseded files : $((total - newest))   (not deleted; left in place)"

# What the deployed db currently holds, so we can report the delta.
declare -A have
if [ -f "$DB" ]; then
  while IFS= read -r e; do
    e=${e%/}; [ -n "$e" ] || continue
    v=${e##*-}; r=${e%-*}; v2=${r##*-}; n=${r%-*}
    have[$n]=$v2-$v
  done < <(tar -tzf "$DB" 2>/dev/null | grep -oE '^[^/]+/' )
fi

changed=(); added=()
for n in "${!bestfile[@]}"; do
  if [ -z "${have[$n]:-}" ]; then added+=("$n ${best[$n]}")
  elif [ "${have[$n]}" != "${best[$n]}" ]; then changed+=("$n ${have[$n]} -> ${best[$n]}")
  fi
done

echo
echo "new in this pass  : ${#added[@]}"
printf '    %s\n' "${added[@]:-}" | sed '/^    $/d' | sort | head -40
echo "updated           : ${#changed[@]}"
printf '    %s\n' "${changed[@]:-}" | sed '/^    $/d' | sort | head -60

# Same-version rebuilds. pacman compares versions, not contents: a package
# rebuilt without a pkgrel bump replaces its file here and the db entry follows,
# but -Syu never delivers it to a system that already has that version. On
# 2026-09-11 that had stranded nine installed packages on .24 (rocm-llvm's
# three, vtk, the ffmpeg soname rebuilds, grim, omarchy). Only files newer than
# the db are hashed, so a normal run costs a handful of sha256sums.
samever=()
if [ -f "$DB" ]; then
  dbdir=$(mktemp -d); trap 'rm -rf "$dbdir"' EXIT
  bsdtar -xf "$DB" -C "$dbdir" 2>/dev/null
  for n in "${!bestfile[@]}"; do
    [ "${have[$n]:-}" = "${best[$n]}" ] || continue
    f=${bestfile[$n]}
    [ "$f" -nt "$DB" ] || continue
    want=$(sed -n '/^%SHA256SUM%$/{n;p;q}' "$dbdir/$n-${best[$n]}/desc" 2>/dev/null)
    [ -n "$want" ] || continue
    [ "$(sha256sum < "$f" | cut -d' ' -f1)" = "$want" ] || samever+=("$n ${best[$n]}")
  done
fi
echo "rebuilt, same ver : ${#samever[@]}"
printf '    %s\n' "${samever[@]:-}" | sed '/^    $/d' | sort
if [ ${#samever[@]} -gt 0 ]; then
  echo "    ^ installed copies of these will not upgrade. Bump pkgrel and rebuild."
  if [ "$COMMIT" -eq 1 ] && [ "${ALLOW_SAME_VERSION:-0}" != 1 ]; then
    echo
    echo "refusing to publish. ALLOW_SAME_VERSION=1 overrides (e.g. a package no" >&2
    echo "system has installed yet)." >&2
    exit 1
  fi
fi

if [ "$COMMIT" -ne 1 ]; then
  echo
  echo "dry run -- nothing written. Re-run with --commit to update $(basename "$DB")."
  exit 0
fi

cp -a "$DB" "$DB.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null
echo
echo "writing $(basename "$DB") ..."
# Plain repo-add: it updates an existing entry in place, which is what we want.
#
# NOT -R. In repo-add(8) that is "remove old package file from disk after
# updating the database" -- it deletes the superseded .pkg.tar.zst, which is the
# opposite of this script's contract of leaving package files alone. It is not
# a "replace the entry" flag; entries are replaced by default.
#
# NOT --files either: it does not exist in pacman 7.1's repo-add, and it is not
# needed -- repo-add regenerates <repo>.files.tar.gz alongside the .db in the
# same run. Verified: both come out with 1298 entries and the same mtime.
repo-add -q "$DB" "${bestfile[@]}" || { echo "repo-add failed" >&2; exit 1; }
echo "done: $newest packages in $(basename "$DB")"
