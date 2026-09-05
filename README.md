# Omarchy for ppc64le

Bringing [Omarchy](https://github.com/omacom/omarchy) (opinionated Arch +
Hyprland) to **powerpc64le**, on top of an existing Arch POWER install.

Target machine: `witherspoon-arkamedes`, AC922 (POWER9, ppc64le), Arch POWER.

## Layout

| Path | What |
|---|---|
| `upstream/omarchy/` | Upstream Omarchy, unmodified. Reference and diff base — do not edit. |
| `packages/` | Our PKGBUILDs: ports of missing packages and ppc64le fixes to existing ones. One directory per package. |
| `repo/` | Built `.pkg.tar.zst` artifacts plus the pacman repo DB, served as a package repo. |
| `installer/` | Omarchy's install flow, adapted for ppc64le (packages clipped, boot path changed). |
| `docs/` | Findings and status. Start with `package-status.md`. |

## Where it stands

51% of Omarchy's 147 base packages are already in Arch POWER. Of the 72 missing,
50 have upstream Arch PKGBUILDs and are mostly a build-and-fix-`arch=()` job, 12
are AUR-only, and 10 come from Omarchy's own repo. Full breakdown, including what
is structurally impossible on POWER and what is merely hard, is in
[`docs/package-status.md`](docs/package-status.md).

## Things that will not port, by design

Omarchy's hardware layer is heavily x86: Intel/NVIDIA graphics stacks, `lib32-*`
multilib, Apple T2 MacBook support, Dell/Framework/Tuxedo/ASUS laptop fixes. Those
get clipped rather than ported.

The boot story is a genuine redesign, not a port: Omarchy assumes **limine** plus
snapper snapshot boot, while POWER9 boots through **petitboot/OPAL**.

For x86-only binaries with no ppc64le target (Electron and Flutter apps such as
`obsidian` and `localsend`), [FEX](../fex-ppc64le) is the escape hatch.

## Related work in this tree

- `../luajit-ppc64le` — giving LuaJIT a real JIT backend on ppc64le. Omarchy's
  `nvim` / `omarchy-nvim` (LazyVim) runs on LuaJIT, which on POWER is currently a
  JIT-less 2017 fork.
- `../powerpc64le-handbook` — what this work has established about POWER9/ppc64le.
- `../repo/archpower` — Arch POWER's PKGBUILD tree.
