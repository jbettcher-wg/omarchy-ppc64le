# chromium on ppc64le: POWER8 / POWER9 build toggle

`power9-toggle.patch` applies to the chromium PKGBUILD that Arch POWER ships
(`~/Development/repo/archpower/chromium/PKGBUILD`, jbettcher's own work) and
adds a single `_power8_compat` switch, so one recipe produces both artifacts
instead of two divergent forks:

```sh
makepkg -e                       # POWER8-legal (default) -- what goes upstream
_power8_compat=0 makepkg -e      # POWER9 / ISA 3.0 -- what runs on the AC922
```

The policy it implements: **source stays POWER8-compliant either way.** No
POWER9-only instruction is written into any source file. The difference is
compiler flags and which build-system feature gates get set -- the LuaJIT model
of a POWER8 ISA floor with ISA 3.0 selected at build or runtime.

## Why this was needed: the shipped recipe is not actually POWER8-legal

Two findings from auditing the 151 PKGBUILD and all 41 applied ppc64le patches:

1. **The `-mcpu`/`-mtune` strip was deleted in the 150 -> 151 rebase.** The 150
   PKGBUILD stripped `-mcpu=`/`-mtune=` from `CFLAGS`/`CXXFLAGS` on ppc64le
   (matching the aarch64/riscv64 pattern); 151 has only the aarch64/riscv64
   branch. GN's unbundle toolchain (`custom_toolchain=//build/toolchain/linux/unbundle:default`)
   passes `$CFLAGS`/`$CXXFLAGS` through verbatim and appends them *after* GN's
   own config flags, so the last `-mcpu` wins. A build host whose makepkg.conf
   sets `-mcpu=power9` -- as this one does -- silently emits ISA 3.0 from the
   "POWER8-legal" recipe. That is why the locally installed
   chromium 151.0.7922.108-1 is full of ISA 3.0 instructions.

2. **`skia-vsx-instructions.patch` hardcodes `-mcpu=power9 -mtune=power9`** into
   skia's `config("default")` -- all of skia, not just the `opts("vsx")` TU --
   and it is applied unconditionally in both r1 and r2. POWER8-legality of the
   upstream submission currently depends on the build host's config file.

The toggle fixes both: it sets `-mcpu` explicitly per branch rather than
inheriting it, and rewrites skia's flags back to power8 when
`_power8_compat=1`.

`README-archpower.md` in the archpower tree is stale on this point -- it still
describes the deleted strip as present. Worth correcting there.

## Patch classification (all 41 applied ppc64le patches audited)

`prepare()` walks `ppc64le-patches/debian-series` and applies every uncommented
`ppc64le/*` line, in series order. Only three ISA-pinning sites exist in the
whole applied set. There is no `_ARCH_PWR8`/`_ARCH_PWR9` gating, no
`-mpower8-vector`, no `-mno-power9-vector`, and no `target("cpu=power8")`
attribute anywhere.

| Patch | Classification | Toggle behaviour |
|---|---|---|
| `third_party/0001-Force-baseline-POWER8-AltiVec-VSX-CPU-features-when-.patch` | **POWER8 accommodation.** Appends `-mcpu=power8 -maltivec -mvsx` to v8's GN `config("toolchain")`. Six added lines, v8 only. It does *not* define or clear `__POWER8_VECTOR__`/`__POWER9_VECTOR__`/`_ARCH_PWR9`, does not edit any `#if` guard, and does not touch skia, boringssl, ffmpeg or libvpx. | applied when `=1`, skipped when `=0` |
| `core/baseline-isa-3-0.patch` | **POWER9 baseline.** Raises `build/config/compiler_cpu_abi.gn`, `v8/BUILD.gn`, `third_party/libvpx/BUILD.gn` to ISA 3.0. Commented out of `debian-series` upstream ("will not work on POWER8"), so it is **not applied today**. Flags, not sources -- policy-compliant. | skipped when `=1`, applied when `=0` |
| `third_party/skia-vsx-instructions.patch` | **Portability fix that overreaches.** The bulk is ppc64 SSE-compat wrappers, correctly floored on `__POWER8_VECTOR__` (which is true under `-mcpu=power9` too -- leave that guard alone). But it also injects `-mcpu=power9` into all of skia. | flags rewritten to power8 when `=1` |
| `third_party/0001-Add-PPC64-support-for-boringssl.patch` | **Required for correctness, and already exactly the target policy** -- `.machine "any"` asm with a runtime `getauxval(AT_HWCAP2)` / `PPC_FEATURE2_HAS_VCRYPTO` gate. The LuaJIT pattern. Do not touch. | always applied |
| `third_party/0003-third_party-ffmpeg-Add-ppc64-generated-config.patch` | **Generic, not a POWER8 cap.** `HAVE_POWER8 1` is FFmpeg's *top* ppc tier; upstream has no POWER9 tier, so there is nothing to unlock. The `_INLINE`/`_EXTERNAL 0` settings disable inline/external asm -- a portability decision. | always applied |
| `third_party/0001-third_party-libvpx-Disable-vsx-on-ppc64.patch` | **Required for correctness.** Upstream libvpx VSX causes VP9 artifacting. Not an ISA-level accommodation. | always applied |
| `third_party/0004-third_party-libvpx-work-around-ambiguous-vsx.patch` | **Required for correctness** (intrinsic ambiguity). Uses `stxvd2x`, ISA 2.06, already POWER8-compliant. Dead code while VSX is off. | always applied |
| `workarounds/HACK-third_party-libvpx-use-generic-gnu.patch` | **Workaround, keep for now.** libvpx *does* have a real `ppc64le-linux-gcc` target, and the disable-vsx patch already applies `--disable-vsx` to it -- so the `generic-gnu` substitution is belt-and-braces. But the blocker is the VSX bug, not the target string: removing the HACK gets you `ppc64le-linux-gcc --disable-vsx`, functionally the same unoptimized C. Low value, non-zero risk. | always applied; its `-mcpu=power8` hunk is overridden by the explicit `-mcpu` in `build()` |

**Do `baseline-isa-3-0` and `Force-baseline-POWER8` conflict?** Not in
practice -- `baseline-isa-3-0` is commented out of the series and never
applied, so the POWER8 forcing wins by default. They touch overlapping files
(`v8/BUILD.gn`, `third_party/libvpx/BUILD.gn`), so the toggle applies exactly
one of them, never both.

## Is a rebuild warranted?

**Not for performance.** All three `-mcpu` sites are either already `power9`
(skia) or already overridden by the environment flags that land later on the
command line (v8, libvpx). Removing them is a no-op for codegen on this host,
which already builds with `-mcpu=power9`. There is no dormant hand-tuned
POWER9 path being suppressed: the only hand-written ppc assembly in the applied
set is boringssl's, which is `.machine "any"` with a runtime `AT_HWCAP2` gate
and already dispatches to vcrypto here.

**Yes for correctness**, but fold it into the next routine rebuild rather than
spending ~1h40m now. The change that actually matters is making the *upstream*
(`_power8_compat=1`) artifact genuinely POWER8-legal again, which is a
regression against a real contribution others depend on.
