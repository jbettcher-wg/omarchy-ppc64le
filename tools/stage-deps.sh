#!/bin/bash
# Stage a package's build dependencies into the unprivileged sysroot.
#
# `makepkg -d` is unavoidable here (no passwordless sudo), but skipping the
# dependency check also means makepkg will not tell us what is missing -- the
# build just fails deep inside meson/cmake with "Dependency X not found". So:
# read depends/makedepends/checkdepends out of the PKGBUILD ourselves, drop
# anything already installed, and sysroot-fetch the rest.
#
# Two bugs fixed here:
#  * checkdepends were never staged (only DEP and MAKEDEP were read), so
#    packages that check at build time lost their tools.
#  * the recipe was once looked for at one flat path holding only our own
#    ~130 recipes, while the other ~640 packages in the queue came from
#    elsewhere, so this script exited 2 ("no PKGBUILD") before staging
#    anything at all -- which is why bluez lost `ell libical` and bolt lost
#    `asciidoc` even though asciidoc is packaged.  Accept an explicit recipe
#    directory as $2, and fall back to the queue's materialised build tree
#    before giving up.
set -uo pipefail
here=$(dirname "$(readlink -f "$0")")
REPOROOT=/home/jbettcher/Development/omarchy-ppc64le
# One local source of build scripts; see tools/bq.py.
PACKAGING=${OMARCHY_PACKAGING:-/home/jbettcher/Development/omarchy-ppc64le-packaging}
# BQ_REPO lets a side build keep its own package pool; see tools/bq.py.
REPO=${BQ_REPO:-$REPOROOT/repo}
BUILDROOT=${BUILDROOT:-/var/tmp/omarchy-bq}

pkg=${1:?usage: stage-deps.sh <package> [recipedir]}
recipedir=${2:-}

# The packaging tree is nested (see its README), so find the recipe by
# pkgbase rather than assuming <root>/<pkg>.
_local=$(find "$PACKAGING" -mindepth 1 -maxdepth 3 -type d \
  -name "$pkg" -exec test -f '{}/PKGBUILD' \; -print -quit 2>/dev/null)
for cand in "$recipedir" "$_local" "$BUILDROOT/build/$pkg"; do
  [ -n "$cand" ] && [ -f "$cand/PKGBUILD" ] && { f="$cand/PKGBUILD"; break; }
done
[ -n "${f:-}" ] || { echo "stage-deps: no PKGBUILD for $pkg"; exit 2; }

mapfile -t deps < <("$here/extract-deps.sh" "$f" \
  | awk -F'\t' '$1=="DEP"||$1=="MAKEDEP"||$1=="CHECKDEP"{print $2}' \
  | sed -E 's/[<>=].*//' | sort -u)

want=(); ours=(); absent=()
for d in "${deps[@]}"; do
  [ -n "$d" ] || continue
  # Our own build wins over whatever is installed.  Checking "is it installed"
  # first meant a package we had deliberately rebuilt was skipped in favour of
  # the older system copy: attica needs ECM >= 6.29 and kept finding the
  # installed 6.27, and libheif would have gone on linking the system
  # libde265 1.0.18 that is missing de265_get_security_limits instead of the
  # 1.1.2 sitting in repo/.
  if ls "$REPO"/${d}-[0-9]*.pkg.tar.zst >/dev/null 2>&1; then
    ours+=("$d")                                        # we built it earlier
  elif pacman -Qq "$d" >/dev/null 2>&1; then
    continue                                            # already on the system
  elif pacman -Si "$d" >/dev/null 2>&1; then want+=("$d")
  else absent+=("$d"); fi
done

# Close over our own repo before staging.
#
# The list above is one level deep: it is whatever the PKGBUILD declares. That
# is fine for anything the host already has at a compatible version, and wrong
# for everything we rebuilt. hyprland declares re2; re2 declares abseil-cpp;
# only re2 got staged, so libre2.so (built here against abseil lts_20260526)
# was linked against the host's installed abseil 20260107 and every absl symbol
# came up undefined.
#
# Only OUR packages need the walk. Arch POWER's packages are internally
# consistent with each other and with the host, so their transitive deps can
# keep resolving to the system copies; ours are the ones that can be newer than
# what is installed.
declare -A _staged=()
for d in "${ours[@]}"; do _staged[$d]=1; done
_frontier=("${ours[@]}")
while [ ${#_frontier[@]} -gt 0 ]; do
  _next=()
  for d in "${_frontier[@]}"; do
    pkgfile=$(ls -t "$REPO"/${d}-[0-9]*.pkg.tar.zst 2>/dev/null | head -1)
    [ -n "$pkgfile" ] || continue
    while read -r sub; do
      sub=${sub%%[<>=]*}
      [ -n "$sub" ] || continue
      [ -n "${_staged[$sub]:-}" ] && continue
      # Only follow it if we built it too; otherwise the system copy is right.
      ls "$REPO"/${sub}-[0-9]*.pkg.tar.zst >/dev/null 2>&1 || continue
      _staged[$sub]=1
      ours+=("$sub")
      _next+=("$sub")
    done < <(bsdtar -xOf "$pkgfile" .PKGINFO 2>/dev/null |
             sed -n 's/^depend = //p')
  done
  _frontier=("${_next[@]:-}")
  [ -z "${_frontier[0]:-}" ] && break
done

# Close over the FETCHED packages too.
#
# The walk above deliberately skips Arch POWER packages, on the grounds that they
# are consistent with each other and with the host. That is true only when the
# host actually has them. A package we *fetch* is by definition not installed, so
# its own dependencies are not guaranteed to be installed either, and nothing
# stages them:
#
#   qt6-tools declares litehtml. litehtml is not installed, so it was fetched.
#   litehtml needs gumbo-parser, which is not installed and was never fetched, so
#   qt6-tools died at 560/708 with "cannot find -lgumbo".
#
# Walk what we fetch, and fetch anything it needs that the host does not already
# provide. Installed packages still short-circuit, so this pulls in the handful
# of genuinely absent libraries and not the whole base system.
declare -A _fetched=()
for d in "${want[@]}"; do _fetched[$d]=1; done
_frontier=("${want[@]:-}")
while [ -n "${_frontier[0]:-}" ]; do
  _next=()
  for d in "${_frontier[@]}"; do
    while read -r sub; do
      sub=${sub%%[<>=]*}
      [ -n "$sub" ] && [ "$sub" != None ] || continue
      [ -n "${_fetched[$sub]:-}" ] && continue
      [ -n "${_staged[$sub]:-}" ] && continue
      # ours wins, host is fine, otherwise fetch it
      if ls "$REPO"/${sub}-[0-9]*.pkg.tar.zst >/dev/null 2>&1; then
        _staged[$sub]=1; ours+=("$sub"); continue
      fi
      pacman -Qq "$sub" >/dev/null 2>&1 && continue
      pacman -Si "$sub" >/dev/null 2>&1 || continue
      _fetched[$sub]=1
      want+=("$sub")
      _next+=("$sub")
    done < <(pacman -Si "$d" 2>/dev/null |
             sed -n 's/^Depends On *: //p' | tr ' ' '\n')
  done
  _frontier=("${_next[@]:-}")
done

# Ours last: a package we built deliberately (libde265 1.1.2) must land on top
# of, not under, the Arch POWER copy of the same name.
[ ${#want[@]} -gt 0 ] && "$here/sysroot-fetch.sh" "${want[@]}" | sed 's/^/  /'
[ ${#ours[@]}  -gt 0 ] && "$here/sysroot-add.sh"   "${ours[@]}" | sed 's/^/  /'
[ ${#absent[@]} -gt 0 ] && echo "  not in Arch POWER and not yet built: ${absent[*]}"
exit 0
