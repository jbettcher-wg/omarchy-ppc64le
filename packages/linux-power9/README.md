# `linux-power9`

There is no PKGBUILD here, and that is not an omission: the kernel ships its own
under `scripts/package/PKGBUILD` and builds packages with `make pacman-pkg`.

Built from `~/Development/linux-7.2.2` (POWER9, 4K pages, Radix MMU, amdgpu=m)
carrying four patches, all of which are separate files in `~/Development/`:

| | |
|---|---|
| `0002` | `syscall_exit_restart` returns the accumulated `exit_result` |
| `0004` | keep the seccomp/ptrace return value when a syscall is skipped — this is the chromium sandbox fix; 7.2 broke it, 7.1 was fine |
| `0005` | clear `exit_flags` before `irqentry_exit` exit work |
| `0006` | `pci_rescan_remove_lock` self-deadlock in `eeh_rmv_device()` — mainline bug since 6.17, upstreamable |

## Building

```sh
cd ~/Development/linux-7.2.2
patch -p1 < .../packages/linux-power9/0001-kbuild-let-pacman-pkg-override-CARCH.patch   # once
PACMAN_CARCH=powerpc64le \
PACMAN_PKGBASE=linux-power9 \
PACMAN_EXTRAPACKAGES="headers api-headers" \
PKGDEST=~/Development/omarchy-ppc64le/repo \
make pacman-pkg -j"$(nproc)"
```

Three things there are load-bearing:

**`PACMAN_CARCH`** needs the patch in this directory. `scripts/Makefile.package`
hardcodes `CARCH="$(UTS_MACHINE)"`, which is `ppc64le` — the kernel's name for
the architecture. Arch POWER tags packages `powerpc64le`, and pacman refuses the
mismatch outright with `ALPM_ERR_PKG_INVALID_ARCH`. Overriding `UTS_MACHINE`
instead would change the kernel's own `uname -m` and force a relink.

**`PACMAN_PKGBASE`** or it names itself `linux-upstream`. The name matters beyond
cosmetics: the package writes `/usr/lib/modules/<release>/pkgbase` containing it,
and mkinitcpio's pacman hook keys on that file to produce
`/boot/vmlinuz-linux-power9` and `/boot/initramfs-linux-power9.img`, which is
what `p9-petitboot-entry` writes boot entries for.

**`PACMAN_EXTRAPACKAGES`** drops the default `debug` split — vmlinux with full
symbols, large and not wanted on an install medium.

## Note on `btrfs`

This config has `CONFIG_BTRFS_FS=y`, so there is no `btrfs.ko` in the package and
`modinfo btrfs` reports `filename: (builtin)`. That is why
`installer/share/omarchy-p9-hooks.conf` writes `btrfs?` with the question mark —
a bare name makes `mkinitcpio` fail with "module not found". Arch POWER's stock
`linux` ships it as a real module, and the `?` makes one file correct for both.
