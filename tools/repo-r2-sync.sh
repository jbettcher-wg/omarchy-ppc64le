#!/bin/bash
# repo-r2-sync.sh -- publish a deployed repo to Cloudflare R2 (or any rclone remote).
#
# Uploads exactly what the repo database references, not everything in the
# directory: repo/ keeps superseded builds and db backups on purpose
# (repo-publish.sh never deletes), and pacman only ever asks for the files the
# db names. Packages go first and the .db/.files last, so a client syncing
# mid-upload never sees a database that names a package not there yet.
#
# R2 has no symlinks, so omarchy-power9.db (-> .db.tar.gz) is uploaded as a
# real file with --copy-links.
#
# Usage:
#   R2_BUCKET=<bucket> tools/repo-r2-sync.sh [--dry-run]
#   REPO=repo-power8 REPO_NAME=omarchy-power8 R2_BUCKET=<bucket> tools/repo-r2-sync.sh
#
# Environment:
#   R2_REMOTE   rclone remote name (default r2), configured by the user with
#               `rclone config` -- credentials never live in this repo
#   R2_BUCKET   bucket name (required)
#   REPO        local repo directory (default <project>/repo)
#   REPO_NAME   database name, and the top-level prefix in the bucket
#               (default omarchy-power9)
#
# pacman.conf on a client then reads:
#   [omarchy-power9]
#   Server = https://<custom domain>/omarchy-power9
set -euo pipefail

PROJECT=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
REPO=${REPO:-$PROJECT/repo}
REPO_NAME=${REPO_NAME:-omarchy-power9}
R2_REMOTE=${R2_REMOTE:-r2}
: "${R2_BUCKET:?set R2_BUCKET to the bucket name}"
DRY=()
[[ ${1:-} == --dry-run ]] && DRY=(--dry-run)

DB=$REPO/$REPO_NAME.db.tar.gz
[[ -f $DB ]] || { echo "repo-r2-sync: no database $DB" >&2; exit 1; }
command -v rclone >/dev/null || { echo "repo-r2-sync: rclone not installed" >&2; exit 1; }
rclone listremotes | grep -qx "$R2_REMOTE:" ||
  { echo "repo-r2-sync: no rclone remote '$R2_REMOTE:' (run rclone config)" >&2; exit 1; }

DEST="$R2_REMOTE:$R2_BUCKET/$REPO_NAME"
list=$(mktemp)
trap 'rm -f "$list"' EXIT

# Every %FILENAME% the database references, plus its signature if one exists.
missing=0
while IFS= read -r f; do
  if [[ -f $REPO/$f ]]; then
    echo "$f"
    [[ -f $REPO/$f.sig ]] && echo "$f.sig"
  else
    echo "repo-r2-sync: db names $f but it is not in $REPO" >&2
    missing=1
  fi
done < <(bsdtar -xOf "$DB" --include='*/desc' | awk '/^%FILENAME%$/ { getline; print }') >"$list"
((!missing)) || { echo "repo-r2-sync: refusing to publish an incomplete repo" >&2; exit 1; }

echo "==> $(grep -vc '\.sig$' "$list") packages -> $DEST"
rclone copy "${DRY[@]}" --files-from "$list" --transfers 16 --checkers 32 \
  --stats 30s --stats-one-line "$REPO" "$DEST"

echo "==> databases -> $DEST"
rclone copy "${DRY[@]}" --copy-links \
  --include "$REPO_NAME.db" --include "$REPO_NAME.db.tar.gz" \
  --include "$REPO_NAME.files" --include "$REPO_NAME.files.tar.gz" \
  "$REPO" "$DEST"
echo "==> done"
