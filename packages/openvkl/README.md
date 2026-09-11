# `openvkl`

Arch's recipe plus `openvkl-ppc64le.patch`.

Open VKL is ISPC kernels plus portable C++; the only ppc64le work is CMake.
Its ISA selection knows x86 (SSE4/AVX/AVX2/AVX-512) and AArch64 (NEON) and
passes `--arch=x86-64` or `aarch64` to ispc, so on POWER it would invoke
`ispc --arch=x86-64 --target=sse4`, which our ispc (built for ppc64le only)
rejects. The patch adds a VSX ISA: one 4-wide CPU device from ispc's
`vsx-i32x4` target, no `-msse4.2` width flag, no dummy second target (same
reasoning as the NEON path: single width, no mangling conflicts),
`--arch=ppc64le`, `OPENVKL_ISA_VSX` exported from `openvklConfig.cmake`
so OSPRay can key on it, and a `VKL_ISPC_TARGET_VSX` enum value so the
device reports `ISA: VSX` rather than `UNKNOWN`. Upstreamable; see
`docs/upstreamable-patches.md`.

Needs `ispc` >= 1.31 built with `PPC64_ENABLED` (our `packages/ispc`),
`embree` from `packages/embree`, `rkcommon` from `packages/rkcommon`;
`openvdb` and `boost` come from Arch POWER.

`check()` is upstream's ctest suite, unchanged; bq runs makepkg
`--nocheck`, so it only runs under a hand `makepkg`.

## Verification (2026-09-10)

The packaged `vklTestsCPU` (bq's sysroot), run by hand to completion:

    All tests passed (310680004 assertions in 47 test cases)

(`.vdb` file tests skipped: `OPENVKL_TEST_VDB_FILENAME` not set, as
upstream's ctest does too.) OSPRay's tutorial render loads this device:
`[openvkl] CPU device instantiated with width: 4, ISA: VSX`. bq: ok 180 s.
