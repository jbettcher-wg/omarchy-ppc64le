# reference/chromium-150

A **reference recipe**, not a package. bq's `local` source reads `packages/`,
so nothing here is ever built as `chromium`; `packages/chromium` (151) is the
browser this tree ships.

## What it is

The Chromium 150 ppc64le recipe that built and ran on POWER9 before the 151
rebase: upstream Arch `chromium` 150.0.7871.128-1 (Arch commit d8dd314) plus
the ppc64le changes, copied verbatim from `~/Development/chromium-build/`,
which lives outside git:

| here | copied from |
|---|---|
| `PKGBUILD`, `.SRCINFO`, `.nvchecker.toml`, Arch patches 138-150, `chromium-ppc64le-patches-r1.tar.gz`, `swiftshader-ppc-xcoff-baseclasses.patch`, `README-archpower.md`, licence files | `chromium-build/chromium-150/` |
| `arch-power-adjustments/` (the PKGBUILD diff against Arch and its README) | `chromium-build/arch-power-adjustments/` |

`README-archpower.md` describes the original .128 recipe as it stood in July
2026. Where it disagrees with the current PKGBUILD, the PKGBUILD's header
comment records what changed since.

## Why it exists

Electron pins a Chromium release, and Electron 43 pins **150**, not the 151 we
ship. `packages/electron43` needs a known-good 150 base on ppc64le: its patch
list, the Debian-derived ppc64le series, the gn and system-library choices, and
the `_power8_compat` toggle. This recipe is that base. Keeping it in git means
it can't be lost the way the earlier out-of-tree builds were (RULES.md #3).

The first commit holds the .128 recipe exactly as it was found. Later commits
move it to the Chromium version the current Electron pins.
