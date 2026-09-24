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

# The dynamic section is not the only place a build tree path ends up. meson's
# `dependency('xkbcomp')` reads bindir straight out of xkbcomp.pc, and when that
# .pc still carried a sysroot prefix the path went into a *string constant*:
#
#   xorg-xwayland 24.1.13-1 baked "/var/tmp/omarchy-bq/sysroot/usr/bin" into
#   XKB_BIN_DIRECTORY, so Xwayland fork/exec'd a xkbcomp that does not exist on
#   the installed system -- "XKB: Failed to compile keymap", then FatalError and
#   SIGABRT, every X11 client dead, and readelf -d perfectly clean.
#
# So also match the literal sysroot path against the whole file, ELF included.
# Literal, not the FORBIDDEN regex: a real package may legitimately contain the
# word "sysroot" (dracut, systemd, cross toolchains), but nothing has any
# business containing the path to OUR staging tree.
#
# $SYSROOT only, deliberately NOT $BUILDROOT. Assert and logging macros expand
# __FILE__, so a build tree path is baked into perfectly healthy binaries as a
# source filename -- networkmanager carries
# "$BUILDROOT/build/networkmanager/src/.../clat.bpf.c" and fcitx5 a handful of
# header paths. Around 160 packages have those. They are a reproducibility wart,
# curable with -ffile-prefix-map, not a defect: nothing opens them at runtime.
# A path under $SYSROOT is different in kind -- it is always something the build
# *resolved* and intends to use, and it is always wrong.
LEAK_PATHS=()
for _lp in "${SYSROOT:-}"; do
  [ -n "$_lp" ] || continue
  _lp=$(readlink -f "$_lp" 2>/dev/null || printf '%s' "$_lp")
  case " ${LEAK_PATHS[*]-} " in *" $_lp "*) ;; *) LEAK_PATHS+=("$_lp") ;; esac
done

# Match the literal paths anywhere in a file. Returns 0 when one is found.
has_leak_path() {
  [ ${#LEAK_PATHS[@]} -gt 0 ] || return 1
  local args=() lp
  for lp in "${LEAK_PATHS[@]}"; do args+=(-e "$lp"); done
  LC_ALL=C grep -qaF "${args[@]}" -- "$1" 2>/dev/null
}

# Stricter variant, for files other builds *read* (.pc, *-config, *.cmake,
# Makefiles). In an ELF a $BUILDROOT path is almost always __FILE__ from an
# assert and harmless; in a cmake or pkg-config file it is a path a downstream
# build will try to use, so it fails there.
has_build_path() {
  local args=() lp
  for lp in "${LEAK_PATHS[@]}" "${BUILDROOT:-}"; do
    [ -n "$lp" ] && args+=(-e "$lp")
  done
  [ ${#args[@]} -gt 0 ] || return 1
  LC_ALL=C grep -qaF "${args[@]}" -- "$1" 2>/dev/null
}

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
# Deliberately no generic "sysroot" alternative. OUR sysroot is matched exactly,
# by literal path, in has_leak_path() above -- which is precise. Matching the
# bare word here instead produced a false positive that rejected a complete vtk
# build over upstream CMake in FindOpenGL.cmake:
#
#   set(_OPENGL_INCLUDE_PATH ${CMAKE_ANDROID_NDK}/sysroot/usr/include)
#   "${EMSCRIPTEN_ROOT_PATH}/cache/sysroot/include")
#
# Those are Android NDK and Emscripten variable references, not build-tree
# paths. "omarchy-work" stays: it is the literal name of an older buildroot of
# ours, so it can only ever be a leak.
# Also no "/src/<x>/(pkg|src)/" heuristic. It was meant to catch makepkg's
# $srcdir layout, but it matches across two paths on one line and rejected a
# complete vtk build over relocatable upstream CMake:
#
#   FILES "${_IMPORT_PREFIX}/include/vtk/vtkh5part/src/H5BlockErrors.h"
#         "${_IMPORT_PREFIX}/include/vtk/vtkh5part/src/H5Block.h"
#
# What is left are literals that cannot occur innocently -- with one
# exception that has to be spelled out. A bare "$srcdir" or "$pkgdir" in a
# shipped file is a makepkg variable that leaked unexpanded, which is a real
# bug. But automake writes "$$srcdir" into every generated Makefile.in: the
# doubled dollar is how a make recipe passes a literal $ to the shell, e.g.
#
#   sed -e "s|^$$srcdir/||"
#
# A plain '\$srcdir' matches the tail of that, so the guard rejected
# xorg-server-src -- 93 "violations" across the pristine upstream autotools
# files it ships, with no build path among them. Require that the $ not be
# preceded by another $; ERE has no lookbehind, hence the (^|[^$]) prefix.
FORBIDDEN='omarchy-work|(^|[^$])\$(srcdir|pkgdir)|/\.cache/|/tmp/makepkg'


# ---------------------------------------------------------------- scripts ----
# The ELF checks above miss the larger half of a package set. A shebang is not
# an ELF header, so `#!/var/tmp/omarchy-bq/sysroot/usr/bin/bash` in pacman-key
# passed this guard cleanly and would have shipped -- it only surfaced when
# mkarchiso ran pacman-key inside a chroot where that path does not exist.
#
# Two things are checked, and deliberately not a third:
#
#   * the interpreter of anything starting with #!, wherever it lives
#   * build-facing text: */bin/*-config, *.pc, *.cmake, Makefile* -- files whose
#     whole job is to hand paths to somebody else's build
#
# NOT checked: documentation. gtk-doc HTML routinely embeds the build path and
# is inert; failing a package over it would train people to ignore this guard.
check_text() {
  local p="$1" dirabs="$2" rel="${1#"$2"}" first interp
  # Skip anything binary-ish; grep -I is the cheap test.
  grep -Iq . -- "$p" 2>/dev/null || return 0

  first=$(head -c 200 -- "$p" 2>/dev/null | head -1)
  case "$first" in
    '#!'*)
      total_script=$((total_script+1))
      interp=${first#\#!}
      interp=${interp# }
      interp=${interp%% *}
      # Only an ABSOLUTE interpreter can encode a build-tree path, which is what
      # this guard is for. A bare name cannot: freecad 1.1.3 ships eight upstream
      # example scripts beginning "#! python" with CRLF line endings -- broken as
      # a shebang on any Linux, authored on Windows, shipped as-is by Arch.
      # Failing the whole package for those is a false positive. The FORBIDDEN
      # check just below still runs on them either way.
      case "$interp" in
        /usr/*|/bin/*|/sbin/*) ;;
        /*) echo "elf-pathguard: FAIL ${rel}: interpreter outside /usr: ${interp}"
            viol=$((viol+1)) ;;
        *)  echo "elf-pathguard: note ${rel}: non-absolute interpreter: ${interp}" ;;
      esac
      if printf '%s' "$interp" | grep -qE "$FORBIDDEN"; then
        echo "elf-pathguard: FAIL ${rel}: build-tree path in shebang: ${interp}"
        viol=$((viol+1))
      fi ;;
  esac

  case "$rel" in
    */bin/*-config|*.pc|*.cmake|*/Makefile*|*/*-config.cmake)
      if grep -qE "$FORBIDDEN" -- "$p" 2>/dev/null || has_build_path "$p"; then
        echo "elf-pathguard: FAIL ${rel}: build-tree path in a file other builds read"
        viol=$((viol+1))
      fi ;;
  esac
}

viol=0
scanned_dirs=0
total_elf=0
total_script=0

for dir in "$@"; do
  [ -d "$dir" ] || { echo "elf-pathguard: not a directory: $dir" >&2; exit 2; }
  scanned_dirs=$((scanned_dirs+1))
  # The pkgdir path itself must never appear in a shipped header.
  dirabs=$(readlink -f "$dir")

  # The literal leak-path check applies to every file, ELF or not (see
  # LEAK_PATHS above). One recursive grep instead of one grep per file: a
  # 140k-file package (gstreamer) spent bq's whole 30-minute guard timeout
  # forking per-file checks.
  if [ ${#LEAK_PATHS[@]} -gt 0 ]; then
    lp_args=()
    for lp in "${LEAK_PATHS[@]}"; do lp_args+=(-e "$lp"); done
    while IFS= read -r -d '' p; do
      echo "elf-pathguard: FAIL ${p#"$dirabs"}: sysroot path baked into file contents"
      viol=$((viol+1))
    done < <(LC_ALL=C grep -rlaFZ "${lp_args[@]}" -- "$dirabs" 2>/dev/null)
  fi

  # One pass classifies every regular file: E = ELF (magic 7f 45 4c 46),
  # T = a check_text candidate (starts with "#!", or a build-facing name).
  # Every other file produced no output from check_text, so it is not visited.
  while IFS= read -r -d '' rec; do
    kind=${rec%%$'\t'*}; p=${rec#*$'\t'}
    if [ "$kind" = T ]; then
      check_text "$p" "$dirabs"; continue
    fi
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
  done < <(python3 - "$dirabs" <<'PYEOF'
import fnmatch, os, stat, sys
root = sys.argv[1]
# check_text's build-facing patterns, matched against the path relative to the
# package dir as bash `case` globs (where * also matches /).
pats = ("*/bin/*-config", "*.pc", "*.cmake", "*/Makefile*", "*/*-config.cmake")
out = sys.stdout.buffer
for dirpath, dirnames, filenames in os.walk(root):
    for name in filenames:
        p = os.path.join(dirpath, name)
        try:
            if not stat.S_ISREG(os.lstat(p).st_mode):
                continue
            with open(p, "rb") as f:
                head = f.read(4)
        except OSError:
            continue
        rel = p[len(root):]
        if head == b"\x7fELF":
            kind = b"E"
        elif head[:2] == b"#!" or any(fnmatch.fnmatchcase(rel, x) for x in pats):
            kind = b"T"
        else:
            continue
        out.write(kind + b"\t" + os.fsencode(p) + b"\0")
PYEOF
)
done

if [ "$viol" -gt 0 ]; then
  echo "elf-pathguard: ${viol} violation(s) across ${total_elf} ELF and ${total_script} script file(s) -- refusing to package" >&2
  exit 1
fi
echo "elf-pathguard: clean (${total_elf} ELF, ${total_script} script files in ${scanned_dirs} dir(s))"
exit 0
