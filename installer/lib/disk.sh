# disk.sh -- device enumeration, the destructive-write guard, partitioning,
# filesystems and mounting.
#
# Nothing here is POWER-specific except two things, both forced by petitboot:
#
#   * /boot is its own partition with a filesystem the *skiroot* kernel can
#     mount. Petitboot has to read the kernel image itself before anything of
#     ours runs, so /boot cannot live inside the btrfs root. ext4 is the case
#     known to work on this hardware.
#   * on pSeries only, an 8 MiB PReP partition for grub-install. PowerNV
#     installs no bootloader at all.

# Device classes that lsblk calls "disk" and that must never be an install
# target. mtdblock is the one that matters on this hardware: on an OpenPOWER
# machine those are the *firmware* flash chips -- the PNOR holding hostboot,
# skiboot, petitboot itself, and the BMC image. `lsblk -d` lists five of them on
# the AC922, right alongside the NVMe drives, and sgdisk would happily write a
# GPT over one.
P9_FORBIDDEN_DEVICE_GLOBS=(mtdblock* mtd* loop* ram* zram* sr* dm-* md*)

device_is_forbidden() {
  local name glob
  name=$(basename "$1")
  for glob in "${P9_FORBIDDEN_DEVICE_GLOBS[@]}"; do
    # shellcheck disable=SC2053
    [[ $name == $glob ]] && return 0
  done
  return 1
}

# Print the candidate install targets. The installer enumerates; the operator
# chooses. This never guesses and never picks a default.
list_disks() {
  local name size model serial
  while read -r name; do
    device_is_forbidden "$name" && continue
    size=$(lsblk -dn -o SIZE "/dev/$name" 2>/dev/null)
    model=$(lsblk -dn -o MODEL "/dev/$name" 2>/dev/null | sed 's/[[:space:]]*$//')
    serial=$(lsblk -dn -o SERIAL "/dev/$name" 2>/dev/null | sed 's/[[:space:]]*$//')
    printf '/dev/%s\t%s\t%s\t%s\n' "$name" "$size" "${model:--}" "${serial:--}"
  done < <(lsblk -dn -o NAME,TYPE | awk '$2 == "disk" { print $1 }')
}

disk_serial() {
  lsblk -dn -o SERIAL "$1" 2>/dev/null | head -1
}

# The guard. A live installer that can eat the disk it booted from, or the
# disk holding the operator's other OS, is the failure mode worth engineering
# against -- this machine has three NVMe drives and only one of them is free.
#
# Refuses when:
#   * the device does not exist or is not a whole disk
#   * any partition of it is mounted, or is the backing device of / or /boot
#   * it holds active swap
#   * a --serial was given and does not match
assert_disk_is_safe() {
  local disk="$1" want_serial="${2:-}"
  local have_serial src

  # Under --dry-run a nonexistent device is a testing convenience, not a
  # hazard: nothing downstream of here touches a disk in that mode, and
  # requiring a real one meant the installer's own logic -- argument handling,
  # repo-server precedence, platform branches, the boot entry -- could only be
  # exercised on the target machine. Every other guard below still runs; this
  # is the one that cannot.
  if [[ ! -b $disk ]]; then
    ((P9_DRY_RUN)) || die "$disk is not a block device"
    warn "$disk is not a block device; continuing because this is a dry run"
    return 0
  fi
  if device_is_forbidden "$disk"; then
    die "$disk is not an install target. mtdblock devices on this platform are
      the firmware flash (PNOR: hostboot, skiboot, petitboot; and the BMC
      image); loop/ram/zram/sr/dm/md devices are not whole disks either."
  fi
  [[ $(lsblk -dn -o TYPE "$disk") == disk ]] ||
    die "$disk is not a whole disk (partition or virtual device)"

  if [[ -n $want_serial ]]; then
    have_serial=$(disk_serial "$disk")
    [[ $have_serial == "$want_serial" ]] ||
      die "serial mismatch: $disk reports '${have_serial:-<none>}', --serial said '$want_serial'"
  fi

  while read -r name mnt; do
    [[ -n $mnt ]] || continue
    die "$disk holds a mounted filesystem ($name on $mnt) -- refusing"
  done < <(lsblk -ln -o NAME,MOUNTPOINT "$disk" | awk 'NF>1')

  for mp in / /boot; do
    src=$(findmnt -no SOURCE "$mp" 2>/dev/null | sed 's/\[.*//') || true
    [[ -n $src ]] || continue
    if [[ $(lsblk -no PKNAME "$src" 2>/dev/null | head -1) == "$(basename "$disk")" ]]; then
      die "$disk is the device backing $mp on the live system -- refusing"
    fi
  done

  if awk 'NR>1 {print $1}' /proc/swaps 2>/dev/null | grep -q "^${disk}"; then
    die "$disk has active swap on it -- refusing"
  fi
}

# sgdisk type codes: 4100 = PowerPC PReP boot, 8300 = Linux filesystem.
# GPT throughout: petitboot reads GPT, and pSeries GRUB wants the PReP
# partition typed so firmware can find it.
partition_disk() {
  local disk="$1" platform="$2" boot_size="$3"

  step "Partitioning $disk ($platform)"
  run wipefs -a "$disk"
  run sgdisk --zap-all "$disk"

  if [[ $platform == pseries ]]; then
    run sgdisk -n 1:0:+8M   -t 1:4100 -c 1:"PReP"  "$disk"
    run sgdisk -n 2:0:+"$boot_size" -t 2:8300 -c 2:"p9boot" "$disk"
    run sgdisk -n 3:0:0     -t 3:8300 -c 3:"p9root" "$disk"
    _p9_prep_n=1 _p9_boot_n=2 _p9_root_n=3
  else
    run sgdisk -n 1:0:+"$boot_size" -t 1:8300 -c 1:"p9boot" "$disk"
    run sgdisk -n 2:0:0     -t 2:8300 -c 2:"p9root" "$disk"
    _p9_prep_n="" _p9_boot_n=1 _p9_root_n=2
  fi

  # Settle BEFORE naming the partitions, so part_path can ask the kernel what
  # they are actually called instead of guessing from the disk name.
  run partprobe "$disk" || true
  run udevadm settle || true

  [[ -n $_p9_prep_n ]] && P9_PART_PREP=$(part_path "$disk" "$_p9_prep_n") || P9_PART_PREP=""
  P9_PART_BOOT=$(part_path "$disk" "$_p9_boot_n")
  P9_PART_ROOT=$(part_path "$disk" "$_p9_root_n")
}

# /dev/sda1 vs /dev/nvme0n1p1 vs /dev/disk/by-id/X-part1: ask the kernel rather
# than guess. The old version guessed from the trailing character of the disk
# name and got by-id paths wrong in both directions:
#
#   /dev/disk/by-id/virtio-p9target   ends in a letter -> "...target1"
#   /dev/disk/by-id/nvme-Samsung_..._S6B0NL0T123456  ends in a digit -> "...456p1"
#
# and the right answer is "-part1" for both. by-id is exactly how a disk should
# be named on real hardware -- /dev/nvme2n1 can move between boots -- so this
# has to be correct, not merely correct for /dev/vdX.
part_path() {
  local disk="$1" n="$2" real part
  real=$(readlink -f "$disk" 2>/dev/null || printf '%s' "$disk")

  # The kernel's own answer, in partition order. Empty under --dry-run (nothing
  # was written) and in the window before udev publishes the nodes.
  part=$(lsblk -lno NAME,TYPE "$real" 2>/dev/null |
           awk '$2 == "part" { print $1 }' | sed -n "${n}p")
  if [[ -n $part ]]; then
    printf '/dev/%s\n' "$part"
    return 0
  fi

  case "$disk" in
    */by-id/*|*/by-path/*|*/by-uuid/*) printf '%s-part%s\n' "$disk" "$n" ;;
    *[0-9])                            printf '%sp%s\n'     "$disk" "$n" ;;
    *)                                 printf '%s%s\n'      "$disk" "$n" ;;
  esac
}

make_filesystems() {
  step "Creating filesystems"
  # ext4 on /boot because petitboot must mount and read it. Do not "improve"
  # this to btrfs or f2fs without re-testing petitboot on the target machine.
  run mkfs.ext4 -F -L p9boot "$P9_PART_BOOT"
  run mkfs.btrfs -f -L p9root "$P9_PART_ROOT"
}

# Subvolume layout from the design (@ @home @log @pkg): keeps snapshots of the
# root from dragging in the package cache and the journal.
mount_target() {
  local mnt="$1"
  local opts="rw,noatime,compress=zstd,discard=async,space_cache=v2"

  step "Mounting target at $mnt"
  run mount -o "$opts" "$P9_PART_ROOT" "$mnt"
  run btrfs subvolume create "$mnt/@"
  run btrfs subvolume create "$mnt/@home"
  run btrfs subvolume create "$mnt/@log"
  run btrfs subvolume create "$mnt/@pkg"
  run umount "$mnt"

  run mount -o "$opts,subvol=@" "$P9_PART_ROOT" "$mnt"
  run mkdir -p "$mnt/boot" "$mnt/home" "$mnt/var/log" "$mnt/var/cache/pacman/pkg"
  run mount -o "$opts,subvol=@home" "$P9_PART_ROOT" "$mnt/home"
  run mount -o "$opts,subvol=@log"  "$P9_PART_ROOT" "$mnt/var/log"
  run mount -o "$opts,subvol=@pkg"  "$P9_PART_ROOT" "$mnt/var/cache/pacman/pkg"
  run mount "$P9_PART_BOOT" "$mnt/boot"
}

umount_target() {
  local mnt="$1"
  run umount -R "$mnt" || true
}

# Read the UUIDs back off the devices we just formatted rather than trusting
# what we think we wrote. Every later step (fstab, grub.cfg, the kernel
# cmdline) keys on these, and a wrong UUID is a silent unbootable install.
read_back_uuids() {
  if ((P9_DRY_RUN)); then
    P9_UUID_BOOT="<boot-uuid>"
    P9_UUID_ROOT="<root-uuid>"
    return 0
  fi
  P9_UUID_BOOT=$(blkid -s UUID -o value "$P9_PART_BOOT")
  P9_UUID_ROOT=$(blkid -s UUID -o value "$P9_PART_ROOT")
  [[ -n $P9_UUID_BOOT && -n $P9_UUID_ROOT ]] ||
    die "could not read filesystem UUIDs back from $P9_PART_BOOT / $P9_PART_ROOT"
  [[ $(blkid -s TYPE -o value "$P9_PART_BOOT") == ext4 ]] ||
    die "$P9_PART_BOOT is not ext4 after mkfs -- petitboot would not read it"
  [[ $(blkid -s TYPE -o value "$P9_PART_ROOT") == btrfs ]] ||
    die "$P9_PART_ROOT is not btrfs after mkfs"
  log "boot UUID $P9_UUID_BOOT (ext4), root UUID $P9_UUID_ROOT (btrfs)"
}
