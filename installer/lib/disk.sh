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
OMP_FORBIDDEN_DEVICE_GLOBS=(mtdblock* mtd* loop* ram* zram* sr* dm-* md*)

device_is_forbidden() {
  local name glob
  name=$(basename "$1")
  for glob in "${OMP_FORBIDDEN_DEVICE_GLOBS[@]}"; do
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
    ((OMP_DRY_RUN)) || die "$disk is not a block device"
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
    run sgdisk -n 2:0:+"$boot_size" -t 2:8300 -c 2:"ompboot" "$disk"
    run sgdisk -n 3:0:0     -t 3:8300 -c 3:"omproot" "$disk"
    _omp_prep_n=1 _omp_boot_n=2 _omp_root_n=3
  else
    run sgdisk -n 1:0:+"$boot_size" -t 1:8300 -c 1:"ompboot" "$disk"
    run sgdisk -n 2:0:0     -t 2:8300 -c 2:"omproot" "$disk"
    _omp_prep_n="" _omp_boot_n=1 _omp_root_n=2
  fi

  # Settle BEFORE naming the partitions, so part_path can ask the kernel what
  # they are actually called instead of guessing from the disk name.
  run partprobe "$disk" || true
  run udevadm settle || true

  [[ -n $_omp_prep_n ]] && OMP_PART_PREP=$(part_path "$disk" "$_omp_prep_n") || OMP_PART_PREP=""
  OMP_PART_BOOT=$(part_path "$disk" "$_omp_boot_n")
  OMP_PART_ROOT=$(part_path "$disk" "$_omp_root_n")

  # Zero the PReP partition. wipefs and --zap-all clear signatures and the
  # partition table, not the bytes underneath, and /boot and / get mkfs but the
  # PReP partition is written raw -- so on a used disk it starts full of
  # whatever filesystem was there before. grub-install then refuses it ("the
  # PReP partition is not empty ... run dd to clear it"), on both attempts, and
  # the install dies. Found on a secondhand 2 TB NVMe that carried xfs; a fresh
  # VM image is all zeroes, which is why QEMU testing never hit it.
  if [[ -n $OMP_PART_PREP ]]; then
    run dd if=/dev/zero of="$OMP_PART_PREP" bs=1M count=8 conv=fsync status=none
  fi
}

# /dev/sda1 vs /dev/nvme0n1p1 vs /dev/disk/by-id/X-part1: ask the kernel rather
# than guess. The old version guessed from the trailing character of the disk
# name and got by-id paths wrong in both directions:
#
#   /dev/disk/by-id/virtio-omptarget   ends in a letter -> "...target1"
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
  run mkfs.ext4 -F -L ompboot "$OMP_PART_BOOT"
  run mkfs.btrfs -f -L omproot "$OMP_PART_ROOT"
}

# Subvolume layout from the design (@ @home @log @pkg): keeps snapshots of the
# root from dragging in the package cache and the journal.
mount_target() {
  local mnt="$1"
  local opts="rw,noatime,compress=zstd,discard=async,space_cache=v2"

  step "Mounting target at $mnt"
  run mount -o "$opts" "$OMP_PART_ROOT" "$mnt"
  run btrfs subvolume create "$mnt/@"
  run btrfs subvolume create "$mnt/@home"
  run btrfs subvolume create "$mnt/@log"
  run btrfs subvolume create "$mnt/@pkg"
  run umount "$mnt"

  run mount -o "$opts,subvol=@" "$OMP_PART_ROOT" "$mnt"
  run mkdir -p "$mnt/boot" "$mnt/home" "$mnt/var/log" "$mnt/var/cache/pacman/pkg"
  run mount -o "$opts,subvol=@home" "$OMP_PART_ROOT" "$mnt/home"
  run mount -o "$opts,subvol=@log"  "$OMP_PART_ROOT" "$mnt/var/log"
  run mount -o "$opts,subvol=@pkg"  "$OMP_PART_ROOT" "$mnt/var/cache/pacman/pkg"
  run mount "$OMP_PART_BOOT" "$mnt/boot"
}

umount_target() {
  local mnt="$1"
  run umount -R "$mnt" || true
}

# Read the UUIDs back off the devices we just formatted rather than trusting
# what we think we wrote. Every later step (fstab, grub.cfg, the kernel
# cmdline) keys on these, and a wrong UUID is a silent unbootable install.
read_back_uuids() {
  if ((OMP_DRY_RUN)); then
    OMP_UUID_BOOT="<boot-uuid>"
    OMP_UUID_ROOT="<root-uuid>"
    return 0
  fi
  OMP_UUID_BOOT=$(blkid -s UUID -o value "$OMP_PART_BOOT")
  OMP_UUID_ROOT=$(blkid -s UUID -o value "$OMP_PART_ROOT")
  [[ -n $OMP_UUID_BOOT && -n $OMP_UUID_ROOT ]] ||
    die "could not read filesystem UUIDs back from $OMP_PART_BOOT / $OMP_PART_ROOT"
  [[ $(blkid -s TYPE -o value "$OMP_PART_BOOT") == ext4 ]] ||
    die "$OMP_PART_BOOT is not ext4 after mkfs -- petitboot would not read it"
  [[ $(blkid -s TYPE -o value "$OMP_PART_ROOT") == btrfs ]] ||
    die "$OMP_PART_ROOT is not btrfs after mkfs"
  log "boot UUID $OMP_UUID_BOOT (ext4), root UUID $OMP_UUID_ROOT (btrfs)"
}
