#!/bin/bash
# isa-guard.sh <pkgdir>... -- bq post-package guard: no instructions above the
# lane's ISA floor.
#
# The baseline lane builds for POWER8 (ISA 2.07) and the POWER9 lane for ISA
# 3.0. The compiler flags alone do not keep code inside those floors: highway's
# PPC10 tier (libjxl ran a POWER10 `pla` on a POWER9), Rust
# #[target_feature] tiers (firefox's jxl_simd), a build's own -mcpu, or a
# toolchain default (gcc's libgcc.a) have all put higher-ISA code into a
# package that was built with the right CFLAGS. This guard decodes every ELF
# object in the package and fails the build when any instruction above the
# floor is not one of the proven-harmless forms below and is not covered by the
# package's entry in tools/isa-allow.tsv.
#
# Method: objdump -M <floor> prints an encoding the floor cannot decode as
# `.long`, and -M power10 decodes it. So "above the floor" means .long under
# the floor's dialect but an instruction under power10. Keys are
# section:address, because relocatable objects (.o in .a archives,
# -ffunction-sections, kernel modules) start every section at 0.
#
# Harmless forms:
#   * jump-table data that objdump decodes as quad-precision instructions. The
#     fields are all ones, so it always comes out as v31 or cr7 operands,
#     e.g. `xsiexpqp v31,v31,v27` or `xststdcqp cr7,v31,127`. Real qp code uses
#     ordinary registers and is NOT excused.
#   * scv: glibc's system-call path, taken only when the kernel advertises it.
#   * darn, up to 4 per file: libstdc++'s random_device, reached only after
#     __builtin_cpu_supports("darn").
#   * Go binaries, up to 22 per file: the runtime-checked bytealg.Index block.
#
# Floor: ISA_GUARD_FLOOR=power8|power9 overrides; otherwise it comes from the
# lane's CFLAGS (-mcpu=power8|power9), read from $BUILDROOT/makepkg.conf.
# Exit 0 = clean, 1 = finding (bq quarantines the package).
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
allow=${ISA_GUARD_ALLOW:-$here/isa-allow.tsv}
OBJDUMP=${OBJDUMP:-objdump}
command -v powerpc64le-unknown-linux-gnu-objdump >/dev/null 2>&1 &&
  OBJDUMP=${OBJDUMP_OVERRIDE:-powerpc64le-unknown-linux-gnu-objdump}

floor=${ISA_GUARD_FLOOR:-}
if [ -z "$floor" ] && [ -n "${BUILDROOT:-}" ] && [ -r "$BUILDROOT/makepkg.conf" ]; then
  cflags=$(bash -c 'source "$1" >/dev/null 2>&1
                    for f in "$1".d/*.conf; do [ -r "$f" ] && source "$f" >/dev/null 2>&1; done
                    printf "%s" "$CFLAGS"' _ "$BUILDROOT/makepkg.conf")
  case " $cflags " in
    *" -mcpu=power8 "*) floor=power8 ;;
    *" -mcpu=power9 "*) floor=power9 ;;
  esac
fi
case $floor in
  power8|power9) ;;
  *) echo "isa-guard: cannot tell the lane's ISA floor (set ISA_GUARD_FLOOR)"; exit 1 ;;
esac

benign_re='^(xs[a-z]+qpo? (v31,v[0-9]+(,v[0-9]+)?|cr7,v[0-9]+,[0-9]+)|scv( |$))'

work=$(mktemp -d "${TMPDIR:-/var/tmp}/isa-guard.XXXXXX")
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT

# Print "<mnemonic> <operands>" for every instruction above the floor in $1.
above() {
  "$OBJDUMP" -d --no-show-raw-insn -M "$floor" "$1" 2>/dev/null |
    awk '/^Disassembly of section/{s=$4} $2==".long"{print s":"$1}' > "$work/lo"
  [ -s "$work/lo" ] || return 0
  "$OBJDUMP" -d --no-show-raw-insn -M power10 "$1" 2>/dev/null |
    awk '/^Disassembly of section/{s=$4} {print s":"$1, $2, $3}' > "$work/hi"
  awk 'NR==FNR{a[$1]=1; next} ($1 in a) && $2!=".long"{print $2, $3}' "$work/lo" "$work/hi"
}

is_elf() { [[ $(od -An -tx1 -N4 "$1" 2>/dev/null) == " 7f 45 4c 46" ]]; }

# Non-harmless count for one ELF file, with the per-file darn/Go excuses.
scan_elf() {
  local f=$1 ins total darn go=0
  ins=$(above "$f")
  [ -n "$ins" ] || { echo 0; return; }
  printf '%s\n' "$ins" >> "$work/all"
  total=$(printf '%s\n' "$ins" | grep -cvE "$benign_re")
  darn=$(printf '%s\n' "$ins" | grep -cE '^darn( |$)')
  [ "$darn" -gt 4 ] && darn=4
  total=$((total - darn))
  if "$OBJDUMP" -h "$f" 2>/dev/null | grep -q '\.go\.buildinfo'; then
    go=$total; [ "$go" -gt 22 ] && go=22
    total=$((total - go))
  fi
  printf '%s\n' "$ins" | grep -vE "$benign_re" | grep -vE '^darn( |$)' >> "$work/bad"
  echo "$total"
}

status=0
for pkgdir in "$@"; do
  [ -d "$pkgdir" ] || continue
  pkg=$(basename "$pkgdir")
  : > "$work/bad"; : > "$work/all"; : > "$work/files"
  n=0
  while IFS= read -r -d '' f; do
    if is_elf "$f"; then
      c=$(scan_elf "$f")
      [ "$c" -gt 0 ] && echo "$c ${f#"$pkgdir"/}" >> "$work/files"
      n=$((n + c))
    elif [[ $f == *.a ]]; then
      rm -rf "$work/ar"; mkdir "$work/ar"
      (cd "$work/ar" && ar x "$f" 2>/dev/null)
      ac=0
      for o in "$work"/ar/*; do
        [ -f "$o" ] && is_elf "$o" || continue
        c=$(scan_elf "$o"); ac=$((ac + c))
      done
      [ "$ac" -gt 0 ] && echo "$ac ${f#"$pkgdir"/}" >> "$work/files"
      n=$((n + ac))
    fi
  done < <(find "$pkgdir" -type f -size +64c -print0)

  allowed=$(awk -F'\t' -v p="$pkg" -v l="$floor" \
    '$1==p && ($2==l || $2=="*") {print $3; exit}' "$allow" 2>/dev/null)
  allowed=${allowed:-0}

  if [ "$n" -le "$allowed" ]; then
    if [ "$n" -gt 0 ]; then
      echo "isa-guard: ok $pkg ($floor floor): $n allowed by isa-allow.tsv (max $allowed)"
    else
      echo "isa-guard: clean $pkg ($floor floor)"
    fi
    continue
  fi

  status=1
  echo "isa-guard: FAIL $pkg ($floor floor): $n instruction(s) above the floor, allowance $allowed"
  echo "  by file:"
  sort -rn "$work/files" | head -10 | sed 's/^/    /'
  echo "  by mnemonic:"
  awk '{print $1}' "$work/bad" | sort | uniq -c | sort -rn | head -10 | sed 's/^/    /'
  src="$(dirname "$(dirname "$pkgdir")")/src"
  if [ -d "$src" ]; then
    hints=$(grep -rIlE -e '-mcpu=power(9|10)|power(9|10)-vector|-mpower(9|10)' \
              -e 'pragma GCC target|__attribute__\(\(target\(' \
              -e 'target_feature\(enable *= *"power(9|10)' \
              -e 'HWY_PPC10|HWY_TARGET_STR_PPC' \
              "$src" 2>/dev/null | head -8)
    if [ -n "$hints" ]; then
      echo "  likely sources (pattern grep):"
      printf '%s\n' "$hints" | sed "s|^$src/|    |"
    fi
  fi
done
exit "$status"
