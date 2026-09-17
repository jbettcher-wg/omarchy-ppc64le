#!/usr/bin/env bash
# Runs INSIDE the QEMU guest, from the payload ISO. Never on the host.
#
# Markers (OMPG_*) are what test/expect-install.txt watches for on the serial
# console; everything else is just the installer's own output.

exec 2>&1
echo "OMPG_BEGIN"

set -x
PAYLOAD=$(dirname "$(dirname "$(readlink -f "$0")")")

# The target is identified by the virtio serial the harness set
# (-device virtio-blk-pci,serial=omptarget), which is also what exercises
# omp-install's --serial guard for real.
TARGET=$(readlink -f /dev/disk/by-id/virtio-omptarget 2>/dev/null || true)
if [ -z "$TARGET" ]; then
  TARGET=/dev/$(lsblk -dn -o NAME,SERIAL | awk '$2 == "omptarget" { print $1; exit }')
fi
echo "OMPG_TARGET=$TARGET"
lsblk -d -o NAME,SIZE,TYPE,MODEL,SERIAL

"$PAYLOAD/omp-install" \
  --disk "$TARGET" \
  --serial omptarget \
  --yes \
  --platform powernv \
  --kernel linux-4k \
  --manifest "$PAYLOAD/guest/omp-test.packages" \
  --repo-name omarchy-power9 \
  --repo-server "http://10.0.2.2:8099" \
  --repo-siglevel optional-trustall \
  --hostname omptest \
  --timezone UTC \
  --locale en_US.UTF-8 \
  --keymap us \
  --user test --password test \
  --cmdline "console=hvc0 loglevel=4"
rc=$?
set +x
echo "OMPG_INSTALL_RC=$rc"

# Evidence, read back off the disk the installer just unmounted.
echo "OMPG_EVIDENCE_BEGIN"
mkdir -p /tmp/verify
if mount "${TARGET}1" /tmp/verify 2>/dev/null; then
  echo "--- /boot contents ---"
  ls -la /tmp/verify
  echo "--- /boot/grub/grub.cfg ---"
  cat /tmp/verify/grub/grub.cfg
  umount /tmp/verify
else
  echo "could not mount ${TARGET}1"
fi
if mount -o subvol=@ "${TARGET}2" /tmp/verify 2>/dev/null; then
  echo "--- /etc/fstab ---"
  cat /tmp/verify/etc/fstab
  echo "--- /etc/mkinitcpio.conf.d ---"
  ls -la /tmp/verify/etc/mkinitcpio.conf.d
  echo "--- first-boot staging ---"
  ls -la /tmp/verify/etc/systemd/system/multi-user.target.wants/ 2>/dev/null
  ls -la /tmp/verify/usr/local/bin/ 2>/dev/null
  umount /tmp/verify
fi
echo "OMPG_EVIDENCE_END"
echo "OMPG_FINISHED rc=$rc"
