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
#  * the recipe was only ever looked for in $REPOROOT/packages/<pkg>, which is
#    where OUR ~130 recipes live.  The other ~640 packages in the queue come
#    from archpower's PKGBUILDs in the build tree, so this script exited 2
#    ("no PKGBUILD") before staging anything at all -- which is why bluez lost
#    `ell libical` and bolt lost `asciidoc` even though asciidoc is packaged.
#    Accept an explicit recipe directory as $2, and fall back to the queue's
#    materialised build tree before giving up.
set -uo pipefail
here=$(dirname "$(readlink -f "$0")")
REPOROOT=/home/jbettcher/Development/omarchy-ppc64le
BUILDROOT=${BUILDROOT:-/var/tmp/omarchy-bq}

pkg=${1:?usage: stage-deps.sh <package> [recipedir]}
recipedir=${2:-}

for cand in "$recipedir" "$REPOROOT/packages/$pkg" "$BUILDROOT/build/$pkg"; do
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
  if ls "$REPOROOT/repo"/${d}-[0-9]*.pkg.tar.zst >/dev/null 2>&1; then
    ours+=("$d")                                        # we built it earlier
  elif pacman -Qq "$d" >/dev/null 2>&1; then
    continue                                            # already on the system
  elif pacman -Si "$d" >/dev/null 2>&1; then want+=("$d")
  else absent+=("$d"); fi
done

# Ours last: a package we built deliberately (libde265 1.1.2) must land on top
# of, not under, the Arch POWER copy of the same name.
[ ${#want[@]} -gt 0 ] && "$here/sysroot-fetch.sh" "${want[@]}" | sed 's/^/  /'
[ ${#ours[@]}  -gt 0 ] && "$here/sysroot-add.sh"   "${ours[@]}" | sed 's/^/  /'
[ ${#absent[@]} -gt 0 ] && echo "  not in Arch POWER and not yet built: ${absent[*]}"
exit 0
