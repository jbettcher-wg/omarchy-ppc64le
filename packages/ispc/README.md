# `ispc`

Intel's SPMD compiler, built for its **experimental ppc64le/VSX target**.

## Why this exists

`packages/freecad/README.md` (pre-2026-09-10) said ispc had no POWER target and
so OSPRay could never exist here. That was true through ispc 1.30. **ispc
1.31.0 (June 2026) added ppc64le**: `--arch=ppc64le` with native
`vsx-i8x16 vsx-i8x32 vsx-i16x8 vsx-i16x16 vsx-i32x4 vsx-i32x8` targets plus the
`generic-*` family, baseline POWER ISA 2.07 (POWER8) with VSX. Upstream marks
it experimental and does not ship it in the official binaries; it is a CMake
opt-in (`PPC64_ENABLED=ON`). This recipe turns it on. Source:
`docs/ReleaseNotes.txt` and `docs/ispc.rst` in the 1.31.0 tree, and
`src/target_enums.cpp` / `builtins/target-vsx-*.ll`.

## Deviations from Arch's recipe

- `arch=(powerpc64le)` only.
- `-D PPC64_ENABLED=ON -D X86_ENABLED=OFF -D ARM_ENABLED=OFF`. Upstream's
  defaults enable x86 on x86 hosts and ARM wherever the host LLVM has the
  backend (it does here). Cross targets are not needed and every extra target
  family compiles its own stdlib/builtins bitcode, so only the host target is
  built. The host LLVM 22.1.8 is inside ispc 1.31's supported window (20-23)
  and has the PowerPC backend (`llvm-config --targets-built`).
- `-D XE_ENABLED=OFF` and the Xe/GPU dependencies dropped
  (`level-zero-*`, `vc-intrinsics`, `spirv-llvm-translator`,
  `intel-compute-runtime`, `openmp`, `lib32-glibc`). Intel GPU offload is
  meaningless on POWER.
- `-D ISPC_OPAQUE_PTR_MODE=OFF` dropped: the option no longer exists in 1.31.
- Tests and benchmarks are not built, so the `benchmark` / `googletest`
  submodule sources go away. Instead `check()` is a real end-to-end test:
  it compiles a saxpy kernel with the freshly built `ispc` for
  `vsx-i32x4`, `vsx-i32x8` and `vsx-i16x8`, links each against a C++ driver
  with `g++`, runs it and checks the sum.
- `ispcrt` (CPU device + `libispcrt_static.a`) is still built; OSPRay links
  the static library at build time, same note as Arch's recipe.
- `ispcrt-cmake-ppc64le.patch`: upstream added the backend but not to the
  CMake helper `ispcrt/cmake/ispc.cmake` that gets installed as
  `/usr/lib/cmake/ispcrt-*/ispc.cmake` and that OSPRay uses to run the
  compiler. Unpatched it passes `--arch=x86-64` on every non-ARM host and
  defines ISA options for x86 only. The patch detects `ppc64le` in
  `ispc --help`, adds an `ISPC_TARGET_VSX` option (default `vsx-i32x4`) and
  passes `--arch=ppc64le`. Upstreamable; see `docs/upstreamable-patches.md`.

## Known cosmetic issue

makepkg warns `Package contains reference to $srcdir`: `__FILE__` strings in
ispc's own assertion messages (`src/opt.cpp`, `src/ast.cpp`, `src/opt.h`).
Arch's x86_64 build has the same. `elf-pathguard` is clean; no runtime path
is recorded.


## Verification

`tools/bq.py` runs makepkg with `--nocheck`, so the `check()` here never
runs under the queue; it is for a hand `makepkg`. The evidence below is from
running the **installed package contents** (bq's sysroot) by hand on
2026-09-10.

- `ispc --version` -> `1.31.0 (build commit c6adb4f86f5678ce, LLVM 22.1.8)`,
  `--help` lists `--arch={ppc64le}`.
- The saxpy test above, run against the packaged `ispc`: `sum=1000000 OK`
  for `vsx-i32x4`, `vsx-i32x8`, `vsx-i16x8`.
- Every `.ispc` in openvkl, openimagedenoise and ospray compiled with it
  (`--arch=ppc64le --target=vsx-i32x4` / `vsx-i32x8` / `vsx-i16x16`), and
  those libraries pass their own suites (see their READMEs).
- bq: 289 s first build, 115 s rebuild.
