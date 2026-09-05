#!/bin/bash
# Fetch an Arch official package repo into packages/<dest>, keeping only the
# recipe files (PKGBUILD, .install, patches, keys) and dropping the git dir.
set -euo pipefail
REPOROOT=/home/jbettcher/Development/omarchy-ppc64le
base=${1:?usage: fetch.sh <pkgbase> [dest]}
dest=${2:-$base}
tmp=$(mktemp -d)
git clone -q --depth 1 "https://gitlab.archlinux.org/archlinux/packaging/packages/$base.git" "$tmp/$base"
mkdir -p "$REPOROOT/packages/$dest"
rm -rf "$tmp/$base/.git" "$tmp/$base/.SRCINFO" "$tmp/$base/.nvchecker.toml"
cp -a "$tmp/$base"/. "$REPOROOT/packages/$dest"/
rm -rf "$tmp"
echo "fetched $base -> packages/$dest"
ls "$REPOROOT/packages/$dest"
