# Apply omarchy-settings' /etc overrides -- once, on first boot, deliberately.
#
# Upstream ships these as an .INSTALL scriptlet (_etc_overrides_apply) that runs
# on every install AND every upgrade of omarchy-settings, with `rm -f` followed
# by `cp -f`. Its own comment calls it "intentionally destructive". That
# scriptlet was removed from the ppc64le omarchy-settings package because the
# build host is an existing Arch workstation, not an Omarchy install, and it is
# NOT reintroduced -- not as a scriptlet, not as a pacman hook.
#
# A machine that came out of p9-install, however, *is* an Omarchy install, so
# the overrides are correct here. They are applied exactly once, from a first-
# boot service, and never again: a later `pacman -Syu` of omarchy-settings will
# not silently rewrite a file the operator has since edited.
#
# Which overrides are applied is a list in /etc/omarchy-p9.conf, so this is a
# visible decision rather than a hidden one.

CONF=/etc/omarchy-p9.conf
[[ -r $CONF ]] && . "$CONF"

SRC="${OMARCHY_PATH:-/usr/share/omarchy}/etc-overrides"
[[ -d $SRC ]] || { echo "no $SRC; omarchy-settings is not installed"; exit 0; }

declare -A DEST=(
  [os-release]=/etc/os-release
  [nsswitch.conf]=/etc/nsswitch.conf
  [security-faillock.conf]=/etc/security/faillock.conf
  [plymouth-plymouthd.conf]=/etc/plymouth/plymouthd.conf
  [dot.bashrc]=/etc/skel/.bashrc
  [cups-cups-browsed.conf]=/etc/cups/cups-browsed.conf
  [cups-cups-files.conf]=/etc/cups/cups-files.conf
)

for name in ${P9_ETC_OVERRIDES:-}; do
  src="$SRC/$name"
  dst="${DEST[$name]:-}"
  if [[ -z $dst ]]; then
    echo "unknown override '$name' in P9_ETC_OVERRIDES; skipping" >&2
    continue
  fi
  if [[ ! -f $src ]]; then
    echo "override '$name' not shipped by this omarchy-settings; skipping" >&2
    continue
  fi
  # cups-files.conf is root:cups 0640; everything else is plain 0644 root:root.
  case "$name" in
    cups-cups-files.conf)
      [[ -f $dst ]] || continue
      install -m 0640 -o root -g cups "$src" "$dst"
      ;;
    cups-cups-browsed.conf)
      [[ -f $dst ]] || continue
      install -m 0644 "$src" "$dst"
      ;;
    *)
      mkdir -p "$(dirname "$dst")"
      # /etc/os-release ships as a symlink into /usr/lib; replacing it changes
      # what every tool on the machine thinks it is running.
      [[ -L $dst ]] && rm -f "$dst"
      install -m 0644 "$src" "$dst"
      ;;
  esac
  echo "applied $name -> $dst"
done
