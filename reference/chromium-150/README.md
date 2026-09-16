# reference/chromium-150

A **reference recipe**, not a package. bq builds only from the packaging
tree, so nothing here is ever built as `chromium`; `chromium` (151) there is
the browser this tree ships.

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
ship. `electron43` needs a known-good 150 base on ppc64le: its patch
list, the Debian-derived ppc64le series, the gn and system-library choices, and
the `_power8_compat` toggle. This recipe is that base. Keeping it in git means
it can't be lost the way the earlier out-of-tree builds were (RULES.md #3).

The first commit holds the .128 recipe exactly as it was found. Later commits
move it to the Chromium version the current Electron pins.

## 150.0.7871.128 -> 150.0.7871.250

`PKGBUILD`'s header lists the changes. The details that don't fit there:

### Sources: no Google tarball for .250

`commondatastorage.googleapis.com/chromium-browser-official` has 150 tarballs
up to `150.0.7871.222` (7 Aug 2026) and nothing later. Electron 43.7.0 pins
`150.0.7871.250` (17 Aug). The recipe starts from the .222 `-lite` tarball and
applies `chromium-150.0.7871.222-250.patch`. `mkdelta.py` generates that
patch; it is the upstream difference between the two tags:

| repository | .222 -> .250 | file diffs kept |
|---|---|---|
| chromium/src | 50 commits | 129 of 153: 4 DEPS gitlinks and 20 iOS/Android `.xtb` files the -lite tarball omits are dropped |
| v8 | 15.0.245.27 -> .31, 4 fixes | 12 of 13: `test/mjsunit/mjsunit.status` is not in -lite |
| angle | 3 `[M150]` fixes | 13 of 13 |
| dawn | 1 `[M150]` fix | 6 of 6 |
| skia | 3 commits | 9 of 9 |

The build doesn't use the stamps the tarball generated from its own checkout,
but they're rewritten to .250 anyway: `LASTCHANGE`, `LASTCHANGE.committime`,
`DAWN_VERSION`, and the skia, GPU-lists and dawn hash headers.

### ppc64le patches: r1 vs r2, and r3

`r1` is Debian's set as of 150.0.7871.124 (the tarball the .128 build used).
`r2` is the packaging tree's, rebased by Debian for 151. The comparison,
ignoring Index/offset churn:

| r2 change | applies to 150? | r3 |
|---|---|---|
| `debian-series`: non-ppc64le lines (pre-gen, sysroot, ar-path, golang, llvm-19, trixie/bookworm) | irrelevant: `prepare()` applies only `ppc64le/*` lines | r1's series |
| drops `fixes/fix-partition-alloc-compile.patch` | **no**: Chromium 150's `partition_alloc.gni` still lacks `ppc64` in `has_64_bit_pointers`; 151 added it upstream | kept |
| `sandbox/0001-sandbox-Enable-seccomp_bpf-for-ppc64.patch`, `0001-Add-PPC64-support-for-boringssl.patch` | context lines only (151's syscall list, comment wording) | r1's |
| `third_party/0002-regenerate-xnn-buildgn.patch` | regenerated for 151's XNNPACK; r1's is 150's | r1's |
| `third_party/skia-vsx-instructions.patch` | 151 moved `SkSpinlock.cpp` / `SkFeatures.h`; 150 has r1's paths | r1's |
| `core/baseline-isa-3-0.patch` retargeted to `build/config/compiler_cpu_abi.gn` | the file exists in 150 too, so r1's `compiler/BUILD.gn` hunk no longer applies. **But r2's hunk sits in the `current_cpu == "x64"` block** (the `-m64` before `-msse3`), not the ppc64 one | rebased: hunk in the ppc64 block, libvpx hunk kept, v8 hunk dropped |

So r3 is r1 with one file replaced: `core/baseline-isa-3-0.patch`. Its header
explains the rebase. The v8 hunk is gone rather than awk-stripped at build
time the way the 151 recipe does it: it can only match the line
Force-baseline-POWER8-AltiVec-VSX inserts, and the POWER9 build is the one that
skips that patch.

The toggle applies exactly as in the packaging tree's `chromium`:

| | `_power8_compat=0` (default) | `_power8_compat=1` |
|---|---|---|
| Force-baseline-POWER8-AltiVec-VSX (v8 `-mcpu=power8`) | skipped | applied |
| core/baseline-isa-3-0 | applied | skipped |
| skia `-mcpu=power9` from skia-vsx-instructions | kept | rewritten to power8 |
| `build()` CFLAGS/CXXFLAGS | `-mcpu=power9 -mtune=power9` | `-mcpu=power8 -mtune=power8` |

Verified with `makepkg --nobuild` (sources, checksums, `prepare()`) for both
values. The browser itself was not rebuilt; `electron43` builds this
tree.

`README-archpower.md` describes the .128 recipe. Its "strip `-mcpu`" paragraph
no longer matches `build()`.
