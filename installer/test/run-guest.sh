#!/usr/bin/env bash
#
# run-guest.sh -- QEMU test rig for omp-install.
#
# Why powernv9 and not pseries: powernv is the real boot path. The machine model
# runs OPAL (skiboot) exactly as an AC922 does, so the thing under test -- "does
# petitboot find and parse what the installer wrote" -- is actually exercised
# rather than approximated by GRUB on a PReP partition.
#
# Why TCG and not KVM: PowerNV means the guest runs in hypervisor mode, and
# KVM-HV cannot delegate that, so `powernv9,accel=kvm` is refused outright. (The
# pseries alternative also fails on this host: its KVM wants 64K guest pages and
# the host kernel is 4K.) So this is full emulation and it is slow. An installer
# test is I/O and shell logic, not compute, so slow is acceptable -- but keep
# the package set minimal.
#
# Everything this creates lives under installer/test/. Nothing is written
# outside the project and nothing is installed on the host.
#
#   ./run-guest.sh prepare        extract the ISO kernel, make the disk image
#                                 and the payload ISO carrying the installer
#   ./run-guest.sh serve          start a local http server over the project's
#                                 package repo (for the [power9] stanza)
#   ./run-guest.sh install        boot the live ISO and run omp-install
#   ./run-guest.sh boot           boot the *installed* disk through petitboot
#   ./run-guest.sh tail [stage]   follow a stage log
#   ./run-guest.sh status
#   ./run-guest.sh stop
#   ./run-guest.sh clean          delete images and logs

set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT=$(cd "$HERE/../.." && pwd)
INSTALLER=$(cd "$HERE/.." && pwd)
WORK="$HERE/work"
IMAGES="$HERE/images"
LOGS="$HERE/logs"
RUN="$HERE/run"

ISO="${OMPT_ISO:-$HOME/Downloads/archpower-current-powerpc64le.iso}"
ISO_LABEL="${OMPT_ISO_LABEL:-ARCH_202602}"
SKIBOOT="${OMPT_SKIBOOT:-/usr/share/qemu/skiboot.lid}"
SKIROOT="${OMPT_SKIROOT:-$WORK/skiroot/BOOTKERNEL}"

SMP="${OMPT_SMP:-2}"
MEM="${OMPT_MEM:-6G}"
DISK_SIZE="${OMPT_DISK_SIZE:-20G}"
REPO_PORT="${OMPT_REPO_PORT:-8099}"

mkdir -p "$WORK" "$IMAGES" "$LOGS" "$RUN"

die() { echo "run-guest: $*" >&2; exit 1; }
say() { echo "run-guest: $*"; }

# --------------------------------------------------------------- prepare ----
cmd_prepare() {
  [[ -f $ISO ]] || die "no ISO at $ISO"
  [[ -f $SKIBOOT ]] || die "no skiboot firmware at $SKIBOOT"

  if [[ ! -f $WORK/arch/boot/ppc64le/vmlinuz-linux-4k ]]; then
    say "extracting the live kernel and initramfs from the ISO"
    bsdtar -xf "$ISO" -C "$WORK" arch/boot/ppc64le boot/grub/grub.cfg
  fi

  say "building the payload ISO (the installer itself)"
  rm -rf "$WORK/payload"
  mkdir -p "$WORK/payload"
  cp -a "$INSTALLER"/{omp-install,lib,bin,share,firstboot} "$WORK/payload/"
  cp -a "$HERE/guest" "$WORK/payload/guest"
  rm -rf "$WORK/payload/guest/.keep"
  xorriso -as mkisofs -V OMPPAYLOAD -o "$IMAGES/payload.iso" "$WORK/payload" >/dev/null 2>&1
  ls -la "$IMAGES/payload.iso"

  if [[ ! -f $IMAGES/target.qcow2 ]]; then
    say "creating the target disk ($DISK_SIZE)"
    qemu-img create -f qcow2 "$IMAGES/target.qcow2" "$DISK_SIZE" >/dev/null
  fi
  say "prepared"
}

# ----------------------------------------------------------------- serve ----
# Serves $PROJECT/repo over http so the guest can be pointed at a [power9]
# stanza. Bound to loopback; QEMU's user network reaches it as 10.0.2.2.
cmd_serve() {
  if [[ -f $RUN/httpd.pid ]] && kill -0 "$(cat "$RUN/httpd.pid")" 2>/dev/null; then
    say "http server already running (pid $(cat "$RUN/httpd.pid"))"
    return 0
  fi
  setsid nohup python3 -m http.server "$REPO_PORT" --bind 127.0.0.1 \
    --directory "$PROJECT/repo" >"$LOGS/httpd.log" 2>&1 &
  echo $! >"$RUN/httpd.pid"
  sleep 1
  say "serving $PROJECT/repo on 127.0.0.1:$REPO_PORT (pid $(cat "$RUN/httpd.pid"))"
}

# ------------------------------------------------------------------ qemu ----
# NOTE: every PCI device needs an explicit bus=pcie.N. QEMU's powernv9 machine
# gives each of its six PHB4s a root port whose secondary bus holds exactly one
# device; without bus= only one of several -device lines is enumerated by
# skiboot and the rest silently do not exist in the guest.
qemu_common=()
build_qemu_common() {
  qemu_common=(
    qemu-system-ppc64
    -machine powernv9,accel=tcg
    -smp "$SMP" -m "$MEM"
    -bios "$SKIBOOT"
    -display none
    -no-reboot
  )
}

start_guest() {
  local stage="$1"; shift
  local sock="$RUN/$stage.sock"
  local log="$LOGS/$stage.log"
  local script="$1"; shift

  rm -f "$sock"
  : >"$log"

  build_qemu_common
  local cmd=("${qemu_common[@]}" -serial "unix:$sock,server=on,wait=off" "$@")

  printf '%s\n' "${cmd[*]}" >"$LOGS/$stage.cmdline"
  setsid nohup "${cmd[@]}" >"$LOGS/$stage.qemu.log" 2>&1 &
  echo $! >"$RUN/$stage.qemu.pid"
  say "qemu pid $(cat "$RUN/$stage.qemu.pid"), serial socket $sock"

  setsid nohup python3 "$HERE/console.py" "$sock" "$log" "$script" \
    >"$LOGS/$stage.console.log" 2>&1 &
  echo $! >"$RUN/$stage.console.pid"
  say "console driver pid $(cat "$RUN/$stage.console.pid"); log $log"
}

# --------------------------------------------------------------- install ----
cmd_install() {
  cmd_prepare
  cmd_serve
  start_guest install "$HERE/expect-install.txt" \
    -kernel "$WORK/arch/boot/ppc64le/vmlinuz-linux-4k" \
    -initrd "$WORK/arch/boot/ppc64le/initramfs-linux-4k.img" \
    -append "console=hvc0 loglevel=4 copytoram=n archisobasedir=arch archisolabel=$ISO_LABEL" \
    -drive "id=live,file=$ISO,format=raw,if=none,readonly=on" \
    -device virtio-blk-pci,bus=pcie.0,drive=live \
    -drive "id=payload,file=$IMAGES/payload.iso,format=raw,if=none,readonly=on" \
    -device virtio-blk-pci,bus=pcie.1,drive=payload \
    -drive "id=target,file=$IMAGES/target.qcow2,format=qcow2,if=none" \
    -device virtio-blk-pci,bus=pcie.2,drive=target,serial=omptarget \
    -netdev user,id=net0 -device virtio-net-pci,bus=pcie.3,netdev=net0
}

# ------------------------------------------------------------------ boot ----
# The stage the whole exercise exists for: nothing but the installed disk and
# petitboot. If an entry appears and it kexecs, the generated grub.cfg is real.
cmd_boot() {
  [[ -f $SKIROOT ]] || die "no skiroot/petitboot payload at $SKIROOT (see extract-skiroot.sh)"
  start_guest boot "$HERE/expect-boot.txt" \
    -kernel "$SKIROOT" \
    -drive "id=target,file=$IMAGES/target.qcow2,format=qcow2,if=none" \
    -device virtio-blk-pci,bus=pcie.0,drive=target,serial=omptarget
}

# --------------------------------------------------------------- control ----
cmd_status() {
  local p
  for p in "$RUN"/*.pid; do
    [[ -e $p ]] || continue
    if kill -0 "$(cat "$p")" 2>/dev/null; then
      echo "running  $(basename "$p" .pid)  pid $(cat "$p")"
    else
      echo "stopped  $(basename "$p" .pid)"
    fi
  done
  ls -la "$LOGS" 2>/dev/null || true
}

cmd_stop() {
  local p
  for p in "$RUN"/*.pid; do
    [[ -e $p ]] || continue
    kill "$(cat "$p")" 2>/dev/null || true
    rm -f "$p"
  done
  say "stopped"
}

cmd_tail() { tail -f "$LOGS/${1:-install}.log"; }

cmd_clean() {
  cmd_stop
  rm -rf "$IMAGES" "$LOGS" "$RUN" "$WORK/payload"
  say "cleaned (kept $WORK/arch and $WORK/skiroot)"
}

case "${1:-}" in
  prepare) cmd_prepare ;;
  serve) cmd_serve ;;
  install) cmd_install ;;
  boot) cmd_boot ;;
  status) cmd_status ;;
  stop) cmd_stop ;;
  tail) shift; cmd_tail "${1:-install}" ;;
  clean) cmd_clean ;;
  *) sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 1 ;;
esac
