# Omarchy for POWER

[![arch: powerpc64le](https://img.shields.io/badge/arch-powerpc64le-0f62fe)](#status)
[![target: POWER9](https://img.shields.io/badge/target-POWER9-9fe870)](#status)
[![POWER8: planned](https://img.shields.io/badge/POWER8-planned-3f4a5a)](docs/power8-secondary-target.md)
[![Omarchy 4.0.3](https://img.shields.io/badge/Omarchy-4.0.3-0f62fe)](https://github.com/omacom/omarchy)
[![base packages: 146/147](https://img.shields.io/badge/base%20packages-146%2F147-9fe870)](#not-available-yet)
[![last commit](https://img.shields.io/github/last-commit/jbettcher-wg/omarchy-ppc64le?color=0f62fe)](https://github.com/jbettcher-wg/omarchy-ppc64le/commits/master)
[![license: MIT](https://img.shields.io/badge/license-MIT-9fe870)](LICENSE)

[Omarchy](https://github.com/omacom/omarchy) (Arch Linux + Hyprland), ported to
**powerpc64le**. It's built on [Arch POWER](https://archlinuxpower.org) and
aimed first at **POWER9** machines.

![Omarchy 4.0.3 on an IBM AC922 (POWER9)](docs/images/desktop.png)

## Status

Omarchy **4.0.3** runs as a daily desktop on an IBM AC922 (8335-GTH, POWER9,
176 threads, Radeon RX 7900 XTX). That includes the Hyprland session, the
Omarchy shell and plugins, Chromium, Neovim with LazyVim on a JIT-enabled
LuaJIT, and `omarchy update`.

| | |
|---|---|
| Omarchy base packages available | **146 of 147** (only `localsend` is missing, below) |
| Packages in the `omarchy-power9` repo | 1,350 |
| Recipes maintained here | 175 |
| Omarchy version | 4.0.3, stable channel (`omarchy` 4.0.3-3, `omarchy-settings` 4.0.3-2) |
| Kernel | `linux-power9` 7.2.2 (4K pages) and `linux-power9-64k` |
| Installer | ISO + `p9-install`, PowerNV and pSeries |
| Release channel | not public yet; packages are unsigned |

The whole userland is rebuilt for POWER9 (`-mcpu=power9`). A **POWER8**
release (separate repo and ISO, built from the same recipes) is planned as a
secondary target; see [`docs/power8-secondary-target.md`](docs/power8-secondary-target.md).

### Notable ports

- **LuaJIT with a working ppc64le JIT backend**
  ([jbettcher-wg/luajit-ppc64le](https://github.com/jbettcher-wg/luajit-ppc64le)).
  It's the first one, as far as we know. Neovim and Omarchy's LazyVim config run
  on it.
- **Chromium 151**, with the Debian ppc64le patch set and POWER9/POWER8 build
  modes.
- **Electron 43** (Chromium 150, Node 24), and **Obsidian** on it.
- **.NET 10 built from source**, with a fix to Mono's ppc64le JIT for ELFv2
  struct returns, so GTK apps like **Pinta** run. The one-time bootstrap is
  documented in [`docs/dotnet-ppc64le-bootstrap.md`](docs/dotnet-ppc64le-bootstrap.md).
- **Qt 6 WebEngine**, **Blender 5.1** (VSX Cycles)
- The full **Hyprland** stack, **quickshell**, and Omarchy's own apps and tools
  (omacalc, omacut, omawrite, tensaku, herdr, cliamp, aether, ttfx, tobi-try).
- Toolchains: **Go 1.27**, **Zig 0.16** (and 0.15 for herdr), LLVM 20/21.
- **ROCm/HIP 7.2.4** and **llama.cpp** for Radeon compute.

![Obsidian on Electron 43, cliamp playing Omarchy Radio, and Pinta 3.1.2 on .NET 10](docs/images/apps.png)

### Not available yet

| Package | Why |
|---|---|
| `localsend` | Flutter app; the Dart VM has no ppc64le back end yet.... |
| `limine`, `limine-snapper-sync` | not applicable; POWER boots through petitboot (below) |

## How it differs from upstream Omarchy

- **Boot.** OpenPOWER firmware boots through **petitboot**, not limine. The
  installer writes a `grub.cfg` that petitboot reads, and a pacman hook keeps
  it current. There are no bootable snapshots; `snapper` is optional.
- **Packages.** They come from the `[omarchy-power9]` repo, listed ahead of
  Arch POWER's `[base]` and `[base-any]`, instead of pkgs.omarchy.org.
- **`omarchy` and `omarchy-settings` are upstream's packages, repacked.** They
  contain no machine code. The recipes drop the limine/snapper/keyring
  dependencies and the update guard hook.
- **Hardware support is clipped.** Intel and NVIDIA graphics, Apple T2, x86
  laptop quirks and multilib don't apply;
  [`installer/share/p9-clipped.packages`](installer/share/p9-clipped.packages)
  lists every dropped package and why.
- **Theme.** `omarchy-theme-power9` is the default theme.

## Using the repository

Add the repo **ahead of** Arch POWER's repos in `/etc/pacman.conf`:

```ini
[omarchy-power9]
SigLevel = PackageNever DatabaseOptional TrustAll
Server = https://omappc64le.download/omarchy-power9

[base-any]
Server = https://repo.archlinuxpower.org/base/any

[base]
Server = https://repo.archlinuxpower.org/base/$arch
```

The repo is served from Cloudflare R2. Packages are **not signed yet**, which is
why `SigLevel` is `PackageNever DatabaseOptional TrustAll`: `PackageNever` also
stops pacman from asking for `.sig` files, whose 404 page is larger than
pacman's signature size limit and would abort downloads under plain
`Optional`. Signing, and restoring `omarchy-keyring`, is planned.

Many packages here are POWER9 rebuilds of Arch POWER packages under the same
name. If something from `[omarchy-power9]` misbehaves, report it here first
rather than to Arch POWER.

Updates work through `omarchy update` or plain `pacman -Syu`. For now
`omarchy update` prints harmless errors from its keyring step
(`omarchy-keyring` and `archlinux-keyring` don't exist on Arch POWER). Our
`omarchy` package reports a system using `[omarchy-power9]` as the **stable**
channel.

## Installing

Build the ISO (needs root for `mkarchiso`, plus the
[kth5/archiso](https://github.com/kth5/archiso) fork at `../archiso-power`):

```sh
iso/build.sh                 # embeds repo/ in the image for an offline install
iso/build.sh --no-repo --repo-server <URL>
```

Output goes to `iso/out/omarchy-p9-YYYY.MM.DD-ppc64le.iso`. Booting it starts
`p9-configurator`, which asks for keyboard, user, disk and timezone, and shows a
summary with the target disk's serial for confirmation. It then runs
`p9-install` under Omarchy's own install dashboard, so the install looks like
upstream's:
- a progress bar driven by the packages actually installed;
- a failure screen with the log tail and options to view the log, reboot or
  drop to a shell;
- a **Reboot Now** prompt when it finishes.

![The Omarchy installer's progress screen on POWER9](docs/images/installer.png)

`p9-install` supports **PowerNV** (bare metal: AC922, Talos II, Blackbird and
other skiboot/petitboot machines) and **pSeries** (KVM/PowerVM guests; it adds
a PReP partition and GRUB). The
layout matches upstream: GPT, ext4 `/boot`, btrfs `/` with `@ @home @log @pkg`
subvolumes. Omarchy's configuration runs on first boot through
`p9-firstboot`. See [`installer/README.md`](installer/README.md).

Testing:
- `installer/test/run-guest.sh prepare|serve|install|boot` runs a full install
  and boot in QEMU `powernv9` through petitboot.
- `tests/qemu-smoke.sh` boots the newest ISO as a pSeries guest.
- `tests/installer-dryrun.sh` exercises the installer's argument and safety
  checks.

## Building packages

Everything is built unprivileged. `tools/bq.py` orders the build, layers build
dependencies with `bwrap` overlays (no chroot, no sudo), runs several packages
in parallel and caches compiles with ccache.

```sh
# edit packages/<pkg>/PKGBUILD, bump pkgrel
tools/bq.py build <pkg> [-j N] [--rebuild --force]
tools/repo-publish.sh              # dry run: what would change in omarchy-power9
tools/repo-publish.sh --commit     # write the published DB
```

Recipe sources are tried in order: `packages/` here, then Arch POWER, then
Arch's GitLab, then optionally the AUR (`--sources`). Packages that build
unmodified from Arch POWER or Arch recipes have no directory here. Every
package passes path guards that reject build-tree paths and stray install
locations. Full details are in [`docs/build-queue.md`](docs/build-queue.md).

### Releasing a new Omarchy version

1. Read upstream's `omarchy.db`: filename, `%SHA256SUM%`, depends.
2. Read the new migrations; a failing migration aborts `omarchy update`.
3. Bump `pkgver` and the checksum in `packages/omarchy` and
   `packages/omarchy-settings`, build, and publish.

## Layout

| Path | Contents |
|---|---|
| `packages/` | PKGBUILDs and patches: ports, ppc64le fixes, Omarchy's own packages |
| `tools/` | `bq.py` build queue, `repo-publish.sh`, dependency closure and soname/repo gap checks, path guards, sysroot helpers |
| `installer/` | `p9-install`, the ISO configurator, first-boot layer, QEMU test rig |
| `iso/` | archiso profile and `build.sh` |
| `tests/` | ISO smoke test, installer dry-run tests |
| `manifest/` | generated dependency closure and build order |
| `docs/` | build system, package status, POWER8 plan, upstreamable patches, investigations |
| `RULES.md` | working rules for this tree |
| `repo/`, `repo-power8/` | built packages and repo DBs (not in git) |
| `upstream/` | reference clones of `omarchy` and `omarchy-iso` (not in git) |

## Upstream work

Portability fixes that belong upstream are tracked in
[`docs/upstreamable-patches.md`](docs/upstreamable-patches.md), for Omarchy,
Arch POWER and individual projects. Patches carry a header saying whether they
are upstreamable or a local workaround.

## License

The tooling, installer, docs and our own recipes and patches are
[MIT](LICENSE). Recipes adapted from Arch Linux, Arch POWER or the AUR, and
patches taken from other projects, keep their original licences; see each
package directory (`LICENSE`, `REUSE.toml` or the patch header).

## Credits

- [Omarchy](https://github.com/omacom/omarchy)
- [Arch POWER](https://archlinuxpower.org), the base distribution
- the [PPC64/LuaJIT](https://github.com/PPC64/LuaJIT) interpreter port that the
  JIT backend builds on
- Debian's chromium team (ppc64le patches)
- Fedora (Qt WebEngine ppc64le patches)
- [kth5/archiso](https://github.com/kth5/archiso) (OpenPOWER boot support)

Maintained by Jordan Bettcher.

![The power9 theme wallpaper, with cliamp playing Omarchy Radio](docs/images/theme-cliamp.png)
