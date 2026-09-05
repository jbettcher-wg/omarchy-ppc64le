# Omarchy on ppc64le — package status

Living document. Regenerate the counts when Arch POWER's repos move or when we
land builds. Measured against Omarchy `install/omarchy-base.packages` (147 pkgs)
and `install/omarchy-other.packages` (60 pkgs) at upstream commit `49306774`,
checked against the Arch POWER sync DB on `witherspoon-arkamedes` (repos: `base`,
`base-any`).

## Headline

| | count | share |
|---|---:|---:|
| Base packages Omarchy wants | 147 | 100% |
| Already in Arch POWER | **75** | 51% |
| Missing | 72 | 49% |

The missing 72 split by **where a PKGBUILD has to come from**, which is what
actually determines effort:

| Source | count | what it means |
|---|---:|---|
| Arch official (`extra`) | **50** | PKGBUILD exists upstream; needs a ppc64le build + `arch=()` fix. Mostly mechanical. |
| AUR only | **12** | PKGBUILD exists but unmaintained-for-POWER; expect `arch=(x86_64)` and x86 assumptions. |
| Omarchy's own repo | **10** | Omarchy publishes these itself; must be tracked from their repo. |

## Missing — Arch official (50)

These have upstream PKGBUILDs. 8 are `arch=any` and need only a rebuild, no
compilation:

- `inxi` | `kernel-modules-hook` | `luarocks` | `pinta`*
- `tldr` | `udiskie` | `uwsm` | `woff2-font-awesome`

\* `pinta` is `arch=any` but **not** a free rebuild: it needs `dotnet-sdk-10.0`,
and Arch POWER is on dotnet-runtime 9.0.100rc2. See `dependency-closure.md`.

The remaining 42 are `x86_64` and need a real ppc64le build:

- `bat` | `bluez-tools` | `bolt` | `brightnessctl`
- `cups-pk-helper` | `dua-cli` | `evince` | `eza`
- `fcitx5-gtk` | `fcitx5-qt` | `fd` | `foot`
- `fzf` | `gnome-disk-utility` | `gpu-screen-recorder` | `grim`
- `hyprland` | `hyprland-guiutils` | `hyprpicker` | `hyprsunset`
- `imv` | `lazydocker` | `lazygit` | `moonlight-qt`
- `mpv-mpris` | `nautilus` | `nautilus-python` | `obs-studio`
- `obsidian` | `pamixer` | `plocate` | `plymouth`
- `power-profiles-daemon` | `quickshell` | `slurp` | `sushi`
- `system-config-printer` | `usage` | `wtype` | `xdg-desktop-portal-hyprland`
- `xournalpp` | `zoxide`

## Missing — AUR only (12)

- `aether` | `cliamp` | `herdr` | `localsend`
- `mise-bin` | `tensaku` | `ttf-ia-writer` | `tzupdate`
- `ufw-docker` | `xdg-terminal-exec` | `yaru-icon-theme` | `yay`

`yay` matters disproportionately: it is Omarchy's AUR helper, it is Go (so it
builds on ppc64le), but *the AUR packages it will then be asked to build mostly
lack `powerpc64le` in `arch=()`*. That is the structural friction in this whole
project, not a per-package bug.

## Missing — Omarchy's own repo (10)

- `asdcontrol` | `hyprland-preview-share-picker` | `nvim` | `omacalc`
- `omacut` | `omarchy-nvim` | `omawrite` | `tobi-try`
- `ttf-jetbrains-mono-nerd-basic` | `ttfx`

Note `nvim` is here: Omarchy ships **its own** nvim package plus `omarchy-nvim`
for the LazyVim config. That is the package that will consume our rebuilt
LuaJIT — see the LuaJIT JIT backend work.

## Already available in Arch POWER (75)

- `alsa-utils` | `avahi` | `bash-completion` | `bluez`
- `bluez-utils` | `btop` | `chromium` | `clang`
- `cups` | `cups-filters` | `ddcutil` | `docker`
- `docker-buildx` | `docker-compose` | `dosfstools` | `dotnet-runtime`
- `exfatprogs` | `expac` | `fakeroot` | `fastfetch`
- `fcitx5` | `ffmpegthumbnailer` | `fontconfig` | `git`
- `gnome-keyring` | `gnome-themes-extra` | `gum` | `gvfs-mtp`
- `gvfs-nfs` | `gvfs-smb` | `imagemagick` | `inetutils`
- `inotify-tools` | `jq` | `kdenlive` | `less`
- `libreoffice-fresh` | `libsecret` | `libvips` | `libyaml`
- `llvm` | `lua51` | `man-db` | `mariadb-libs`
- `mpv` | `networkmanager` | `noto-fonts` | `noto-fonts-cjk`
- `noto-fonts-emoji` | `nss-mdns` | `pacman-contrib` | `postgresql-libs`
- `python-gobject` | `python-poetry-core` | `qemu-user-static-binfmt` | `qrencode`
- `qt6-imageformats` | `ripgrep` | `ruby` | `sddm`
- `socat` | `starship` | `tesseract` | `tesseract-data-eng`
- `tmux` | `tree-sitter-cli` | `ufw` | `unzip`
- `whois` | `wireless-regdb` | `wireplumber` | `wl-clipboard`
- `xdg-desktop-portal-gtk` | `yt-dlp` | `zbar`

## `omarchy-other.packages` — hardware/platform layer

Of the 60, **35 are structurally N/A on POWER** and get clipped: Intel/NVIDIA
graphics stacks, `lib32-*` multilib, Apple T2/MacBook, Dell/Framework/Tuxedo/ASUS
laptop fixes, x86 firmware.

- `apple-bcm-firmware` | `apple-t2-audio-config` | `asusctl` | `broadcom-wl`
- `dell-xps-touchpad-haptics` | `dell-xps13-sidecar-amps` | `intel-ipu7-camera` | `intel-lpmd`
- `intel-media-driver` | `lib32-nvidia-580xx-utils` | `lib32-nvidia-utils` | `libva-intel-driver`
- `libva-nvidia-driver` | `libvpl` | `linux-firmware-marvell` | `linux-ptl`
- `linux-ptl-headers` | `linux-t2` | `linux-t2-headers` | `macbook12-spi-driver-dkms`
- `nvidia-580xx-dkms` | `nvidia-580xx-utils` | `nvidia-dkms` | `nvidia-open-dkms`
- `nvidia-utils` | `qmk-hid` | `sof-firmware` | `t2fanrd`
- `thermald` | `tuxedo-drivers-nocompatcheck-dkms` | `vpl-gpu-rt` | `vulkan-asahi`
- `vulkan-intel` | `vulkan-radeon` | `yt6801-dkms`

The 25 that do apply need POWER equivalents or review:

- `autoconf-archive` | `base` | `base-devel` | `btrfs-progs`
- `dkms` | `egl-wayland` | `gst-plugin-pipewire` | `gtk4-layer-shell`
- `libpulse` | `limine` | `limine-mkinitcpio-hook` | `limine-snapper-sync`
- `linux` | `linux-firmware` | `linux-headers` | `lsp-plugins-lv2`
- `pipewire` | `pipewire-alsa` | `pipewire-jack` | `pipewire-pulse`
- `qt6-wayland` | `snapper` | `webp-pixbuf-loader` | `yay-debug`
- `zram-generator`

Boot is the notable one: Omarchy assumes **limine** + snapper. POWER9 boots via
**petitboot/OPAL**, so the bootloader, snapshot-boot integration, and the ISO
story all need rethinking rather than porting.

## Known-hard targets

| Package | Why | Options |
|---|---|---|
| `obsidian` | Electron; no ppc64le target | run under FEX, or drop |
| `localsend` | Flutter; no ppc64le target | drop or substitute |
| `gpu-screen-recorder` | NVENC/VAAPI paths | V100s present, but driver support on POWER is the question |
| `quickshell` | Qt6/QML, large | should build; volume of work |
| `plymouth` | early-boot graphics | interacts with petitboot, not GRUB/limine |

## Build progress

Live count. Every entry listed as built was **verified by running it**, not
merely by compiling. Ordering follows the tiers in `dependency-closure.md`.

| Clump | Built | Failed | Blocked / parked |
|---|---:|---:|---|
| 1 — `arch=any` | 7 | 0 | `pinta` (.NET 10) |
| 2 — Rust CLI | 5 | 0 | — |
| 3 — Go CLI | 3 | 0 | — |
| 4 — small C / Wayland | 12 | 0 | — |
| 5 — larger C/C++ | 8 | 0 | — |
| 6 — Hyprland stack | 19 | 0 | — |
| 7 — GNOME / desktop apps | 20 | 0 | — |
| 8 — editor tooling | 9 | 0 | `prettier`, `typescript-language-server`, `vtsls` |

**99 packages in `repo/`** (excluding `-debug-`), from **87 PKGBUILDs**.

Everything on the original target list is built except `pinta`, `obsidian` and
`localsend`, all three of which were blocked before a compiler was ever invoked.

### What the diffs actually look like

Across 87 packages:

| Kind of change | Count |
|---|---:|
| No change at all (`arch=any`) | 12 |
| `powerpc64le` added to `arch()` and nothing else | **59** |
| `arch()` + a packaging substitution | 9 |
| `arch()` + a checksum refresh | 2 |
| Patches to upstream source code | **2** |

Two source patches out of 87 packages. Both are in
`upstreamable-patches.md`, both are architecture-neutral (riscv64 and s390x hit
them identically), and both are the same shape: a code path that exists for
"everything else" and had never been taken.

- `rnnoise` — the scalar `#else` in `src/vec.h` does not compile anywhere: it
  includes a header that does not exist and calls a macro that is not defined,
  both Opus leftovers.
- `marksman` — the Makefile's `uname -m` → .NET RID table has no ppc64le case,
  so the RID silently becomes `linux-`.

### Unplanned packages the closure did not predict

- `libde265` 1.1.2 — Arch POWER's `libheif` is built against a newer libde265
  than it ships, so *anything* linking libheif fails at link time. Their bug,
  not ours; we carry the fix so the queue could proceed.
- `pnpm` — not in Arch POWER at all; needed by two Node language servers.
  Bootstrapped rather than packaged (see `nvim-tooling.md`).

## Method

Availability came from `pacman -Si` against the box's sync DB. Classification
came from the Arch package API (`archlinux.org/packages/search/json`) and the
AUR RPC v5 `info` endpoint. Anything in neither is Omarchy-published.
