#!/bin/bash
# Fetch an Arch official package repo into packages/<dest>, keeping only the
# recipe files (PKGBUILD, .install, patches, keys) and dropping the git dir.
set -euo pipefail
REPOROOT=/home/jbettcher/Development/omarchy-ppc64le
base=${1:?usage: fetch.sh <pkgbase> [dest]}
# Mirror Arch POWER: if their tree nests this pkgbase under a category
# (kf6/, xorg/, python/ ...), ours lands under the same category, so the
# two trees stay comparable and bq can tell whose recipe is newer.
ARCHPOWER=${ARCHPOWER:-$HOME/Development/repo/archpower}
dest=${2:-}
if [ -z "$dest" ]; then
  apdir=$(find "$ARCHPOWER" -mindepth 1 -maxdepth 3 -type d -name "$base" \
    -exec test -f '{}/PKGBUILD' \; -print -quit 2>/dev/null)
  rel=${apdir#"$ARCHPOWER"/}
  case "$rel" in
    */*) dest=$rel ;;
    *)   dest=$base ;;
  esac
fi
tmp=$(mktemp -d)
git clone -q --depth 1 "https://gitlab.archlinux.org/archlinux/packaging/packages/$base.git" "$tmp/$base"
mkdir -p "$REPOROOT/packages/$dest"
rm -rf "$tmp/$base/.git" "$tmp/$base/.SRCINFO" "$tmp/$base/.nvchecker.toml"
cp -a "$tmp/$base"/. "$REPOROOT/packages/$dest"/
rm -rf "$tmp"
echo "fetched $base -> packages/$dest"
ls "$REPOROOT/packages/$dest"
