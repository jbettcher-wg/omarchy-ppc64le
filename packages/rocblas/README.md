# `rocblas`

ROCm's BLAS. The GEMMs come from Tensile: a Python generator that emits and
assembles a kernel library per GPU architecture at build time, which is what
makes this package's build size and time scale with the target list.

## Scope: `GPU_TARGETS=gfx1100`, on purpose

Arch builds for `$(rocm-supported-gfx)` -- twenty-odd architectures. This
recipe builds for **one**, the RX 7900 XTX in this machine. That is a
deliberate scope decision, not an oversight: each architecture is a full
Tensile generate+assemble pass, and no other AMD GPU is present.

**If MI50s (gfx906) go into this box, this recipe must change to
`GPU_TARGETS="gfx1100;gfx906"` and be rebuilt**, and so must
`../llama.cpp-hip`. rocBLAS has no runtime fallback for an architecture
without a Tensile library; a gfx906 would enumerate and then fail every GEMM.

## Deviations from Arch's recipe

- `arch=()` gains `powerpc64le`.
- `GPU_TARGETS=gfx1100` instead of `$(rocm-supported-gfx)` (above); this
  also drops the `rocm-toolchain` makedepend that provides that script.
- No clients: `BUILD_CLIENTS_BENCHMARKS/TESTS/SAMPLES=OFF`. rocblas-bench
  and rocblas-test need `roctracer`, `gtest`, `cblas` and `rocm-smi-lib`;
  `roctracer` does not exist for ppc64le and none of it is on the HIP
  path. `depends` loses `cblas` and `roctracer` accordingly.
- `python-tensile` dropped, and Tensile found in-tree via
  `Tensile_DIR`/`Tensile_ROOT` + `PYTHONPATH`. Arch's `BUILD_WITH_PIP=OFF`
  does **not** mean "use the in-tree copy" in 7.2.4: it means "Tensile is
  already installed" (their `python-tensile`), and `Tensile_TEST_LOCAL_PATH`
  is only read on the `BUILD_WITH_PIP=ON` path, which creates a venv and
  pip-installs the tree (and would reach PyPI for anything missing). The
  first build here died at `find_package(Tensile 4.45.0)` for exactly that
  reason. `TensileConfig.cmake` documents `Tensile_ROOT` as the hook for a
  checkout; pointing it at `shared/tensile/Tensile` and putting
  `shared/tensile` on `PYTHONPATH` (so `bin/TensileCreateLibrary` can
  `import Tensile`) needs no venv, no pip and no network. Its imports are
  `msgpack`, `joblib`, `yaml`; `rich` is a `ConditionalImports` optional.
  `python-pyaml` -> `python-pyyaml`: Tensile does `import yaml`; `pyaml` is
  an unrelated pretty-printer.
- `ROCM_PATH=/opt/rocm` exported in `build()`; `../rocm-llvm/README.md`.
- Arch's `remove-mf16c-flag...patch` is not applied by Arch's own recipe
  any more and the flag is gone from 7.2.4's CMake; the file is not
  carried.

## Evidence

bq: `rocblas ... ok 1175s rocblas-7.2.4-3-powerpc64le.pkg.tar.zst`
(50 MB; Tensile generated 7,269 gfx1100 kernels on 64 threads, then the
library's 483 host objects compiled with amdclang++ for ppc64le). No
source change was needed in rocBLAS or Tensile: nothing in either tests
the host architecture. The library is exercised, GEMMs checked for sane
output, by llama.cpp in `../llama.cpp-hip/README.md`.
