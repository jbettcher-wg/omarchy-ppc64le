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
