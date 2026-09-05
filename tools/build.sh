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
# Some build systems (notably cmake projects that set their own linker flags)
# drop the LDFLAGS we export, and the link then fails with "cannot find -lfoo"
# for a library that *is* staged. LIBRARY_PATH and *_INCLUDE_PATH are honoured
# by gcc itself, so they survive whatever the build system does with flags.
export LIBRARY_PATH="$SYSROOT/usr/lib:${LIBRARY_PATH:-}"
export C_INCLUDE_PATH="$SYSROOT/usr/include:${C_INCLUDE_PATH:-}"
export CPLUS_INCLUDE_PATH="$SYSROOT/usr/include:${CPLUS_INCLUDE_PATH:-}"
export XDG_DATA_DIRS="$SYSROOT/usr/share:/usr/share"
export GI_TYPELIB_PATH="$SYSROOT/usr/lib/girepository-1.0:${GI_TYPELIB_PATH:-}"
# Staged tools can carry a compiled-in RUNPATH into a plugin directory that
# only exists under /usr (valac -> /usr/lib/vala-0.56/libvalaccodegen.so). The
# symptom is unhelpful: meson just says "Unknown compiler: valac". So put the
# sysroot's library subdirectories on LD_LIBRARY_PATH too, not only usr/lib.
export LD_LIBRARY_PATH="$SYSROOT/usr/lib:${LD_LIBRARY_PATH:-}"
for _sd in "$SYSROOT"/usr/lib/*/; do
  compgen -G "$_sd*.so*" >/dev/null && LD_LIBRARY_PATH="${_sd%/}:$LD_LIBRARY_PATH"
done
export LD_LIBRARY_PATH
for _pd in "$SYSROOT"/usr/lib/python3.*/site-packages; do
  [ -d "$_pd" ] && export PYTHONPATH="$_pd:${PYTHONPATH:-}"
done
# xmlto resolves its docbook format scripts from a prefix compiled in at build
# time (/usr), so a sysroot copy finds nothing and reports only "I don't know
# how to convert docbook into man". It honours FORMAT_DIR as an override.
[ -d "$SYSROOT/usr/share/xmlto/format" ] && export FORMAT_DIR="$SYSROOT/usr/share/xmlto/format"
export PATH="$SYSROOT/usr/bin:$PATH"

# graphviz looks for its plugin registry at a compiled-in path under /usr. A
# staged copy has none, and gi-docgen then dies with "Format: svg_inline not
# recognized" while generating API docs. GVBINDIR redirects it, and `dot -c`
# writes the registry once.
if [ -d "$SYSROOT/usr/lib/graphviz" ]; then
  export GVBINDIR="$SYSROOT/usr/lib/graphviz"
  [ -e "$GVBINDIR"/config* ] 2>/dev/null || "$SYSROOT/usr/bin/dot" -c >/dev/null 2>&1
fi

# Present the sysroot at the paths a package would actually be installed to.
#
# Environment variables (PKG_CONFIG_PATH, CPPFLAGS, LIBRARY_PATH...) only reach
# builds that cooperate. Plenty do not: obs-studio hardcodes
# /usr/include/mbedtls3, plymouth hardcodes /usr/share/pixmaps, valac and
# graphviz bake /usr paths into their binaries. bubblewrap can stack a
# read-only overlayfs of the sysroot over /usr *without root*, so staged
# packages simply appear where they belong and none of those cases need
# special-casing. The overlay is read-only and process-local; the real /usr is
# untouched (RULES.md).
BWRAP=()
if command -v bwrap >/dev/null && [ -d "$SYSROOT/usr" ]; then
  BWRAP=(bwrap --dev-bind / / --overlay-src "$SYSROOT/usr" --overlay-src /usr --ro-overlay /usr)
fi

log="$LOGDIR/$pkg.log"
echo "=== building $pkg -> $log"
( cd "$bdir" && "${BWRAP[@]}" makepkg -d --noconfirm --nocheck --needed "$@" ) >"$log" 2>&1
rc=$?
if [ $rc -eq 0 ]; then
  echo "OK   $pkg"
  ls -1 "$PKGDEST"/*.pkg.tar.zst 2>/dev/null | grep -F "$pkg" | tail -3
else
  echo "FAIL $pkg (rc=$rc)  -- tail of $log:"
  tail -30 "$log"
fi
exit $rc
