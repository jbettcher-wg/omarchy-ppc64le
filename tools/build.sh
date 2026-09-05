#!/bin/bash
# Build one package from the omarchy-ppc64le tree.
#
# The build box has no passwordless sudo, so `makepkg -d` (skip dependency
# checks) is used against the 1374 packages already installed. Anything we
# build ourselves is extracted into SYSROOT and offered to the next build via
# PKG_CONFIG_PATH / CMAKE_PREFIX_PATH / CPPFLAGS / LDFLAGS.

set -uo pipefail

REPOROOT=/home/jbettcher/Development/omarchy-ppc64le
WORK=/home/jbettcher/omarchy-work
SYSROOT=$WORK/sysroot
PKGDEST=$REPOROOT/repo
LOGDIR=$WORK/logs

pkg=${1:?usage: build.sh <package>}
shift || true

mkdir -p "$SYSROOT" "$PKGDEST" "$LOGDIR" "$WORK/build"
src="$REPOROOT/packages/$pkg"
[ -d "$src" ] || { echo "no such package dir: $src"; exit 2; }

bdir="$WORK/build/$pkg"
rm -rf "$bdir"; mkdir -p "$bdir"
cp -a "$src"/. "$bdir"/
rm -rf "$bdir/src" "$bdir/pkg"

export PKGDEST
# Non-interactive ssh sessions land in the POSIX locale, and bsdtar then
# refuses to extract source tarballs containing non-ASCII filenames.
export LANG=C.UTF-8 LC_ALL=C.UTF-8
export PKG_CONFIG_PATH="$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/share/pkgconfig:${PKG_CONFIG_PATH:-}"
export CMAKE_PREFIX_PATH="$SYSROOT/usr:${CMAKE_PREFIX_PATH:-}"
export CPPFLAGS="-I$SYSROOT/usr/include ${CPPFLAGS:-}"
export LDFLAGS="-L$SYSROOT/usr/lib -Wl,-rpath-link,$SYSROOT/usr/lib ${LDFLAGS:-}"
export XDG_DATA_DIRS="$SYSROOT/usr/share:/usr/share"
export GI_TYPELIB_PATH="$SYSROOT/usr/lib/girepository-1.0:${GI_TYPELIB_PATH:-}"
export LD_LIBRARY_PATH="$SYSROOT/usr/lib:${LD_LIBRARY_PATH:-}"
for _pd in "$SYSROOT"/usr/lib/python3.*/site-packages; do
  [ -d "$_pd" ] && export PYTHONPATH="$_pd:${PYTHONPATH:-}"
done
# xmlto resolves its docbook format scripts from a prefix compiled in at build
# time (/usr), so a sysroot copy finds nothing and reports only "I don't know
# how to convert docbook into man". It honours FORMAT_DIR as an override.
[ -d "$SYSROOT/usr/share/xmlto/format" ] && export FORMAT_DIR="$SYSROOT/usr/share/xmlto/format"
export PATH="$SYSROOT/usr/bin:$PATH"

log="$LOGDIR/$pkg.log"
echo "=== building $pkg -> $log"
( cd "$bdir" && makepkg -d --noconfirm --nocheck --needed "$@" ) >"$log" 2>&1
rc=$?
if [ $rc -eq 0 ]; then
  echo "OK   $pkg"
  ls -1 "$PKGDEST"/*.pkg.tar.zst 2>/dev/null | grep -F "$pkg" | tail -3
else
  echo "FAIL $pkg (rc=$rc)  -- tail of $log:"
  tail -30 "$log"
fi
exit $rc
