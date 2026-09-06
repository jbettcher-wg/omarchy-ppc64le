#!/usr/bin/env bash
#
# extract-skiroot.sh -- pull a real petitboot out of a PNOR firmware image.
#
# Stage 2 of the test rig needs the thing that actually reads our grub.cfg:
# petitboot, running in skiroot, under OPAL. QEMU's powernv9 machine boots
# skiboot from /usr/share/qemu/skiboot.lid and then jumps to whatever payload
# `-kernel` supplies -- which on real hardware is the PNOR's BOOTKERNEL
# partition. So: take the BOOTKERNEL out of a firmware backup and hand it to
# QEMU as the payload.
#
# The user's own AC922 firmware backups are under
# ~/Back-up/Power9-Firmware/{AC922,TALOS}/*.pnor.squashfs.tar. Those are BMC
# update bundles: a tar holding pnor.xz.squashfs, whose contents are the PNOR
# partitions one file per partition.
#
# BOOTKERNEL is wrapped in a POWER Secure Boot Container: a 4096-byte header
# (skiboot's SECURE_BOOT_HEADERS_SIZE) followed by the payload, which is the
# skiroot zImage.epapr -- an ELF64 LE PPC executable with entry 0x20000000,
# exactly where skiboot looks for a kernel.
#
# Read-only with respect to the firmware backups; everything lands under
# installer/test/work/skiroot/.

set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
OUT="$HERE/work/skiroot"
SRC="${1:-$HOME/Back-up/Power9-Firmware/AC922/OCC7.pnor.squashfs.tar}"

[[ -f $SRC ]] || { echo "no firmware bundle at $SRC" >&2; exit 1; }
command -v unsquashfs >/dev/null || { echo "need squashfs-tools" >&2; exit 1; }

mkdir -p "$OUT"
cd "$OUT"

echo "extracting pnor.xz.squashfs from $(basename "$SRC")"
tar xf "$SRC" pnor.xz.squashfs

echo "extracting BOOTKERNEL"
rm -rf raw
unsquashfs -q -f -d raw pnor.xz.squashfs BOOTKERNEL >/dev/null

# ROM_container_raw, packed and big-endian:
#   0  u32 magic          0x17082011
#   4  u16 version        1
#   6  u64 container_size
size=$(od -An -tu8 -j6 -N8 --endian=big raw/BOOTKERNEL | tr -d ' ')
echo "secure-boot container: magic $(od -An -tx1 -N4 raw/BOOTKERNEL | tr -d ' '), payload $size bytes"

# Everything after the 4096-byte header (skiboot's SECURE_BOOT_HEADERS_SIZE).
# The partition is zero-padded past the payload and the ELF loader ignores the
# tail, so take it all rather than trusting the length field.
dd if=raw/BOOTKERNEL of=BOOTKERNEL bs=4096 skip=1 status=none

file BOOTKERNEL
echo "wrote $OUT/BOOTKERNEL"
