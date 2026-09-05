#!/bin/bash
# Extract packages we have built ourselves into the local sysroot, so dependent
# builds find their headers, pkg-config files, cmake configs and libraries
# without needing root.
set -uo pipefail
WORK=/home/jbettcher/omarchy-work
SYSROOT=$WORK/sysroot
REPO=/home/jbettcher/Development/omarchy-ppc64le/repo
mkdir -p "$SYSROOT"

rc=0
for name in "$@"; do
  f=$(ls -t "$REPO"/${name}-[0-9]*.pkg.tar.zst 2>/dev/null | grep -v -- '-debug-' | head -1)
  if [ -z "$f" ]; then echo "sysroot-add: no built package for $name"; rc=1; continue; fi
  tar -I zstd -xf "$f" -C "$SYSROOT" \
    --exclude=.PKGINFO --exclude=.BUILDINFO --exclude=.MTREE --exclude=.INSTALL 2>/dev/null
  echo "sysroot += $(basename "$f")"
done

# pkg-config and cmake files carry absolute /usr prefixes; repoint them into the
# sysroot so dependent builds resolve include and library paths correctly.
for d in "$SYSROOT/usr/lib/pkgconfig" "$SYSROOT/usr/share/pkgconfig"; do
  [ -d "$d" ] || continue
  find "$d" -name '*.pc' | while read -r pc; do
    sed -i "s|^prefix=/usr$|prefix=$SYSROOT/usr|" "$pc"
  done
done
exit $rc
