# omp replacement for upstream install/config/enable-services.sh.
#
# Same list, two changes. Each unit is enabled independently: upstream's version
# is a straight run of `systemctl enable` lines under `set -e`, and one absent
# unit -- entirely possible while the ppc64le package set is still being
# back-filled -- would abort the rest of the configuration layer. And units are
# started as well as enabled; see the note on the exception below.
#
# Removed from upstream's list: nothing. Added: sshd.service -- upstream is a
# laptop distribution and does not enable it. This is a headless-capable POWER
# server administered over the network, and an install that comes up with a
# graphical target, no sshd and no serial console has exactly one failure mode.
# Revisit if this ever targets machines sitting on someone's desk.
#
# Also added: systemd-timesyncd.service. Nothing else in this layer, and nothing
# in the installer, ever sets the clock -- so the target keeps whatever the
# firmware handed it, forever. The first install came up three days behind: enough
# to make `make` print "Clock skew detected" through an entire kernel build, and
# enough to break TLS certificate validation outright. timesyncd steps the clock
# itself at start -- it does not go through timedated -- so it works even where
# `timedatectl` cannot activate.

# Upstream enables without starting, because upstream runs this in the target
# chroot during the install and a reboot always follows. This layer runs on the
# target's FIRST BOOT instead, where nothing follows -- so "enable only" leaves
# every unit inert until the user reboots a second time. That is how the first
# install came up with NetworkManager enabled and no network: correct on paper,
# useless in practice. Enable and start, so the first boot behaves like every
# boot after it.
#
# sddm is the exception: omp-firstboot is ordered Before=display-manager.service,
# so systemd starts it in this same transaction once we exit. Starting it here
# would race that.
#
# --no-block is load-bearing, not a tidy-up. A blocking `systemctl start` from
# inside a oneshot that other units are ordered against deadlocks: the start
# waits for a job that cannot run until this unit finishes. It did exactly that
# on the first install -- ten minutes in the services step, then
#
#   omp-firstboot.service: start operation timed out. Terminating.
#
# and because the whole layer died there, the /etc overrides after it never ran:
# no dot.bashrc (so no starship prompt), no nsswitch, no faillock, and no
# firstboot-done marker. Enqueue the jobs and let systemd order them itself.
NO_START=" sddm.service "

enable_unit() {
  local unit="$1"
  if ! systemctl cat "$unit" >/dev/null 2>&1; then
    echo "absent   $unit (package not installed)" >&2
    return
  fi
  if ! systemctl enable "$unit" >/dev/null 2>&1; then
    echo "FAILED   $unit" >&2
    return
  fi
  if [[ $NO_START == *" $unit "* ]]; then
    echo "enabled  $unit (start deferred to display-manager ordering)"
  elif systemctl start --no-block "$unit" >/dev/null 2>&1; then
    echo "started  $unit"
  else
    echo "enabled  $unit (but failed to start)" >&2
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
  systemd-oomd.service \
  systemd-timesyncd.service \
  sshd.service; do
  enable_unit "$unit"
done

# Nothing in the session needs to block on the network; mirrors upstream.
systemctl mask NetworkManager-wait-online.service >/dev/null 2>&1 || true
