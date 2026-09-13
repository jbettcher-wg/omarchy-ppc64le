#!/usr/bin/env bash
# Boot the Omarchy ppc64le ISO as a pseries KVM guest on the AC922.
#
# PREFER installer/test/run-guest.sh. It predates this file and is strictly more
# capable: it runs -machine powernv9 against real skiboot, installs to a virtio
# disk identified by serial, reads the result back off the filesystem it just
# unmounted, and -- with extract-skiroot.sh -- boots the installed disk through
# actual petitboot and kexecs it. That last stage is the only pre-hardware proof
# that the grub.cfg we generate is parsed by the thing that has to parse it.
#
# This script uses pseries, which is SLOF: there is no petitboot in it at all.
# It was written without checking what the tree already had, and its inability
# to test the boot path was then mistaken for a limit of QEMU rather than a
# limit of this file. Kept because booting the ISO image itself (rather than a
# side-loaded payload) is still occasionally useful; reach for run-guest.sh
# first.
#
#   ./tests/qemu-smoke.sh [-i ISO] [-m MEM] [-c CPUS] [-d SIZE] [-w WORKDIR]
#
# What this does and does not test.
#
# It tests the parts that actually broke on hardware: archiso init, copytoram
# and the medium re-discovery that follows it, the configurator's forms, disk
# partitioning, and pacstrap over the network. The target is a qcow2 file, so
# nothing here can reach a real disk.
#
# It does not test petitboot. QEMU's pseries machine is SLOF, not OPAL, and the
# openpower.grub bootmode writes grub.cfg for petitboot -- there is no petitboot
# in a pseries guest to read it. So the kernel and initramfs are pulled out of
# the image and passed with -kernel/-initrd, which is the same thing petitboot
# would do, minus the menu. Bare-metal boot stays a hardware test.
#
# It needs the kernel built with CONFIG_PPC_PSERIES and virtio. A PowerNV-only
# kernel gets as far as SLOF handing off and then sits there with no platform,
# no disk driver and no console.
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT=$(cd "$HERE/.." && pwd)

ISO=""
MEM=16G
CPUS=8
DISK=40G
WORK="${TMPDIR:-/var/tmp}/omarchy-qemu"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i) ISO="$2"; shift 2 ;;
    -m) MEM="$2"; shift 2 ;;
    -c) CPUS="$2"; shift 2 ;;
    -d) DISK="$2"; shift 2 ;;
    -w) WORK="$2"; shift 2 ;;
    *)  echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ -n $ISO ]] || ISO=$(find "$PROJECT/iso/out" -maxdepth 1 -name 'omarchy-p9-*.iso' | sort | tail -1)
[[ -f $ISO ]] || { echo "no ISO (looked in $PROJECT/iso/out)" >&2; exit 1; }

command -v qemu-system-ppc64 >/dev/null || { echo "qemu-system-ppc64 not installed" >&2; exit 1; }
[[ -r /dev/kvm ]] || echo "warning: no /dev/kvm -- this will fall back to TCG and be very slow" >&2

mkdir -p "$WORK"

# The label is what archiso's hook searches for; read it off the image rather
# than recomputing profiledef's date, which drifts the moment the month rolls.
LABEL=$(blkid -s LABEL -o value "$ISO" 2>/dev/null || true)
[[ -n $LABEL ]] || LABEL=$(bsdtar -xOf "$ISO" boot/grub/grub.cfg 2>/dev/null |
                           sed -n 's/.*archisolabel=\([A-Za-z0-9_]*\).*/\1/p' | head -1)
[[ -n $LABEL ]] || { echo "could not determine the ISO label" >&2; exit 1; }

echo "==> iso    $ISO"
echo "==> label  $LABEL"

bsdtar -C "$WORK" -xf "$ISO" \
  arch/boot/ppc64le/vmlinuz-linux-power9 \
  arch/boot/ppc64le/initramfs-linux-power9.img
KERNEL="$WORK/arch/boot/ppc64le/vmlinuz-linux-power9"
INITRD="$WORK/arch/boot/ppc64le/initramfs-linux-power9.img"
[[ -f $KERNEL && -f $INITRD ]] || { echo "kernel/initramfs not found in the image" >&2; exit 1; }

TARGET="$WORK/target.qcow2"
[[ -f $TARGET ]] || qemu-img create -f qcow2 "$TARGET" "$DISK" >/dev/null
echo "==> target $TARGET ($DISK, qcow2 -- no real disk is reachable from the guest)"

# copytoram=y rather than leaving it at auto. On hardware the BMC presents the
# image as an optical device and archiso copies to RAM and unmounts the medium;
# on a virtio disk auto would keep it mounted and quietly skip the exact code
# path -- find_boot_medium -- that this is meant to exercise.
CMDLINE="archisobasedir=arch archisolabel=$LABEL copytoram=y console=hvc0 loglevel=4"

echo "==> booting; ctrl-a x to quit"
exec qemu-system-ppc64 \
  -machine pseries,accel=kvm:tcg \
  -smp "$CPUS" -m "$MEM" -nographic \
  -kernel "$KERNEL" -initrd "$INITRD" -append "$CMDLINE" \
  -drive file="$ISO",format=raw,if=none,id=medium,readonly=on \
  -device virtio-blk-pci,drive=medium \
  -drive file="$TARGET",format=qcow2,if=none,id=target \
  -device virtio-blk-pci,drive=target \
  -netdev user,id=net0 -device virtio-net-pci,netdev=net0
