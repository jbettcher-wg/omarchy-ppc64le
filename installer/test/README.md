# `installer/test/` — a QEMU rig that actually runs the installer

Static checking cannot tell you whether an installer works. What this rig
exercises, and nothing else can:

* partitioning and `mkfs` against a real block device
* `pacstrap` into it, with the substituted `pacman.conf`
* `mkinitcpio -P` producing an initramfs that **boots** — the substitution most
  likely to be silently wrong
* the generated `/boot/grub/grub.cfg` being something **petitboot genuinely
  parses**, on ext4 `/boot` with btrfs `/`

## Why `powernv9`, and why TCG

`-machine powernv9` is the real boot path: OPAL (skiboot) exactly as an AC922
runs it, and — with a BOOTKERNEL payload — petitboot itself. `pseries` would
only approximate it, with GRUB on a PReP partition instead.

There is no KVM here, and that is not a configuration mistake:

* PowerNV means the guest runs in **hypervisor mode**, which KVM-HV cannot
  delegate, so `powernv9,accel=kvm` is refused outright.
* `pseries,accel=kvm` also fails on this host: that KVM implementation wants 64K
  guest pages and the host kernel is 4K.

So the guest is fully emulated and slow. An installer test is I/O and shell
logic rather than compute, so slow is acceptable — but keep the package set
small. `guest/omp-test.packages` is `base mkinitcpio btrfs-progs e2fsprogs`, not
the 674-package closure. The point is the mechanism, not the manifest.

## Layout

```
run-guest.sh          the runner: prepare / serve / install / boot / tail / stop / clean
console.py            drives the guest over its serial socket (expect-style)
expect-install.txt    stage 1 script
expect-boot.txt       stage 2 script
guest/run-install.sh  what runs inside the guest
guest/omp-test.packages
extract-skiroot.sh    pulls petitboot out of a PNOR firmware backup
work/                 extracted ISO kernel, payload staging, skiroot   (gitignored)
images/               target.qcow2, payload.iso                        (gitignored)
logs/                 serial logs                                      (gitignored)
```

Everything is inside the project. Nothing is installed on the host; the only
host process the rig starts besides QEMU is `python3 -m http.server` over
`../../repo`, bound to loopback, which the guest reaches as `10.0.2.2` through
QEMU's user network.

## Running it

```
./run-guest.sh install       # boot the live ISO, run omp-install on a blank disk
./run-guest.sh tail install  # watch
./run-guest.sh status
./run-guest.sh stop

./extract-skiroot.sh         # once: get a petitboot payload
./run-guest.sh boot          # boot the installed disk through petitboot
./run-guest.sh tail boot
```

## Result

Both stages pass. Stage 2's serial log, condensed:

```
Petitboot (v1.15)
[vda1] Processing new Disk device
Parsed GRUB configuration from /grub/grub.cfg
Booting in 10 sec: [vda1] Omarchy POWER9 (linux-4k)
  [Disk: vda1 / 61af3ef3-05f0-40ee-b5df-b2b7595b17d9]
Loaded initrd from file:///var/petitboot/mnt/dev/vda1/initramfs-linux-4k.img
kernel image from file:///var/petitboot/mnt/dev/vda1/vmlinuz-linux-4k
Running boot hooks / Performing kexec load / booting...
...
Arch POWER 7.1.4-1-4k (hvc0)
omptest login:
```

The petitboot doing the parsing is 1.15 out of the AC922's own PNOR backup, not
a stand-in. `logs/boot-verified.log` keeps that run.

## Things this rig taught us the hard way

* **Every PCI device needs an explicit `bus=pcie.N`.** QEMU's `powernv9` gives
  each of its six PHB4s a root port whose secondary bus holds exactly one
  device. Without `bus=`, several `-device` lines land where only the first is
  enumerated and the rest silently do not exist in the guest — `lsblk` shows one
  disk and no error is printed anywhere.
* **The console echoes what you type.** `send '... echo MARKER'` followed by
  `expect MARKER` matches the echo, not the result, so a failed command reads as
  a success. Every marker in `expect-install.txt` differs from the text that
  produced it.
* **`copytoram=n`.** archiso otherwise copies 633 MB of squashfs into a tmpfs
  before it starts, which is both slow under TCG and a large bite out of guest
  RAM.
* Root on the Arch POWER ISO has an empty password, and the autologin drop-in is
  `getty@tty1` only — a serial console gets a normal `archiso login:` prompt, so
  the script types `root`.
* **`pacman -Sy` against a `mktemp -d` root fails.** `DownloadUser = alpm` drops
  privileges for the transfer and cannot traverse a 0700 root-owned directory:
  `could not open file …/<repo>.db.part: Permission denied`, on a repository that
  `curl` fetches fine. `lib/target.sh` chmods the throwaway root to 0755.
* **`pacman -Sy` also needs root even with `-r`.** So `--dry-run` on the build
  host checks everything except package resolution, and says so.

### A real bug it found, outside this installer

Arch POWER's **`kbd` 2.10.0-1 links `/usr/bin/loadkeys` against
`libxkbcommon.so.0` but its `depends=` still lists only `glibc gzip pam`.**
mkinitcpio's `sd-vconsole` hook pulls `loadkeys` in, so on a target where
nothing else drags `libxkbcommon` in, `mkinitcpio -P` fails with

```
==> ERROR: binary dependency 'libxkbcommon.so.0' not found for 'loadkeys'
```

and the machine gets no initramfs. Invisible on a full Omarchy install (Hyprland
pulls libxkbcommon in anyway) and invisible to any amount of reading. The
manifest now lists `libxkbcommon` explicitly, with a comment saying the line can
go once `kbd` is fixed.
