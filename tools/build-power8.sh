#!/bin/bash
# build-power8.sh -- build packages for the POWER8 (ISA 2.07) secondary target.
#
# Same recipes, same bq, different pool: packages land in repo-power8/ and every
# compile gets -mcpu=power8 from tools/makepkg.conf.d/00-power8.conf. Nothing
# global changes; the POWER9 builder keeps /tmp/omarchy-bq, .bq-state.json and
# repo/. See docs/power8-secondary-target.md, section 3.
#
# Usage:
#   tools/build-power8.sh plan <pkgbase>... | -f targets.txt   write the queue
#   tools/build-power8.sh build [-j N] [bq build options]      build the queue
#   tools/build-power8.sh <pkgbase>...                         plan, then build
#
# Environment (defaults shown):
#   BQ_BUILDROOT=/var/tmp/omarchy-bq-power8   build tree, sysroot, state, tmp
#   BQ_REPO=<project>/repo-power8             package pool and output
#
# Before publishing anything built here, scan it for ISA 3.0 instructions; the
# compiler flags cannot see recipes that pin POWER9 themselves.
set -euo pipefail

PROJECT=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
DROPIN=$PROJECT/tools/makepkg.conf.d/00-power8.conf

export BQ_BUILDROOT=${BQ_BUILDROOT:-/var/tmp/omarchy-bq-power8}
export BQ_STATE=${BQ_STATE:-$BQ_BUILDROOT/state.json}
export BQ_REPO=${BQ_REPO:-$PROJECT/repo-power8}
export TMPDIR=$BQ_BUILDROOT/tmp

# Refuse to build without the drop-in: without it this is a POWER9 build that
# lands in the POWER8 pool, which is worse than no build.
[[ -r $DROPIN ]] || { echo "build-power8.sh: $DROPIN is missing" >&2; exit 1; }
bash -n "$DROPIN"

mkdir -p "$BQ_REPO" "$TMPDIR" "$BQ_BUILDROOT/makepkg.conf.d" "$BQ_BUILDROOT/srcdest"
install -m644 "$DROPIN" "$BQ_BUILDROOT/makepkg.conf.d/00-power8.conf"

QUEUE=$BQ_BUILDROOT/queue.json
bq() { python3 "$PROJECT/tools/bq.py" --buildroot "$BQ_BUILDROOT" "$@"; }

do_build() {
  bq build -q "$QUEUE" --pkgdest "$BQ_REPO" --repo-db "" --timeout 21600 "$@"
}

case "${1:-}" in
  plan)  shift; bq plan "$@" ;;
  build) shift; do_build "$@" ;;
  ""|-h|--help) sed -n '2,20p' "$0"; exit 0 ;;
  *)     bq plan "$@" && do_build ;;
esac
