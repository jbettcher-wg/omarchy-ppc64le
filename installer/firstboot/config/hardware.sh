# p9 replacement for upstream install/hardware/all.sh.
#
# Upstream's file is 38 run_logged lines. 30 of them are x86 laptop vendor
# quirks -- ASUS ROG / Z13 / PTL, Framework 16 and its QMK HID, Dell XPS
# touchpad haptics and sidecar amps, Surface, Apple T2 (SPI keyboard, suspend
# NVMe, brcmfmac), Lenovo Yoga speakers, Tuxedo backlight, yt6801 ethernet,
# BCM43xx, hid_apple fnmode -- plus the Intel block (video acceleration, lpmd,
# thermald, the Panther Lake kernel swap, IPU7 camera, FRED, WiFi7 EHT, SOF
# firmware) and nvidia.sh. None of it exists on POWER9 and several entries
# install packages that have no powerpc64le build.
#
# hardware/pacman.sh adds the arch-mact2 repository for T2 MacBooks. Not run.
#
# What survives, in upstream's own order:

# --- network.sh: NetworkManager wins, retire archinstall's networkd state ---
systemctl disable iwd.service 2>/dev/null || true
for unit in \
  systemd-networkd.service \
  systemd-networkd.socket \
  systemd-networkd-varlink.socket \
  systemd-networkd-varlink-metrics.socket \
  systemd-networkd-resolve-hook.socket; do
  systemctl disable "$unit" 2>/dev/null || true
done
systemctl disable systemd-networkd-wait-online.service 2>/dev/null || true
systemctl mask    systemd-networkd-wait-online.service 2>/dev/null || true

# --- bluetooth.sh ---
if systemctl cat bluetooth.service >/dev/null 2>&1; then
  systemctl enable bluetooth.service >/dev/null 2>&1 || true
fi

# --- set-wireless-regdom.sh, verbatim in effect ---
regdom_file=/etc/conf.d/wireless-regdom
if [[ -f $regdom_file ]] && ! grep -q '^WIRELESS_REGDOM=' "$regdom_file"; then
  timezone=""
  [[ -e /etc/localtime ]] && {
    timezone=$(readlink -f /etc/localtime || true)
    timezone=${timezone#/usr/share/zoneinfo/}
  }
  country="${timezone%%/*}"
  if [[ ! $country =~ ^[A-Z]{2}$ && -n $timezone && -f /usr/share/zoneinfo/zone.tab ]]; then
    country=$(awk -v tz="$timezone" '$3 == tz {print $1; exit}' /usr/share/zoneinfo/zone.tab)
  fi
  [[ $country =~ ^[A-Z]{2}$ ]] && echo "WIRELESS_REGDOM=\"$country\"" >>"$regdom_file"
fi

# --- vulkan.sh, resolved at build time rather than by lspci ---
# Upstream detects the GPU and calls omarchy-pkg-add. On a fresh target that
# means a package install on first boot, which fails on an offline machine.
# vulkan-radeon is in p9-base.packages instead: AMD is the only discrete GPU
# with a working driver stack on POWER9. Report what is actually present.
if command -v lspci >/dev/null 2>&1; then
  lspci | grep -iE '(VGA|Display)' || true
fi
pacman -Qq vulkan-radeon >/dev/null 2>&1 &&
  echo "vulkan-radeon present" ||
  echo "vulkan-radeon NOT installed -- Vulkan will not work on the AMD GPU" >&2

# --- speaker-tuning.sh ---
# lsp-plugins-lv2 is likewise in the manifest rather than installed here.
if command -v omarchy-audio-tuning >/dev/null 2>&1; then
  omarchy-audio-tuning match >/dev/null 2>&1 &&
    echo "a shipped speaker tuning matches this machine" ||
    echo "no shipped speaker tuning matches this machine (expected on a workstation)"
fi

# --- fix-fkeys.sh / fix-synaptic-touchpad.sh ---
# hid_apple fnmode and Synaptics InterTouch are laptop-keyboard and PS/2
# touchpad concerns. Neither exists on this hardware; not carried over.
true
