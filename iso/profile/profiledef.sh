#!/usr/bin/env bash
# shellcheck disable=SC2034
#
# Omarchy ppc64le live/install medium.
#
# Derived from kth5/archiso configs/releng-ppc64le. Build it with THAT fork's
# mkarchiso, not /usr/bin/mkarchiso: Arch POWER packages upstream archiso, which
# has no openpower.grub bootmode and cannot produce a bootable ppc64le image.
#
# arch= is only the packages.<arch> suffix and the install path; pacman.conf is
# what declares Architecture = powerpc64le.

iso_name="omarchy-p9"
iso_label="ARCH_$(date +%Y%m)"
iso_publisher="Omarchy ppc64le <https://omarchy.org>"
iso_application="Omarchy POWER9 Live/Install"
iso_version="$(date +%Y.%m.%d)"
install_dir="arch"
buildmodes=('iso')
bootmodes=('openpower.grub')
arch="ppc64le"
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'xz' '-b' '1M' '-Xdict-size' '1M')
file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/root"]="0:0:750"
  ["/root/.automated_script.sh"]="0:0:755"
  ["/usr/local/bin/Installation_guide"]="0:0:755"
  ["/usr/local/bin/livecd-sound"]="0:0:755"
  ["/root/.bash_profile"]="0:0:644"
  ["/root/p9-configurator"]="0:0:755"
  ["/usr/local/share/omarchy-p9/p9-install"]="0:0:755"
  ["/usr/local/share/omarchy-p9/bin/p9-petitboot-entry"]="0:0:755"
)
