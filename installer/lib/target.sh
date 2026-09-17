# target.sh -- everything that happens inside /mnt after pacstrap.
#
# All of this is Omarchy's install flow carried over: fstab, locale, timezone,
# hostname, the initramfs, the user, and handing the desktop's own provisioning
# off to first boot. Only two lines in here are ppc64le-specific -- the
# mkinitcpio drop-in that gets installed, and the absence of any bootloader
# step (that lives in bin/omp-petitboot-entry).

# --- pacman configuration for the target -------------------------------------
#
# Rendered from share/pacman.conf.in. Written BEFORE pacstrap so pacstrap
# itself uses it (-C), and left in place afterwards -- unlike upstream, which
# installs offline and then overwrites /etc/pacman.conf at the end with the
# Omarchy channel. There is nothing to switch to here: the repositories the
# install used are the repositories the machine should keep.
# render_pacman_conf <path> [force] [for_target]
# force=1 writes even under --dry-run: the file goes to the throwaway work
# directory, and without it the resolve step below has no config to read, which
# would make --dry-run unable to check the one thing it is best placed to check.
# One repository's stanza, or nothing when it has no usable server.
#
# Factored out because the installer can write two: the distribution publishes
# a baseline pool (omarchy-ppc64le, POWER8-legal, runs on every ppc64le
# machine) and an optimised one (omarchy-power9). When both are given the
# optimised pool is written FIRST -- pacman takes the first repo that has a
# name, regardless of version, so stanza order is what makes an optimised
# package win where one exists and the baseline fill in the rest.
_repo_stanza() {
  local name="$1" siglevel="$2" for_target="$3"
  local -n _srvs="$4"
  local -a servers=("${_srvs[@]}") kept=() dropped=()
  local _srv out=""

  ((${#servers[@]})) || return 0
  [[ ${servers[0]} == none ]] && return 0

  # The target keeps this file forever; the install-time copy lives for one
  # pacstrap. A file:// server on the boot medium is right for the install and
  # wrong afterwards -- /run/archiso/bootmnt does not exist once the machine
  # reboots, so pacman reports a failed database on every -Sy for the life of
  # the system. Drop those from the target's copy.
  #
  # Only when something else remains. On an ISO that bundles its repo and names
  # no network mirror, the medium URL is the only server there is: a target with
  # a [repo] stanza and no Server silently has no repo, which is worse than one
  # that fails loudly and can be pointed at a mirror by hand.
  if ((for_target)); then
    for _srv in "${servers[@]}"; do
      case "$_srv" in
        file:///run/archiso/*|file:///run/omp-medium/*) dropped+=("$_srv") ;;
        *) kept+=("$_srv") ;;
      esac
    done
    if ((${#dropped[@]})); then
      if ((${#kept[@]})); then
        servers=("${kept[@]}")
        log "target pacman.conf: [$name] dropped ${#dropped[@]} boot-medium server(s); they do not survive a reboot"
      else
        warn "the only [$name] server is on the boot medium; the target will
      carry a Server it cannot reach. Give --repo-server a network mirror, or
      edit /etc/pacman.conf after the first boot."
      fi
    fi
  fi

  # $( ) strips trailing newlines, so add them back explicitly or SigLevel
  # and the first Server end up on one line.
  out=$(printf '[%s]\nSigLevel = %s' "$name" "$siglevel")$'\n'
  for _srv in "${servers[@]}"; do
    out+=$(printf 'Server = %s\n' "$_srv")$'\n'
  done
  printf '%s' "$out"
}

render_pacman_conf() {
  local out="$1" force="${2:-0}" for_target="${3:-0}" stanza="" note="" _s=""

  _s=$(_repo_stanza "$OMP_REPO_NAME" "$OMP_REPO_SIGLEVEL" "$for_target" OMP_REPO_SERVERS)
  [[ -n $_s ]] && stanza+="$_s"$'\n'
  if [[ -n ${OMP_BASELINE_REPO_NAME:-} ]]; then
    _s=$(_repo_stanza "$OMP_BASELINE_REPO_NAME" \
         "${OMP_BASELINE_REPO_SIGLEVEL:-$OMP_REPO_SIGLEVEL}" "$for_target" \
         OMP_BASELINE_REPO_SERVERS)
    [[ -n $_s ]] && stanza+="$_s"$'\n'
  fi

  if [[ -n $stanza ]]; then
    note="[$OMP_REPO_NAME] SigLevel is '$OMP_REPO_SIGLEVEL', chosen with --repo-siglevel."
    [[ -n ${OMP_BASELINE_REPO_NAME:-} ]] &&
      note+=" [$OMP_BASELINE_REPO_NAME] is the baseline pool, listed after it so the optimised build wins where one exists and the baseline fills in the rest."
  else
    note="No [$OMP_REPO_NAME] stanza: --repo-server was 'none'. Arch POWER only."
  fi

  if ((OMP_DRY_RUN && !force)); then
    printf '  would write %s\n' "$out" >&2
    return 0
  fi

  mkdir -p "$(dirname "$out")"
  awk -v stanza="$stanza" -v note="$note" \
    -v basesig="$OMP_BASE_SIGLEVEL" -v baseany="$OMP_BASE_ANY_SERVER" -v base="$OMP_BASE_SERVER" '
    { gsub(/@OMP_REPO_STANZA@/, stanza)
      gsub(/@OMP_SIGLEVEL_NOTE@/, note)
      gsub(/@OMP_BASE_SIGLEVEL@/, basesig)
      gsub(/@OMP_BASE_ANY_SERVER@/, baseany)
      gsub(/@OMP_BASE_SERVER@/, base)
      print }
  ' "$OMP_SHARE/pacman.conf.in" >"$out"
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
  if ! pacman -r "$root" --config "$conf" --arch "$OMP_ARCH" -Sy >>"$OMP_LOG_FILE" 2>&1; then
    rm -rf "$root"
    die "could not sync the package databases -- check the repositories in $conf"
  fi
  local out rc=0
  out=$(pacman -r "$root" --config "$conf" --arch "$OMP_ARCH" \
    -Sp --print-format '%r %n %v' "$@" 2>&1) || rc=$?
  rm -rf "$root"
  if ((rc != 0)); then
    printf '%s\n' "$out" >&2
    die "package resolution failed -- every name above that pacman could not find
      is a package that still has to be built for ppc64le. Nothing was written
      to the disk."
  fi
  printf '%s\n' "$out" >"$OMP_WORKDIR/resolved.txt"
  log "resolved $(wc -l <"$OMP_WORKDIR/resolved.txt") packages"
}

# --- fstab --------------------------------------------------------------------
write_fstab() {
  local mnt="$1"
  step "Writing fstab"
  if ((OMP_DRY_RUN)); then
    printf '  would run: genfstab -U %s >> %s/etc/fstab\n' "$mnt" "$mnt" >&2
    return 0
  fi
  genfstab -U "$mnt" >>"$mnt/etc/fstab"
  # The check that is not "exit 0": /boot must be there, by UUID, as ext4.
  grep -qE "UUID=$OMP_UUID_BOOT[[:space:]]+/boot[[:space:]]+ext4" "$mnt/etc/fstab" ||
    die "fstab does not carry /boot as ext4 by UUID -- petitboot would boot a kernel nobody updates"
  log "fstab ok"
}

# --- system identity ----------------------------------------------------------
configure_system() {
  local mnt="$1"
  step "Configuring locale, timezone, hostname and console"

  if ((OMP_DRY_RUN)); then
    printf '  would set locale=%s tz=%s host=%s keymap=%s\n' \
      "$OMP_LOCALE" "$OMP_TIMEZONE" "$OMP_HOSTNAME" "$OMP_KEYMAP" >&2
    return 0
  fi

  printf '%s UTF-8\n' "$OMP_LOCALE" >>"$mnt/etc/locale.gen"
  printf 'LANG=%s\n' "$OMP_LOCALE" >"$mnt/etc/locale.conf"
  printf 'KEYMAP=%s\n' "$OMP_KEYMAP" >"$mnt/etc/vconsole.conf"
  printf '%s\n' "$OMP_HOSTNAME" >"$mnt/etc/hostname"
  cat >"$mnt/etc/hosts" <<EOF
127.0.0.1	localhost
::1		localhost
127.0.1.1	$OMP_HOSTNAME.localdomain	$OMP_HOSTNAME
EOF
  ln -sf "/usr/share/zoneinfo/$OMP_TIMEZONE" "$mnt/etc/localtime"
  arch-chroot "$mnt" locale-gen >>"$OMP_LOG_FILE" 2>&1
  arch-chroot "$mnt" hwclock --systohc >>"$OMP_LOG_FILE" 2>&1 || true
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

  if ((OMP_DRY_RUN)); then
    printf '  would install %s -> %s\n' \
      "$OMP_SHARE/omp-hooks.conf" "$mnt/etc/mkinitcpio.conf.d/omp-hooks.conf" >&2
    printf '  would run: arch-chroot %s mkinitcpio -P\n' "$mnt" >&2
    return 0
  fi

  install -Dm644 "$OMP_SHARE/omp-hooks.conf" \
    "$mnt/etc/mkinitcpio.conf.d/omp-hooks.conf"

  # If the target still carries Omarchy's own drop-in (it should not -- the
  # ppc64le omarchy-settings package removes it -- but a future upstream
  # version could reintroduce it), take it out. Leaving both in place means
  # the later-sorting one wins and it is a coin toss which.
  if [[ -f $mnt/etc/mkinitcpio.conf.d/omarchy_hooks.conf ]]; then
    warn "target carries Omarchy's omarchy_hooks.conf; removing it (it names btrfs-overlayfs, plymouth and microcode)"
    rm -f "$mnt/etc/mkinitcpio.conf.d/omarchy_hooks.conf"
  fi

  # The plymouth hook bakes the *active* theme into the initramfs, and until
  # first boot applies omarchy-settings' /etc overrides that is plymouth's own
  # default (bgrt). Put Omarchy's plymouthd.conf (Theme=omarchy) in place first,
  # or the splash stays wrong until something else rebuilds the initramfs.
  # etc-overrides.sh installs the same file again at first boot; that is a no-op.
  local plymouth_override="$mnt/usr/share/omarchy/etc-overrides/plymouth-plymouthd.conf"
  if [[ -f $plymouth_override ]]; then
    install -Dm644 "$plymouth_override" "$mnt/etc/plymouth/plymouthd.conf"
    log "plymouth: Theme=omarchy set before building the initramfs"
  else
    warn "no $plymouth_override; the initramfs gets plymouth's default theme"
  fi

  run_loud arch-chroot "$mnt" mkinitcpio -P ||
    die "mkinitcpio failed in the target -- see $OMP_LOG_FILE. Nothing will boot until this is fixed."

  local k kernel_img initrd_img
  for k in "$OMP_KERNEL_PKG" ${OMP_KERNEL_64K:+"$OMP_KERNEL_64K"}; do
    kernel_img="$mnt/boot/vmlinuz-$k"
    initrd_img="$mnt/boot/initramfs-$k.img"
    [[ -f $kernel_img ]] || die "no $kernel_img -- the kernel package did not install one"
    [[ -f $initrd_img ]] || die "no $initrd_img -- mkinitcpio produced nothing"
    log "$k: kernel $(stat -c%s "$kernel_img") bytes, initramfs $(stat -c%s "$initrd_img") bytes"
  done
}

# --- boot entry ---------------------------------------------------------------
configure_boot() {
  local mnt="$1"
  step "Writing the petitboot boot entry"

  if ((OMP_DRY_RUN)); then
    printf '  would run omp-petitboot-entry in %s\n' "$mnt" >&2
    return 0
  fi

  install -Dm755 "$OMP_LIBEXEC/omp-petitboot-entry" "$mnt/usr/local/bin/omp-petitboot-entry"

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
Exec = /usr/local/bin/omp-petitboot-entry
NeedsTargets
HOOK

  install -Dm644 /dev/stdin "$mnt/etc/default/petitboot-entry" <<EOF
# Extra kernel command line for the generated petitboot entries.
# omp-petitboot-entry sources this file.
OMP_CMDLINE="$OMP_CMDLINE"
OMP_ENTRY_TITLE="$OMP_ENTRY_TITLE"
# Listed first, so it is entry 0 and the default. Other kernels follow.
OMP_DEFAULT_KERNEL="$OMP_KERNEL_PKG"
EOF

  OMP_ROOT_UUID="$OMP_UUID_ROOT" \
    OMP_BOOT_UUID="$OMP_UUID_BOOT" \
    OMP_ROOTFLAGS="subvol=@" \
    OMP_CMDLINE="$OMP_CMDLINE" \
    OMP_ENTRY_TITLE="$OMP_ENTRY_TITLE" \
    OMP_DEFAULT_KERNEL="$OMP_KERNEL_PKG" \
    arch-chroot "$mnt" /usr/local/bin/omp-petitboot-entry ||
    die "could not write the petitboot boot entry"

  # The discriminator. The root UUID cannot appear in this file by accident:
  # if it is there, the entry was built from the filesystem we actually made.
  local n
  n=$(grep -c "root=UUID=$OMP_UUID_ROOT" "$mnt/boot/grub/grub.cfg" || true)
  ((n > 0)) || die "grub.cfg does not name root=UUID=$OMP_UUID_ROOT"
  log "grub.cfg carries $n entry/entries for root=UUID=$OMP_UUID_ROOT"
  sed -n '/BEGIN petitboot-entry/,/END petitboot-entry/p' "$mnt/boot/grub/grub.cfg" |
    tee -a "$OMP_LOG_FILE"

  # pSeries is the only platform that installs a bootloader, because SLOF has
  # no petitboot. grub reads the same grub.cfg petitboot does: every entry
  # above does `search --set=root --fs-uuid` and uses /boot-relative paths.
  #
  # Fatal here, not a warning: without GRUB in the PReP partition the disk does
  # not boot, and an install that "succeeds" into that is worse than one that
  # stops. grub-install also writes boot-device to NVRAM through nvsetenv; if
  # that alone fails (some hypervisors refuse it), retry with --no-nvram --
  # SLOF still scans the disks and boots the PReP ELF, the firmware boot order
  # just is not pinned to this disk.
  if [[ $OMP_PLATFORM == pseries ]]; then
    [[ -n ${OMP_PART_PREP:-} ]] || die "pSeries install with no PReP partition"
    step "pSeries: installing GRUB to the PReP partition $OMP_PART_PREP"
    local grub_args=(--target=powerpc-ieee1275 --boot-directory=/boot
      --modules="part_gpt ext2")
    if ! run_loud arch-chroot "$mnt" grub-install "${grub_args[@]}" "$OMP_PART_PREP"; then
      warn "grub-install failed; retrying without the NVRAM boot-device update"
      run_loud arch-chroot "$mnt" grub-install --no-nvram "${grub_args[@]}" "$OMP_PART_PREP" ||
        die "grub-install failed -- a pSeries target without GRUB does not boot"
      warn "GRUB installed, but boot-device was not set in NVRAM; SLOF will find it by scanning"
    fi
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
# --- theme branding -----------------------------------------------------------
#
# /etc/fastfetch/config.jsonc comes from omarchy-settings, shipped byte-for-byte
# as upstream built it, and hardcodes the logo as
# ~/.config/omarchy/branding/about.txt. That path is per-user, so no package can
# set it for an account that does not exist yet; upstream seeds it from
# /etc/skel/.config/omarchy/branding/, which omarchy-settings owns and fills
# with Omarchy's own U+2588 block logo.
#
# omarchy-theme-power9 ships the braille OpenPOWER cube at
# themes/power9/branding/about.txt but has no way to install it: writing to
# /etc/skel from that package is a pacman file conflict with omarchy-settings,
# which owns both paths. So the installer overwrites the seed instead, here,
# before any account exists -- which is what makes it cover BOTH account paths:
# the useradd in configure_users below, and the deferred first-boot wizard
# (omarchy-provision-owner), which also runs `useradd -m` and so reads the same
# skel. Nothing did this before, and fastfetch on a fresh install showed the
# stock block logo despite the theme being installed.
#
# Caveat: omarchy-settings declares no backup= entries, so a later upgrade of it
# restores upstream's about.txt in /etc/skel. Accounts already created keep the
# cube -- their $HOME copy is never touched -- but accounts created after such an
# upgrade revert. `omarchy-theme-power9-branding` re-applies it per user.
apply_theme_branding() {
  local mnt="$1"
  local src="$mnt/usr/share/omarchy/themes/power9/branding"
  local dst="$mnt/etc/skel/.config/omarchy/branding"

  # The stock install ships omarchy-theme-powerpc, not omarchy-theme-power9, so
  # the cube being absent is the normal case now, not a fault: log, don't warn.
  if [[ ! -d $src ]]; then
    log "branding: omarchy-theme-power9 not installed; new accounts keep Omarchy's own logo"
    return 0
  fi

  step "Seeding POWER9 branding into /etc/skel"
  if ((OMP_DRY_RUN)); then
    printf '  would copy %s/about.txt -> %s/\n' "$src" "$dst" >&2
    return 0
  fi

  # about.txt only. The screensaver keeps Omarchy's own logo, which
  # omarchy-settings already seeds in /etc/skel.
  local f
  for f in about; do
    if [[ -r $src/$f.txt ]]; then
      install -Dm644 "$src/$f.txt" "$dst/$f.txt"
      log "branding: $f.txt <- themes/power9"
    else
      warn "theme branding $f.txt is missing; leaving the seeded default in place"
    fi
  done
}

configure_users() {
  local mnt="$1"

  apply_theme_branding "$mnt"

  # Omarchy's shell setup reaches new accounts through /etc/skel/.bashrc, which
  # omarchy-settings only ships as an override (etc-overrides/dot.bashrc) that
  # first boot applies. An account created here, before first boot, copied
  # bash's stock 3-line skel instead and never got Omarchy's environment --
  # found on the POWER8 builder. Deferred installs were fine: their account is
  # created at first boot, after the override. Put it in place now; first boot
  # installs the same file again, which changes nothing.
  local bashrc_override="$mnt/usr/share/omarchy/etc-overrides/dot.bashrc"
  if [[ -f $bashrc_override ]]; then
    if ((OMP_DRY_RUN)); then
      printf '  would install %s -> %s/etc/skel/.bashrc\n' "$bashrc_override" "$mnt" >&2
    else
      install -Dm644 "$bashrc_override" "$mnt/etc/skel/.bashrc"
      log "skel: Omarchy .bashrc in place before creating accounts"
    fi
  else
    warn "no $bashrc_override; new accounts get bash's stock .bashrc"
  fi

  if [[ -z $OMP_USER ]]; then
    step "Deferring account creation to the target's first boot"
    if ((OMP_DRY_RUN)); then
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

  step "Creating $OMP_USER"
  if ((OMP_DRY_RUN)); then
    printf '  would useradd -m -G wheel %s\n' "$OMP_USER" >&2
    return 0
  fi
  arch-chroot "$mnt" useradd -m -G wheel -s /bin/bash "$OMP_USER" >>"$OMP_LOG_FILE" 2>&1
  # install -D, not a bare redirect: /etc/sudoers.d only exists once sudo is
  # installed, and a target that has not got there yet is exactly the case a
  # bare `>` fails on ("No such file or directory") after the disk is already
  # partitioned and pacstrapped.
  printf '%%wheel ALL=(ALL:ALL) ALL\n' |
    install -Dm0440 /dev/stdin "$mnt/etc/sudoers.d/00-omarchy-wheel"
  arch-chroot "$mnt" test -x /usr/bin/sudo ||
    warn "sudo is not installed in the target; the wheel grant is inert until it is"
  if [[ -n $OMP_PASSWORD ]]; then
    printf '%s:%s\n' "$OMP_USER" "$OMP_PASSWORD" | arch-chroot "$mnt" chpasswd
    printf 'root:%s\n' "$OMP_PASSWORD" | arch-chroot "$mnt" chpasswd
  else
    warn "no --password given: set one with 'passwd' before rebooting, or arm deferred provisioning"
  fi


  # Tell sddm who just got created.
  #
  # Omarchy's sddm theme has NO username field. It is password-only and submits
  # userModel.lastUser, read from /var/lib/sddm/state.conf -- the record of who
  # logged in last. On a freshly installed machine nobody ever has, so the theme
  # submits an empty string and PAM answers:
  #
  #   pam_unix(sddm:auth): check pass; user unknown
  #   [PAM] authenticate: User not known to the underlying authentication module
  #
  # which reads like a rejected password and is nothing of the sort -- ruser= is
  # empty in the log. The account cannot be logged into because it has never
  # been logged into. Upstream's install/login/sddm.sh says outright that "the
  # ISO owns autologin/session state because it knows whether the target is
  # encrypted", so this is the installer's job by design; we never did it.
  #
  # The autologin drop-in matches upstream: the operator already authenticated
  # in the configurator. Upstream drops it after the first boot on unencrypted
  # installs -- that cleanup is NOT reproduced here, so it persists. Remove
  # /etc/sddm.conf.d/autologin.conf on the target to require a password.
  if [[ -n $OMP_USER ]] && arch-chroot "$mnt" test -x /usr/bin/sddm 2>/dev/null; then
    local _sess=omarchy.desktop
    if ! arch-chroot "$mnt" test -e "/usr/local/share/wayland-sessions/$_sess" &&
       ! arch-chroot "$mnt" test -e "/usr/share/wayland-sessions/$_sess"; then
      _sess=hyprland-uwsm.desktop
    fi

    install -d -m 0750 "$mnt/var/lib/sddm"
    printf '[Last]\nSession=%s\nUser=%s\n' "$_sess" "$OMP_USER" \
      >"$mnt/var/lib/sddm/state.conf"
    arch-chroot "$mnt" chown -R sddm:sddm /var/lib/sddm >>"$OMP_LOG_FILE" 2>&1 || true

    install -d -m 0755 "$mnt/etc/sddm.conf.d"
    printf '[Autologin]\nUser=%s\nSession=%s\n' "$OMP_USER" "$_sess" \
      >"$mnt/etc/sddm.conf.d/autologin.conf"
    log "sddm: seeded last-user and autologin for $OMP_USER (session $_sess)"
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

  if ((OMP_DRY_RUN)); then
    printf '  would install %s -> %s/usr/local/lib/omp/\n' "$OMP_FIRSTBOOT" "$mnt" >&2
    return 0
  fi

  install -d -m 0755 "$mnt/usr/local/lib/omp"
  cp -a "$OMP_FIRSTBOOT/config" "$mnt/usr/local/lib/omp/"
  install -Dm755 "$OMP_FIRSTBOOT/omp-firstboot" "$mnt/usr/local/bin/omp-firstboot"
  install -Dm644 "$OMP_FIRSTBOOT/omp-firstboot.service" \
    "$mnt/etc/systemd/system/omp-firstboot.service"
  install -d -m 0755 "$mnt/etc/systemd/system/multi-user.target.wants"
  ln -sf ../omp-firstboot.service \
    "$mnt/etc/systemd/system/multi-user.target.wants/omp-firstboot.service"

  install -Dm644 /dev/stdin "$mnt/etc/omp.conf" <<EOF
# Read by omp-firstboot on the target's first boot. Written by omp-install.
OMP_PLATFORM="$OMP_PLATFORM"
OMP_KERNEL_PKG="$OMP_KERNEL_PKG"
OMP_REPO_NAME="$OMP_REPO_NAME"
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
OMP_ETC_OVERRIDES="nsswitch.conf security-faillock.conf plymouth-plymouthd.conf dot.bashrc cups-cups-browsed.conf cups-cups-files.conf"
EOF
  log "first-boot layer staged; it runs before omarchy-provision-owner"
}
