# `openimagedenoise`

Arch's recipe plus `oidn-ppc64le.patch`, minus the GPU backends.

## The DNNL question

The worry was that OIDN's neural-net runtime is x86-only (oneDNN). It is
not, since OIDN 2.x: the CPU device is ISPC convolution kernels
(`devices/cpu/cpu_conv.ispc`) plus a little C++. The x86-only pieces --
cpuid, the AMX conv path, DNNL -- are all gated behind `OIDN_ARCH_X64`;
AArch64 already builds the generic ISPC path (and BNNS on macOS). So POWER
follows the ARM shape.

## What the patch does

- `OIDN_ARCH=PPC64LE` in `oidn_platform.cmake`, `--arch=ppc64le` in
  `oidn_ispc.cmake`.
- ispc targets: `vsx-i32x8` for the f32 kernels, `vsx-i32x8` /
  `vsx-i16x16` for the f16 ones -- the same widths as NEON, so the same
  32-byte channel block (`BLOCKC_BYTESIZE`) and the same conv blocking
  constants.
- A `CPUArch::VSX` value on both the ISPC and C++ side. Without it
  `getCPUArch()` hits `#error "Unsupported architecture"`, and even with a
  stub the device would report `Unknown` and enumerate no CPU device at all.
- `OIDN_ARCH_PPC64LE` in `common/platform.h` for the device-name suffix.
- **compiler-rt at link time.** ispc lowers `float16` on the VSX targets
  through LLVM's soft-float helpers (`__extendhfsf2`, `__truncsfhf2`, ...),
  and libgcc does not provide them on POWER (GCC has no `_Float16` there).
  The first build linked fine and then failed `dlopen(RTLD_NOW)` of the
  device module with `undefined symbol: __extendhfsf2`, so OIDN enumerated
  zero devices and 15 of 16 tests failed. The PPC64LE branch now links
  `libclang_rt.builtins-powerpc64le.a` into the CPU device module
  (`compiler-rt` in makedepends; override with
  `-DOIDN_PPC64LE_RT_BUILTINS=<path>`). The f16 kernels are only selected on
  the x86 AMX path, so on VSX they are dead code that merely has to resolve.

Upstreamable; see `docs/upstreamable-patches.md`.

## Deviations from Arch's recipe

- `OIDN_DEVICE_CUDA=OFF`, `OIDN_DEVICE_HIP=OFF` and the `cuda` /
  `hip-runtime-amd` makedepends dropped: neither exists on POWER.
- `-fcf-protection=none` dropped: x86-only flag.
- `ispc` must be >= 1.31 with `PPC64_ENABLED` (`packages/ispc`).

`check()` runs upstream's `oidnTest`; bq runs makepkg `--nocheck`, so it
only runs under a hand `makepkg`.

## Verification (2026-09-10)

Packaged `oidnTest` (bq's sysroot), run by hand after the compiler-rt fix:

    All tests passed (1646 assertions in 16 test cases)

`oidnGetNumPhysicalDevices()` -> 1 (`CPU`), `oidnNewDevice(CPU)` and commit
without error. bq: ok 28 s.
