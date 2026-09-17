# common.sh -- logging, guards and small helpers shared by omp-install.
#
# Carried over in spirit from upstream Omarchy's install/helpers/logging.sh:
# same idea (one log file, one line per step, exit code recorded), trimmed to
# what an installer that runs from a live medium actually needs.

OMP_LOG_FILE="${OMP_LOG_FILE:-/var/log/omp-install.log}"

log() {
  printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$OMP_LOG_FILE" >&2
}

step() {
  printf '\n[%s] == %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$OMP_LOG_FILE" >&2
}

# Omarchy's install dashboard (configurator/omarchy-install-dashboard) draws
# its progress bar from a JSON state file, the same one upstream's orchestrator
# writes. omp-install only writes it when the configurator hands it a path: a
# dry run on the build host has no dashboard and no /run/omarchy-install.
#
# The names are the dashboard's own phase names, so each lands in the band the
# dashboard already allots it -- "Installing Arch + Omarchy" is the one it
# drives from the package count rather than the clock.
OMP_STATE_FILE="${OMP_STATE_FILE:-}"
OMP_PHASES=(
  "Starting installation"
  "Preparing live environment"
  "Preparing install target"
  "Installing Arch + Omarchy"
  "Configuring system"
  "Finalizing user"
)
OMP_STARTED_AT=$(date +%s)

phase() {
  local name="$1" finished="${2:-null}" i index=-1
  [[ -n $OMP_STATE_FILE ]] && command -v jq >/dev/null 2>&1 || return 0
  for i in "${!OMP_PHASES[@]}"; do
    [[ ${OMP_PHASES[$i]} == "$name" ]] && index=$i
  done
  mkdir -p "$(dirname "$OMP_STATE_FILE")" 2>/dev/null || return 0
  # Written aside and renamed, so the dashboard's 0.5s poll never reads half.
  jq -n \
    --argjson started_at "$OMP_STARTED_AT" \
    --argjson phase_started_at "$(date +%s)" \
    --arg current_phase "$name" \
    --arg target "$OMP_MNT" \
    --argjson current_index "$index" \
    --argjson total_phases "${#OMP_PHASES[@]}" \
    --argjson finished_at "$finished" \
    '{
      started_at: $started_at,
      phase_started_at: $phase_started_at,
      current_phase: $current_phase,
      target: $target,
      current_index: $current_index,
      total_phases: $total_phases
    } + if $finished_at == null then {} else {finished_at: $finished_at} end' \
    >"$OMP_STATE_FILE.tmp" 2>/dev/null &&
    mv -f "$OMP_STATE_FILE.tmp" "$OMP_STATE_FILE" || true
}

warn() {
  printf '[%s] WARNING: %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$OMP_LOG_FILE" >&2
}

die() {
  printf '[%s] ERROR: %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$OMP_LOG_FILE" >&2
  exit 1
}

# Every mutating command in this installer goes through run(). --dry-run then
# prints the plan and writes nothing, which is the only way any of this can be
# checked on a machine it must never touch.
run() {
  if ((OMP_DRY_RUN)); then
    printf '  would run: %s\n' "$*" >&2
    return 0
  fi
  printf '  + %s\n' "$*" >>"$OMP_LOG_FILE"
  "$@" >>"$OMP_LOG_FILE" 2>&1
}

# Same, but the caller wants the output on the console (pacstrap, mkinitcpio).
run_loud() {
  if ((OMP_DRY_RUN)); then
    printf '  would run: %s\n' "$*" >&2
    return 0
  fi
  printf '  + %s\n' "$*" >>"$OMP_LOG_FILE"
  "$@" 2>&1 | tee -a "$OMP_LOG_FILE"
  return "${PIPESTATUS[0]}"
}

require_root() {
  ((EUID == 0)) || die "omp-install must run as root"
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
  ((OMP_ASSUME_YES)) && return 0
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
OMP_MEDIUM_MNT="${OMP_MEDIUM_MNT:-/run/omp-medium}"

find_boot_medium() {
  local want="$1" dev fstype label mnt
  # Still mounted where it was, or already relocated by an earlier call.
  for mnt in /run/archiso/bootmnt "$OMP_MEDIUM_MNT"; do
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
  mkdir -p "$OMP_MEDIUM_MNT"
  for dev in "${cands[@]}"; do
    mountpoint -q "$OMP_MEDIUM_MNT" && umount "$OMP_MEDIUM_MNT" 2>/dev/null
    # -t auto, because a hybrid image mounts as iso9660 off the disk but the
    # kernel wants to be told when it is looking at the partition.
    mount -o ro -t auto "$dev" "$OMP_MEDIUM_MNT" 2>/dev/null || continue
    [[ -d $OMP_MEDIUM_MNT/$want ]] && { printf '%s\n' "$OMP_MEDIUM_MNT"; return 0; }
    umount "$OMP_MEDIUM_MNT" 2>/dev/null
  done
  rmdir "$OMP_MEDIUM_MNT" 2>/dev/null
  return 1
}
