# `hipblas-common`

Header-only: the enums and types hipBLAS and hipBLASLt share. Arch POWER
ships 6.3.2; hipBLAS 7.2.4 wants the matching 7.2.4 headers, so it is
rebuilt here from the same `rocm-libraries` tag as `rocblas` and `hipblas`.

## Deviations from Arch's recipe

- `arch=('any')` already; no arch edit. `build()` exports
  `ROCM_PATH=/opt/rocm` (the recipe compiles with `hipcc`; see
  `../rocm-llvm/README.md` for why hipcc needs that in a non-login
  environment). **That was the only change needed.**

## Evidence

bq: `hipblas-common ... ok hipblas-common-7.2.4-1-any.pkg.tar.zst` (the
6.8 GiB "peak build tree" is the monorepo checkout, not the build).
Consumed by `../hipblas` and, through it, by llama.cpp on the GPU.
