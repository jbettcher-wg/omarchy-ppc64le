# Dependency closure for the Omarchy ppc64le build queue

Resolved on `witherspoon-arkamedes` against the live Arch POWER sync DB
(`base`, `base-any`; 5936 packages, 1374 installed) plus the packaging tree at
`$OMARCHY_PACKAGING`. (This run predates the consolidation, when the recipes
were still split across `packages/` and the archpower checkout; the counts
below are from that resolution.)

Method: fetch each target's upstream PKGBUILD from
`gitlab.archlinux.org/archlinux/packaging/packages/<pkgbase>`, source it with
`CARCH=powerpc64le`, collect `depends`/`makedepends`/`checkdepends`, strip
version constraints, resolve names *and soname `provides`* against the sync DB,
then recurse into whatever is still unresolved. Three levels were enough to
close.

## Headline

| | count |
|---|---:|
| Targets in the build queue | 45 |
| Unique deps across the queue | 362 |
| Already in Arch POWER | 315 |
| **Missing — must be built first** | **32** |
| Missing and structurally blocked | 3 |
| Deps present but too old | **0** |

Two findings that shape the work:

1. **Arch POWER's PKGBUILD tree contains none of the 45 targets.** It carries
   the 1821 packages Arch POWER *has*; our queue is by definition its
   complement. So every recipe starts from Arch official, not from a
   POWER-adapted base. The "start from archpower" shortcut does not apply to
   this queue.
2. **Nothing is too old.** Not one version constraint in the whole closure
   fails against Arch POWER. The gap is purely *presence*, and presence is
   mostly `arch=()`. This is the arch-gating pattern again, one level up: the
   distro is current, it just has not been asked to build these.

## The 32 missing dependencies, by cluster

### Hyprland's own libraries (9) — the single biggest block

Hyprland has been split into a stack of small Hypr\* libraries. None are in
Arch POWER; all are C++23, CMake or Meson, no arch-specific code expected.

| Package | Needed by |
|---|---|
| `hyprutils` | hyprland, hyprland-guiutils, hyprpicker, hyprsunset, xdg-desktop-portal-hyprland |
| `hyprlang` | hyprland, hyprland-guiutils, hyprsunset, xdg-desktop-portal-hyprland |
| `hyprwayland-scanner` | hyprland, hyprpicker, hyprsunset, xdg-desktop-portal-hyprland (makedep) |
| `hyprland-protocols` | hyprland, hyprsunset, xdg-desktop-portal-hyprland (makedep) |
| `hyprcursor` | hyprland |
| `hyprgraphics` | hyprland |
| `hyprwire` | hyprland |
| `aquamarine` | hyprland |
| `hyprtoolkit` | hyprland-guiutils |

Order within the cluster: `hyprutils` and `hyprwayland-scanner` first
(everything else wants them), then `hyprlang`, `hyprland-protocols`,
`hyprcursor`, `hyprgraphics`, `hyprwire`, then `aquamarine`, then `hyprtoolkit`.

`aquamarine` is the one to watch: it is Hyprland's DRM/KMS backend, the layer
that actually touches hardware assumptions. Everything above it is
data-structure and parsing code.

### obs-studio's vendored-library tail (7)

| Package | Note |
|---|---|
| `cef` | Chromium Embedded Framework. **No ppc64le build published.** |
| `libdatachannel` | pulls `libjuice` (also missing) |
| `libjuice` | transitive, small C |
| `rnnoise` | small C, has x86 SIMD paths with a generic fallback |
| `websocketpp` | header-only C++ |
| `qrcodegen-cmake` | provides `qrcodegencpp-cmake`; small |
| `mbedtls3` | Arch POWER has mbedtls 4; obs wants the 3.x compat package |

`cef` is the blocker. obs-studio builds with `-DENABLE_BROWSER=OFF`, which drops
the browser source and the CEF dependency entirely. That is the plan.

### nautilus / GNOME files chain (7)

| Package | Needed by |
|---|---|
| `gexiv2` | nautilus, localsearch |
| `gnome-autoar` | nautilus |
| `localsearch` | nautilus |
| `libiptcdata` | localsearch |
| `totem-pl-parser` | localsearch (referenced there as `totem-plparser`) |
| `xdg-user-dirs-gtk` | nautilus |
| `libgxps` | evince |

`nautilus` is itself a dep of `nautilus-python`, and `evince` a dep of `sushi`,
so clump 7 has real internal ordering:
`gexiv2 → libiptcdata → totem-pl-parser → localsearch → gnome-autoar →
xdg-user-dirs-gtk → nautilus → nautilus-python`, and `libgxps → evince → sushi`.

### foot's terminal libraries (2)

`fcft` and `tllist` — both by foot's own author, both tiny C.

### Miscellaneous (5)

| Package | Needed by | Note |
|---|---|---|
| `cpptrace` | quickshell | C++ stacktrace library |
| `cxxopts` | pamixer (makedep) | header-only |
| `tomlplusplus` | hyprland | header-only |
| `sdbus-cpp` | xdg-desktop-portal-hyprland | C++ D-Bus |
| `glaze` | hyprland (makedep) | header-only JSON |

Four of the five are header-only or nearly so. Cheap.

### `python-pycups` (1)

`pycups` pkgbase, needed by `system-config-printer`. Pure CPython extension.

## Deps we intend to *drop* rather than build

These appear in the closure but are avoidable, and avoiding them is much
cheaper than porting them.

| Dep | Wanted by | Why drop | How |
|---|---|---|---|
| `pandoc` | `eza` (makedep) | Haskell, and Arch POWER has **no `ghc` at all** — this is a compiler bootstrap, not a package. Used for exactly one thing: rendering `man/*.md`. | drop man page generation |
| `sway` | `foot` (makedep) | only used to run foot's PGO training under a headless compositor; drags in `wlroots0.20`, also missing | build foot without PGO |
| `cargo-edit` | `bat` (makedep) | only for `cargo set-version` during packaging | drop the version-pin step |
| `cef` | `obs-studio` (makedep) | no ppc64le binaries exist | `-DENABLE_BROWSER=OFF` |

## Structurally blocked

| Package | Blocked on | Size of the remaining problem |
|---|---|---|
| `pinta` 3.1.2 | `dotnet-sdk-10.0` / `dotnet-runtime-10.0`. Arch POWER ships **dotnet-runtime 9.0.100rc2**, and the .NET 10 PKGBUILD itself wants `llvm20`/`clang20` while Arch POWER is on LLVM 22. | Two nested bootstraps (LLVM 20 *and* .NET 10). Out of proportion to one paint program. An older Pinta targeting .NET 9 may build on what is already there — the cheap route if Pinta is wanted. |
| `obsidian` | Electron; no ppc64le target | FEX, or drop |
| `localsend` | Flutter; no ppc64le target | FEX, or drop |

Note `pinta` was counted as a free `arch=any` rebuild in `package-status.md`.
That is what its PKGBUILD says, and it is true of the *output* — but the .NET
SDK it builds against does not exist here, so it is not free. Corrected there.

## Build order

Leaves first. Each line depends only on lines above it.

```
tier 0  (no missing deps at all — clumps 1-5 except foot and pamixer)
        inxi kernel-modules-hook luarocks tldr udiskie uwsm font-awesome
        fd dua-cli zoxide bat* eza*
        lazygit lazydocker fzf
        grim slurp wtype brightnessctl imv
        plocate bluez-tools bolt cups-pk-helper power-profiles-daemon plymouth
        stylua shfmt
tier 1  tllist cxxopts tomlplusplus glaze websocketpp cpptrace
        hyprutils hyprwayland-scanner hyprland-protocols
        libiptcdata gexiv2 libjuice rnnoise qrcodegen-cmake mbedtls3
        sdbus-cpp libgxps gnome-autoar xdg-user-dirs-gtk pycups
tier 2  fcft(tllist) pamixer(cxxopts)
        hyprlang hyprcursor hyprgraphics hyprwire
        totem-pl-parser libdatachannel(libjuice)
        system-config-printer(pycups) evince(libgxps)
tier 3  foot(fcft,tllist) aquamarine hyprpicker hyprsunset
        localsearch(gexiv2,libiptcdata,totem-pl-parser)
        sushi(evince) obs-studio(-browser) xournalpp gnome-disk-utility
tier 4  hyprland(aquamarine,+8) xdg-desktop-portal-hyprland(sdbus-cpp)
        hyprtoolkit quickshell(cpptrace)
        nautilus(localsearch,gnome-autoar,gexiv2,xdg-user-dirs-gtk)
tier 5  hyprland-guiutils(hyprtoolkit) nautilus-python(nautilus)
```

`*` bat and eza each need a makedep dropped first (see above).

## Build environment constraint

There is **no passwordless sudo** on the build box, and `pacman --root` refuses
to run unprivileged, so build dependencies cannot be installed the normal way.

The workaround: 1374 packages are already installed, including a full
`base-devel`, meson, ninja, cmake, rust 1.97, go 1.26, gtk3/gtk4 and qt6-base —
so `makepkg -d` (skip dep checks) covers most of the queue. For genuinely
missing deps, the packages we build ourselves are extracted into a sysroot at
`~/omarchy-work/sysroot` and picked up via `PKG_CONFIG_PATH`, `CPPFLAGS`,
`LDFLAGS` and `CMAKE_PREFIX_PATH`. Verified working.

---

# The complete bare-install closure

*Computed 2026-09-05 by `tools/closure.py`. Supersedes the 674-package floor.*

The earlier figure of **674** packages — `base` + `base-devel` + the 77
Omarchy targets that resolve against Arch POWER today — was known to be a floor,
because it closed only over what Arch POWER already ships. The 70 Omarchy
packages it could not resolve are exactly the ones we build ourselves, and
*their* dependencies were not in that closure at all.

Closing over both universes at once gives the real number.

| | count |
|---|---:|
| **Total bare-install closure** | **858** |
| — from the Arch POWER sync DB | 761 |
| — built here already (`repo/`) | 96 |
| — recipe present, not yet built | 1 (`yay`) |
| Compressed | **2.14 GiB** |
| Installed | **6.64 GiB** |

858 against a 674 floor, inside the predicted 800–900 band. The 184-package
difference is precisely the second-order cost of the packages Arch POWER lacks:
their own dependencies.

## Method

`pacman -Sp` cannot do this on its own. It stops at the first name that is not
in a sync repo, and that set is the entire point of the exercise. So
`closure.py` walks the union of three universes:

1. the Arch POWER sync databases, parsed straight out of
   `/var/lib/pacman/sync/*.db` (never modified);
2. every package we have already built, read from the authoritative `.PKGINFO`
   inside `repo/*.pkg.tar.zst` — not guessed from a PKGBUILD, which is free to
   set `provides` inside `package_()` and frequently does;
3. the packaging tree — every build script we have, at any depth — via
   `.SRCINFO`, falling back to sourcing the `PKGBUILD` with
   `CARCH=powerpc64le`.

Soname `provides` are indexed alongside real names, which is what resolves
entries like `libsdbus-c++.so`.

Two details that were wrong on the first pass and are worth recording:

- **`base` and `base-devel` are metapackages here, not groups.** `pacman -Sg
  base` returns nothing at all, and `pacman -Sg base-devel` returns three
  unrelated `automake` versions. Expanding them as groups silently dropped the
  entire base system from the closure.
- **Naive cycle detection over-reports by an order of magnitude.** A first cut
  flagged 139 packages as circular. They were not: once one real cycle blocks,
  every package downstream of it also never becomes ready. Tarjan's algorithm
  over the residual graph finds the five genuine strongly-connected components,
  all of them long-standing Arch cycles:

  ```
  gdk-pixbuf2 ↔ glycin ↔ librsvg
  libglvnd ↔ mesa
  qt6-multimedia ↔ qt6-multimedia-ffmpeg
  ruby ↔ rubygems
  tesseract ↔ tesseract-data-afr
  ```

  Each is cut at its alphabetically-first member so the manifest stays a total
  order.

## Output

`manifest/bare-install.txt` — 858 lines, `name  version  repo  origin`,
**dependency-ordered**: leaves (`adwaita-cursors`, `alsa-ucm-conf`) first,
dependents (`hyprland`, `nautilus-python`, `xournalpp`) last.
`manifest/bare-install-names.txt` is the same list, names only.

It serves double duty as the ISO's offline mirror manifest — that is the point
of emitting it ordered rather than sorted.

## The 14 that still do not resolve

No recipe exists anywhere for these, so they are outside the closure rather than
missing from it:

| | |
|---|---|
| Omarchy's own, unpublished | `omacalc`, `omacut`, `omawrite`, `ttfx`, `hyprland-preview-share-picker` |
| AUR, not yet fetched | `aether`, `cliamp`, `herdr`, `mise-bin`, `tensaku`, `asdcontrol` |
| Structurally blocked (see above) | `pinta` (.NET 10), `obsidian` (Electron), `localsend` (Flutter) |

The first eleven are work; the last three are decisions.
