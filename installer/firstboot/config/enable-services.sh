# p9 replacement for upstream install/config/enable-services.sh.
#
# Same list, same intent (enable only -- the machine reboots after an install,
# so nothing is started mid-configuration). The only change is that each unit
# is enabled independently: upstream's version is a straight run of
# `systemctl enable` lines under `set -e`, and one absent unit -- entirely
# possible while the ppc64le package set is still being back-filled -- would
# abort the rest of the configuration layer.
#
# Removed from upstream's list: nothing. Added: nothing.

enable_unit() {
  local unit="$1"
  if systemctl cat "$unit" >/dev/null 2>&1; then
    if systemctl enable "$unit" >/dev/null 2>&1; then
      echo "enabled  $unit"
    else
      echo "FAILED   $unit" >&2
    fi
  else
    echo "absent   $unit (package not installed)" >&2
  fi
}

for unit in \
  cups.service \
  avahi-daemon.service \
  linux-modules-cleanup.service \
  docker.socket \
  systemd-resolved.service \
  NetworkManager.service \
  power-profiles-daemon.service \
  sddm.service \
  systemd-oomd.service; do
  enable_unit "$unit"
done

# Nothing in the session needs to block on the network; mirrors upstream.
systemctl mask NetworkManager-wait-online.service >/dev/null 2>&1 || true
