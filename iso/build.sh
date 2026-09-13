#!/usr/bin/env bash
# Build the Omarchy ppc64le live/install ISO.
#
#   ./iso/build.sh [-o OUTDIR] [-w WORKDIR]
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
#   2. It injects repo/ onto the medium at p9repo/omarchy-power9/. That path is not
#      decorative: p9-install defaults to
#          P9_REPO_SERVER=file:///run/archiso/bootmnt/p9repo/omarchy-power9
#      i.e. the repo is read off the boot medium, no network. This mirrors what
#      upstream Omarchy's ISO does -- "the installer reads this mirror straight
#      from the ISO during installation".
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
# The bundled repo is 4.3G of a 5.2G image. archiso boots copytoram, so that
# whole 4.3G is read off the medium into RAM and then thrown away when the
# medium is unmounted -- the install pays for it twice and gets to keep none of
# it. --no-repo drops it and installs over the network instead; the image lands
# near 1G and copytoram becomes cheap.
BUNDLE_REPO=1
REPO_SERVERS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) OUTDIR="$2"; shift 2 ;;
    -w) WORKDIR="$2"; shift 2 ;;
    --no-repo) BUNDLE_REPO=0; shift ;;
    --repo-server) REPO_SERVERS+=("$2"); shift 2 ;;
    *)  echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

# What p9-install will use when the operator names no --repo-server. A bundled
# repo goes first so the install reads it at local speed; anything given with
# --repo-server follows, and is all there is under --no-repo.
_servers=()
((BUNDLE_REPO)) && _servers+=("file:///run/archiso/bootmnt/p9repo/omarchy-power9")
_servers+=("${REPO_SERVERS[@]:-}")
if ((!BUNDLE_REPO)) && ((!${#REPO_SERVERS[@]})); then
  echo "--no-repo with no --repo-server: the ISO would have nowhere to install from" >&2
  exit 2
fi

MKARCHISO="$ARCHISO/archiso/mkarchiso"
[[ -x $MKARCHISO ]] || { echo "no mkarchiso at $MKARCHISO -- clone https://github.com/kth5/archiso" >&2; exit 1; }
grep -q openpower "$MKARCHISO" || { echo "$MKARCHISO has no openpower bootmode; wrong archiso" >&2; exit 1; }
[[ -f $PROJECT/repo/omarchy-power9.db ]] || { echo "no repo db at $PROJECT/repo -- run repo-add first" >&2; exit 1; }

mkdir -p "$OUTDIR"
# mkarchiso builds the airootfs as root, so everything it leaves behind is
# root-owned -- an unprivileged rm here fails on every file from the previous
# run. Ask for the sudo ticket now rather than halfway through the build.
sudo rm -rf "$WORKDIR"

# Render the profile into the work dir: pacman.conf carries @P9_REPO_DIR@
# rather than an absolute path, because the same tree is read from the build
# host and over an sshfs mount where the prefix differs.
rendered="$WORKDIR/profile"
mkdir -p "$WORKDIR"
cp -a "$PROFILE" "$rendered"
sed -i "s|@P9_REPO_DIR@|$PROJECT/repo|" "$rendered/pacman.conf"

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
chmod 755 "$rendered/airootfs/root/p9-configurator" "$inst/p9-install"
# Into share/, not $inst: p9-install reads $P9_SHARE/repo-servers.conf and
# P9_SHARE is $P9_ROOT/share. Written one level up it is simply never found,
# and the installer silently falls back to its built-in default.
printf '%s\n' "${_servers[@]}" | grep . > "$inst/share/repo-servers.conf"

# The live system's /etc/pacman.conf comes from the pacman package, so without
# this the live environment knows nothing about [omarchy-power9] -- pacman -Sy
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
if grep -q "@P9_REPO_DIR@" "$rendered/pacman.conf"; then
  echo "build.sh: @P9_REPO_DIR@ substitution failed" >&2; exit 1
fi
echo "==> repo for the build: $PROJECT/repo"

echo "==> mkarchiso ($MKARCHISO)"
sudo "$MKARCHISO" -v -w "$WORKDIR" -o "$OUTDIR" "$rendered"

iso=$(find "$OUTDIR" -maxdepth 1 -name 'omarchy-p9-*.iso' -newer "$PROFILE/profiledef.sh" | sort | tail -1)
[[ -n $iso ]] || { echo "mkarchiso produced no ISO in $OUTDIR" >&2; exit 1; }
echo "==> built $iso"

if ((!BUNDLE_REPO)); then
  echo "==> --no-repo: not injecting $PROJECT/repo"
  echo "==> done: $iso"
  ls -la "$iso"
  exit 0
fi

echo "==> injecting repo at p9repo/omarchy-power9/ ($(du -sh "$PROJECT/repo" | cut -f1))"
# Map repo/ straight into the image rather than staging a copy: the repo is
# several GiB, and after mkarchiso has run $WORKDIR is root-owned anyway, so a
# staging directory there would need sudo to create and double the I/O for
# nothing. xorriso reads the source tree directly.
out="${iso%.iso}-repo.iso"
xorriso -indev "$iso" -outdev "$out" \
        -boot_image any replay \
        -map "$PROJECT/repo" /p9repo/omarchy-power9 \
        -commit -eject all

mv -f "$out" "$iso"
echo "==> done: $iso"
ls -la "$iso"
