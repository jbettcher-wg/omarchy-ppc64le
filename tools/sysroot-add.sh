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

rc=0
for name in "$@"; do
  f=$(ls -t "$REPO"/${name}-[0-9]*.pkg.tar.zst 2>/dev/null | grep -v -- '-debug-' | head -1)
  if [ -z "$f" ]; then echo "sysroot-add: no built package for $name"; rc=1; continue; fi
  tar -I zstd -xf "$f" -C "$SYSROOT" \
    --exclude=.PKGINFO --exclude=.BUILDINFO --exclude=.MTREE --exclude=.INSTALL 2>/dev/null
  echo "sysroot += $(basename "$f")"
done

# pkg-config files carry absolute /usr paths; repoint them into the sysroot.
"$(dirname "$(readlink -f "$0")")/sysroot-fixup.sh" "$SYSROOT"
exit $rc
