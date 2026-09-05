#!/bin/bash
# Verify a built package by extracting it to a staging directory and running
# the binary. Never installs into the live system (see RULES.md).
#
#   verify.sh <pkgname> [-- <argv to run instead of "<pkgname> --version">]
set -uo pipefail
WORK=/home/jbettcher/omarchy-work
REPO=/home/jbettcher/Development/omarchy-ppc64le/repo
STAGE=$WORK/verify
SYSROOT=$WORK/sysroot

pkg=${1:?usage: verify.sh <pkgname> [-- cmd...]}; shift
mkdir -p "$STAGE"
f=$(ls -t "$REPO"/${pkg}-[0-9]*.pkg.tar.zst 2>/dev/null | grep -v -- '-debug-' | head -1)
[ -n "$f" ] || { echo "verify: no built package for $pkg"; exit 2; }
tar -I zstd -xf "$f" -C "$STAGE" \
  --exclude=.PKGINFO --exclude=.BUILDINFO --exclude=.MTREE --exclude=.INSTALL 2>/dev/null

export PATH="$STAGE/usr/bin:$SYSROOT/usr/bin:$PATH"
export LD_LIBRARY_PATH="$STAGE/usr/lib:$SYSROOT/usr/lib:${LD_LIBRARY_PATH:-}"
export GI_TYPELIB_PATH="$STAGE/usr/lib/girepository-1.0:$SYSROOT/usr/lib/girepository-1.0:${GI_TYPELIB_PATH:-}"
export XDG_DATA_DIRS="$STAGE/usr/share:$SYSROOT/usr/share:/usr/share"
for d in "$STAGE" "$SYSROOT"; do
  for pd in "$d"/usr/lib/python3.*/site-packages; do
    [ -d "$pd" ] && export PYTHONPATH="$pd:${PYTHONPATH:-}"
  done
done

# Run under a read-only overlay of the staged package (and the sysroot) on
# /usr, so wrapper scripts and binaries that hardcode /usr paths resolve to what
# we built rather than failing or, worse, silently testing the system copy.
# Unprivileged, process-local; the real /usr is untouched (RULES.md).
RUN=()
if command -v bwrap >/dev/null; then
  # bwrap stacks --overlay-src with the LAST one as the top-most layer, so the
  # live /usr must be listed FIRST. With the old order (stage, sysroot, /usr)
  # anything that also exists in the real /usr silently shadowed what we built
  # -- e.g. verifying neovim against the system libluajit-5.1.so.2 instead of
  # the one in the sysroot.
  RUN=(bwrap --dev-bind / / --overlay-src /usr \
       --overlay-src "$SYSROOT/usr" --overlay-src "$STAGE/usr" --ro-overlay /usr)
fi

if [ "${1:-}" = "--" ]; then shift; else set -- "$pkg" --version; fi
echo "--- $pkg: $* ---"
"${RUN[@]}" "$@" 2>&1 | head -4
echo "   (exit ${PIPESTATUS[0]})  ELF: $(file -b "$STAGE/usr/bin/${1}" 2>/dev/null | cut -d, -f1-2)"
