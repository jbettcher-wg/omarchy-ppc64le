#!/bin/bash
# Stage Arch POWER packages into the unprivileged sysroot.
#
# The build box has no passwordless sudo, so build dependencies cannot be
# installed with `pacman -S`. `pacman -Sp` does work unprivileged and resolves
# mirror URLs, so we download the package and unpack it into ~/omarchy-work/
# sysroot. Nothing outside that directory is touched — the live system is
# never modified.
set -uo pipefail
# SYSROOT and the package cache must follow the caller.  These were hardcoded
# under $HOME, so every dependency bq staged landed in ~/omarchy-work/sysroot
# while the build overlaid /var/tmp/omarchy-bq/sysroot -- which is why
# go-md2man, asciidoc, ell and libical were "staged" and still not found.
WORK=${BQ_WORK:-/home/jbettcher/omarchy-work}
SYSROOT=${SYSROOT:-$WORK/sysroot}
CACHE=${BQ_PKGCACHE:-${BUILDROOT:+$BUILDROOT/pkgcache}}
CACHE=${CACHE:-$WORK/pkgcache}
mkdir -p "$SYSROOT" "$CACHE"

rc=0
for name in "$@"; do
  urls=$(pacman -Sp --print-format '%l' "$name" 2>/dev/null) || {
    echo "sysroot-fetch: cannot resolve $name"; rc=1; continue; }
  for u in $urls; do
    f="$CACHE/$(basename "$u")"
    if [ ! -s "$f" ]; then
      case "$u" in
        file://*) cp "${u#file://}" "$f" ;;
        *) curl -sSL -o "$f" "$u" || { echo "download failed: $u"; rc=1; continue; } ;;
      esac
    fi
    tar -I zstd -xf "$f" -C "$SYSROOT" \
      --exclude=.PKGINFO --exclude=.BUILDINFO --exclude=.MTREE --exclude=.INSTALL 2>/dev/null
    echo "sysroot += $(basename "$f")"
  done
done

# pkg-config files carry absolute /usr paths; repoint them into the sysroot.
"$(dirname "$(readlink -f "$0")")/sysroot-fixup.sh" "$SYSROOT"
exit $rc
