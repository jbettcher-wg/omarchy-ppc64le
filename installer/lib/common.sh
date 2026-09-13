# common.sh -- logging, guards and small helpers shared by p9-install.
#
# Carried over in spirit from upstream Omarchy's install/helpers/logging.sh:
# same idea (one log file, one line per step, exit code recorded), trimmed to
# what an installer that runs from a live medium actually needs.

P9_LOG_FILE="${P9_LOG_FILE:-/var/log/p9-install.log}"

log() {
  printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$P9_LOG_FILE" >&2
}

step() {
  printf '\n[%s] == %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$P9_LOG_FILE" >&2
}

warn() {
  printf '[%s] WARNING: %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$P9_LOG_FILE" >&2
}

die() {
  printf '[%s] ERROR: %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$P9_LOG_FILE" >&2
  exit 1
}

# Every mutating command in this installer goes through run(). --dry-run then
# prints the plan and writes nothing, which is the only way any of this can be
# checked on a machine it must never touch.
run() {
  if ((P9_DRY_RUN)); then
    printf '  would run: %s\n' "$*" >&2
    return 0
  fi
  printf '  + %s\n' "$*" >>"$P9_LOG_FILE"
  "$@" >>"$P9_LOG_FILE" 2>&1
}

# Same, but the caller wants the output on the console (pacstrap, mkinitcpio).
run_loud() {
  if ((P9_DRY_RUN)); then
    printf '  would run: %s\n' "$*" >&2
    return 0
  fi
  printf '  + %s\n' "$*" >>"$P9_LOG_FILE"
  "$@" 2>&1 | tee -a "$P9_LOG_FILE"
  return "${PIPESTATUS[0]}"
}

require_root() {
  ((EUID == 0)) || die "p9-install must run as root"
}

require_tools() {
  local missing=() t
  for t in "$@"; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  ((${#missing[@]} == 0)) ||
    die "missing required tools: ${missing[*]} (install them on the live medium)"
}

confirm() {
  local prompt="$1"
  ((P9_ASSUME_YES)) && return 0
  if command -v gum >/dev/null 2>&1; then
    gum confirm "$prompt"
  else
    local reply
    read -r -p "$prompt [y/N] " reply </dev/tty
    [[ $reply == [yY] ]]
  fi
}

# Detect PowerNV (bare metal, OPAL, petitboot in firmware) vs pSeries (SLOF or
# PowerVM, real GRUB on a PReP partition). This is the only place the two
# platforms diverge -- see README, "Bootloader".
detect_platform() {
  local plat=""
  if [[ -r /proc/cpuinfo ]]; then
    plat=$(awk -F': *' '/^platform/ {print $2; exit}' /proc/cpuinfo)
  fi
  case "$plat" in
    PowerNV*) echo powernv ;;
    pSeries*) echo pseries ;;
    *)
      if [[ -d /sys/firmware/opal ]]; then echo powernv; else echo pseries; fi
      ;;
  esac
}

# The ISO boots with copytoram=y: archiso pulls the squashfs into RAM and then
# unmounts the boot medium, so /run/archiso/bootmnt -- and the repo bundled
# next to it -- is gone by the time the installer runs. Find the medium again
# instead of making the operator mount it by hand. Echoes the mountpoint.
P9_MEDIUM_MNT="${P9_MEDIUM_MNT:-/run/p9-medium}"

find_boot_medium() {
  local want="$1" dev fstype label mnt
  # Still mounted where it was, or already relocated by an earlier call.
  for mnt in /run/archiso/bootmnt "$P9_MEDIUM_MNT"; do
    [[ -d $mnt/$want ]] && { printf '%s\n' "$mnt"; return 0; }
  done

  local -a cands=()
  # archiso records the volume label it booted from on the command line; that
  # is the one device we can name without guessing.
  label=$(sed -n 's/.*archisolabel=\([^ ]*\).*/\1/p' /proc/cmdline)
  [[ -n $label && -e /dev/disk/by-label/$label ]] && cands+=("/dev/disk/by-label/$label")
  # Otherwise try every iso9660/udf block device, whole disks and partitions
  # alike: attached as BMC virtual media the image shows up as a partition on
  # a fake USB disk, written to a stick it is the disk itself.
  while read -r dev fstype; do
    [[ $fstype == iso9660 || $fstype == udf ]] && cands+=("/dev/$dev")
  done < <(lsblk -rno NAME,FSTYPE 2>/dev/null)

  ((${#cands[@]})) || return 1
  mkdir -p "$P9_MEDIUM_MNT"
  for dev in "${cands[@]}"; do
    mountpoint -q "$P9_MEDIUM_MNT" && umount "$P9_MEDIUM_MNT" 2>/dev/null
    # -t auto, because a hybrid image mounts as iso9660 off the disk but the
    # kernel wants to be told when it is looking at the partition.
    mount -o ro -t auto "$dev" "$P9_MEDIUM_MNT" 2>/dev/null || continue
    [[ -d $P9_MEDIUM_MNT/$want ]] && { printf '%s\n' "$P9_MEDIUM_MNT"; return 0; }
    umount "$P9_MEDIUM_MNT" 2>/dev/null
  done
  rmdir "$P9_MEDIUM_MNT" 2>/dev/null
  return 1
}
