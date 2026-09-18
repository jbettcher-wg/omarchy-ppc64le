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
#      has to for Arch POWER [base]. --bundle-repo also puts the pool's share
#      of the install onto the medium at omp-repo/<repo name>/, read ahead of
#      the network servers -- for testing packages that are not published yet.
#      Only what omp-install will pacstrap from the pool goes on (the manifest,
#      the kernel, grub, and their dependencies), with its own database; the
#      rest of the pool stays on the network servers.
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
# Network install by default. A bundled repo is read off the medium into RAM
# (archiso boots copytoram) and thrown away when the medium is unmounted, so it
# carries only the install closure, never the whole pool. --no-repo is still accepted; it is
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
KERNEL_PKG=""                   # derived from REPO_NAME below unless --kernel says

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
    --kernel) KERNEL_PKG="$2"; shift 2 ;;
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
MEDIUM_DIR="omp-repo/$REPO_NAME"
DEFAULT_REPO_SERVER="$REPO_BASE_URL/$REPO_NAME"

# The kernel follows the pool the same way the directory does, and for the same
# reason: the live medium has to BOOT on the machine it is handed to before the
# installer ever runs. linux-power9 is built -mcpu=power9, so a baseline ISO
# carrying it takes an illegal instruction on a POWER8 long before there is a
# console to say so -- and the baseline pool does not even contain it. The
# baseline ships linux-omarchy, the same patch set configured POWER8. The name is
# also baked into share/kernel-pkg.conf below, so omp-install installs the kernel
# the medium booted rather than restating a default of its own.
if [[ -z $KERNEL_PKG ]]; then
  case "$REPO_NAME" in
    omarchy-power9) KERNEL_PKG="linux-power9" ;;
    *)              KERNEL_PKG="linux-omarchy" ;;
  esac
fi
# The ISO filename follows the pool too: omarchy-<date>-ppc64le.iso for the
# baseline, omarchy-power9-<date>-ppc64le.iso for --power9.
case "$REPO_NAME" in
  omarchy-power9) BOOT_LABEL="Omarchy POWER9";  ISO_NAME="omarchy-power9" ;;
  *)              BOOT_LABEL="Omarchy ppc64le"; ISO_NAME="omarchy" ;;
esac

# Is $KERNEL_PKG in the pool's database? Matched on the db entry name
# (<pkgname>-<pkgver>-<pkgrel>/), not a file glob: linux-omarchy-[0-9]* would
# also match linux-omarchy-64k-..., and a 64K kernel standing in for the 4K one
# is exactly the silent substitution this check exists to prevent.
kernel_in_pool() {
  [[ -f $REPO_DB ]] || return 1
  bsdtar -tf "$REPO_DB" 2>/dev/null | grep -qE "^${KERNEL_PKG//./\\.}-[^-/]+-[^-/]+/\$"
}

# What omp-install will use when the operator names no --repo-server. A bundled
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
  printf 'kernel        : %s%s\n' "$KERNEL_PKG" \
    "$(kernel_in_pool && echo '  (in pool)' || echo '  (NOT IN POOL -- build it or pass --kernel)')"
  printf 'boot label    : %s\n' "$BOOT_LABEL"
  printf 'iso name      : %s-<date>-ppc64le.iso\n' "$ISO_NAME"
  printf 'package cache : %s\n' "${ISO_CACHE:-/var/cache/omarchy-iso/pkg}"
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
kernel_in_pool || { echo "kernel $KERNEL_PKG is not in [$REPO_NAME] ($REPO_DB) -- build it into the pool or pass --kernel" >&2; exit 1; }

# --bundle-repo carries the install closure, not the pool. The whole pool made
# an 8.9G image of which the install used a few hundred packages, and archiso
# boots copytoram, so every byte was read into RAM for nothing. Resolve exactly
# what omp-install resolves -- the manifest plus the kernel, plus grub for
# pSeries -- against the pool and Arch POWER [base], and keep the files that
# come from the pool. Done before mkarchiso so a manifest the pool cannot
# satisfy fails in seconds instead of after the image is built.
BUNDLE_DIR="${TMPDIR:-/var/tmp}/omarchy-iso-bundle/$REPO_NAME"
if ((BUNDLE_REPO)); then
  _res=$(mktemp -d)
  mkdir -p "$_res/db/sync"
  cp "$REPO_DB" "$_res/db/sync/$REPO_NAME.db"
  for _r in base-any:any base:powerpc64le; do
    curl -sfL -o "$_res/db/sync/${_r%%:*}.db" \
      "https://repo.archlinuxpower.org/base/${_r#*:}/${_r%%:*}.db" ||
      { echo "could not fetch the Arch POWER ${_r%%:*} database to resolve the bundle" >&2; exit 1; }
  done
  printf '[options]\nArchitecture = powerpc64le\nSigLevel = Never\n[%s]\nServer = file:///nonexistent\n[base-any]\nServer = file:///nonexistent\n[base]\nServer = file:///nonexistent\n' \
    "$REPO_NAME" > "$_res/pacman.conf"
  mapfile -t _want < <(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$PROJECT/installer/share/omp-base.packages" | awk 'NF')
  _want+=("$KERNEL_PKG" grub)
  # omp-install adds the 64K-page twin of our kernels; bundle it too.
  case "$KERNEL_PKG" in linux-omarchy | linux-power9) _want+=("$KERNEL_PKG-64k") ;; esac
  if ! _closure=$(pacman --config "$_res/pacman.conf" --dbpath "$_res/db" --arch powerpc64le \
        -Sp --print-format '%r %f' "${_want[@]}" 2>"$_res/err"); then
    echo "the install manifest does not resolve against [$REPO_NAME] + [base]:" >&2
    sed 's/^/  /' "$_res/err" >&2
    # "could not satisfy dependencies" names nothing; say which entries break.
    for _n in "${_want[@]}"; do
      pacman --config "$_res/pacman.conf" --dbpath "$_res/db" --arch powerpc64le \
        -Sp --print-format '%n' "$_n" >/dev/null 2>&1 || echo "  unresolvable: $_n" >&2
    done
    rm -rf "$_res"; exit 1
  fi
  rm -rf "$_res"
  rm -rf "$BUNDLE_DIR"; mkdir -p "$BUNDLE_DIR"
  _files=()
  while read -r _repo _file; do
    [[ $_repo == "$REPO_NAME" ]] || continue
    [[ -f $REPO_POOL/$_file ]] || { echo "[$REPO_NAME] db lists $_file but $REPO_POOL has no such file" >&2; exit 1; }
    cp --reflink=auto "$REPO_POOL/$_file" "$BUNDLE_DIR/"
    [[ -f $REPO_POOL/$_file.sig ]] && cp --reflink=auto "$REPO_POOL/$_file.sig" "$BUNDLE_DIR/"
    _files+=("$BUNDLE_DIR/$_file")
  done <<<"$_closure"
  LC_ALL=C.UTF-8 repo-add -q "$BUNDLE_DIR/$REPO_NAME.db.tar.gz" "${_files[@]}"
  echo "==> bundle: ${#_files[@]} of $(wc -l <<<"$_closure") install packages come from [$REPO_NAME] ($(du -sh "$BUNDLE_DIR" | cut -f1))"
fi

mkdir -p "$OUTDIR"
# mkarchiso builds the airootfs as root, so everything it leaves behind is
# root-owned -- an unprivileged rm here fails on every file from the previous
# run. Ask for the sudo ticket now rather than halfway through the build.
sudo rm -rf "$WORKDIR"

# Render the profile into the work dir: pacman.conf carries @OMP_REPO_DIR@ and
# @OMP_REPO_NAME@ rather than an absolute path and a fixed pool name, because
# the same tree is read from the build host and over an sshfs mount where the
# prefix differs, and because either pool can be built from.
rendered="$WORKDIR/profile"
mkdir -p "$WORKDIR"
cp -a "$PROFILE" "$rendered"
sed -i -e "s|@OMP_REPO_DIR@|$REPO_POOL|" -e "s|@OMP_REPO_NAME@|$REPO_NAME|" \
  "$rendered/pacman.conf"

# Give the image build its own package cache. mkarchiso pacstraps with this
# pacman.conf, and with no CacheDir it uses the HOST's /var/cache/pacman/pkg --
# where a package of the same version but different content (a same-version
# rebuild of ours, or the POWER9 pool's build of a package the baseline also
# has) fails the checksum and aborts the whole build:
#
#   File /var/cache/pacman/pkg/coreutils-9.11-2-powerpc64le.pkg.tar.zst is
#   corrupted (invalid or corrupted package (checksum)).
#
# It bit three separate builds. A cache of its own also means an ISO build
# never adds to, or invalidates, what the host has installed. Not under
# $WORKDIR: that is wiped every run, and re-downloading [base] each time is
# minutes of network for nothing.
ISO_CACHE="${ISO_CACHE:-/var/cache/omarchy-iso/pkg}"
mkdir -p "$ISO_CACHE"
sed -i -e "s|^#CacheDir .*|CacheDir    = $ISO_CACHE/|" "$rendered/pacman.conf"
grep -q "^CacheDir" "$rendered/pacman.conf" ||
  { echo "build.sh: could not set CacheDir in the rendered pacman.conf" >&2; exit 1; }

# The live kernel is rendered the same way: packages.ppc64le, grub.cfg and the
# mkinitcpio preset all carry @OMP_KERNEL_PKG@, and the preset's own filename has
# to match the pkgbase or mkinitcpio builds no initramfs for the medium.
_preset_dir="$rendered/airootfs/etc/mkinitcpio.d"
mv "$_preset_dir/@OMP_KERNEL_PKG@.preset" "$_preset_dir/$KERNEL_PKG.preset"
sed -i -e "s|@OMP_KERNEL_PKG@|$KERNEL_PKG|g" -e "s|@OMP_BOOT_LABEL@|$BOOT_LABEL|g" \
  -e "s|@OMP_ISO_NAME@|$ISO_NAME|g" \
  "$rendered/packages.ppc64le" "$rendered/grub/grub.cfg" "$_preset_dir/$KERNEL_PKG.preset" \
  "$rendered/profiledef.sh"
if _left=$(grep -rlE "@OMP_(KERNEL_PKG|BOOT_LABEL|ISO_NAME)@" "$rendered" 2>/dev/null) && [[ -n $_left ]]; then
  echo "build.sh: unrendered kernel placeholder in:" >&2; printf '  %s\n' $_left >&2; exit 1
fi

# Sync the installer in from installer/ rather than keeping a second copy under
# iso/profile/airootfs. The first real ISO shipped an installer from before the
# repo was renamed to omarchy-power9, so it synced [power9] and looked for
# power9.db -- because the checked-in copy was stale and nothing said so. One
# source of truth removes the class.
inst="$rendered/airootfs/usr/local/share/omp"
rm -rf "$inst"; mkdir -p "$inst" "$rendered/airootfs/usr/local/bin"
cp -a "$PROJECT"/installer/{omp-install,lib,bin,share,firstboot} "$inst/"
ln -sf ../share/omp/omp-install "$rendered/airootfs/usr/local/bin/omp-install"
cp -a "$PROJECT/installer/configurator/omp-configurator" "$rendered/airootfs/root/omp-configurator"
# Omarchy's install dashboard: omp-configurator runs omp-install under it, so the
# install shows upstream's centered progress screen and Reboot Now prompt
# instead of raw pacstrap output.
cp -a "$PROJECT/installer/configurator/omarchy-install-dashboard" "$rendered/airootfs/usr/local/bin/omarchy-install-dashboard"
chmod 755 "$rendered/airootfs/root/omp-configurator" "$inst/omp-install" \
  "$rendered/airootfs/usr/local/bin/omarchy-install-dashboard"
# Into share/, not $inst: omp-install reads $OMP_SHARE/repo-servers.conf and
# OMP_SHARE is $OMP_ROOT/share. Written one level up it is simply never found,
# and the installer silently falls back to its built-in default.
printf '%s\n' "${_servers[@]}" | grep . > "$inst/share/repo-servers.conf"
# The pool NAME travels with the server list. Without it an ISO built --power9
# would hand omp-install a set of omarchy-power9 servers under the installer's
# own default repo name, and pacman would look for omarchy-ppc64le.db on a
# server that only has the other one.
printf '%s\n' "$REPO_NAME" > "$inst/share/repo-name.conf"
# And the kernel with it: the installed system should run the kernel the medium
# booted. omp-install derives the same default from the repo name, but a
# `--kernel` given here (say linux-omarchy-64k) has to reach the install too.
printf '%s\n' "$KERNEL_PKG" > "$inst/share/kernel-pkg.conf"

# The live system's /etc/pacman.conf comes from the pacman package, so without
# this the live environment knows nothing about [$REPO_NAME] -- pacman -Sy
# in a second tty cannot install so much as a missing tool. Reuse the profile's
# conf, which already has the repo ahead of [base], but swap the build host's
# file:// path for the servers the ISO is actually built with: @OMP_REPO_DIR@
# is a directory on the machine that ran this script and means nothing here.
_live="$rendered/airootfs/etc/pacman.conf"
mkdir -p "$(dirname "$_live")"
awk -v servers="$(printf '%s\n' "${_servers[@]}" | grep . | sed 's/^/Server = /')" '
  /^Server = file:\/\/@OMP_REPO_DIR@/ { print servers; next }
  { print }
' "$PROFILE/pacman.conf" > "$_live"
# Non-comment lines only: the profile explains the placeholder in a comment,
# and that comment is still true for the build-side conf.
if grep -vE '^\s*#' "$_live" | grep -q "@OMP_REPO_DIR@"; then
  echo "build.sh: live pacman.conf still has an unsubstituted @OMP_REPO_DIR@" >&2; exit 1
fi
echo "==> installer synced from $PROJECT/installer"
echo "==> repo servers baked in:"; sed 's/^/      /' "$inst/share/repo-servers.conf"

# Assert the file landed where the installer will actually look for it.
#
# This is not paranoia. The first --no-repo ISO wrote repo-servers.conf to
# $inst/ while omp-install reads $OMP_SHARE/repo-servers.conf, and $OMP_SHARE is
# $OMP_ROOT/share -- one directory apart. Nothing failed: the installer silently
# fell back to its built-in file:///run/archiso/bootmnt/... default, which does
# not exist on an image built --no-repo, and pacstrap ran against a repo
# pointing at nothing. The image had already shipped before anyone noticed.
#
# So check both halves, and derive the consumer's path from omp-install itself
# rather than restating it here -- a guard that hardcodes the same assumption as
# the code it guards is worth nothing.
_want=$(grep -oE '\$OMP_SHARE/[A-Za-z0-9._-]+' "$inst/omp-install" | grep repo-servers | head -1)
[[ -n $_want ]] || { echo "build.sh: omp-install no longer reads a repo-servers file; update this guard" >&2; exit 1; }
_want=${_want/\$OMP_SHARE/$inst/share}
if [[ ! -r $_want ]]; then
  echo "build.sh: wrote the repo server list, but omp-install reads $_want and it is not there" >&2
  exit 1
fi
echo "==> verified omp-install will read ${_want#"$inst/"}"
# Same guard for the repo name: derive the consumer's path from omp-install
# rather than restating it, so a rename there fails here instead of silently
# installing from the wrong pool name.
_wantn=$(grep -oE '\$OMP_SHARE/[A-Za-z0-9._-]+' "$inst/omp-install" | grep repo-name | head -1)
[[ -n $_wantn ]] || { echo "build.sh: omp-install no longer reads a repo-name file; update this guard" >&2; exit 1; }
_wantn=${_wantn/\$OMP_SHARE/$inst/share}
[[ -r $_wantn ]] || { echo "build.sh: wrote the repo name, but omp-install reads $_wantn and it is not there" >&2; exit 1; }
echo "==> verified omp-install will read ${_wantn#"$inst/"} ($REPO_NAME)"
_wantk=$(grep -oE '\$OMP_SHARE/[A-Za-z0-9._-]+' "$inst/omp-install" | grep kernel-pkg | head -1)
[[ -n $_wantk ]] || { echo "build.sh: omp-install no longer reads a kernel-pkg file; update this guard" >&2; exit 1; }
_wantk=${_wantk/\$OMP_SHARE/$inst/share}
[[ -r $_wantk ]] || { echo "build.sh: wrote the kernel name, but omp-install reads $_wantk and it is not there" >&2; exit 1; }
echo "==> verified omp-install will read ${_wantk#"$inst/"} ($KERNEL_PKG)"
if grep -q "@OMP_REPO_DIR@" "$rendered/pacman.conf"; then
  echo "build.sh: @OMP_REPO_DIR@ substitution failed" >&2; exit 1
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

iso=$(find "$OUTDIR" -maxdepth 1 -name "$ISO_NAME-[0-9]*-ppc64le.iso" -newer "$PROFILE/profiledef.sh" | sort | tail -1)
[[ -n $iso ]] || { echo "mkarchiso produced no ISO in $OUTDIR" >&2; exit 1; }
echo "==> built $iso"

if ((!BUNDLE_REPO)); then
  echo "==> network install: not injecting $REPO_POOL (--bundle-repo embeds it)"
  echo "==> done: $iso"
  ls -la "$iso"
  exit 0
fi

echo "==> injecting the install closure at $MEDIUM_DIR/ ($(du -sh "$BUNDLE_DIR" | cut -f1))"
# The closure was staged in $BUNDLE_DIR before mkarchiso (outside $WORKDIR,
# which mkarchiso leaves root-owned); xorriso maps it straight into the image.
out="${iso%.iso}-repo.iso"
xorriso -indev "$iso" -outdev "$out" \
        -boot_image any replay \
        -map "$BUNDLE_DIR" "/$MEDIUM_DIR" \
        -commit -eject all

mv -f "$out" "$iso"
echo "==> done: $iso"
ls -la "$iso"
