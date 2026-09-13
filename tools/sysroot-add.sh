#!/bin/bash
# Extract packages we have built ourselves into the local sysroot, so dependent
# builds find their headers, pkg-config files, cmake configs and libraries
# without needing root.
set -uo pipefail
WORK=${BQ_WORK:-/home/jbettcher/omarchy-work}
SYSROOT=${SYSROOT:-$WORK/sysroot}
# BQ_REPO lets a side build keep its own package pool; see tools/bq.py.
REPO=${BQ_REPO:-/home/jbettcher/Development/omarchy-ppc64le/repo}
mkdir -p "$SYSROOT"

here=$(dirname "$(readlink -f "$0")")

rc=0
staged=()
for name in "$@"; do
  f=$(ls -t "$REPO"/${name}-[0-9]*.pkg.tar.zst 2>/dev/null | grep -v -- '-debug-' | head -1)
  if [ -z "$f" ]; then echo "sysroot-add: no built package for $name"; rc=1; continue; fi
  tar -I zstd -xf "$f" -C "$SYSROOT" \
    --exclude=.PKGINFO --exclude=.BUILDINFO --exclude=.MTREE --exclude=.INSTALL 2>/dev/null
  echo "sysroot += $(basename "$f")"
  staged+=("$f")
done

# The overlay merges directories, so a package staged over an older installed
# copy of itself still shows every host file the new version dropped (repo go
# 1.27.1 over host go 1.26.5 leaked 165 stale files into /usr/lib/go and broke
# every Go build). Mark the directories the package owns exclusively as
# overlay-opaque so the stale files stay hidden. SYSROOT_LOWER names the
# sysroot layers under this one (bq -j slots), which an opaque mark would hide
# too. See tools/sysroot-opaque.py and docs/build-queue.md.
if [ ${#staged[@]} -gt 0 ]; then
  lower=()
  IFS=: read -ra _lowers <<< "${SYSROOT_LOWER:-}"
  for l in "${_lowers[@]}"; do [ -n "$l" ] && lower+=(--lower "$l"); done
  python3 "$here/sysroot-opaque.py" --sysroot "$SYSROOT" "${lower[@]}" "${staged[@]}"
fi

# pkg-config files carry absolute /usr paths; repoint them into the sysroot.
"$here/sysroot-fixup.sh" "$SYSROOT"
exit $rc
