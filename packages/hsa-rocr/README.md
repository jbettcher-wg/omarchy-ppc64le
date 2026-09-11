# `hsa-rocr`

The HSA runtime -- `libhsa-runtime64.so`, the user-space half of KFD: it
opens `/dev/kfd`, builds AQL queues, rings doorbells, and hands the GPU its
code objects. Since 7.x it also contains what used to be `hsakmt-roct`
(`libhsakmt`). Everything above it (`rocminfo`, HIP, OpenCL) is a client of
this library, so this is where an x86 memory-model assumption would do the
most damage.

## Deviations from Arch's recipe

- `arch=()` gains `powerpc64le`.
- `prepare()` applies `0001-ppc64le-fences-spin-hint-and-image-support.patch`
  (header explains each hunk; summary below).
- `-D Clang_DIR=/opt/rocm/lib/llvm/lib/cmake/clang -D LLVM_DIR=...`. The
  blit kernels (`image/blit_src`) and trap handlers are compiled for
  `amdgcn` by whatever `find_package(Clang HINTS ${CMAKE_PREFIX_PATH}/llvm)`
  returns. CMake consults the `CMAKE_PREFIX_PATH` *environment* variable
  before `HINTS`, and bq exports `CMAKE_PREFIX_PATH=/usr:...`, so on this
  host -- which has Arch's `llvm`/`clang` 22 installed -- the first build
  picked `/usr/bin/clang-22` and died with `unable to execute command:
  posix_spawn failed` trying to run a `/usr/bin/ld.lld` that is not
  installed. bq's triage blamed a harmless `find_package(NUMA)` warning
  (the recipe falls back to `find_library`); the real error was 400 lines
  further down. Pinning `Clang_DIR`/`LLVM_DIR` is correct on any host.
- `makedepends`: `xxd` -> `tinyxxd`. `xxd` is a virtual name provided by
  `vim`, `gvim` and `tinyxxd`; bq's stage-deps resolves makedepends with
  `pacman -Si`, which does not resolve virtuals, so the recipe names the
  real package. `tinyxxd` is the one that does not pull in an editor.

## The patch, and the memory-ordering decision behind it

Upstream builds for x86 and (as of 7.x) loongarch64 and nothing else.
`core/util/utils.h` includes `<x86intrin.h>` only on x86, yet
`amd_aql_queue.cpp`, `amd_blit_kernel.cpp`, `intercept_queue.cpp` and
`amd_gpu_agent.h` call `_mm_sfence()` / `_mm_mfence()` unconditionally, and
`core/util/locks.h` spins on `_mm_pause()`. On ppc64le the build dies at the
first of them. (`core/util/atomic_helpers.h`, the *portable* atomics layer,
is fine: its x86 write-combining special case is `#if`-gated and every other
architecture gets C11 `__atomic_*` with real memory orders.)

What each x86 site is for, and what it became on POWER:

| site | x86 intent | POWER |
|---|---|---|
| `AqlQueue::StoreRelaxed`: `_mm_sfence(); *doorbell = v` | drain WC buffers before the doorbell MMIO write so the GPU sees the packet before the ring | `sync` |
| ring-buffer header stores when the ring is in device memory (`needsPcieOrdering()`) | keep the packet body ahead of the header over PCIe | `sync` |
| `PcieWcFlush`: `sfence; write last byte; mfence; read back` | force WC flush to a large-BAR buffer | `sync` both |
| `locks.h` spin | `pause` | `or 1,1,1; or 2,2,2` |

Why a full `sync` and not the release fence GCC's own `<xmmintrin.h>`
compat header would give for `_mm_sfence()` (that header expands it to
`__atomic_thread_fence(__ATOMIC_RELEASE)`, i.e. `lwsync`):

- Every one of those stores targets memory the GPU reads over PCIe --
  doorbell BAR, VRAM ring, large-BAR kernarg buffer -- and KFD maps all of
  it **caching-inhibited** on POWER (`pgprot_noncached` /
  `pgprot_writecombine` both set `I=1` under radix).
- Power ISA 3.0B Book II 4.6.1 [DOC]: `lwsync` orders accesses "for which
  the specified storage location is in storage that is Memory Coherence
  Required and is neither Write Through Required nor Caching Inhibited".
  A CI store is outside that set. So `lwsync; store-to-doorbell` leaves the
  preceding cacheable stores to the AQL ring unordered against the
  doorbell, which is precisely the race the x86 `sfence` exists to close.
- The Linux kernel draws the same conclusion: powerpc `writel()` is
  `sync; stw` (`arch/powerpc/include/asm/io.h`, `DEF_MMIO_OUT_D`).
- Cost: one `hwsync` per dispatch. The handbook measured a `SEQ_CST` RMW at
  44 ns against 30 ns for `ACQ_REL` [MEASURED]; a kernel launch is
  microseconds. Not worth a weaker, wrong barrier.

The spin hint is the powerpc kernel's `cpu_relax()`: drop SMT thread
priority (`or 1,1,1`, HMT_low) and restore it (`or 2,2,2`, HMT_medium).

Two smaller hunks: `image/util.h` had `#error "Processor not identified"`
for anything but x86/loongarch (the `__rdtsc()` it once wanted is no longer
used there), and `IMAGE_SUPPORT` defaulted **off** for non-x86 hosts. That
default is not a degraded build: `clr/rocclr/device/rocm/rocdevice.cpp`
refuses an agent whose `hsa_extensions` lack `HSA_EXTENSION_IMAGES`, so HIP
would see no device at all.

Upstream already has `#ifdef __PPC64__` in `libhsakmt` (`fmm.c`,
`topology.c`) from IBM's POWER9 work; that half needed nothing.

## The crash that a green build did not show: the vDSO is `linux-vdso64.so.1`

With the fences fixed the package built, and every `hsa_init()` then
segfaulted:

```
#0  rocr::os::callback(dl_phdr_info*, unsigned long, void*)   libhsa-runtime64.so.1
#1  dl_iterate_phdr                                            libc.so.6
#2  rocr::os::GetLoadedToolsLib()
#3  rocr::core::Runtime::LoadTools()
#4  rocr::core::Runtime::Load()  ->  hsa_init
=> lxvb16x vs33,0,r30      r30 = 0x2d8
```

(that instruction is GCC 16's POWER9 inline `strcmp`; the symbolic frames
came from a `!strip` rebuild in a scratch dir, bq strips its packages.)

`GetLoadedToolsLib()` walks every loaded object's `PT_DYNAMIC` looking for
a `HSA_AMD_TOOL_PRIORITY` string, and skips the vDSO by testing
`dlpi_name` for `"vdso.so"`. The vDSO's soname is `linux-vdso.so.1` on
x86 and aarch64 but **`linux-vdso64.so.1` on ppc64** (`ldd /bin/true`),
so the filter misses. The vDSO's dynamic section is mapped read-only by the
kernel and ld.so never relocates its entries in place, so `DT_STRTAB` is
still the link-time offset `0x2d8`; the runtime's `ABS_ADDR()` is
`(ptr)` under glibc (correct for every *relocated* object), and
`strcmp(0x2d8, ...)` follows. The same string test exists in the code
object loader (`amd_hsa_loader.cpp`, `GetUriFromMemoryInExecutableFile`).
The patch changes both to match `"vdso"`.

This is the kind of bug the brief warned about: it is not in any x86-gated
code, the build is green, and only running it finds it.

## Evidence

Build (bq, `--rebuild --force` after the vDSO fix; `--force` alone skips
an entry already marked ok):

```
[1/1] hsa-rocr ... ok  29s  hsa-rocr-7.2.4-1-powerpc64le.pkg.tar.zst
```

`rocminfo` (this repo's 7.2.4, under bq's overlay, `LD_LIBRARY_PATH=/opt/rocm/lib`):

```
Runtime Version:         1.18
  Name:                    gfx1100
  Uuid:                    GPU-99b0802ac8a19292
  Marketing Name:          AMD Radeon RX 7900 XTX
  Device Type:             GPU
  Chip ID:                 29772(0x744c)
  Cacheline Size:          128(0x80)
  Compute Unit:            96
  Fast F16 Operation:      TRUE
  Wavefront Size:          32(0x20)
  Max Waves Per CU:        32(0x20)
      Name:                    amdgcn-amd-amdhsa--gfx1100
      Name:                    amdgcn-amd-amdhsa--gfx11-generic
```

plus two CPU agents (the AC922's two sockets, 88 threads each as the
runtime counts them). Kernels dispatched through this runtime's doorbell
path ran correctly on the GPU -- 2,864 launches in 10 s with the result
checked -- see `../hip-runtime/README.md`.

## Evidence

Filled in below as the package is built and exercised on the RX 7900 XTX.
