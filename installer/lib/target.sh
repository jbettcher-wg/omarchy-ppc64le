# target.sh -- everything that happens inside /mnt after pacstrap.
#
# All of this is Omarchy's install flow carried over: fstab, locale, timezone,
# hostname, the initramfs, the user, and handing the desktop's own provisioning
# off to first boot. Only two lines in here are ppc64le-specific -- the
# mkinitcpio drop-in that gets installed, and the absence of any bootloader
# step (that lives in bin/p9-petitboot-entry).

# --- pacman configuration for the target -------------------------------------
#
# Rendered from share/pacman.conf.in. Written BEFORE pacstrap so pacstrap
# itself uses it (-C), and left in place afterwards -- unlike upstream, which
# installs offline and then overwrites /etc/pacman.conf at the end with the
# Omarchy channel. There is nothing to switch to here: the repositories the
# install used are the repositories the machine should keep.
# render_pacman_conf <path> [force]
# force=1 writes even under --dry-run: the file goes to the throwaway work
# directory, and without it the resolve step below has no config to read, which
# would make --dry-run unable to check the one thing it is best placed to check.
render_pacman_conf() {
  local out="$1" force="${2:-0}" stanza="" note=""

  if [[ -n $P9_REPO_SERVER && $P9_REPO_SERVER != none ]]; then
    stanza=$(printf '[%s]\nSigLevel = %s\nServer = %s\n' \
      "$P9_REPO_NAME" "$P9_REPO_SIGLEVEL" "$P9_REPO_SERVER")
    note="[$P9_REPO_NAME] SigLevel is '$P9_REPO_SIGLEVEL', chosen with --repo-siglevel."
  else
    stanza=""
    note="No [$P9_REPO_NAME] stanza: --repo-server was 'none'. Arch POWER only."
  fi

  if ((P9_DRY_RUN && !force)); then
    printf '  would write %s\n' "$out" >&2
    return 0
  fi

  mkdir -p "$(dirname "$out")"
  awk -v stanza="$stanza" -v note="$note" \
    -v basesig="$P9_BASE_SIGLEVEL" -v baseany="$P9_BASE_ANY_SERVER" -v base="$P9_BASE_SERVER" '
    { gsub(/@P9_REPO_STANZA@/, stanza)
      gsub(/@P9_SIGLEVEL_NOTE@/, note)
      gsub(/@P9_BASE_SIGLEVEL@/, basesig)
      gsub(/@P9_BASE_ANY_SERVER@/, baseany)
      gsub(/@P9_BASE_SERVER@/, base)
      print }
  ' "$P9_SHARE/pacman.conf.in" >"$out"
}

# --- package resolution -------------------------------------------------------
#
# Read the manifest, drop comments, add the kernel. The resolve step below is
# the control the design asks for: today it MUST fail on the Omarchy packages
# that have not been built for ppc64le yet, and that failure list is the
# remaining work, enumerated by the tool instead of by anyone's memory.
read_manifest() {
  sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$1" | awk 'NF'
}

resolve_packages() {
  local conf="$1"
  shift
  # pacman refuses -Sy as a non-root user even against an alternate root, so on
  # the build host (RULES.md: no sudo) --dry-run can check everything except
  # this. Say so rather than failing: the live medium runs as root and gets the
  # real check.
  if ((EUID != 0)); then
    warn "not root: skipping package resolution (pacman -Sy needs root even with -r)."
    warn "the $# names in the manifest were NOT checked against the repositories."
    return 0
  fi
  local root
  root=$(mktemp -d)
  # 0755, not mktemp's 0700. pacman drops privileges to DownloadUser (alpm) for
  # the actual transfer, and alpm cannot traverse a root-only directory -- the
  # database sync then fails with "could not open file .../<repo>.db.part:
  # Permission denied" even though the repository is perfectly reachable.
  chmod 0755 "$root"
  mkdir -p "$root/var/lib/pacman" "$root/var/cache/pacman/pkg"
  if ! pacman -r "$root" --config "$conf" --arch "$P9_ARCH" -Sy >>"$P9_LOG_FILE" 2>&1; then
    rm -rf "$root"
    die "could not sync the package databases -- check the repositories in $conf"
  fi
  local out rc=0
  out=$(pacman -r "$root" --config "$conf" --arch "$P9_ARCH" \
    -Sp --print-format '%r %n %v' "$@" 2>&1) || rc=$?
  rm -rf "$root"
  if ((rc != 0)); then
    printf '%s\n' "$out" >&2
    die "package resolution failed -- every name above that pacman could not find
      is a package that still has to be built for ppc64le. Nothing was written
      to the disk."
  fi
  printf '%s\n' "$out" >"$P9_WORKDIR/resolved.txt"
  log "resolved $(wc -l <"$P9_WORKDIR/resolved.txt") packages"
}

# --- fstab --------------------------------------------------------------------
write_fstab() {
  local mnt="$1"
  step "Writing fstab"
  if ((P9_DRY_RUN)); then
    printf '  would run: genfstab -U %s >> %s/etc/fstab\n' "$mnt" "$mnt" >&2
    return 0
  fi
  genfstab -U "$mnt" >>"$mnt/etc/fstab"
  # The check that is not "exit 0": /boot must be there, by UUID, as ext4.
  grep -qE "UUID=$P9_UUID_BOOT[[:space:]]+/boot[[:space:]]+ext4" "$mnt/etc/fstab" ||
    die "fstab does not carry /boot as ext4 by UUID -- petitboot would boot a kernel nobody updates"
  log "fstab ok"
}

# --- system identity ----------------------------------------------------------
configure_system() {
  local mnt="$1"
  step "Configuring locale, timezone, hostname and console"

  if ((P9_DRY_RUN)); then
    printf '  would set locale=%s tz=%s host=%s keymap=%s\n' \
      "$P9_LOCALE" "$P9_TIMEZONE" "$P9_HOSTNAME" "$P9_KEYMAP" >&2
    return 0
  fi

  printf '%s UTF-8\n' "$P9_LOCALE" >>"$mnt/etc/locale.gen"
  printf 'LANG=%s\n' "$P9_LOCALE" >"$mnt/etc/locale.conf"
  printf 'KEYMAP=%s\n' "$P9_KEYMAP" >"$mnt/etc/vconsole.conf"
  printf '%s\n' "$P9_HOSTNAME" >"$mnt/etc/hostname"
  cat >"$mnt/etc/hosts" <<EOF
127.0.0.1	localhost
::1		localhost
127.0.1.1	$P9_HOSTNAME.localdomain	$P9_HOSTNAME
EOF
  ln -sf "/usr/share/zoneinfo/$P9_TIMEZONE" "$mnt/etc/localtime"
  arch-chroot "$mnt" locale-gen >>"$P9_LOG_FILE" 2>&1
  arch-chroot "$mnt" hwclock --systohc >>"$P9_LOG_FILE" 2>&1 || true
}

# --- initramfs ----------------------------------------------------------------
#
# Substitution 3. Install the drop-in, then build. mkinitcpio's own pacman hook
# has already run once during pacstrap against the stock (busybox) HOOKS; this
# rebuild is the one that matters, and its failure is fatal on purpose -- an
# install that continues past a failed initramfs produces a machine that
# petitboot will happily kexec into a kernel panic.
configure_initramfs() {
  local mnt="$1"
  step "Installing the mkinitcpio drop-in and building the initramfs"

  if ((P9_DRY_RUN)); then
    printf '  would install %s -> %s\n' \
      "$P9_SHARE/omarchy-p9-hooks.conf" "$mnt/etc/mkinitcpio.conf.d/omarchy-p9-hooks.conf" >&2
    printf '  would run: arch-chroot %s mkinitcpio -P\n' "$mnt" >&2
    return 0
  fi

  install -Dm644 "$P9_SHARE/omarchy-p9-hooks.conf" \
    "$mnt/etc/mkinitcpio.conf.d/omarchy-p9-hooks.conf"

  # If the target still carries Omarchy's own drop-in (it should not -- the
  # ppc64le omarchy-settings package removes it -- but a future upstream
  # version could reintroduce it), take it out. Leaving both in place means
  # the later-sorting one wins and it is a coin toss which.
  if [[ -f $mnt/etc/mkinitcpio.conf.d/omarchy_hooks.conf ]]; then
    warn "target carries Omarchy's omarchy_hooks.conf; removing it (it names btrfs-overlayfs, plymouth and microcode)"
    rm -f "$mnt/etc/mkinitcpio.conf.d/omarchy_hooks.conf"
  fi

  run_loud arch-chroot "$mnt" mkinitcpio -P ||
    die "mkinitcpio failed in the target -- see $P9_LOG_FILE. Nothing will boot until this is fixed."

  local kernel_img="$mnt/boot/vmlinuz-$P9_KERNEL_PKG"
  local initrd_img="$mnt/boot/initramfs-$P9_KERNEL_PKG.img"
  [[ -f $kernel_img ]] || die "no $kernel_img -- the kernel package did not install one"
  [[ -f $initrd_img ]] || die "no $initrd_img -- mkinitcpio produced nothing"
  log "kernel $(stat -c%s "$kernel_img") bytes, initramfs $(stat -c%s "$initrd_img") bytes"
}

# --- boot entry ---------------------------------------------------------------
configure_boot() {
  local mnt="$1"
  step "Writing the petitboot boot entry"

  if ((P9_DRY_RUN)); then
    printf '  would run p9-petitboot-entry in %s\n' "$mnt" >&2
    return 0
  fi

  install -Dm755 "$P9_LIBEXEC/p9-petitboot-entry" "$mnt/usr/local/bin/p9-petitboot-entry"

  # Keep the entries current across kernel upgrades. Named exactly as the
  # linux-power9 package's future hook so that, when that package lands, its
  # copy in /usr/share/libalpm/hooks is shadowed by this one rather than both
  # firing. Either script is idempotent, so the overlap is harmless.
  install -Dm644 /dev/stdin "$mnt/etc/pacman.d/hooks/95-petitboot-entry.hook" <<'HOOK'
[Trigger]
Type = Path
Operation = Install
Operation = Upgrade
Operation = Remove
Target = usr/lib/modules/*/pkgbase
Target = boot/vmlinuz-*
Target = boot/initramfs-*.img

[Action]
Description = Updating the petitboot boot entries in /boot/grub/grub.cfg...
When = PostTransaction
Exec = /usr/local/bin/p9-petitboot-entry
NeedsTargets
HOOK

  install -Dm644 /dev/stdin "$mnt/etc/default/petitboot-entry" <<EOF
# Extra kernel command line for the generated petitboot entries.
# p9-petitboot-entry sources this file.
P9_CMDLINE="$P9_CMDLINE"
P9_ENTRY_TITLE="$P9_ENTRY_TITLE"
EOF

  P9_ROOT_UUID="$P9_UUID_ROOT" \
    P9_BOOT_UUID="$P9_UUID_BOOT" \
    P9_ROOTFLAGS="subvol=@" \
    P9_CMDLINE="$P9_CMDLINE" \
    P9_ENTRY_TITLE="$P9_ENTRY_TITLE" \
    arch-chroot "$mnt" /usr/local/bin/p9-petitboot-entry ||
    die "could not write the petitboot boot entry"

  # The discriminator. The root UUID cannot appear in this file by accident:
  # if it is there, the entry was built from the filesystem we actually made.
  local n
  n=$(grep -c "root=UUID=$P9_UUID_ROOT" "$mnt/boot/grub/grub.cfg" || true)
  ((n > 0)) || die "grub.cfg does not name root=UUID=$P9_UUID_ROOT"
  log "grub.cfg carries $n entry/entries for root=UUID=$P9_UUID_ROOT"
  sed -n '/BEGIN petitboot-entry/,/END petitboot-entry/p' "$mnt/boot/grub/grub.cfg" |
    tee -a "$P9_LOG_FILE"

  # pSeries is the only platform that installs a bootloader, because SLOF has
  # no petitboot. Untested here; PowerNV is the target.
  if [[ $P9_PLATFORM == pseries && -n ${P9_PART_PREP:-} ]]; then
    step "pSeries: installing GRUB to the PReP partition $P9_PART_PREP"
    run_loud arch-chroot "$mnt" grub-install --target=powerpc-ieee1275 \
      --boot-directory=/boot --modules="part_gpt ext2" "$P9_PART_PREP" ||
      warn "grub-install failed; on PowerNV this does not matter, on pSeries it does"
  fi
}

# --- users --------------------------------------------------------------------
#
# Two modes, both of them Omarchy's:
#
#   deferred (default)  no user is created now. /var/lib/omarchy/provisioning/pending
#                       is armed and upstream's own omarchy-provision-owner.service
#                       asks for the account on the target's tty1 at first boot.
#                       This is upstream's "--defer-provisioning" path, unmodified,
#                       and it is the only way Omarchy's setup form ever runs on
#                       ppc64le hardware without running it on the build host.
#   --user NAME         create the account here, the ordinary archinstall shape.
configure_users() {
  local mnt="$1"

  if [[ -z $P9_USER ]]; then
    step "Deferring account creation to the target's first boot"
    if ((P9_DRY_RUN)); then
      printf '  would arm /var/lib/omarchy/provisioning/pending\n' >&2
      return 0
    fi
    install -d -m 0755 "$mnt/var/lib/omarchy/provisioning"
    : >"$mnt/var/lib/omarchy/provisioning/pending"

    local unit=$mnt/usr/share/omarchy/install/provisioning/omarchy-provision-owner.service
    if [[ -f $unit ]]; then
      install -Dm644 "$unit" "$mnt/etc/systemd/system/omarchy-provision-owner.service"
      install -d -m 0755 "$mnt/etc/systemd/system/multi-user.target.wants"
      ln -sf ../omarchy-provision-owner.service \
        "$mnt/etc/systemd/system/multi-user.target.wants/omarchy-provision-owner.service"
      log "armed omarchy-provision-owner.service for first boot"
    else
      warn "the omarchy package is not installed, so there is no first-boot account wizard."
      warn "Pass --user to create an account now, or the target will have no login."
    fi
    return 0
  fi

  step "Creating $P9_USER"
  if ((P9_DRY_RUN)); then
    printf '  would useradd -m -G wheel %s\n' "$P9_USER" >&2
    return 0
  fi
  arch-chroot "$mnt" useradd -m -G wheel -s /bin/bash "$P9_USER" >>"$P9_LOG_FILE" 2>&1
  # install -D, not a bare redirect: /etc/sudoers.d only exists once sudo is
  # installed, and a target that has not got there yet is exactly the case a
  # bare `>` fails on ("No such file or directory") after the disk is already
  # partitioned and pacstrapped.
  printf '%%wheel ALL=(ALL:ALL) ALL\n' |
    install -Dm0440 /dev/stdin "$mnt/etc/sudoers.d/00-omarchy-wheel"
  arch-chroot "$mnt" test -x /usr/bin/sudo ||
    warn "sudo is not installed in the target; the wheel grant is inert until it is"
  if [[ -n $P9_PASSWORD ]]; then
    printf '%s:%s\n' "$P9_USER" "$P9_PASSWORD" | arch-chroot "$mnt" chpasswd
    printf 'root:%s\n' "$P9_PASSWORD" | arch-chroot "$mnt" chpasswd
  else
    warn "no --password given: set one with 'passwd' before rebooting, or arm deferred provisioning"
  fi
}

# --- first boot ---------------------------------------------------------------
#
# The config layer. Upstream runs omarchy-apply-system in the target chroot at
# ISO finalization; here it runs on the target's own first boot instead --
# partly because two of its steps have no ppc64le equivalent and had to be
# replaced, and partly because several of the rest (udevadm, updatedb, ufw,
# service enablement) want a live system rather than a chroot.
stage_firstboot() {
  local mnt="$1"
  step "Staging the first-boot configuration layer"

  if ((P9_DRY_RUN)); then
    printf '  would install %s -> %s/usr/local/lib/omarchy-p9/\n' "$P9_FIRSTBOOT" "$mnt" >&2
    return 0
  fi

  install -d -m 0755 "$mnt/usr/local/lib/omarchy-p9"
  cp -a "$P9_FIRSTBOOT/config" "$mnt/usr/local/lib/omarchy-p9/"
  install -Dm755 "$P9_FIRSTBOOT/p9-firstboot" "$mnt/usr/local/bin/p9-firstboot"
  install -Dm644 "$P9_FIRSTBOOT/p9-firstboot.service" \
    "$mnt/etc/systemd/system/p9-firstboot.service"
  install -d -m 0755 "$mnt/etc/systemd/system/multi-user.target.wants"
  ln -sf ../p9-firstboot.service \
    "$mnt/etc/systemd/system/multi-user.target.wants/p9-firstboot.service"

  install -Dm644 /dev/stdin "$mnt/etc/omarchy-p9.conf" <<EOF
# Read by p9-firstboot on the target's first boot. Written by p9-install.
P9_PLATFORM="$P9_PLATFORM"
P9_KERNEL_PKG="$P9_KERNEL_PKG"
P9_REPO_NAME="$P9_REPO_NAME"
# Which of Omarchy's /etc overrides to apply once, on first boot only.
# Upstream applies these from a pacman scriptlet on every install and upgrade;
# that scriptlet is removed from the ppc64le omarchy-settings package because it
# is destructive on a machine that is not an Omarchy install, and it is NOT
# reintroduced here. A fresh target from this installer *is* an Omarchy install,
# so they are applied once, deliberately, and never again.
#
# os-release is held back by default: this spin is Arch POWER with Omarchy on
# top, and /etc/os-release is what pacman tooling, bug reports and half the
# desktop read to identify the distribution. Add it if you disagree.
P9_ETC_OVERRIDES="nsswitch.conf security-faillock.conf plymouth-plymouthd.conf dot.bashrc cups-cups-browsed.conf cups-cups-files.conf"
EOF
  log "first-boot layer staged; it runs before omarchy-provision-owner"
}
