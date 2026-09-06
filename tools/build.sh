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
  # The LAST --overlay-src is the top-most layer, so /usr goes first and the
  # sysroot on top -- otherwise a staged package that also exists in the live
  # /usr is shadowed by the system copy, which is the opposite of the point.
  BWRAP=(bwrap --dev-bind / / --overlay-src /usr --overlay-src "$SYSROOT/usr" --ro-overlay /usr)
fi

# Non-interactive ssh sessions land in the POSIX locale, and bsdtar then
# refuses to extract source tarballs containing non-ASCII filenames.
export LANG=C.UTF-8 LC_ALL=C.UTF-8
export PKG_CONFIG_PATH="$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/share/pkgconfig:${PKG_CONFIG_PATH:-}"
# CMake searches CMAKE_PREFIX_PATH ahead of the system prefixes, so pointing it
# at the sysroot makes find_library/find_path return absolute paths under
# ~/omarchy-work. Most are harmless -- they become -I/-L, which are not recorded
# in the output -- but any path CMake bakes into a target leaks $HOME into a
# shipped binary. neovim 0.12.5-1 shipped
#   DT_NEEDED [$SYSROOT/usr/lib/lua/5.1/lpeg.so]
# exactly this way.
#
# Under the bwrap overlay the sysroot is *already* visible at /usr, so listing
# /usr first resolves to the same files under a path that is still correct after
# the package is installed. The sysroot entry stays for the no-bwrap case.
if [ ${#BWRAP[@]} -gt 0 ]; then
  export CMAKE_PREFIX_PATH="/usr:$SYSROOT/usr:${CMAKE_PREFIX_PATH:-}"
else
  export CMAKE_PREFIX_PATH="$SYSROOT/usr:${CMAKE_PREFIX_PATH:-}"
fi
# Fail-closed guard against build-tree paths in shipped ELF headers. PKGBUILDs
# reference it as "${ELF_PATHGUARD:-...}"; it is enforced again after the build
# for recipes that have not adopted the snippet.
export ELF_PATHGUARD="$REPOROOT/tools/elf-pathguard.sh"
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

log="$LOGDIR/$pkg.log"
echo "=== building $pkg -> $log"
( cd "$bdir" && "${BWRAP[@]}" makepkg -d --noconfirm --nocheck --needed "$@" ) >"$log" 2>&1
rc=$?

# Enforce the ELF path guard on every package built, whether or not its PKGBUILD
# calls the snippet. makepkg leaves the staged trees in $bdir/pkg/<pkgname>, so
# this is the same check package() would have run -- but it runs *after* makepkg
# has already written the archive into PKGDEST, so a rejected package has to be
# quarantined rather than merely reported. A recipe that adopts the package()
# snippet fails earlier and never produces an archive at all.
if [ $rc -eq 0 ] && [ -x "$ELF_PATHGUARD" ]; then
  for _pd in "$bdir"/pkg/*/; do
    [ -d "$_pd" ] || continue
    if ! "$ELF_PATHGUARD" "$_pd" >>"$log" 2>&1; then
      echo "FAIL $pkg -- elf-pathguard rejected $(basename "$_pd"):"
      grep "elf-pathguard: FAIL" "$log" | tail -20
      rc=90
    fi
  done
  if [ $rc -eq 90 ]; then
    mkdir -p "$WORK/rejected"
    while read -r _f; do
      [ -f "$_f" ] || continue
      mv -f "$_f" "$WORK/rejected/" && echo "  quarantined $(basename "$_f") -> $WORK/rejected/"
    done < <( cd "$bdir" && makepkg --packagelist 2>/dev/null )
  fi
fi

if [ $rc -eq 0 ]; then
  echo "OK   $pkg"
  ls -1 "$PKGDEST"/*.pkg.tar.zst 2>/dev/null | grep -F "$pkg" | tail -3
else
  echo "FAIL $pkg (rc=$rc)  -- tail of $log:"
  tail -30 "$log"
fi
exit $rc
