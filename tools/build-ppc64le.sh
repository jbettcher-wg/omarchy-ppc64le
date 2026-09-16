#!/bin/bash
# build-ppc64le.sh -- build packages for the baseline ppc64le pool.
#
# The baseline is compiled POWER8-legal (ISA 2.07), which is why it is the
# pool everyone gets: ISA 2.07 runs on POWER8 through POWER11, i.e. every
# ppc64le machine. A build is named for what it RUNS ON, not for what it was
# tuned for -- hence repo-ppc64le/ and [omarchy-ppc64le], even though the
# compiler flags say power8.
#
# Same recipes, same bq, different pool: packages land in repo-ppc64le/ and
# every compile gets -mcpu=power8 from tools/makepkg.conf.d/00-power8.conf
# (an ISA-level file, so it keeps the ISA name). Nothing global changes; the
# POWER9-optimised builder keeps /tmp/omarchy-bq, .bq-state.json and repo/.
# See docs/power8-secondary-target.md, section 3.
#
# Usage:
#   tools/build-ppc64le.sh plan <pkgbase>... | -f targets.txt   write the queue
#   tools/build-ppc64le.sh build [-j N] [bq build options]      build the queue
#   tools/build-ppc64le.sh <pkgbase>...                         plan, then build
#
# Environment (defaults shown):
#   BQ_BUILDROOT=/var/tmp/omarchy-bq-ppc64le  build tree, sysroot, state, tmp
#   BQ_REPO=<project>/repo-ppc64le            package pool and output
#
# Before publishing anything built here, scan it for ISA 3.0 instructions; the
# compiler flags cannot see recipes that pin POWER9 themselves.
set -euo pipefail

PROJECT=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
DROPIN=$PROJECT/tools/makepkg.conf.d/00-power8.conf

export BQ_BUILDROOT=${BQ_BUILDROOT:-/var/tmp/omarchy-bq-ppc64le}
export BQ_STATE=${BQ_STATE:-$BQ_BUILDROOT/state.json}
export BQ_REPO=${BQ_REPO:-$PROJECT/repo-ppc64le}
export TMPDIR=$BQ_BUILDROOT/tmp

# Refuse to build without the drop-in: without it this is a POWER9 build that
# lands in the baseline pool, which is worse than no build -- the baseline is
# the one pool that promises to run on a POWER8.
[[ -r $DROPIN ]] || { echo "build-ppc64le.sh: $DROPIN is missing" >&2; exit 1; }
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
  ""|-h|--help) sed -n '2,27p' "$0"; exit 0 ;;
  *)     bq plan "$@" && do_build ;;
esac
