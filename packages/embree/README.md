# `embree`

Intel's ray-tracing kernels, ported to ppc64le. Nobody ships this for POWER:
Fedora has `ExclusiveArch: x86_64 aarch64`, Void has `archs="aarch64* x86_64*"`,
and Godot's answer for its bundled copy was to turn the raycast module off on
PPC. The port is `embree-ppc64le.patch` (291 lines, header explains each
hunk); the rest of this file is the recipe-level story.

## How it works

Embree's kernels are written against SSE intrinsics and selected by the
`__SSE*__` macros. GCC (>= 8) and clang ship `<xmmintrin.h>` ..
`<nmmintrin.h>` for powerpc64le that implement SSE through SSE4.2 on VSX
(POWER8+), gated behind `-DNO_WARN_X86_INTRINSICS`. Embree's own AArch64
port does the same thing with `sse2neon.h`, so the shape already exists in
the tree: an `EMBREE_ARM`-style CMake switch, a per-ISA flag set that
*defines* `__SSE4_2__` instead of passing `-msse4.2`, and an emulation header
for whatever the compatibility layer lacks. On POWER that header is 90 lines:
`_mm_getcsr`/`_mm_setcsr` and the MXCSR FTZ/DAZ/exception-mask macros
(no-ops; POWER has no MXCSR and no denormal penalty), `_mm_dp_ps`,
`_mm_insert_ps`, `_mm_popcnt_u32/u64`, `_mm_stream_load_si128`.

## Deviations from Arch's recipe

- `arch=()` gains `powerpc64le`; `prepare()` applies the patch.
- `powerpc64le` branch in the `_MAX_ISA` case: `EMBREE_MAX_ISA=NONE` with
  `EMBREE_ISA_SSE2=OFF EMBREE_ISA_SSE42=ON`. Every POWER8+ has VSX, so a
  runtime ISA ladder is pointless; one tier, the way the ARM build has one
  NEON tier. This also sidesteps OSPRay's "add a dummy second ispc target
  when Embree is multi-ISA" rule.
- `EMBREE_IGNORE_CMAKE_CXX_FLAGS=OFF` on ppc64le so makepkg's
  `-mcpu=power9` reaches the compiler (Embree otherwise replaces CXXFLAGS
  with its own set).
- `check()` added: `embree-ppc64le-smoke.c` builds against the just-built
  `libembree4`, traces a single ray, a missing ray and a 4-wide packet
  against one triangle and checks every hit and `tfar`. Package exists only
  if `EMBREE-RUNTIME-OK`.

## Evidence

Scratch build with both SSE2 and SSE4.2 tiers, GCC 16.1.1, `verbose=2`:

```
CPU       : Unknown CPU (IBM)
ISA       : XMM SSE SSE2 SSE3 SSSE3 SSE4.1 SSE4.2 POPCNT
Targets   : SSE2 SSE4.2  (compile time enabled)
intersector4  = sse42::BVH4Triangle4Intersector4HybridMoellerNoFilter
ray1 geomID=0 tfar=5.000000 u=0.250000 v=0.500000
ray2 geomID=4294967295 (expect miss)
pkt[0..2] geomID=0 tfar=5.0   pkt[3] geomID=4294967295
EMBREE-RUNTIME-OK
```

bq build of this recipe (SSE4.2 only): `embree ... ok 56s
embree-4.4.1-1-powerpc64le.pkg.tar.zst`. bq runs makepkg `--nocheck`, so
the `check()` did not run there; the same smoke test was run by hand against
the packaged `libembree4.so.4` from bq's sysroot with the same result
(`EMBREE-RUNTIME-OK`, `Targets: SSE SSE2 SSE3 SSSE3 SSE4.1 SSE4.2`).
Beyond that, Open VKL's and OSPRay's suites run on top of this library
(see their READMEs).

Not ported: AVX/AVX2/AVX-512 tiers (no 256/512-bit VSX), SYCL, the
tutorials (off in Arch's recipe too).
