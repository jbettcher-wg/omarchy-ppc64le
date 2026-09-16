#!/usr/bin/env bash
# Build the Omarchy ppc64le live/install ISO.
#
#   ./iso/build.sh [-o OUTDIR] [-w WORKDIR] [--repo-server URL]... [--bundle-repo]
#
# Two things this does that a plain mkarchiso run does not:
#
#   1. It uses kth5/archiso, NOT /usr/bin/mkarchiso. Arch POWER packages
#      *upstream* archiso (URL gitlab.archlinux.org/archlinux/archiso, packager
#      Alwxander Baldeck), which ships only x86 bootmodes -- bios.syslinux and
#      uefi-*. There is no openpower.grub in it, so it cannot produce a bootable
#      ppc64le image no matter what profiledef.sh says. The fork is not packaged
#      anywhere; it has to be a checkout.
#
#   2. It bakes the repo name and servers into the installer. By default the
#      pool is the BASELINE, https://omappc64le.download/omarchy-ppc64le: it is
#      built POWER8-legal (ISA 2.07) so it runs on POWER8 through POWER11, i.e.
#      every ppc64le machine, which is the only honest default for an image
#      anyone might boot. --power9 selects the POWER9-optimised pool instead
#      (--repo-name/--pool name the two halves by hand). The image carries what
#      the live system needs and the install downloads the rest, as it already
#      has to for Arch POWER [base]. --bundle-repo also injects the pool
#      directory onto the medium at p9repo/<repo name>/, read ahead of the
#      network servers -- for testing packages that are not published yet.
#
#      archiso has no mechanism for putting arbitrary files in the ISO
#      filesystem (airootfs goes *inside* the squashfs, which is the wrong side
#      of the mount), so it is added afterwards with xorriso. That is safe here
#      because openpower.grub writes only grub.cfg and the kernels into isofs --
#      petitboot reads them as files and there is no El Torito record to damage.
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT=$(cd "$HERE/.." && pwd)
# Resolve relative to the project, not $HOME: under sudo $HOME is /root and
# the checkout is not there. Falls back to the invoking user's home when the
# checkout lives somewhere else entirely.
_home="${SUDO_USER:+$(getent passwd "$SUDO_USER" | cut -d: -f6)}"
_home="${_home:-$HOME}"
ARCHISO="${ARCHISO_FORK:-}"
if [[ -z $ARCHISO ]]; then
  for _c in "$PROJECT/../archiso-power" "$_home/Development/archiso-power"; do
    [[ -x $_c/archiso/mkarchiso ]] && { ARCHISO=$(cd "$_c" && pwd); break; }
  done
fi
ARCHISO="${ARCHISO:-$_home/Development/archiso-power}"
PROFILE="$HERE/profile"
OUTDIR="$HERE/out"
WORKDIR="${TMPDIR:-/var/tmp}/omarchy-iso-work"
# Network install by default. A bundled repo makes the image the size of repo/
# (12G by 2026-09), and archiso boots copytoram, so all of it is read off the
# medium into RAM and thrown away when the medium is unmounted -- the install
# pays for it twice and keeps none of it. --no-repo is still accepted; it is
# the default now.
# Which package pool this ISO installs from.
#
# The baseline is the default and that is deliberate: a build is named for what
# it RUNS ON, not for what it was tuned for. omarchy-ppc64le is compiled
# POWER8-legal (ISA 2.07), so it runs on every ppc64le machine from POWER8 to
# POWER11 -- an ISO handed to a tester must install from it. omarchy-power9 is
# the optimised pool for machines known to be POWER9, selected with --power9.
REPO_NAME="omarchy-ppc64le"
REPO_POOL=""                    # derived from REPO_NAME below unless --pool says
REPO_BASE_URL="${REPO_BASE_URL:-https://omappc64le.download}"
BUNDLE_REPO=0
PRINT_CONFIG=0
REPO_SERVERS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) OUTDIR="$2"; shift 2 ;;
    -w) WORKDIR="$2"; shift 2 ;;
    --bundle-repo) BUNDLE_REPO=1; shift ;;
    --no-repo) BUNDLE_REPO=0; shift ;;
    --repo-server) REPO_SERVERS+=("$2"); shift 2 ;;
    --repo-name) REPO_NAME="$2"; shift 2 ;;
    --pool) REPO_POOL="$2"; shift 2 ;;
    --power9) REPO_NAME="omarchy-power9"; shift ;;
    --print-config) PRINT_CONFIG=1; shift ;;
    *)  echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

# The pool directory follows the repo name unless one was given: the
# POWER9-optimised pool is the original repo/, everything else is repo-<suffix>
# (omarchy-ppc64le -> repo-ppc64le), which is how the pools sit on disk.
if [[ -z $REPO_POOL ]]; then
  case "$REPO_NAME" in
    omarchy-power9) REPO_POOL="$PROJECT/repo" ;;
    *)              REPO_POOL="$PROJECT/repo-${REPO_NAME#omarchy-}" ;;
  esac
fi
REPO_DB="$REPO_POOL/$REPO_NAME.db"
MEDIUM_DIR="p9repo/$REPO_NAME"
DEFAULT_REPO_SERVER="$REPO_BASE_URL/$REPO_NAME"

# What p9-install will use when the operator names no --repo-server. A bundled
# repo goes first so the install reads it at local speed; the network servers
# follow, and are all there is without --bundle-repo. With no --repo-server
# they are the public repo, bundled or not, so an installed system always
# keeps a server it can reach after reboot.
((${#REPO_SERVERS[@]})) || REPO_SERVERS=("$DEFAULT_REPO_SERVER")
_servers=()
((BUNDLE_REPO)) && _servers+=("file:///run/archiso/bootmnt/$MEDIUM_DIR")
_servers+=("${REPO_SERVERS[@]}")

# Everything above is pure option handling, so it can be shown without root and
# without mkarchiso. --print-config exists to make the pool selection checkable
# on its own: which repo, which directory, which database, which servers.
if ((PRINT_CONFIG)); then
  printf 'repo name     : %s\n' "$REPO_NAME"
  printf 'pool directory: %s\n' "$REPO_POOL"
  printf 'repo database : %s%s\n' "$REPO_DB" \
    "$([[ -f $REPO_DB ]] && echo '  (present)' || echo '  (MISSING -- run repo-add first)')"
  printf 'default server: %s\n' "$DEFAULT_REPO_SERVER"
  printf 'medium path   : %s  (--bundle-repo: %s)\n' "$MEDIUM_DIR" \
    "$((BUNDLE_REPO))"
  printf 'servers baked in:\n'
  printf '      %s\n' "${_servers[@]}"
  exit 0
fi

MKARCHISO="$ARCHISO/archiso/mkarchiso"
[[ -x $MKARCHISO ]] || { echo "no mkarchiso at $MKARCHISO -- clone https://github.com/kth5/archiso" >&2; exit 1; }
grep -q openpower "$MKARCHISO" || { echo "$MKARCHISO has no openpower bootmode; wrong archiso" >&2; exit 1; }
[[ -f $REPO_DB ]] || { echo "no repo db at $REPO_DB -- run repo-add first" >&2; exit 1; }

mkdir -p "$OUTDIR"
# mkarchiso builds the airootfs as root, so everything it leaves behind is
# root-owned -- an unprivileged rm here fails on every file from the previous
# run. Ask for the sudo ticket now rather than halfway through the build.
sudo rm -rf "$WORKDIR"

# Render the profile into the work dir: pacman.conf carries @P9_REPO_DIR@ and
# @P9_REPO_NAME@ rather than an absolute path and a fixed pool name, because
# the same tree is read from the build host and over an sshfs mount where the
# prefix differs, and because either pool can be built from.
rendered="$WORKDIR/profile"
mkdir -p "$WORKDIR"
cp -a "$PROFILE" "$rendered"
sed -i -e "s|@P9_REPO_DIR@|$REPO_POOL|" -e "s|@P9_REPO_NAME@|$REPO_NAME|" \
  "$rendered/pacman.conf"

# Sync the installer in from installer/ rather than keeping a second copy under
# iso/profile/airootfs. The first real ISO shipped a p9-install from before the
# repo was renamed to omarchy-power9, so it synced [power9] and looked for
# power9.db -- because the checked-in copy was stale and nothing said so. One
# source of truth removes the class.
inst="$rendered/airootfs/usr/local/share/omarchy-p9"
rm -rf "$inst"; mkdir -p "$inst" "$rendered/airootfs/usr/local/bin"
cp -a "$PROJECT"/installer/{p9-install,lib,bin,share,firstboot} "$inst/"
ln -sf ../share/omarchy-p9/p9-install "$rendered/airootfs/usr/local/bin/p9-install"
cp -a "$PROJECT/installer/configurator/p9-configurator" "$rendered/airootfs/root/p9-configurator"
# Omarchy's install dashboard: p9-configurator runs p9-install under it, so the
# install shows upstream's centered progress screen and Reboot Now prompt
# instead of raw pacstrap output.
cp -a "$PROJECT/installer/configurator/omarchy-install-dashboard" "$rendered/airootfs/usr/local/bin/omarchy-install-dashboard"
chmod 755 "$rendered/airootfs/root/p9-configurator" "$inst/p9-install" \
  "$rendered/airootfs/usr/local/bin/omarchy-install-dashboard"
# Into share/, not $inst: p9-install reads $P9_SHARE/repo-servers.conf and
# P9_SHARE is $P9_ROOT/share. Written one level up it is simply never found,
# and the installer silently falls back to its built-in default.
printf '%s\n' "${_servers[@]}" | grep . > "$inst/share/repo-servers.conf"
# The pool NAME travels with the server list. Without it an ISO built --power9
# would hand p9-install a set of omarchy-power9 servers under the installer's
# own default repo name, and pacman would look for omarchy-ppc64le.db on a
# server that only has the other one.
printf '%s\n' "$REPO_NAME" > "$inst/share/repo-name.conf"

# The live system's /etc/pacman.conf comes from the pacman package, so without
# this the live environment knows nothing about [$REPO_NAME] -- pacman -Sy
# in a second tty cannot install so much as a missing tool. Reuse the profile's
# conf, which already has the repo ahead of [base], but swap the build host's
# file:// path for the servers the ISO is actually built with: @P9_REPO_DIR@
# is a directory on the machine that ran this script and means nothing here.
_live="$rendered/airootfs/etc/pacman.conf"
mkdir -p "$(dirname "$_live")"
awk -v servers="$(printf '%s\n' "${_servers[@]}" | grep . | sed 's/^/Server = /')" '
  /^Server = file:\/\/@P9_REPO_DIR@/ { print servers; next }
  { print }
' "$PROFILE/pacman.conf" > "$_live"
# Non-comment lines only: the profile explains the placeholder in a comment,
# and that comment is still true for the build-side conf.
if grep -vE '^\s*#' "$_live" | grep -q "@P9_REPO_DIR@"; then
  echo "build.sh: live pacman.conf still has an unsubstituted @P9_REPO_DIR@" >&2; exit 1
fi
echo "==> installer synced from $PROJECT/installer"
echo "==> repo servers baked in:"; sed 's/^/      /' "$inst/share/repo-servers.conf"

# Assert the file landed where the installer will actually look for it.
#
# This is not paranoia. The first --no-repo ISO wrote repo-servers.conf to
# $inst/ while p9-install reads $P9_SHARE/repo-servers.conf, and $P9_SHARE is
# $P9_ROOT/share -- one directory apart. Nothing failed: the installer silently
# fell back to its built-in file:///run/archiso/bootmnt/... default, which does
# not exist on an image built --no-repo, and pacstrap ran against a repo
# pointing at nothing. The image had already shipped before anyone noticed.
#
# So check both halves, and derive the consumer's path from p9-install itself
# rather than restating it here -- a guard that hardcodes the same assumption as
# the code it guards is worth nothing.
_want=$(grep -oE '\$P9_SHARE/[A-Za-z0-9._-]+' "$inst/p9-install" | grep repo-servers | head -1)
[[ -n $_want ]] || { echo "build.sh: p9-install no longer reads a repo-servers file; update this guard" >&2; exit 1; }
_want=${_want/\$P9_SHARE/$inst/share}
if [[ ! -r $_want ]]; then
  echo "build.sh: wrote the repo server list, but p9-install reads $_want and it is not there" >&2
  exit 1
fi
echo "==> verified p9-install will read ${_want#"$inst/"}"
# Same guard for the repo name: derive the consumer's path from p9-install
# rather than restating it, so a rename there fails here instead of silently
# installing from the wrong pool name.
_wantn=$(grep -oE '\$P9_SHARE/[A-Za-z0-9._-]+' "$inst/p9-install" | grep repo-name | head -1)
[[ -n $_wantn ]] || { echo "build.sh: p9-install no longer reads a repo-name file; update this guard" >&2; exit 1; }
_wantn=${_wantn/\$P9_SHARE/$inst/share}
[[ -r $_wantn ]] || { echo "build.sh: wrote the repo name, but p9-install reads $_wantn and it is not there" >&2; exit 1; }
echo "==> verified p9-install will read ${_wantn#"$inst/"} ($REPO_NAME)"
if grep -q "@P9_REPO_DIR@" "$rendered/pacman.conf"; then
  echo "build.sh: @P9_REPO_DIR@ substitution failed" >&2; exit 1
fi
echo "==> repo for the build: [$REPO_NAME] from $REPO_POOL"

# mkarchiso copies airootfs with --no-preserve=mode and then restores only the
# modes profiledef.sh lists in file_permissions, so any other script reaches the
# image as 0644. omarchy-install-dashboard shipped that way: the configurator's
# -x check failed, and the install ran with no progress screen and no Reboot Now
# prompt while looking otherwise fine. Refuse to build rather than find out on
# the next install. customize_airootfs.sh is skipped: archiso no longer runs it.
_unlisted=$(cd "$rendered/airootfs" &&
  find . -type f -perm -u+x ! -path ./root/customize_airootfs.sh | sed 's#^\.##' | sort |
  while read -r f; do grep -qF "[\"$f\"]" "$PROFILE/profiledef.sh" || echo "$f"; done)
if [[ -n $_unlisted ]]; then
  echo "build.sh: executables with no file_permissions entry in profiledef.sh;" >&2
  echo "mkarchiso would ship them 0644:" >&2
  printf '  %s\n' $_unlisted >&2
  exit 1
fi
echo "==> every airootfs executable has a file_permissions entry"

echo "==> mkarchiso ($MKARCHISO)"
sudo "$MKARCHISO" -v -w "$WORKDIR" -o "$OUTDIR" "$rendered"

iso=$(find "$OUTDIR" -maxdepth 1 -name 'omarchy-p9-*.iso' -newer "$PROFILE/profiledef.sh" | sort | tail -1)
[[ -n $iso ]] || { echo "mkarchiso produced no ISO in $OUTDIR" >&2; exit 1; }
echo "==> built $iso"

if ((!BUNDLE_REPO)); then
  echo "==> network install: not injecting $REPO_POOL (--bundle-repo embeds it)"
  echo "==> done: $iso"
  ls -la "$iso"
  exit 0
fi

echo "==> injecting repo at $MEDIUM_DIR/ ($(du -sh "$REPO_POOL" | cut -f1))"
# Map the pool straight into the image rather than staging a copy: the repo is
# several GiB, and after mkarchiso has run $WORKDIR is root-owned anyway, so a
# staging directory there would need sudo to create and double the I/O for
# nothing. xorriso reads the source tree directly.
out="${iso%.iso}-repo.iso"
xorriso -indev "$iso" -outdev "$out" \
        -boot_image any replay \
        -map "$REPO_POOL" "/$MEDIUM_DIR" \
        -commit -eject all

mv -f "$out" "$iso"
echo "==> done: $iso"
ls -la "$iso"
