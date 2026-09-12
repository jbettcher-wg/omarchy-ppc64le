#!/bin/bash
# ccache-check.sh -- prove the compiler cache is wired in AND cannot mask a
# flag change.
#
# The second half is the point. A cache that returns a hit across a change of
# -mcpu would be worse than no cache at all: a POWER8-targeted build would
# silently reuse POWER9 objects, and this tree has already shipped a Rust
# toolchain whose -Ctarget-cpu=pwr9 was silently not applying for weeks. So
# this does not read ccache's documentation and believe it; it compiles the
# same file twice with different -mcpu and checks both that ccache reports a
# miss and that the two objects actually differ.
#
# Everything runs against a throwaway CCACHE_DIR, so the real cache is not
# touched and the counters are exact.
#
#   tools/ccache-check.sh            # all checks must pass
#   tools/ccache-check.sh --break    # feed the flag-change checks two IDENTICAL
#                                    # compilations; they must then FAIL, which
#                                    # is what shows they are live
#
# SYSROOT=<dir> stacks that sysroot into the overlay, so the check runs in the
# same sandbox shape bq builds in.
set -uo pipefail

BREAK=0
[ "${1:-}" = "--break" ] && BREAK=1

WORK=$(mktemp -d /var/tmp/ccache-check.XXXXXX) || exit 2
trap 'rm -rf "$WORK"' EXIT
export CCACHE_DIR="$WORK/cache"
export CCACHE_COMPILERCHECK=content
mkdir -p "$CCACHE_DIR"

fails=0
ok()   { printf '  %-58s ok\n'   "$1"; }
bad()  { printf '  %-58s FAIL  %s\n' "$1" "${2:-}"; fails=$((fails+1)); }
say()  { printf '%s\n' "$1"; }

stat_of() { ccache --print-stats | awk -F'\t' -v k="$1" '$1==k{print $2}'; }

# --- the source -------------------------------------------------------------
# Two ways to differ under -mcpu: an ISA macro the compiler defines itself, and
# a loop the vectoriser handles differently. Either alone would be enough; both
# means a false hit cannot hide behind one of them being a no-op.
cat > "$WORK/t.c" <<'EOF'
float acc(const float *a, const float *b, int n) {
    float s = 0;
    for (int i = 0; i < n; i++) s += a[i] * b[i];
#ifdef _ARCH_PWR9
    s += 1.0f;          /* only compiled in at ISA 3.0 */
#endif
    return s;
}
EOF

# --- the sandbox ------------------------------------------------------------
# bq builds under `bwrap --ro-overlay /usr`, and /usr/lib/ccache/bin lives on
# the host /usr. Whether it survives that overlay has to be checked from
# *inside*, not from the shell that set it up.
BW=()
if command -v bwrap >/dev/null; then
  BW=(bwrap --dev-bind / / --overlay-src /usr)
  if [ -n "${SYSROOT:-}" ] && [ -d "$SYSROOT/usr" ]; then
    BW+=(--overlay-src "$SYSROOT/usr")
  else
    # --ro-overlay wants two sources; an empty upper layer reproduces the
    # shape bq uses on a buildroot whose sysroot has nothing in it yet.
    mkdir -p "$WORK/emptyusr"
    BW+=(--overlay-src "$WORK/emptyusr")
  fi
  BW+=(--ro-overlay /usr --)
fi
run() { "${BW[@]}" env PATH="/usr/lib/ccache/bin:$PATH" "$@"; }

say "sandbox"
shim=$(run bash -c 'type -p gcc')
if [ "$shim" = /usr/lib/ccache/bin/gcc ]; then
  ok "gcc resolves to the ccache shim inside the sandbox"
else
  bad "gcc resolves to the ccache shim inside the sandbox" "got '$shim'"
fi
real=$(run bash -c 'readlink -f /usr/lib/ccache/bin/gcc')
if [ "$real" = /usr/bin/ccache ]; then
  ok "...and that shim is ccache"
else
  bad "...and that shim is ccache" "got '$real'"
fi

# --- cold, warm, and the flag change ----------------------------------------
compile() {  # $1 = -mcpu value, $2 = output
  run gcc -O2 -mcpu="$1" -mtune="$1" -c "$WORK/t.c" -o "$2" 2>"$WORK/err" \
    || { bad "compile with -mcpu=$1" "$(head -2 "$WORK/err")"; return 1; }
}

say "hit and miss accounting"
h0=$(stat_of direct_cache_hit); m0=$(stat_of cache_miss)
compile power8 "$WORK/a.o" || exit 1
h1=$(stat_of direct_cache_hit); m1=$(stat_of cache_miss)
[ "$m1" -eq $((m0+1)) ] && ok "cold compile is a miss" \
  || bad "cold compile is a miss" "miss $m0 -> $m1"
[ "$h1" -eq "$h0" ] && ok "...and not a hit" || bad "...and not a hit" "hit $h0 -> $h1"

compile power8 "$WORK/a2.o" || exit 1
h2=$(stat_of direct_cache_hit); m2=$(stat_of cache_miss)
[ "$h2" -eq $((h1+1)) ] && ok "identical recompile is a hit" \
  || bad "identical recompile is a hit" "hit $h1 -> $h2"
if cmp -s "$WORK/a.o" "$WORK/a2.o"; then
  ok "...returning the same object"
else
  bad "...returning the same object"
fi

# The check that matters. In --break mode the "changed" flag is not changed at
# all, so a hit is expected and correct -- and both assertions below must then
# fail, which is how we know they are testing something.
say "a changed -mcpu must not hit"
NEWCPU=power9
[ "$BREAK" -eq 1 ] && NEWCPU=power8
[ "$BREAK" -eq 1 ] && say "  [--break] using -mcpu=$NEWCPU again instead of power9"

compile "$NEWCPU" "$WORK/b.o" || exit 1
h3=$(stat_of direct_cache_hit); m3=$(stat_of cache_miss)
if [ "$m3" -eq $((m2+1)) ] && [ "$h3" -eq "$h2" ]; then
  ok "-mcpu change is a miss, not a hit"
else
  bad "-mcpu change is a miss, not a hit" "hit $h2 -> $h3, miss $m2 -> $m3"
fi
if cmp -s "$WORK/a.o" "$WORK/b.o"; then
  bad "-mcpu change produces different code" "objects are byte-identical"
else
  ok "-mcpu change produces different code"
fi

# And the code difference is the ISA one, not incidental: _ARCH_PWR9 gates an
# extra addition, so exactly one object carries the constant load for it.
if [ "$BREAK" -eq 0 ]; then
  n8=$(objdump -d "$WORK/a.o" 2>/dev/null | grep -c 'fadds\|xsaddsp')
  n9=$(objdump -d "$WORK/b.o" 2>/dev/null | grep -c 'fadds\|xsaddsp')
  if [ "$n9" -gt "$n8" ]; then
    ok "the power9 object has the _ARCH_PWR9-gated add ($n8 -> $n9)"
  else
    bad "the power9 object has the _ARCH_PWR9-gated add" "$n8 vs $n9"
  fi
fi

echo
if [ "$fails" -gt 0 ]; then echo "FAILED: $fails check(s)"; exit 1; fi
echo "all checks passed"
