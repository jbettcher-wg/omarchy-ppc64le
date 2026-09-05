#!/bin/bash
# Extract packages we have built into the local sysroot, so that dependent
# builds can find their headers/pkgconfig/libs without root.
set -euo pipefail
WORK=/home/jbettcher/omarchy-work
SYSROOT=$WORK/sysroot
REPO=/home/jbettcher/Development/omarchy-ppc64le/repo
mkdir -p "$SYSROOT"
for name in "$@"; do
  f=$(ls -t "$REPO"/${name}-[0-9]*-powerpc64le.pkg.tar.zst "$REPO"/${name}-[0-9]*-any.pkg.tar.zst 2>/dev/null | head -1)
  [ -n "$f" ] || { echo "sysroot-add: no built package for $name"; exit 1; }
  tar -I zstd -xf "$f" -C "$SYSROOT" --exclude=.PKGINFO --exclude=.BUILDINFO --exclude=.MTREE --exclude=.INSTALL
  echo "sysroot += $(basename "$f")"
done
# pkgconfig files carry absolute prefixes; rewrite them to point into the sysroot
find "$SYSROOT/usr/lib/pkgconfig" "$SYSROOT/usr/share/pkgconfig" -name '*.pc' 2>/dev/null | while read -r pc; do
  grep -q "^prefix=$SYSROOT" "$pc" || sed -i "s|^prefix=/usr$|prefix=$SYSROOT/usr|" "$pc"
done
