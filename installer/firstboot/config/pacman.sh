# omp replacement for upstream install/post-install/pacman.sh.
#
# What upstream does and we do NOT:
#
#   cp -f $OMARCHY_PATH/default/pacman/pacman-stable.conf /etc/pacman.conf
#   cp -f $OMARCHY_PATH/default/pacman/mirrorlist-stable  /etc/pacman.d/mirrorlist
#
# That repoints the machine at pkgs.omarchy.org, which publishes x86_64 and
# aarch64 only. On powerpc64le it would replace a working package source with
# an empty one. omp-install already wrote the correct /etc/pacman.conf -- the
# same file the install itself ran from -- so there is nothing to restore.
#
#   source "$OMARCHY_INSTALL/hardware/pacman.sh"
#
# adds the arch-mact2 repository for Apple T2 MacBooks (SigLevel = Never).
# Not applicable, and not something to add unread.
#
# What is kept: the CUPS ownership fix, because it is about file ownership
# racing pacman, not about repositories.

echo "pacman: keeping the repositories omp-install configured"
grep -E '^\[' /etc/pacman.conf | tr -d '[]' | tr '\n' ' '
echo

if [[ -f $OMARCHY_PATH/etc-overrides/cups-cups-files.conf && -f /etc/cups/cups-files.conf ]]; then
  install -m 0640 -o root -g cups \
    "$OMARCHY_PATH/etc-overrides/cups-cups-files.conf" /etc/cups/cups-files.conf
  rm -f /etc/cups/cups-files.conf.pacnew
fi
