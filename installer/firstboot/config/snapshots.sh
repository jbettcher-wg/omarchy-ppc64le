# p9 replacement for upstream install/config/snapper.sh.
#
# Upstream's version is not really about snapshots, it is about boot entries:
# it creates the snapper root config, then
#
#   systemctl enable --now snapper-cleanup.timer limine-snapper-sync.service
#
# limine-snapper-sync is what turns snapper snapshots into limine boot menu
# entries. There is no limine on POWER9 -- petitboot reads /boot/grub/grub.cfg
# out of firmware -- so there is nothing to sync to, and snapper stops being a
# boot-chain component and goes back to being an ordinary btrfs tool.
#
# Consequence, stated plainly: this spin has NO bootable snapshots. Rolling
# back means booting the installed system (or a live medium), restoring the
# subvolume, and re-running p9-petitboot-entry. Nothing in the boot menu offers
# to do it for you. Reproducing limine's snapshot-boot on petitboot would mean
# emitting one menuentry per snapshot with rootflags=subvol=<snapshot> -- which
# the grammar allows and nobody here has tested; it is not in this installer.
#
# snapper itself is optional. If it is installed, configure retention the way
# upstream does and enable cleanup. If it is not, say so and move on.

if ! command -v snapper >/dev/null 2>&1; then
  echo "snapper is not installed; skipping (it is an optdepend here, not a base package)"
  return 0 2>/dev/null || exit 0
fi

SNAPPER_CONFIG_PATH="${OMARCHY_SNAPPER_CONFIG_PATH:-/etc/snapper/configs/root}"
SNAPPER_CONF_PATH="${OMARCHY_SNAPPER_CONF_PATH:-/etc/conf.d/snapper}"
template="${OMARCHY_SNAPPER_TEMPLATE:-${OMARCHY_PATH:-/usr/share/omarchy}/default/snapper/root}"

if [[ ! -f $SNAPPER_CONFIG_PATH ]]; then
  mkdir -p "$(dirname "$SNAPPER_CONFIG_PATH")"
  snapper --no-dbus -c root create-config / >/dev/null 2>&1 ||
    snapper -c root create-config / >/dev/null 2>&1 || true
fi

[[ -f $template ]] && install -m 0644 "$template" "$SNAPPER_CONFIG_PATH"

mkdir -p "$(dirname "$SNAPPER_CONF_PATH")"
printf '%s\n' 'SNAPPER_CONFIGS="root"' >"$SNAPPER_CONF_PATH"
chmod 0644 "$SNAPPER_CONF_PATH"

systemctl disable snapper-timeline.timer >/dev/null 2>&1 || true
systemctl enable snapper-cleanup.timer   >/dev/null 2>&1 || true
# limine-snapper-sync.service: deliberately not enabled. See above.
