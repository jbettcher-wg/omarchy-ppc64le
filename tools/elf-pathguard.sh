#!/bin/bash
# elf-pathguard.sh -- refuse to ship a package whose ELF headers point into the
# build tree.
#
# Why this exists: neovim 0.12.5-1 shipped with
#   DT_NEEDED [/home/jbettcher/omarchy-work/sysroot/usr/lib/lua/5.1/lpeg.so]
# an absolute reference into the unprivileged bwrap sysroot. It ran fine on the
# build host and would have kept running until someone deleted ~/omarchy-work.
# Nothing in makepkg checks for this, so we check for it.
#
# Usage:
#   elf-pathguard.sh <dir>...        # scan a $pkgdir (or an extracted package)
#
# Exit 0 clean, 1 on any violation (prints each), 2 on usage error.
#
# Reusable PKGBUILD snippet -- put this at the end of package():
#
#     # Fail the build if any shipped ELF records a build-tree path.
#     "${ELF_PATHGUARD:-$startdir/../../tools/elf-pathguard.sh}" "$pkgdir"
#
# tools/build.sh exports ELF_PATHGUARD and also runs this over every built
# package unconditionally, so a PKGBUILD that forgets the snippet is still
# covered. If neither path resolves the command fails -- the guard is
# fail-closed on purpose: a guard that silently no-ops is not a guard.
set -uo pipefail

[ $# -ge 1 ] || { echo "usage: elf-pathguard.sh <dir>..." >&2; exit 2; }

# Absolute DT_NEEDED / R[UN]PATH entries are tolerated only under these real
# system library roots. Arch's own neovim ships
# NEEDED [/usr/lib/lua/5.1/lpeg.so], so a blanket "no absolute paths" rule
# would be wrong; the thing that must never appear is a path outside /usr.
is_system_path() {
  case "$1" in
    /usr/lib/*|/usr/lib64/*|/lib/*|/lib64/*|/usr/lib|/usr/lib64|/lib|/lib64) return 0 ;;
    *) return 1 ;;
  esac
}

# Substrings that mean "build tree" no matter where they appear -- these catch
# a leak even in a path that would otherwise pass the prefix test, and catch
# relative RUNPATH entries too.
FORBIDDEN='omarchy-work|/sysroot/|(^|/)sysroot(/|$)|/src/[^:]*/(pkg|src)/|\$srcdir|\$pkgdir|/\.cache/|/tmp/makepkg'

viol=0
scanned_dirs=0
total_elf=0

for dir in "$@"; do
  [ -d "$dir" ] || { echo "elf-pathguard: not a directory: $dir" >&2; exit 2; }
  scanned_dirs=$((scanned_dirs+1))
  # The pkgdir path itself must never appear in a shipped header.
  dirabs=$(readlink -f "$dir")

  while IFS= read -r -d '' p; do
    [ "$(head -c4 -- "$p" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "7f454c46" ] || continue
    out=$(readelf -dW -- "$p" 2>/dev/null) || continue
    [ -n "$out" ] || continue
    total_elf=$((total_elf+1))
    rel=${p#"$dirabs"}

    while IFS= read -r line; do
      case "$line" in
        *'(NEEDED)'*)
          v=${line##*'Shared library: ['}; v=${v%]}
          bad=
          case "$v" in
            /*) is_system_path "$v" || bad="absolute DT_NEEDED outside /usr" ;;
          esac
          [ -z "$bad" ] && printf '%s' "$v" | grep -qE "$FORBIDDEN" && bad="build-tree path in DT_NEEDED"
          [ -z "$bad" ] && case "$v" in "$dirabs"*) bad="pkgdir path in DT_NEEDED" ;; esac
          if [ -n "$bad" ]; then
            echo "elf-pathguard: FAIL ${rel}: ${bad}: ${v}"; viol=$((viol+1))
          fi ;;
        *'(RPATH)'*|*'(RUNPATH)'*)
          kind=RUNPATH; case "$line" in *'(RPATH)'*) kind=RPATH ;; esac
          v=${line##*'path: ['}; v=${v%]}
          # each colon-separated element judged on its own
          IFS=: read -ra elems <<< "$v"
          for e in "${elems[@]}"; do
            [ -n "$e" ] || continue
            bad=
            case "$e" in
              '$ORIGIN'*|'${ORIGIN}'*) : ;;                  # relocatable, fine
              /*) is_system_path "$e" || bad="absolute $kind outside /usr" ;;
              *)  bad="relative $kind entry" ;;
            esac
            [ -z "$bad" ] && printf '%s' "$e" | grep -qE "$FORBIDDEN" && bad="build-tree path in $kind"
            [ -z "$bad" ] && case "$e" in "$dirabs"*) bad="pkgdir path in $kind" ;; esac
            if [ -n "$bad" ]; then
              echo "elf-pathguard: FAIL ${rel}: ${bad}: ${e}"; viol=$((viol+1))
            fi
          done ;;
      esac
    done <<< "$out"
  done < <(find "$dirabs" -type f -print0)
done

if [ "$viol" -gt 0 ]; then
  echo "elf-pathguard: ${viol} violation(s) across ${total_elf} ELF file(s) -- refusing to package" >&2
  exit 1
fi
echo "elf-pathguard: clean (${total_elf} ELF files in ${scanned_dirs} dir(s))"
exit 0
