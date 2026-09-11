# `hip-runtime` (produces `hip-runtime-amd`)

The HIP host runtime (`libamdhip64.so`, built from CLR = rocclr + hipamd),
`hiprtc`, the `hipcc`/`hipconfig` drivers, and the HIP headers. Sits on
`hsa-rocr` and `comgr`.

## Deviations from Arch's recipe

- `arch=()` gains `powerpc64le`.
- `pkgname=(hip-runtime-amd)` only. Arch's pkgbase also builds
  `hip-runtime-nvidia`, which `makedepends` on `cuda`; there is no CUDA for
  ppc64le (NVIDIA dropped POWER after CUDA 11 and Arch POWER has no
  package), so that half is removed rather than gated.
- The hipcc git source is named `rocm-llvm::` instead of
  `hip-runtime-hipcc::`. makepkg keys its SRCDEST mirror on that name, and
  Arch's name would clone the 4.5 GiB ROCm llvm-project a second time; this
  reuses the mirror `rocm-llvm` already made. Same URL, same tag.
- `prepare()` applies `0001-clr-ppc64le-arch-fences-and-spin-hint.patch`
  and `0002-clr-char-vectors-signed-on-unsigned-char-hosts.patch`.

## Patch 0002: `char4` is unsigned on a POWER host

CUDA's `vector_types.h` declares `char1`..`char4` with `signed char`
members; HIP builds them from plain `char`
(`__MAKE_VECTOR_TYPE__(char, char)` in `amd_hip_vector_types.h`). Plain
char is unsigned on ppc64le, and the device pass inherits the host's
signedness (`-fno-signed-char` on the `-triple amdgcn -aux-triple
powerpc64le` cc1 line), so `char4` was four unsigned bytes on the GPU too.
CUDA-ported code that stores a negative value into a member gets a
float->unsigned conversion, which AMDGPU clamps to 0.

Found through llama.cpp: `quantize_mmq_q8_1` does `char4 q; q.x =
roundf(...)`, so every quantized matmul with more than 8 columns (the MMQ
path; MMVQ uses `int8_t` and was fine) lost all negative activations.
Qwen3-8B generated at full speed on the GPU and produced garbage;
`test-backend-ops -o MUL_MAT` failed 178 of 1,021 cases, every one a
quantized type with n >= 16. With the patched headers (tested as an overlay
before rebuilding this package) it fails 13, all `iq1_s` -- a separate
issue that `-fsigned-char` does not fix either.

The patch is conditional on `__CHAR_UNSIGNED__`, so x86 keeps `char4`'s
type identity and mangling byte-for-byte. `math_fwd.h`'s `__ockl_sdot4`
declaration takes `char4`'s native vector and follows it; it is `extern
"C"` and ockl takes `<4 x i8>`, so nothing changes below the declaration.

Anything compiled against the 7.2.4-1 headers that uses `char1`..`char4`
keeps the old behaviour until rebuilt; llama.cpp-hip is the one known user.

## Patch 0001

`rocclr/include/top.hpp` classifies the host as `ATI_ARCH_ARM` or
`ATI_ARCH_X86` and defines nothing otherwise. Mostly that is silent --
`Os::spinPause()` just becomes a no-op -- but
`device/rocm/rocvirtual.cpp` (`VirtualGPU::submitKernelInternal`) and
`hipamd/src/hip_graph_internal.cpp` call `_mm_sfence()`/`_mm_mfence()`
with no guard at all, around the write-then-read-back that flushes a
large-BAR kernarg buffer. ppc64le fails to compile there.

The patch adds `ATI_ARCH_PPC64` and defines both fences as a full `sync`,
for the reason worked through in `../hsa-rocr/README.md`: the buffer is
device memory mapped caching-inhibited, and Power ISA 3.0B Book II 4.6.1
excludes CI storage from `lwsync`'s ordering, so a release fence would
compile and order nothing. `Os::spinPause()` gets the kernel's
`cpu_relax()` sequence (`or 1,1,1; or 2,2,2`).

## Smoke tests shipped with the recipe

- `hip-ppc64le-vecadd.hip` -- vectorAdd over 4,194,304 floats, every
  element checked on the host, and the agent name printed so a host
  fallback cannot pass as a GPU run.
- `hip-ppc64le-busy.hip` -- a dependent-chain kernel launched back to back
  for N seconds, so `rocm-smi` can be sampled meanwhile.
- `test.cpp` / `test.sh` -- Arch's own saxpy check, unchanged.
- `validate-staged.sh` -- runs all of it against bq's staged `/opt/rocm`
  under the same bwrap overlay bq builds with; sets the two environment
  variables an installed `rocm-core` would (see its header).

## Evidence

bq: `hip-runtime ... ok 124s hip-runtime-amd-7.2.4-1-powerpc64le.pkg.tar.zst`.

Everything below ran on the AC922 against the RX 7900 XTX through this
repo's 7.2.4 stack, nothing installed, `validate-staged.sh`:

```
$ /opt/rocm/bin/hipcc --offload-arch=gfx1100 -O2 -o vecadd hip-ppc64le-vecadd.hip
[exit 0]
$ file vecadd
ELF 64-bit LSB pie executable, 64-bit PowerPC, OpenPOWER ELF V2 ABI, dynamically linked
  NEEDED [libamdhip64.so.7]
$ ./vecadd
devices=1 name="AMD Radeon RX 7900 XTX" gcnArchName=gfx1100 CUs=48 pci=0003:03:00 totalMem=24560 MiB
checked 4194304 elements, 0 mismatches, max abs err 0
c[0]=3.000000 c[1]=2.502000 c[n-1]=3.106000 (want 3.000000 2.502000 3.106000)
VECADD-OK

$ ./archtest            # Arch's test.cpp, saxpy
Agent AMD Radeon RX 7900 XTX
System version 11.0
TESTS PASSED!
```

That it executed on the GPU and not on some fallback: `rocm-smi` sampled
three times while `hip-ppc64le-busy.hip` ran, then once after.

```
idle before:   sclk 0-31 MHz   Average Graphics Package Power 39-43 W   GPU use 0 %
during:        sclk 3065 MHz   310 W / 275 W / 279 W                  GPU use 100 % (x3)
busy: 2864 launches in 10.0s, out[0..3]=1.00238 ... (err=no error)
after:         GPU use 1 %
```

(`CUs=48` from `hipGetDeviceProperties` against `Compute Unit: 96` in
rocminfo is HIP reporting WGPs on gfx11; both are the 7900 XTX.)

2,864 dispatches through the patched doorbell path with correct results is
the evidence for the `sync` decision in `../hsa-rocr/README.md` as far as
a smoke test can give it; the handbook's memory-ordering doc is right that
a race there would be intermittent, so this is "no failure observed under
load", not a proof.
