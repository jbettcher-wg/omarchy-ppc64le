#!/bin/bash
# Fetch an upstream build script INTO the packaging tree.
#
# Arch's GitLab and the AUR are import sources, not build-time sources: bq
# builds only from the packaging tree, so the way a new recipe enters the
# distro is to fetch it here, review it, and commit it. Only the recipe files
# are kept (PKGBUILD, .install, patches, keys); the git dir, .SRCINFO and
# .nvchecker.toml are dropped so the imported copy is regenerated from what we
# actually build.
set -euo pipefail

# One local source of build scripts. A builder clones the packaging repo and
# points this at it; the default is where a normal checkout lands.
PACKAGING=${OMARCHY_PACKAGING:-$HOME/Development/omarchy-ppc64le-packaging}
ARCHPOWER=${ARCHPOWER:-$HOME/Development/repo/archpower}

usage() { echo "usage: fetch.sh [--aur] <pkgbase> [dest]" >&2; exit 2; }

src=gitlab
case ${1:-} in
  --aur) src=aur; shift ;;
  --gitlab) shift ;;
  -*) usage ;;
esac
base=${1:?$(usage)}
dest=${2:-}

[ -d "$PACKAGING" ] || { echo "no packaging tree at $PACKAGING" >&2; exit 2; }

# Where the recipe belongs. In order of authority:
#   1. it is already in the tree -- update it in place, never create a second
#      directory for a pkgbase (that is the duplicate error bq refuses to guess
#      past);
#   2. Arch POWER nests it under a category and the checkout is available --
#      use the same category, since our layout mirrors theirs;
#   3. otherwise the top level, which is where Arch's flat namespace maps.
if [ -z "$dest" ]; then
  mapfile -t _have < <(find "$PACKAGING" -mindepth 1 -maxdepth 3 -type d \
    -name "$base" -exec test -f '{}/PKGBUILD' \; -print | sort)
  case ${#_have[@]} in
    0) ;;
    1) dest=${_have[0]#"$PACKAGING"/} ;;
    *) echo "ambiguous pkgbase $base, ${#_have[@]} directories claim it:" >&2
       printf '  %s\n' "${_have[@]}" >&2
       echo "resolve that first: one pkgbase, one directory." >&2; exit 2 ;;
  esac
fi
if [ -z "$dest" ] && [ -d "$ARCHPOWER" ]; then
  apdir=$(find "$ARCHPOWER" -mindepth 1 -maxdepth 3 -type d -name "$base" \
    -exec test -f '{}/PKGBUILD' \; -print -quit 2>/dev/null)
  rel=${apdir#"$ARCHPOWER"/}
  case "$rel" in */*) dest=$rel ;; esac
fi
dest=${dest:-$base}

case $src in
  gitlab) url="https://gitlab.archlinux.org/archlinux/packaging/packages/$base.git" ;;
  aur)    url="https://aur.archlinux.org/$base.git" ;;
esac

tmp=$(mktemp -d -p /var/tmp fetch.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
GIT_TERMINAL_PROMPT=0 git clone -q --depth 1 "$url" "$tmp/$base"
[ -f "$tmp/$base/PKGBUILD" ] || { echo "$src has no PKGBUILD for $base" >&2; exit 1; }
rm -rf "$tmp/$base/.git" "$tmp/$base/.SRCINFO" "$tmp/$base/.nvchecker.toml"

mkdir -p "$PACKAGING/$dest"
cp -a "$tmp/$base"/. "$PACKAGING/$dest"/
echo "fetched $base from $src -> $dest"
ls "$PACKAGING/$dest"
echo
echo "Review it, then commit it in $PACKAGING -- an uncommitted recipe is not"
echo "a source of truth, and bq will build whatever is on disk."
