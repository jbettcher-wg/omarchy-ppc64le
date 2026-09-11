#!/usr/bin/env bash
# Reject a package that installs files outside the standard roots.
#
# The companion to elf-pathguard.sh, which inspects ELF RUNPATHs and the text of
# installed scripts. Neither looks at *where a package puts things*, and that is
# its own failure mode: a build system takes a directory from a .pc file whose
# prefix still points at the build sysroot, and installs to that absolute path
# instead of $pkgdir. The package builds, installs and reports success.
#
# Twelve packages in the repo shipped that way before this existed. Two mattered:
#
#   grim   /home/jbettcher/omarchy-work/sysroot/usr/share/fish/vendor_completions.d/grim.fish
#   rtkit  /var/tmp/omarchy-bq/sysroot/usr/share/dbus-1/system-services/...
#
# grim was the expensive one. Installing it creates /home/<user> as root, so the
# installer's later `useradd -m` finds an existing home and silently declines to
# copy /etc/skel -- the account ends up with no shell config, no Hyprland config
# and no branding, and nothing anywhere reports an error. That cost most of an
# evening to trace back from "the desktop looks wrong".
#
# rtkit's D-Bus service and polkit policy landed under /var/tmp, so RealtimeKit
# never registers and audio threads never get realtime priority. Silent too.
#
# Takes either a $pkgdir (as bq invokes it, before the archive exists) or a
# built .pkg.tar.zst (handy for auditing the repo after the fact).
#
# Usage: pkg-pathguard.sh <pkgdir|pkg.tar.zst> [...]
#        exit 0 = clean, 1 = at least one package ships a stray path
set -uo pipefail

# Everything a package may legitimately own. Deliberately conservative: adding a
# root here should be a decision, not a reflex to make a build pass.
# The bare entries are compatibility symlinks the `filesystem` package exists to
# create: bin/lib/lib64/sbin for merged-/usr, and var/{lock,mail,run} pointing
# into /run and /var/spool. They are files by tar's reckoning, not directories,
# so the trailing-slash filter does not exclude them.
ALLOWED='^(usr|etc|opt|srv|boot)/|^var/(lib|cache|log|empty|games|db)/|^(bin|lib|lib64|sbin)$|^var/(lock|mail|run)$'

rc=0
for pkg in "$@"; do
  if [[ -d $pkg ]]; then
    # A pkgdir: everything that is not a directory, relative to its root.
    stray=$(cd "$pkg" && find . -mindepth 1 -not -type d -printf '%P\n' 2>/dev/null |
            grep -vE '^\.' |
            grep -vE "$ALLOWED" || true)
  elif [[ -f $pkg ]]; then
    # A built archive. .PKGINFO/.BUILDINFO/.MTREE are metadata, not installed
    # files. Directories carry a trailing slash; a stray one only matters
    # because of the file inside it, and that file is listed too.
    stray=$(bsdtar -tf "$pkg" 2>/dev/null |
            grep -vE '^\.' |
            grep -vE '/$' |
            grep -vE "$ALLOWED" || true)
  else
    echo "pkg-pathguard: no such file or directory: $pkg" >&2; rc=1; continue
  fi

  if [[ -n $stray ]]; then
    echo "pkg-pathguard: $(basename "$pkg") installs outside the standard roots:" >&2
    printf '    %s\n' $stray >&2
    rc=1
  fi
done
exit $rc
