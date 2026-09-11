# `embree`

Intel's ray-tracing kernels, ported to ppc64le. Nobody ships this for POWER:
Fedora has `ExclusiveArch: x86_64 aarch64`, Void has `archs="aarch64* x86_64*"`,
and Godot's answer for its bundled copy was to turn the raycast module off on
PPC. Two patches, headers explain each hunk:

| patch | what |
|---|---|
| `embree-ppc64le.patch` (291 lines) | the port: CMake detection (`EMBREE_PPC64LE`), the `__SSE*__` ISA switch modelled on the AArch64/`sse2neon` port, `__64BIT__`, a fixed SSE4.2+POPCNT feature report, and a 90-line shim for what GCC's SSE-on-VSX compatibility headers lack |
| `embree-ppc64le-vsx.patch` (3,466 lines) | the 4-wide SIMD layer written directly on VSX; selected by `_embree_vsx=native` (default) |

`_embree_vsx=sse` in the PKGBUILD rebuilds 4.4.1-1: Embree's SSE4.2 kernels
compiled through `<xmmintrin.h>`..`<nmmintrin.h>` with
`-DNO_WARN_X86_INTRINSICS`. Both modes build the same single `sse42` ISA
tier and the same ABI (`nm -D` export lists identical, 154 symbols
`[MEASURED]`), so Blender, OSPRay, Open VKL and VTK need no rebuild.

## The native VSX layer (`_embree_vsx=native`, 4.4.1-2)

Embree keeps every SIMD dependency behind `vfloat4`/`vint4`/`vuint4`/
`vboolf4` (`common/simd/`), the `__m128`-backed math types (`Vec3fa`,
`Vec3fx`, `Vec3ia`, `Vec3ba`, `Vec2fa`, `Color`) and a dozen scalar helpers
in `emath.h`; no kernel source calls `_mm_*` directly. The patch replaces
exactly that surface, as `common/simd/*_vsx.h` and `common/math/*_vsx.h`
(the shape of upstream's `*_sycl.h` split), with `common/simd/vsx/vsx.h` as
the base. Storage is `__vector float` / `__vector int`; operations are
`vec_*` builtins and GCC vector extensions. `<immintrin.h>` is never
included, so a surviving `_mm_*` is a compile error; the only x86 spellings
that exist are the non-SIMD platform hints the system layer spells that way
(`_mm_pause`, `_mm_mfence`, `_mm_prefetch`, `_mm_malloc/_mm_free`, the MXCSR
accessors as no-ops), defined in `vsx.h`.

What it does differently from the compat build, and why (lane-level facts
established by `powerpc64le-handbook/probes/vsx_lane_probe.cpp`, GCC 16.1.1,
`[MEASURED]` at `-mcpu=power8` and `-mcpu=power9`):

- **Movemask and mask tests.** `movemask` is one `vbpermq` (ISA 2.07) with
  the control `{96,64,32,0,0x80..}`, which gathers the four word sign bits
  into bits 0..3 in x86 order. `all/any/none` do not go through a mask at
  all: they are record-form compares (`vcmpequw.`) whose CR6 result feeds
  the branch directly. The compat build also uses `vbpermq` for every
  `_mm_movemask_ps` -- 5,224 of them in the old library, 1,831 in the new.
- **Fused multiply-add.** `madd/msub/nmadd/nmsub` are
  `vec_madd/vec_msub/vec_nmsub/vec_nmadd` (`xvmadd*`, `xvmsub*`,
  `xvnmsub*`, `xvnmadd*`), for `vfloat4`, `Vec3fa/fx`, `Vec2fa` and the
  scalar helpers (`xsmaddasp`), and `node_intersector1.h` /
  `node_intersector_packet.h` take the fused traversal shape (`org*rdir`
  precomputed, one `msub` per slab plane) that upstream enables for AVX2 and
  NEON. Note that unlike the Cycles case, the compat build was *already*
  fused: Embree passes no `-ffp-contract`, GCC's default is `fast` for C++,
  and it contracts the compat headers' `_mm_mul_ps`+`_mm_add_ps` after
  inlining -- 54,200 fused vector ops in the old package. The native layer
  has 58,651 because the FMA shape reaches the traversal.
- **Shuffles.** `__builtin_shuffle` with a constant mask, so GCC emits the
  single-instruction permutes where they exist (`xxswapd`, `xxspltd`,
  `xxspltw`, `xxmrghw/lw`, `vmrgew/ow`, `xxpermdi`); `shuffle<1,0,3,2>` is
  a doubleword rotate by 32 (`vrld`), the word rotations are `vec_sld`, and
  `shift_right_1` one `vsldoi` against zero. Blends with immediate masks are
  `xxsel` with a constant. The compat headers emit a control-vector
  `vpermr` for every `_mm_shuffle_ps`: 22,472 control-vector permutes in the
  old library, 2,750 in the new (the remaining ones are `{1,2,0,3}` in
  `cross()` and the sorting networks' `{0,2,1,3}`).
- **`min/max` keep SSE `minps/maxps` NaN semantics** -- the second operand
  whenever the compare is unordered -- as compare+select (`xvcmpgtsp` +
  `xxsel`) rather than one `xvminsp/xvmaxsp`. This is not pedantry:
  `xvminsp` returns the *non-NaN* operand, `OBBNode::clear()` marks empty
  children of the oriented-bounds nodes (hair/curves) with NaN transforms,
  and the intersector culls them through
  `max(tnear, tNearXYZ) <= min(tfar, tFarXYZ)`. With `xvminsp` those
  children were traversed and `embree_verify`'s `regression_static`
  dereferenced `emptyNode` as a leaf `[MEASURED]`. `mini/maxi` (integer
  min/max on the float bits, what the AABB hot path uses) are
  `vminsw/vmaxsw` as on x86.
- **Conversions.** `vint4(vfloat4)` rounds to nearest-even (`xvrspic` +
  `vctsxs`) like `cvtps2dq`; out-of-range saturates where SSE returns
  `0x80000000`. `vfloat4(vuint4)` is one `xvcvuxwsp`; the SSE tier's
  two-step trick double-rounds above 2^31, so the native result is the
  correctly rounded one (11 records in the probe, listed as documented).
- **`rcp`/`rsqrt`**: `xvresp`/`xvrsqrtesp` estimates (14.6 / 15.4 bits
  `[MEASURED]`; x86 `rcpps` is 12) plus one fused Newton step (24.0 / 23.4
  bits). Scalar `rcp(float)` is an exact `xsdivsp`; `rcp(0.0f)` is therefore
  `inf` where the SSE emulation's `r*(2-r*a)` gives NaN (documented).
- **Narrow loads/stores** (quantized nodes, curve bounds): four bytes or
  halfwords widen to words with two merges against zero or two unpacks, no
  memory constants; `vint4::store(unsigned char*)` is the SSE `packus` pair
  (`vpkswus`+`vpkshus`), `vint4::store(unsigned short*)` the modulo pack
  (`vpkuwum`) that upstream's per-lane `(unsigned short)` cast implies (a
  first, saturating, version of it was caught by the probe).
- **Compares.** `!=`, `>`, `>=` are the ordered/unordered forms the NEON
  tier uses (`!=` true for NaN, `>` and `>=` false); SSE's `cmpnlt/cmpnle`
  are unordered. `embree_verify` and the renders agree; a NaN reaching those
  compares means invalid input in Embree's terms.
- **ISA floor is POWER8.** Everything is ISA 2.07 at `-mcpu=power8`; at
  `-mcpu=power9` GCC picks `lxv/stxv`, `lxvwsx`, `mtvsrws`,
  `xxinsertw/xxextractuw` for the same builtins. No `_ARCH_PWR9`
  conditionals were needed.

Two things the Cycles work reported and this one confirms `[MEASURED]`:
both builds use all 64 VSRs in the hot objects, and vector stack traffic is
the same order (compat 1,756 loads / 6,001 stores against `r1` in the
library, native 1,857 / 5,524) -- the tax of emulation is permutes and lane
transfers, not register pressure.

## Deviations from Arch's recipe

- `arch=()` gains `powerpc64le`; `prepare()` applies both patches.
- `powerpc64le` branch in the `_MAX_ISA` case: `EMBREE_MAX_ISA=NONE` with
  `EMBREE_ISA_SSE2=OFF EMBREE_ISA_SSE42=ON`. Every POWER8+ has VSX, so a
  runtime ISA ladder is pointless; one tier, the way the ARM build has one
  NEON tier. This also sidesteps OSPRay's "add a dummy second ispc target
  when Embree is multi-ISA" rule.
- `EMBREE_IGNORE_CMAKE_CXX_FLAGS=OFF` on ppc64le so makepkg's
  `-mcpu=power9` reaches the compiler (Embree otherwise replaces CXXFLAGS
  with its own set).
- `-DEMBREE_PPC64LE_NATIVE_VSX=ON|OFF` from `_embree_vsx=native|sse`.
- `check()` added: `embree-ppc64le-smoke.c` builds against the just-built
  `libembree4`, traces a single ray, a missing ray and a 4-wide packet
  against one triangle and checks every hit and `tfar`. Package exists only
  if `EMBREE-RUNTIME-OK`. bq runs makepkg `--nocheck`, so it is also run by
  hand against the packaged library (below).

## Evidence (4.4.1-2, native), all `[MEASURED]` on the AC922, GCC 16.1.1

Parity before anything else. Four levels, plus the ISA check:

1. **Operation level.** `powerpc64le-handbook/probes/embree_vsx_probe.cpp`
   compiles the real Embree headers twice -- compat build and native build,
   namespaces renamed -- and compares every operation of the four SIMD
   types, the math types and the scalar helpers over 48 random input tuples
   plus a NaN/inf/-0 set: 32,067 records, 29,470 bit-identical, 661 within
   tolerance (the fused ops, whose scale is `|a*b|+|c|` per lane in double;
   the `rcp`/`rsqrt` estimates, 2^-20 relative), 77 documented differences
   (`rcp(0)`, uint->float rounding), 0 mismatches. Three controls that must
   mismatch, one per comparison class, fired (a build-specific constant, a
   1e-3 fused deviation, a 5e-4 approximate deviation).
   The probe found two real defects before the renders could: the
   saturating `store(unsigned short*)`, and -- via `embree_verify` -- the
   `min/max` NaN semantics.
2. **`embree_verify`** (upstream's suite; scratch trees with
   `EMBREE_TUTORIALS=ON`, GLFW off, same CXXFLAGS as the package):

   | build | passed | failed | failed and ignored |
   |---|---|---|---|
   | compat (`sse`) | 2126 | 0 | 16 |
   | native | 2126 | 0 | 16 |

   The 16 ignored failures are the same 16 sub-cases of
   `SSE4.2.watertight_subdiv` in both logs (the only test printing `!`
   markers). The first native run crashed in `SSE4.2.regression_static`
   (the `xvminsp` NaN case above); after the fix the counts are identical.
3. **Smoke test** against the packaged `libembree4.so.4` from
   `embree-4.4.1-2-powerpc64le.pkg.tar.zst`, extracted, nothing installed:
   `EMBREE-RUNTIME-OK` (single ray hit `tfar=5`, miss, 4-wide packet lanes
   0-2 hit, lane 3 miss).
4. **BMW27 render parity.** The installed `blender 17:5.1.0-5` (native VSX
   Cycles kernel) rendering `/var/tmp/blender-bq/scenes/bmw27/bmw27_cpu.blend`
   with `-E CYCLES -o <out>-#### -F PNG -f 1 -- --cycles-device CPU`, once
   against the installed `libembree4.so.4` (4.4.1-1, compat) and once with
   `LD_LIBRARY_PATH` pointing at the extracted 4.4.1-2 library (`LD_DEBUG=libs`
   confirms which file was loaded); the two PNGs compared with `idiff`:

   | pair | mean error | RMS | PSNR | pixels over 1e-6 | max |
   |---|---|---|---|---|---|
   | 4.4.1-1 compat vs 4.4.1-2 native | 5.98e-05 | 9.2e-04 | 60.7 dB | 7,326 (1.41 %) | 0.082 at (267,209), a headlight pixel |

   `old.log` loaded `/usr/lib/libembree4.so.4`, `new.log`
   `/var/tmp/embree-vsx/pkg-new/usr/lib/libembree4.so.4`; nothing else
   differed. The Blender README's own SSE-vs-scalar kernel pair on this scene
   scores 60.4 dB, 1.63 %, max 0.082 at one headlight pixel -- the same
   class of rounding-level difference (both libraries approximate `rcp`,
   from different seeds, and the native one fuses the traversal). Blender's
   `Time:` lines from those two logs, incidental and taken while the box
   went from load 6 to 156, are 01:13.49 (compat) and 01:08.37 (native);
   they are not a measurement.

   For scale, the same binary rendering BMW27 twice with the same library
   differs in 9-21 of 518,400 pixels (PSNR 97-98 dB), and a seed change gives
   PSNR 42.7 dB with 69.6 % of pixels touched (`packages/blender/README.md`).
   No timing was taken; the box was carrying other builds.
5. **ISA.** A `-mcpu=power8` compile of the native tree decodes identically
   under `objdump -M power8` and `-M power9` (15,129 `.long` both ways,
   i.e. zero instructions the POWER8 dialect cannot decode); the control on
   the `-mcpu=power9` library shows 190,797 instructions across 34 ISA 3.0
   mnemonics (`lxv`, `stxv`, `xxspltib`, `lxvwsx`, `mtvsrws`, ...)
   (`powerpc64le-handbook/probes/isa30scan.sh`).

Static census of the packaged libraries
(`powerpc64le-handbook/probes/vsx_census.sh`; both LTO, `-O2 -mcpu=power9`
plus Embree's `-O3`):

| `libembree4.so.4` | 4.4.1-1 compat | 4.4.1-2 native |
|---|---|---|
| instructions | 1,896,754 | 1,735,670 |
| fused vector FMA (`xvmadd*/xvmsub*/xvnmadd*/xvnmsub*`) | 54,200 | 58,651 |
| other vector float (`xv*sp`) | 110,062 | 108,561 |
| control-vector permutes (`vperm/vpermr/xxperm`) | 22,472 | 2,750 |
| single-op permutes (`xxsldwi vsldoi xxpermdi xxswapd xxspltw xxmrg* vmrg* vrld vbpermq xxinsertw xxextractuw`) | 82,425 | 55,333 |
| of which `xxinsertw` | 32,088 | 252 |
| `xxsel` | 47,254 | 38,736 |
| VSR<->GPR/FPR transfers and scalar<->vector converts | 55,129 | 41,449 |
| vector loads / stores | 104,695 / 69,569 | 95,901 / 65,332 |
| scalar VSX float (`xs*`, excluding FMA) | 15,718 | 16,943 |

Hot objects, non-LTO scratch builds, same flags: `bvh_intersector1_bvh4`
83,304 -> 67,483 instructions, control-vector permutes 1,472 -> 208, fused
2,616 -> 2,868; `bvh_intersector_hybrid4_bvh4` 149,258 -> 125,627, permutes
1,734 -> 208, fused 5,142 -> 6,469; `curve_intersector_virtual_4v` 160,115
-> 126,397, permutes 4,838 -> 512.

bq build: `embree ... ok 51s embree-4.4.1-2-powerpc64le.pkg.tar.zst`.

Not ported: AVX/AVX2/AVX-512 tiers (no 256/512-bit VSX), SYCL, the
tutorials (off in Arch's recipe too; the scratch builds turn them on for
`embree_verify`).

Full design notes and the numbers behind every claim above:
`powerpc64le-handbook/docs/embree-native-vsx.md`.
