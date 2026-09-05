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

`omarchy-nvim` is **built** — see “The editor” below. `nvim` turned out not to be
a separate Omarchy package after all: `omarchy-nvim` depends on `neovim>=0.9.0`,
so Arch's `neovim` PKGBUILD is the right one, and it is now built against our
JIT-capable LuaJIT.

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
| `pinta` | needs `dotnet-sdk-10.0`; Arch POWER is on .NET 9, and the .NET 10 PKGBUILD itself wants LLVM 20 against a distro on LLVM 22 | two nested bootstraps, or an older Pinta targeting .NET 9 |
| `gpu-screen-recorder` | NVENC/VAAPI paths | **built**, `arch()` only. Runtime capture on POWER still untested. |
| `quickshell` | Qt6/QML, large | **built**, `arch()` only |
| `plymouth` | early-boot graphics | **built**; still interacts with petitboot rather than GRUB/limine, which is a boot-integration question, not a build one |

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
| beyond the clumps | 6 | 0 | — |
| 9 — the editor | 13 | 0 | — |

The last row is the remainder of the "missing — Arch official" list that the
clumps did not name: `mpv-mpris` 1.2, `usage` 5.1.0, `fcitx5-gtk` 5.1.7,
`fcitx5-qt` 5.1.14, `moonlight-qt` 6.1.0 and `gpu-screen-recorder` 6.1.0. All
six were `arch()` and nothing else — including `gpu-screen-recorder`, which the
known-hard table below had flagged for its NVENC/VAAPI paths.

**129 packages in `repo/`** (excluding `-debug-`), from **106 PKGBUILDs**.

**Of the 50 missing Arch-official packages, 47 are built.** The three that are
not — `pinta`, `obsidian`, `localsend` — were all blocked before a compiler was
ever invoked, by a missing prebuilt runtime rather than by anything about the
architecture.

## The editor (clump 9)

Omarchy's editor is now packaged and running natively, which is the one thing
the whole LuaJIT ppc64le JIT effort existed for.

| Package | Version | Change needed |
|---|---|---|
| `luajit` | 2.1.1788628050 | **new PKGBUILD**: builds our rebased tree with the ppc64le JIT backend, and carries one source patch (ELFv2 CR save-slot, see below). `jit.status()` is true; soname stays `libluajit-5.1.so.2` |
| `neovim` | 0.12.5 | `arch()` only |
| `libmpack`, `lua51-mpack`, `unibilium`, `libvterm`, `libluv` | | `arch()` only |
| `lua51-lpeg` | 1.1.0 | `arch()`, plus trimming the split to the Lua 5.1 package |
| `tree-sitter-{c,lua,markdown,query,vim,vimdoc}` | | `arch()` only |
| `omarchy-nvim` | 2026.8.13-2 | vendored x86-64 `stylua`/`shfmt` replaced by symlinks to the native packages, plus a drop-in that stops mason from trying to download binaries that do not exist for this architecture |

So the editor stack was `arch=()` plus a compile, exactly like the tooling in
`nvim-tooling.md` — with one exception, and it was not in a PKGBUILD.

### The one real bug: an ELFv2 CR save slot in LuaJIT

`nvim --headless -c 'checkhealth vim.health'` aborted on
``try_leave: Assertion `trylevel > 0' failed``, and so did every interactive
start of the LazyVim config, on the snacks dashboard. It reproduced with
`jit.off()`, so it was not the trace compiler; the same neovim source built
against PUC Lua 5.1 did not abort, so it was not neovim either.

LuaJIT's `saveregs` pushed the interpreter frame and then saved the caller's
CR at `8(sp)`. In ELFv2, `8(sp)` and `16(sp)` of a frame are the linkage-area
CR and LR save words that the frame owner's **callees** write into. So any C
helper the interpreter called that itself used a non-volatile CR field
(CR2-CR4) overwrote LuaJIT's saved CR, and `restoreregs` handed the C caller
back a corrupted CR. `SAVE_LR` had already avoided this by using
`CFRAME_SPACE+16`; `SAVE_CR` now uses `CFRAME_SPACE+8`.

It bit neovim because GCC caches `do_cmdline()`'s `flags & DOCMD_EXCRESET`
predicate in CR3 across thousands of instructions and many calls, and a
FileType autocommand runs Lua in between. A Lua-only test suite cannot see a
CR clobber at all, which is why LuaJIT's own 383/3/0 differential suite and
upstream's `ffi_call.lua` ABI test were both green with the bug present.
`packages/luajit/nvcr-probe.c` is the regression test — it sets CR2/CR3/CR4
from C, calls into the VM, and checks them afterwards — and it runs in
`check()`.

### What the editor does on this machine

Measured on `witherspoon-arkamedes`, neovim 0.12.5 with Omarchy's pinned
LazyVim config (52 plugins), JIT on versus `jit.off()`:

| Workload | JIT | `jit.off()` | speedup |
|---|---:|---:|---:|
| pure-Lua fuzzy score, 3.4k paths x 5 needles | 3.2 ms | 174.3 ms | **54x** |
| snacks.nvim's own picker matcher, 3417 items | 2.1 ms | 13.0 ms | **6.1x** |
| `ffi.C` call into an nvim symbol x200k | 1.6 ms | 41.7 ms | **27x** |
| FFT-shaped `double[]` loop, 64k x 8 | 0.8 ms | 93.2 ms | **118x** |
| table/`HREFK` churn, 500k | 26.6 ms | 54.7 ms | 2.1x |
| coroutine switches, 100k | 5.1 ms | 10.1 ms | 2.0x |
| `string.buffer` encode+decode, 20k tables | 48.6 ms | 51.9 ms | 1.07x |
| `string.dump` + `load` x4000 | 11.4 ms | 11.0 ms | 0.97x |
| LazyVim TUI startup (`lazy.stats()`) | 37.3 ms | 30.1 ms | **0.81x** |

The last two rows are the honest half. `string.buffer` and `string.dump` are
C, so the JIT has nothing to compile, and **startup is about 20% slower with
the JIT on** — trace compilation on code that runs once never pays itself
back. What the JIT buys is everything the user waits on interactively: the
picker, the matcher, FFI-heavy plugin code.

826 traces are compiled in a normal editing session.

Parity was checked before any of that was believed: `:checkhealth` output is
**byte-identical** between a JIT session and a `jit.off()` session, `:messages`
is empty and identical in both, and a scripted session (snacks file picker over
5784 files, snacks live grep, treesitter, `lua-language-server` attach and
hover, edit/undo) produced the same match counts in both modes.

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
