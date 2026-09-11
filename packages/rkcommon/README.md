# `rkcommon`

Arch's recipe plus `rkcommon-ppc64le.patch`.

Not as portable as it looks. Three x86 leftovers hide behind `#else` branches
instead of architecture tests, so any target that is neither x86 nor NEON
falls into them, and the first ppc64le build died in GCC's `xmmintrin.h`
with `#error "Please read comment above. Use -DNO_WARN_X86_INTRINSICS"`:

- `math/rkmath.h`: `rcp()`/`rsqrt()` on `_mm_rcp_ss`/`_mm_rsqrt_ss`. The
  patch defines `NO_WARN_X86_INTRINSICS` for `__powerpc64__` and uses GCC's
  SSE-on-VSX headers, so numerics match x86. Public header, so the define
  has to live there, not in CXXFLAGS.
- `memory/malloc.cpp`: `_mm_malloc`/`_mm_free` -> the `posix_memalign` path
  Apple ARM already uses.
- `tasking/detail/tasking_system_init.cpp`: sets MXCSR FTZ/DAZ per worker
  thread. No MXCSR on POWER; no-ops, as on the `RKCOMMON_NO_SIMD` path.

Upstreamable; see `docs/upstreamable-patches.md`. `check()` is upstream's
ctest suite, unchanged -- note bq runs makepkg `--nocheck`, so it only
runs under a hand `makepkg`. Verified indirectly: Open VKL's 47-case suite
and OSPRay's tutorial render both run on this library (their READMEs have
the numbers). Base of the OSPRay stack (`rkcommon -> openvkl -> ospray`).
bq: ok 25 s.
