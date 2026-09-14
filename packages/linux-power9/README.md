# `linux-power9`

The POWER9 kernel, as a recipe. `PKGBUILD` here builds **both** kernels that
this distro ships:

| `_pagesize` | pkgbase | pkgver | splits |
|---|---|---|---|
| `4k` (default) | `linux-power9` | `7.2.6` | `-headers`, `-api-headers` |
| `64k` | `linux-power9-64k` | `7.2.6_64k` | `-headers` |

Everything it is made of is a tracked file in this directory: mainline
`linux-7.2.6.tar.xz` from kernel.org (by sha256), eight patches, and the two
configs. Nothing is taken from a working tree any more.

7.2.6 (pkgrel 1) moved from 7.2.2 and turned on **Rust** for the first time on
powerpc, for NVIDIA's `nova-core`/`drm-nova`; see patch `0008` and
"Rust, Nova and Nouveau" below. The history section that follows describes
the 7.2.2 move into this recipe and is kept as written.

## What changed, and why

Until now this was the one package in `packages/` that could not be rebuilt
from the repo. It was built by hand with `make pacman-pkg` out of
`~/Development/linux-7.2.2` and `~/Development/linux-7.2.2-64k`, the patches
were loose files in `~/Development/`, and **the config was tracked nowhere at
all** — it existed only as `.config` inside those two trees. A lost home
directory, or one `make mrproper`, and the hand-set options below were gone
with no way to reconstruct them. RULES.md §3 says the recipes are the asset;
this directory now holds one.

The old flow's `0001-kbuild-let-pacman-pkg-override-CARCH.patch` is gone —
see "The CARCH patch" below.

Verified before the switch: the two working trees are byte-identical to
`linux-7.2.2.tar.xz` plus these seven patches (a full `diff -rq` of both trees
against a patched pristine extract shows nothing but `scripts/Makefile.package`,
which is the CARCH patch), and the `.config` each one carried is byte-identical
to `config.4k` / `config.64k` here.

## The patches

Applied in the order they are listed in `source=()`; 0003 edits the block 0001
adds, and 0005 edits the function 0002 changes, so the order is load-bearing.

| | what it fixes | disposition |
|---|---|---|
| `0001` | xHCI on the AMD Promontory-19 (`1022:43fc`, the B650 card in PHB 0030) sets AC64 in HCCPARAMS1 but drops the high bits of the 64-bit DMA addresses it is given. The powernv IOMMU bypass window is based at bit 59, so every DMA lands somewhere else and the PHB freezes the PE. `XHCI_NO_64BIT_SUPPORT` keeps it on the 32-bit TCE window. | hardware quirk, upstreamable |
| `0002` | `syscall_exit_restart()` returned only what the restart added instead of the accumulated `regs->exit_result`. The asm uses that value to pick between a full GPR restore and the fast path that zeroes r4–r12, so dropping the `_TIF_RESTOREALL` that `start_thread()` set zeroes the ELFv2 entry point in r12. | powerpc bug, upstreamable |
| `0003` | The same xHCI also prefetches TRBs past the end of a ring segment. Harmless where the next page happens to be mapped; on powernv the TCE window ends exactly at the segment and the unattributable inbound read fences the PHB. `XHCI_TRB_OVERFETCH`. | hardware quirk, upstreamable |
| `0004` | When a syscall is skipped (seccomp `RET_ERRNO`/`_TRAP`/`_TRACE`, `PTRACE_SYSEMU`, tracer rejection) powerpc took the return value from r3 but the generic code had already stored it in `pt_regs`, so every `SECCOMP_RET_ERRNO` came back as `ENOSYS`. **This is the chromium sandbox fix** — 7.2 broke it, 7.1 was fine. | powerpc bug, upstreamable |
| `0005` | Clear `exit_flags` in `arch_interrupt_exit_prepare()` rather than in `interrupt_exit_user_prepare()`, so flags set by the exit work `irqentry_exit()` runs (`arch_do_signal_or_restart()` → `_TIF_RESTOREALL`) survive to be read. Mirrors `syscall_exit_prepare()`. Pairs with 0002. | powerpc bug, upstreamable |
| `0006` | `eeh_rmv_device()` takes `pci_rescan_remove_lock`, but every caller already holds it since 1010b4c012b0. The first PE reset involving a device whose driver has no EEH error handlers (xhci_hcd, ahci, …) deadlocks `eehd` against itself, and because the global lock is never released all later PCI hotplug/rescan/remove blocks too. | mainline bug since 6.17, upstreamable |
| `0007` | `add_pages()` grows `max_pfn` for ZONE_DEVICE ranges, which are not RAM. `dma_direct_get_required_mask()` reads `max_pfn`, so once amdgpu registers device-private memory for KFD SVM, `dma_go_direct()` starts refusing the powernv pseudo-bypass and mappings silently go through a software `iommu_table` the hardware is no longer consulting — DMA to unrelated RAM, no fault. Only reachable with 64K pages (with 4K the registration fails on the linear-map range), so this is what makes **ROCm safe on the 64K kernel**. | mm/powerpc bug, upstreamable |

| `0008` | Enables Rust on 64-bit little-endian powerpc. Mainline 7.2 selects `HAVE_RUST` only on arm, arm64, loongarch, riscv, s390, um and x86, so `CONFIG_RUST` -- and with it `NOVA_CORE` and `DRM_NOVA` -- is not even offered. Like x86_64 it generates `scripts/target.json`: rustc's own `powerpc64le-unknown-linux-gnu` data layout and ELFv2 ABI with `-altivec,-vsx,-hard-float`, matching the C side's `-msoft-float -mno-altivec -mno-vsx`; `-Ccode-model=large` for modules to match `-mcmodel=large`; `BINDGEN_TARGET_powerpc` and the GCC-only powerpc flags libclang rejects. Written for 7.2.6 by `~/Development/kernel-rust-ppc64le.py`. | enablement, upstreamable once proven |

All seven 7.2.2 patches apply unchanged to 7.2.6 (0003 needs 0001 first, as listed).

`0006` was regenerated against pristine 7.2.2 while writing this recipe: the
loose copy applied with `fuzz 1` because its hunk header undercounted the
context by one line. The result is identical.

## The configs

`config.4k` and `config.64k` are verbatim kbuild `.config` files, copied out of
the two working trees. Keep them verbatim — kconfig rewrites the header on every
save, so a comment added here would be lost on the next refresh, which is why
the reasoning lives in this file instead.

`prepare()` copies the chosen one to `.config` and runs `make olddefconfig` —
**not** `oldconfig` (prompts) and never a bare hand edit: `olddefconfig` is what
regenerates `include/config/auto.conf`. Builds 14 and 16 shipped without
`HSA_AMD` because a hand-edited `.config` was built against a stale `auto.conf`.
The 7.2.6 configs were made from the 7.2.2 ones: `olddefconfig` against the
7.2.6 tree with the patches applied, the additions below set with
`scripts/config`, and `olddefconfig` again, then copied here verbatim.

Options in there that are not obvious and must survive any refresh:

- **`CONFIG_HSA_AMD=y`** — `/dev/kfd`, which ROCm needs for GPU compute and
  which btop reads for GPU stats.
- **`CONFIG_PPC_OF_BOOT_TRAMPOLINE=y`** — without it the kernel cannot boot
  under SLOF, i.e. as a pseries KVM guest.
- **VM guest drivers, as modules** — `DRM_VIRTIO_GPU`, `DRM_BOCHS` (QEMU
  standard VGA), `DRM_OFDRM` (the SLOF framebuffer), `VIRTIO_INPUT`,
  `HW_RANDOM_VIRTIO`. The config already had pseries, `HVC_CONSOLE` and virtio
  block/net/SCSI, so a guest booted but had no display device at all: serial
  only, and Hyprland could not start. They do nothing on bare metal.
- **The netfilter set** — `NETFILTER_ADVANCED`, `NF_TABLES`, `NFT_COMPAT`,
  `NETFILTER_XTABLES_LEGACY`, `IP_NF_IPTABLES_LEGACY` and 137 `XT_`/`NFT_`/
  `IP_NF_`/`IP6_NF_` modules. Without these **ufw and docker do not work**.
- **`CONFIG_LOCALVERSION`** — `""` for 4K, `"-64k"` for 64K. This is what makes
  the module directory `/usr/lib/modules/7.2.6-64k` and the pkgver `7.2.6_64k`.
  `prepare()` asserts `make -s kernelrelease` still matches `pkgver`, so an
  accidental edit fails the build instead of silently renaming the package.
- **`CONFIG_RUST=y`, `NOVA_CORE=m`, `DRM_NOVA=m`** -- see below.
- **`CONFIG_MODVERSIONS` is off.** `RUST` depends on `!MODVERSIONS ||
  GENDWARFKSYMS`, and `GENDWARFKSYMS` needs DWARF debug info, which these
  kernels do not build (`DEBUG_INFO_NONE=y`). The cost: out-of-tree modules
  lose symbol-CRC checking.
- **`DRM_NOUVEAU=m`** -- a working display on NVIDIA cards today (Turing and
  newer via GSP firmware from `linux-firmware-nvidia`).
- **`VFIO=m`, `VFIO_PCI=m`, `VFIO_IOMMU_SPAPR_TCE=m`** -- PCI passthrough; the
  sPAPR TCE backend is the one POWER uses.
- **`VSOCKETS=m`, `VHOST_VSOCK=m`** -- host/guest sockets for KVM.
- **Network and Wi-Fi drivers, as modules**, so installs on other POWER
  machines find their NIC: Intel `E1000E IGB IGC IXGBE I40E ICE`, Broadcom
  `BNXT TIGON3 BNX2X`, Mellanox `MLX4_EN MLX5_CORE`, Realtek `R8169`, Aquantia
  `AQTION`; Wi-Fi `IWLWIFI/IWLMVM`, MediaTek `MT7921E/U MT7925E MT76x2U`,
  Qualcomm `ATH9K ATH10K_PCI ATH11K_PCI`, Realtek `RTW88_8822CE RTW89_8852BE`,
  Broadcom `BRCMFMAC` (PCIe and USB).

The two configs differ only in the page-size block and what kconfig derives
from it: `PPC_64K_PAGES`/`PAGE_SHIFT=16`, `ARCH_FORCE_MAX_ORDER` 12 → 8, the
`ARCH_MMAP_RND_BITS` range, and three options that only become available at 64K
(`PPC_VAS=y`, `CRYPTO_DEV_NX_COMPRESS_{PSERIES,POWERNV}=m`). They are kept as
two whole files rather than a base plus a fragment because a kernel config is
not safely composable by text.

## Rust, Nova and Nouveau

Asked for by a Talos II tester with an RTX 3070.

- **Toolchain.** `makedepends` gains `rust`, `rust-src`, `rust-bindgen` (kernel
  minimum bindgen 0.71.1; ours is 0.72.1) and `clang` (bindgen needs libclang).
  `make rustavailable` passes on .24 with rustc 1.98.1.
- **The trap.** `olddefconfig` re-evaluates `RUST_IS_AVAILABLE`; if any of those
  is missing from the build environment, `CONFIG_RUST` -- and every Rust
  driver -- is dropped without an error. `prepare()` therefore fails the build
  when `.config` no longer has `CONFIG_RUST=y`.
- **What Nova is in 7.2.6.** ~13.7k lines: it identifies Turing, Ampere, Ada,
  Hopper and Blackwell GPUs and boots the GSP firmware (it asks for
  `nvidia/<chip>/gsp/*-570.144.bin`, which `linux-firmware-nvidia` ships), but
  `drm-nova` only offers GETPARAM/GEM_CREATE/GEM_INFO: no modesetting, no
  display. **Nouveau is what drives a screen**; Nova is there to test.
- Both are modules and claim the same PCI IDs, so only one binds; pick with
  `modprobe.blacklist=`.

### `btrfs` is built in

`CONFIG_BTRFS_FS=y`, so there is no `btrfs.ko` and `modinfo btrfs` reports
`filename: (builtin)`. That is why `installer/share/omarchy-p9-hooks.conf`
writes `btrfs?` with the question mark — a bare name makes `mkinitcpio` fail
with "module not found". Arch POWER's stock `linux` ships it as a real module,
and the `?` makes one file correct for both.

### `pkgbase` is load-bearing

The package writes `/usr/lib/modules/<release>/pkgbase`, and mkinitcpio's pacman
hook keys on that file to produce `/boot/vmlinuz-linux-power9` and
`/boot/initramfs-linux-power9.img` — which is what `p9-petitboot-entry` writes
boot entries for. Renaming the package renames the boot files.

## Building both

```sh
# 4K (the default)
makepkg
# 64K
_pagesize=64k makepkg
```

`_pagesize` is read from the environment with `4k` as the default so neither
build needs the file edited. Note that `bq` keys its `local` recipe source on
the **directory** name, so `bq build linux-power9` gets the 4K kernel and the
64K one has to be run by hand (or from a future `packages/linux-power9-64k/`
that symlinks these files).

`makepkg --nobuild` runs everything through `prepare()` — download, checksums,
patches, config, `olddefconfig` — without compiling, which is the cheap way to
check this recipe after a version bump.

## Versioning

`pkgrel` is now **a number in the PKGBUILD**, shared by both page sizes.

The old flow took it from kbuild's `.version` counter (`scripts/build-version`,
passed in as `KBUILD_REVISION`), which incremented on every `make` in the
working tree — which is why the 4K kernel reached `-21` and the 64K one only
`-3` for the same source. That counter does not exist for a `makepkg` build out
of a fresh tarball, and it never belonged in a package version anyway: it
counted local compiles, not recipe changes.

It starts at **22**, above the highest number the old flow ever published
(`linux-power9 7.2.2-21`), so both `7.2.2-22` and `7.2.2_64k-22` are clean
upgrades over what is deployed. `tools/repo-publish.sh` refuses to publish a
package whose version already exists in the db with different contents, so:

- **any** change to this directory — a patch, either config, the PKGBUILD —
  bumps `pkgrel` by one, for both page sizes at once;
- a new kernel version sets `_kernver`, its `sha256sum`, and resets `pkgrel=1`;
- never rebuild and republish without bumping. pacman compares versions, not
  contents, and `-Syu` will not deliver a same-version rebuild.

`KBUILD_BUILD_VERSION` is set to `pkgrel` in `build()`, so the `#22` in
`uname -v` names the package version the running kernel came from — the one
genuinely useful thing the old `.version` counter did.

## The CARCH patch

**It did not survive, and it is not needed.** It was deleted with this change
(recover it from git history if the `make pacman-pkg` flow is ever wanted
again).

`scripts/Makefile.package` hardcodes `CARCH="$(UTS_MACHINE)"` when it invokes
makepkg, and `UTS_MACHINE` is the kernel's own name for the architecture,
`ppc64le`. Arch POWER tags packages `powerpc64le`, and pacman refuses the
mismatch outright with `ALPM_ERR_PKG_INVALID_ARCH` — so `make pacman-pkg`
produced a kernel that could not be installed on the distribution that built
it. The patch added a `PACMAN_CARCH` override.

None of that applies here. This PKGBUILD is invoked by makepkg directly, it
declares `arch=(powerpc64le)` itself, and `CARCH` comes from
`/etc/makepkg.conf` (`export CARCH="powerpc64le"`). Nothing reads
`UTS_MACHINE`, and `scripts/Makefile.package` is never entered.

## Not carried over from the old flow

- **`depends=()` is empty**, as it was under `make pacman-pkg` — the in-tree
  `scripts/package/PKGBUILD` declares none, and the shipped `7.2.2-21` packages
  have none. Arch's own `linux` uses `depends=(coreutils kmod initramfs)`.
  Adding them would be an improvement, but it changes what pacman requires at
  install time and is deliberately left out of the change that only moves the
  recipe into the repo.
- **`PACMAN_EXTRAPACKAGES`** is now the `_extra` array per page size. The
  `debug` split (unstripped `vmlinux`) stays dropped: large, and not wanted on
  an install medium.
- **No signature check.** kernel.org publishes a detached `.sign` for the
  tarball; this recipe pins the sha256 instead, because `validpgpkeys` needs
  the signing keys in the builder's keyring and `bq` builds without one.
