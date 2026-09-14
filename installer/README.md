# `installer/` — Omarchy's install flow, forked for POWER9

This is Omarchy's installer with **four substitutions**. It is not a rewrite:
partitioning, `mkfs`, `pacstrap`, `genfstab`, the account step, the package
manifest and the whole post-install configuration layer are upstream's, carried
over and called by name from `/usr/share/omarchy/install/`. When upstream moves,
the delta you have to re-review is what is in this file.

Upstream reference: `../upstream/omarchy/` at `49306774` (4.0.0.alpha).
Design it implements: `~/Development/powerpc64le-handbook/docs/power9-distro-spin.md`,
§2.4 (boot chain), §5.5 (installer), §6 (repo).

```
p9-install                  the installer
lib/common.sh               logging, guards, dry-run plumbing
lib/disk.sh                 enumeration, the destructive-write guard, partitioning
lib/target.sh               everything inside /mnt after pacstrap
bin/p9-petitboot-entry      substitution 1 -- writes /boot/grub/grub.cfg
share/omarchy-p9-hooks.conf substitution 3 -- the mkinitcpio drop-in
share/pacman.conf.in        substitution 4 -- the repository layout
share/p9-base.packages      the manifest
share/p9-clipped.packages   what was dropped from upstream's manifests, with reasons
firstboot/                  the configuration layer, moved to the target's first boot
test/                       a QEMU powernv9 rig that actually runs all of it
```

---

## The four substitutions

### 1. Bootloader — limine → a `grub.cfg` petitboot parses

Upstream installs `limine`, writes `default/limine/limine.conf`, and drives it
through `limine-entry-tool` and `limine-snapper-sync`.

POWER9 boots OpenBMC → hostboot/skiboot → skiroot Linux + **petitboot**, all of
it in flash. There is no bootloader to install and nothing is written to a boot
sector. Petitboot's `pb-discover` mounts every block device it can and looks for
`/boot/grub/grub.cfg` (among 17 paths) relative to each partition root, parses
it with its own grub2 grammar, and `kexec`s what it names.

So the boot install step is **one file**, written by `bin/p9-petitboot-entry`:

```
### BEGIN petitboot-entry ###
menuentry 'Omarchy POWER9 (linux-power9)' {
    search --set=root --fs-uuid <boot-uuid>
    linux /vmlinuz-linux-power9 root=UUID=<root-uuid> rootflags=subvol=@ rw loglevel=3
    initrd /initramfs-linux-power9.img
}
### END petitboot-entry ###
```

Four things about that block are deliberate:

* **Only the intersection grammar.** `menuentry`, `set`, `search --set=root
  --fs-uuid`, `linux`, `initrd`. Petitboot implements a subset of GRUB and
  ignores `insmod`/`echo`/`export`; `search --file` it does **not** implement.
  Staying in the intersection means the same file also boots under real GRUB on
  pSeries/QEMU, which is what makes the pSeries path cheap.
* **Partition-relative paths.** `/boot` is its own partition, so the kernel is
  `/vmlinuz-…`, never `/boot/vmlinuz-…`.
* **`grub-mkconfig` is not used.** Its `powerpc-ieee1275` output is full of
  `insmod`, `load_video`, `gfxpayload` and `if` blocks — outside the
  intersection — and it clobbers the whole file. This machine's
  `/boot/grub/grub.cfg` is hand-maintained.
* **Marker-block editing.** Everything outside `### BEGIN/END petitboot-entry ###`
  survives byte-for-byte. The script refuses to run when `/boot` is not a mount
  point, which is the classic "wrote the kernel into the root filesystem's /boot
  directory" failure.

A pacman hook at `/etc/pacman.d/hooks/95-petitboot-entry.hook` re-runs it after
`mkinitcpio`, so kernel upgrades keep the entries current. The design assigns
that hook to the future `linux-power9` package; this one is named identically so
the package's copy in `/usr/share/libalpm/hooks` is shadowed rather than
duplicated, and both scripts are idempotent anyway.

**Gone with limine, and worth saying out loud:** there are **no bootable
snapshots**. Upstream gets them from `limine-snapper-sync`. Rolling back here
means restoring the subvolume from a live medium and re-running
`p9-petitboot-entry`. Emitting one `menuentry` per snapshot with
`rootflags=subvol=<snapshot>` is grammatically possible and is *not* in this
installer because nobody has tested it.

`snapper` itself is demoted from a base package to an optional one: it was in
the base set to feed limine, and it is a perfectly good btrfs tool without it.

### 2. Kernel — `linux` → `$P9_KERNEL_PKG`, default `linux-power9`

Upstream pacstraps stock `linux`. This spin wants the user's own kernel: 7.2.2
built from `~/Development/linux-7.2.2` with three local patches (two AMD
Promontory xHCI quirks, one powerpc `exit_result` fix), `CONFIG_POWER9_CPU=y`,
4K pages, `NR_CPUS=176`.

**That package does not exist yet.** The kernel is currently hand-installed
(`cp vmlinux /boot/vmlinuz-power9`, `make modules_install`, a manual
`mkinitcpio -k`). So the kernel package name is a **variable**, `--kernel` /
`$P9_KERNEL_PKG`, defaulting to `linux-power9`.

What the installer expects of whatever you name:

* an **Arch-shaped kernel package**: it installs
  `/usr/lib/modules/<release>/vmlinuz` and, next to it, a `pkgbase` file
  containing the package name. mkinitcpio's own pacman hook keys *everything* on
  that `pkgbase` file — a module directory without one is skipped silently,
  which is exactly why the hand-installed 7.2.2 never got an automatic
  initramfs, and why `p9-petitboot-entry` iterates `/usr/lib/modules/*/pkgbase`
  rather than globbing `/boot`.
* it must therefore produce `/boot/vmlinuz-<pkgbase>` and, after `mkinitcpio -P`,
  `/boot/initramfs-<pkgbase>.img`. Those are the names the boot entry uses, and
  the installer fails if either is missing.
* `<pkgbase>-headers` is desirable, not required.

For bring-up against Arch POWER's own kernels: `--kernel linux-4k` (4K pages,
matching the AC922 config) or `--kernel linux` (64K). The QEMU test uses
`linux-4k`.

### 3. mkinitcpio — the one that has to be right

Upstream ships `etc/mkinitcpio.conf.d/omarchy_hooks.conf`, which replaces
`HOOKS` **wholesale**:

```
HOOKS=(base udev plymouth keyboard autodetect microcode modconf kms keymap
       consolefont block encrypt filesystems fsck btrfs-overlayfs)
```

On this platform `mkinitcpio -P` against that array fails outright:

| Entry | Why it fails or is wrong here |
|---|---|
| `btrfs-overlayfs` | provided only by `limine-mkinitcpio-hook`. No limine on ppc64le → no `/usr/lib/initcpio/install/btrfs-overlayfs` → error |
| `plymouth` | its initcpio hook ships with plymouth and is named unconditionally |
| `microcode` | x86 CPU microcode; meaningless on POWER9 |
| `udev` (not `systemd`) | converts a working *systemd* initramfs into a busybox one — a whole-boot-path change, and `sd-vconsole` has no busybox equivalent configured here |

The ppc64le `omarchy-settings` package already deletes that file. This installer
supplies `share/omarchy-p9-hooks.conf` in its place (and removes upstream's if a
future version reintroduces it):

```
MODULES+=(nvme? nvme_core? ext4? btrfs? virtio_blk? virtio_pci? virtio_scsi? amdgpu?)
HOOKS=(base systemd autodetect modconf kms keyboard keymap sd-vconsole block filesystems fsck)
```

The `HOOKS` array is not invented: it is the one measured working on the AC922
today. `/boot` is ext4 because petitboot must read it, `/` is btrfs, and both
are covered by `filesystems` plus the explicit modules.

**The trailing `?` is load-bearing.** mkinitcpio's `add_module()` counts a
module as found only when `modinfo` reports a `filename:` that looks like a
path. A module compiled *into* the kernel reports `filename: (builtin)`, so a
bare name errors with `module not found: 'btrfs'`. The user's 7.2.2 config has
`CONFIG_BLK_DEV_NVME=y`, `CONFIG_EXT4_FS=y` and `CONFIG_BTRFS_FS=y` — all
builtin — while Arch POWER's stock `linux` ships all three as `.ko`. `name?`
makes one file correct for both. (Verified on the box:
`modinfo -k 7.2.2 btrfs` → `filename: (builtin)`;
`modinfo -k 7.1.5-1 nvme` → a real `.ko` path.)

Side finding, not fixed by this installer because `$HOME` and `/etc` are
off-limits: the live machine's `/etc/mkinitcpio.conf` says
`MODULES=(amdgpu btrfs)` without the `?`, and `btrfs` is builtin in its running
kernel — so `mkinitcpio -k 7.2.2` there is already in the failing case.

`encrypt`/`sd-encrypt` are deliberately absent: petitboot cannot read an
encrypted `/boot`, so LUKS-on-`/` is possible later but is not wired up, and the
LUKS re-key branch of Omarchy's first-boot provisioning therefore never fires
(it is gated on a staged key file this installer does not create).

### 4. Repo — `pkgs.omarchy.org` → the local `[power9]` over Arch POWER

Upstream's `install/post-install/pacman.sh` copies
`default/pacman/pacman-stable.conf` and `mirrorlist-stable` over `/etc`,
repointing the machine at `pkgs.omarchy.org`. That archive publishes `x86_64`
and `aarch64`. On `powerpc64le` this step does not switch channels, it removes
the only working package source. It is not run, at install time or at first
boot; `firstboot/config/pacman.sh` documents that in place of it.

What is written instead (`share/pacman.conf.in`) is the design's overlay: Arch
POWER stays the base distribution and the project's own repository is listed
**ahead** of it, so repo order does the overriding and nothing in `[base]` has
to be rebuilt.

```
[power9]                                   ← --repo-name / --repo-server
[base-any]  https://repo.archlinuxpower.org/base/any
[base]      https://repo.archlinuxpower.org/base/$arch
```

**`SigLevel` is an explicit decision, not a default.** There is no signing key
for `[power9]` yet (`gpg` on the build host has no secret key), so:

* `--repo-siglevel required` — the design's target state. Fails until the repo
  is signed and a `power9-keyring` is trusted.
* `--repo-siglevel optional-trustall` — `PackageNever DatabaseOptional TrustAll`. Installs unsigned
  packages without verification, and pacman never requests `.sig` files. That
  part is load-bearing: the public repo is served from Cloudflare R2, which
  answers a missing `.sig` with a 27 KB 404 page, over pacman's 16 KiB
  signature limit, and plain `Optional` then aborts the whole transaction.
  The stopgap until the repo is signed.

`p9-install` **refuses to start** without one of them, and prints a warning when
`TrustAll` is chosen. Nothing here quietly turns verification off.

The repository *name* and *server* are variables too, because the design's
target layout (`repo/power9/os/$arch`, db `power9.db`) is not what is on disk
today (`repo/`, db `omarchy-ppc64le.db`). `--repo-name omarchy-ppc64le
--repo-server http://…` works against the current tree; the defaults are the
design's.

---

## Carried over unchanged

* **Partitioning and filesystems.** GPT, an ext4 `/boot`, btrfs `/` with
  `@ @home @log @pkg`, `compress=zstd,discard=async`. The only POWER-specific
  parts are that `/boot` *must* be a separate partition petitboot can read, and
  the 8 MiB PReP partition on pSeries.
* **`pacstrap` / `genfstab` / `arch-chroot`.** `arch-install-scripts`, as the
  design specifies. `archinstall` is not in Arch POWER and has no petitboot
  notion.
* **The account step.** By default `p9-install` creates no user: it arms
  `/var/lib/omarchy/provisioning/pending` and enables upstream's own
  `omarchy-provision-owner.service`, so Omarchy's setup form — keyboard,
  username, password, full name, hostname, timezone, all of
  `install/provisioning/setup-form.sh` — runs on the target's tty1 at first
  boot, unmodified. That is upstream's `--defer-provisioning` path, and it is
  the only way those scripts ever run on ppc64le hardware without running them
  on the build host (`RULES.md` §1). `--user NAME` gives the ordinary
  create-it-now shape instead.
* **The configuration layer**, script by script — see below.
* **The package manifest**, as a projection of `omarchy-base.packages` and the
  applicable rows of `omarchy-other.packages`.

## The configuration layer, moved to first boot

Upstream runs `omarchy-apply-system` inside the target chroot at ISO
finalization. Here `firstboot/p9-firstboot` runs the same work on the target's
own first boot, ordered `Before=omarchy-provision-owner.service` and
`Before=display-manager.service`.

It sources upstream's leaves by name out of `/usr/share/omarchy/install/`:

| Upstream | Here |
|---|---|
| `config/theme-system.sh`, `browser-policy.sh`, `increase-lockout-limit.sh`, `lockscreen-pam.sh`, `fix-powerprofilesctl-shebang.sh`, `ssh-command-path.sh`, `ssh-keepalive.sh`, `docker.sh`, `locate.sh`, `firewall.sh` | run as-is |
| `config/enable-services.sh` | replaced: same units, same order, but each `systemctl enable` is independent so one absent unit cannot abort the rest while the package set is still being back-filled |
| `config/snapper.sh` | replaced by `config/snapshots.sh`: snapper optional, `limine-snapper-sync.service` not enabled |
| `hardware/all.sh` (38 leaves) | replaced by `config/hardware.sh`: keeps `network.sh`, `bluetooth.sh`, `set-wireless-regdom.sh` and the reporting half of `vulkan.sh` / `speaker-tuning.sh`. The other 30 are Intel / NVIDIA / Apple T2 / Dell / Framework / ASUS / Tuxedo / Lenovo quirks, plus a Panther Lake kernel swap. `hardware/pacman.sh` adds the `arch-mact2` repo with `SigLevel = Never`; not carried over |
| `login/sddm.sh`, `post-install/udev.sh`, `post-install/localdb.sh` | run as-is |
| `post-install/pacman.sh` | replaced — substitution 4 |

Two differences in *how* they run:

* **Failure is isolated.** `omarchy-apply-system` sources `all.sh` under
  `set -e`, so one failing leaf takes the whole run down. On a first boot that
  would leave a machine with no configuration and — in the deferred case — no
  user account. Here every step runs in its own `bash -eE` child; failures are
  logged to `/var/log/p9-firstboot.log`, named in a summary, and stepped over.
* **`vulkan-radeon` and `lsp-plugins-lv2` are in the manifest** rather than
  installed by `omarchy-pkg-add` at first boot, because a fresh target may have
  no network.

### `/etc` overrides

`omarchy-settings` ships `/usr/share/omarchy/etc-overrides/` (os-release,
nsswitch.conf, faillock.conf, plymouthd.conf, `/etc/skel/.bashrc`, two CUPS
files). Upstream applies them from an `.INSTALL` scriptlet that runs on **every
install and upgrade**, `rm -f` then `cp -f`; its own comment calls this
"intentionally destructive". That scriptlet was removed from the ppc64le
package because the build host is an existing Arch workstation, and **it is not
reintroduced here** — not as a scriptlet, not as a pacman hook. Neither is
`00-omarchy-update-guard.hook`, which aborts every `pacman -Syu` in favour of
`omarchy update`, a command that needs the Omarchy channel this architecture
does not have.

A machine that came out of `p9-install`, however, *is* an Omarchy install, so
the overrides are correct there. `firstboot/config/etc-overrides.sh` applies
them **once**, from the first-boot service, from a list in
`/etc/omarchy-p9.conf` — so it is a visible decision and a later upgrade never
silently rewrites a file the operator has since edited.

`os-release` is **held out of that list by default**: this spin is Arch POWER
with Omarchy on top, and `/etc/os-release` is what pacman tooling, bug reports
and half the desktop read to decide what they are running. Add it to
`P9_ETC_OVERRIDES` if you disagree; the file is shipped either way.

---

## Things in Omarchy's flow with no sensible ppc64le equivalent

| Upstream | Why there is nothing to port |
|---|---|
| limine + `limine-entry-tool` + `limine-snapper-sync` + `default/limine/limine.conf` | the bootloader is in firmware. Not a missing port — the wrong component |
| Bootable snapper snapshots | a consequence of the above |
| `install/hardware/{intel,apple,asus,framework,lenovo}/**`, `nvidia.sh`, `dell-*`, `surface.sh`, `fix-tuxedo-backlight.sh`, `fix-yt6801-*`, `fix-bcm43xx.sh`, `fix-fkeys.sh`, `fix-synaptic-touchpad.sh` | x86 laptop hardware. An AC922 or a Raptor board has none of it |
| `hardware/pacman.sh` (`arch-mact2`) | an Apple T2 package mirror |
| `lib32-*` | no multilib on ppc64le |
| `microcode` (hook and packages) | x86 CPU microcode |
| `obsidian`, `localsend` | Electron and Flutter; no ppc64le target. FEX is the escape hatch |
| `pinta` | needs .NET 10; Arch POWER is on .NET 9 |
| `mise-bin` | a prebuilt x86_64 tarball. Replaced by `mise` built from source |
| `install/user/mise-work.sh`'s Node bootstrap | it globs `node-v*-linux-**x64**.tar.gz`. Node does publish `linux-ppc64le` tarballs, so an ISO could bundle one, but the glob would not find it. Left alone: it warns and falls back to `mise use -g node@latest` over the network. **This is the one place upstream's user-side code is knowingly wrong for this architecture and has not been patched.** |

---

## Testing — what has actually been run

`test/` boots a real OPAL machine model under QEMU (`-machine powernv9`, TCG —
KVM cannot host a PowerNV guest) and runs the installer in it. See
`test/README.md` for how, and for the rig's own gotchas.

**Both stages pass.** With a minimal package set (`base mkinitcpio libxkbcommon
btrfs-progs e2fsprogs` + `--kernel linux-4k`), on a blank 20 GiB virtual disk:

*Stage 1 — install.* Arch POWER's live ISO under OPAL; `p9-install` resolves
145 packages against `[power9]` (served over HTTP from this project's `repo/`)
plus Arch POWER `[base]`; refuses everything but the disk whose virtio serial
matches `--serial`; partitions; `mkfs`; reads the UUIDs back; `pacstrap`s;
writes fstab; installs the mkinitcpio drop-in and rebuilds the initramfs
cleanly; writes the boot entry; stages the first-boot layer. Exit 0, with
`/boot/grub/grub.cfg`, `/etc/fstab`, `/etc/mkinitcpio.conf.d/omarchy-p9-hooks.conf`
and the enabled `p9-firstboot.service` read back off the disk afterwards.

*Stage 2 — boot.* Nothing attached but the installed disk, and the payload
skiboot jumps to is **petitboot 1.15 taken out of the AC922's own PNOR backup**
(`test/extract-skiroot.sh`). Serial log, condensed:

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
p9test login:
```

So the generated `grub.cfg` is parsed by the real petitboot, the entry is
offered by name, the kernel and initramfs are found by partition-relative path
on the ext4 `/boot`, and the initramfs built from
`share/omarchy-p9-hooks.conf` mounts the btrfs `subvol=@` root and reaches a
login prompt. That is the whole boot chain, end to end.

### Three real bugs the guest run found that reading could not

1. **`mkinitcpio -P` failed on a minimal target**: Arch POWER's `kbd` 2.10.0-1
   links `loadkeys` against `libxkbcommon.so.0` but does not declare the
   dependency, so `sd-vconsole` aborted the build. Invisible on a full Omarchy
   install, where Hyprland drags libxkbcommon in anyway. `libxkbcommon` is now
   an explicit manifest entry with the reason attached.
2. **`pacman -Sy` against a `mktemp -d` root fails** with
   `could not open file …/<repo>.db.part: Permission denied` — `DownloadUser =
   alpm` cannot traverse a 0700 root-owned directory. The resolve step now
   chmods its throwaway root.
3. **`/etc/sudoers.d` may not exist** on a target where `sudo` is not
   installed; the wheel grant used a bare redirect and died *after* the disk was
   partitioned and pacstrapped. It is an `install -D` now.

### What remains untested

* **Real hardware.** Nothing here has been run on the AC922. `RULES.md` §1
  forbids it, there is no `sudo`, and the machine is a daily driver.
* **`linux-power9`.** The package does not exist, so the default `--kernel` has
  never been exercised. The rig used `linux-4k`; what the installer asks of a
  kernel package is written down above and is what Arch's own packaging does.
* **The real manifest.** `share/p9-base.packages` cannot resolve today: the
  Omarchy packages (`omarchy`, `omarchy-settings`, `aether`, `yay`, `mise` and
  Omarchy's ten own-repo packages) are not published in a repository yet. The
  resolve step is written so that this failure names them; that list is the
  remaining packaging work.
* **The first-boot layer.** It is staged and its unit is enabled, but it has
  never run: it needs the Omarchy packages to be installed to have anything to
  configure. The pieces it drives are upstream's own scripts, sourced by name.
* **Deferred provisioning.** `--user` was used in the rig because the account
  wizard needs the `omarchy` package. Upstream's `omarchy-provision-owner` is
  armed and enabled by the installer but has not been watched running.
* **pSeries.** The PReP partition and `grub-install --target=powerpc-ieee1275`
  path is written and never executed.
* **`snapper`, plymouth, SDDM, the desktop.** Out of the minimal set.

One more guard, added after `--list-disks` was run on the AC922 for the first
time: `lsblk -d` reports the machine's five **`mtdblock` devices as `disk`**,
right beside the NVMe drives. On an OpenPOWER machine those are the firmware
flash — PNOR (hostboot, skiboot, petitboot) and the BMC image — and `sgdisk`
would write a GPT over one without complaint. `mtd*` is refused by name, along
with `loop/ram/zram/sr/dm/md`, and they are filtered out of `--list-disks`. (That guard and the `--list-disks`
rewrite landed after the guest runs above; they change enumeration and the
`--dry-run` ordering, not the install path, and were checked separately on the
host — `--disk /dev/mtdblock0` is refused, `--list-disks` shows only the three
NVMe drives.)

Static checking on the build host is `bash -n` plus `p9-install --dry-run`,
which prints every command and writes nothing (the read-only disk guard still
runs, so it needs a device that exists). `--dry-run` as a non-root user
cannot do the package-resolution step (pacman needs root even with `-r`) and
says so rather than pretending.
