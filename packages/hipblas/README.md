# `hipblas`

The BLAS marshalling layer HIP programs (llama.cpp's `ggml-hip` among them)
call; on AMD it forwards to rocBLAS, and its LAPACK-style routines to
rocSOLVER.

## Deviations from Arch's recipe

- `arch=()` gains `powerpc64le`.
- `BUILD_WITH_SOLVER=OFF`, and `rocsolver` leaves `depends`. rocSOLVER
  needs rocSPARSE; neither exists for ppc64le, and llama.cpp uses the BLAS
  half only. Programs that call `hipblasSgetrf` & co. will get
  `HIPBLAS_STATUS_NOT_SUPPORTED` from this build -- PyTorch's `torch.linalg`
  would, for instance. Revisit when rocSOLVER is ported.
- `ROCM_PATH=/opt/rocm` exported in `build()`; `../rocm-llvm/README.md`.

## Evidence

bq: `hipblas ... ok 227s hipblas-7.2.4-1-powerpc64le.pkg.tar.zst`. No
source change needed. Exercised by llama.cpp (`../llama.cpp-hip/README.md`).
