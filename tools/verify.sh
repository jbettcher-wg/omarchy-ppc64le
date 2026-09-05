#!/bin/bash
# Verify a built package by extracting it to a staging directory and running
# the binary. Never installs into the live system (see RULES.md).
#
#   verify.sh <pkgname> [-- <argv to run instead of "<pkgname> --version">]
set -uo pipefail
WORK=/home/jbettcher/omarchy-work
REPO=/home/jbettcher/Development/omarchy-ppc64le/repo
STAGE=$WORK/verify
SYSROOT=$WORK/sysroot

pkg=${1:?usage: verify.sh <pkgname> [-- cmd...]}; shift
mkdir -p "$STAGE"
f=$(ls -t "$REPO"/${pkg}-[0-9]*.pkg.tar.zst 2>/dev/null | grep -v -- '-debug-' | head -1)
[ -n "$f" ] || { echo "verify: no built package for $pkg"; exit 2; }
tar -I zstd -xf "$f" -C "$STAGE" \
  --exclude=.PKGINFO --exclude=.BUILDINFO --exclude=.MTREE --exclude=.INSTALL 2>/dev/null

export PATH="$STAGE/usr/bin:$SYSROOT/usr/bin:$PATH"
export LD_LIBRARY_PATH="$STAGE/usr/lib:$SYSROOT/usr/lib:${LD_LIBRARY_PATH:-}"
export GI_TYPELIB_PATH="$STAGE/usr/lib/girepository-1.0:$SYSROOT/usr/lib/girepository-1.0:${GI_TYPELIB_PATH:-}"
export XDG_DATA_DIRS="$STAGE/usr/share:$SYSROOT/usr/share:/usr/share"
for d in "$STAGE" "$SYSROOT"; do
  for pd in "$d"/usr/lib/python3.*/site-packages; do
    [ -d "$pd" ] && export PYTHONPATH="$pd:${PYTHONPATH:-}"
  done
done

if [ "${1:-}" = "--" ]; then shift; else set -- "$pkg" --version; fi
echo "--- $pkg: $* ---"
"$@" 2>&1 | head -4
echo "   (exit ${PIPESTATUS[0]})  ELF: $(file -b "$STAGE/usr/bin/${1}" 2>/dev/null | cut -d, -f1-2)"
