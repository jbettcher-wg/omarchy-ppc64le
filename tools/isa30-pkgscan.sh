#!/bin/bash
# isa30-pkgscan.sh -- count ISA 3.0 (POWER9-only) instructions in packages.
#
# The package-level form of powerpc64le-handbook/probes/isa30scan.sh, same
# method: disassemble every ppc64le ELF with objdump's POWER8 dialect and its
# POWER9 dialect. An encoding only POWER9 decodes comes out as `.long` under
# -M power8, so (.long under power8) - (.long under power9) is the number of
# ISA 3.0 instructions. Data embedded in text is `.long` under both and cancels.
# The controls that prove the method fails in both directions are in
# docs/power8-secondary-target.md, section 2.
#
# Usage:
#   tools/isa30-pkgscan.sh <pkg.tar.zst>...          one line per package
#   tools/isa30-pkgscan.sh --repo [DIR]              newest build of every
#                                                    package in DIR (repo/)
# Output: <count>\t<package file>, sorted by count, largest first.
# A POWER8 repo ships only packages that scan 0, or whose ISA 3.0 code is
# behind a runtime AT_HWCAP2 check (see section 5 of the doc).
set -uo pipefail

scan_one() {
  local pkg=$1 d total=0 f n8 n9
  d=$(mktemp -d "${TMPDIR:-/var/tmp}/isa30.XXXXXX")
  bsdtar -xf "$pkg" -C "$d" 2>/dev/null
  while IFS= read -r -d '' f; do
    # ELF, 64-bit PowerPC only; skips scripts, data and foreign binaries.
    [[ $(od -An -tx1 -N4 "$f" 2>/dev/null) == " 7f 45 4c 46" ]] || continue
    file -b "$f" | grep -q '64-bit LSB .*PowerPC' || continue
    n8=$(objdump -d --no-show-raw-insn -M power8 "$f" 2>/dev/null | grep -cP '^\s+[0-9a-f]+:\s+\.long\b')
    n9=$(objdump -d --no-show-raw-insn -M power9 "$f" 2>/dev/null | grep -cP '^\s+[0-9a-f]+:\s+\.long\b')
    total=$((total + n8 - n9))
  done < <(find "$d" -type f -size +1k -print0)
  # Packages extract some directories read-only (etc/bluetooth); rm needs write.
  chmod -R u+rwX "$d" 2>/dev/null
  rm -rf "$d"
  printf '%d\t%s\n' "$total" "$pkg"
}
export -f scan_one

if [[ ${1:-} == --repo ]]; then
  dir=${2:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)/repo}
  # Newest build of each pkgname: name-ver-rel-arch, name may contain dashes.
  mapfile -t pkgs < <(cd "$dir" && ls -1t *.pkg.tar.zst 2>/dev/null |
    awk '{ n=$0; sub(/-[^-]+-[^-]+-[^-]+\.pkg\.tar\.zst$/, "", n); if (!(n in seen)) { seen[n]=1; print } }' |
    grep -v -- '-any\.pkg\.tar\.zst$' | grep -v -- '-debug-' | sed "s#^#$dir/#")
else
  pkgs=("$@")
fi
((${#pkgs[@]})) || { sed -n '2,19p' "$0"; exit 2; }

printf '%s\0' "${pkgs[@]}" | xargs -0 -n1 -P "$(nproc)" bash -c 'scan_one "$1"' _ | sort -t$'\t' -k1,1nr
