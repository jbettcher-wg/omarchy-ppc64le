#!/bin/bash
# Stage a package's build dependencies into the unprivileged sysroot.
#
# `makepkg -d` is unavoidable here (no passwordless sudo), but skipping the
# dependency check also means makepkg will not tell us what is missing -- the
# build just fails deep inside meson/cmake with "Dependency X not found". So:
# read depends/makedepends out of the PKGBUILD ourselves, drop anything already
# installed, and sysroot-fetch the rest.
#
# Deps that are not in Arch POWER at all are reported and skipped; those are the
# ones we have to build, and docs/dependency-closure.md lists them.
set -uo pipefail
here=$(dirname "$(readlink -f "$0")")
REPOROOT=/home/jbettcher/Development/omarchy-ppc64le

pkg=${1:?usage: stage-deps.sh <package>}
f="$REPOROOT/packages/$pkg/PKGBUILD"
[ -f "$f" ] || { echo "stage-deps: no PKGBUILD for $pkg"; exit 2; }

mapfile -t deps < <("$here/extract-deps.sh" "$f" \
  | awk -F'\t' '$1=="DEP"||$1=="MAKEDEP"{print $2}' \
  | sed -E 's/[<>=].*//' | sort -u)

want=(); ours=(); absent=()
for d in "${deps[@]}"; do
  [ -n "$d" ] || continue
  pacman -Qq "$d" >/dev/null 2>&1 && continue          # already on the system
  if ls "$REPOROOT/repo"/${d}-[0-9]*.pkg.tar.zst >/dev/null 2>&1; then
    ours+=("$d")                                        # we built it earlier
  elif pacman -Si "$d" >/dev/null 2>&1; then want+=("$d")
  else absent+=("$d"); fi
done

[ ${#want[@]} -gt 0 ] && "$here/sysroot-fetch.sh" "${want[@]}" | sed 's/^/  /'
[ ${#ours[@]}  -gt 0 ] && "$here/sysroot-add.sh"   "${ours[@]}" | sed 's/^/  /'
[ ${#absent[@]} -gt 0 ] && echo "  not in Arch POWER and not yet built: ${absent[*]}"
exit 0
