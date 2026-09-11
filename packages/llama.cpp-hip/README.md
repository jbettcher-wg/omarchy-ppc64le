# `llama.cpp-hip`

llama.cpp with ggml's HIP backend, for the RX 7900 XTX through this repo's
ROCm 7.2.4 stack. The first real workload on the ppc64le HIP port.

## Which recipe, and why

Two starting points existed: Arch's official `llama-cpp` (0.4.0) and the
AUR `llama.cpp-hip` (b10705). Arch's builds against a *separate* `ggml`
package (`LLAMA_USE_SYSTEM_GGML=ON`) whose HIP backend would have to be
ported and version-locked as a second package; the AUR one builds ggml
in-tree with `GGML_HIP=ON` in a single package. The AUR shape is the
cleaner HIP build and is what this recipe derives from, trimmed:

- `rocm-hip-sdk` makedepend gone (it is a meta-package pulling in every
  ROCm library); `rocm-llvm` + `hipblas` + `rocblas` are what is used.
- No web UI: `LLAMA_BUILD_UI` needs `npm` at build time and
  `LLAMA_USE_PREBUILT_UI` downloads a bundle from Hugging Face at
  configure time. Both off; `llama-server` still serves its API.
- No systemd unit / sysusers / conf files from the AUR author's external
  asset repo.
- `-mllvm --amdgpu-unroll-threshold-local=600` not carried; it is an
  undocumented tuning flag and this recipe measures a baseline first.
- `openmp` (LLVM libomp) dropped from `depends`: the host code is built by
  gcc here and ggml's OpenMP is libgomp.

## ppc64le specifics

- `GGML_NATIVE=OFF` + `GGML_CPU_POWERPC_CPUTYPE=power9`. With `GGML_NATIVE`
  on, ggml-cpu greps `/proc/cpuinfo` and picks `-mcpu=power10` on a POWER10
  build host; with it off and no cputype it emits generic
  `-mcpu=powerpc64le`, which loses the VSX quant kernels. The explicit
  cputype is the project's `-mcpu=power9` policy stated where ggml reads it.
- `GPU_TARGETS=gfx1100`, same one-GPU scope as `../rocblas/README.md`
  (change both together if gfx906 cards arrive).
- Device code and the HIP host pass go through CMake's HIP language with
  `CMAKE_HIP_COMPILER=/opt/rocm/lib/llvm/bin/clang++`; everything else is
  gcc 16.
- `sha256sums` differ from the AUR's for the same tag: GitHub regenerated
  the archive. Measured here.

## Needs two fixes below it

- rocm-llvm `2:7.2.4-2` (patch 0002, `__bf16` on PowerPC). Without it
  every `ggml-cuda/*.cu` fails `amd_hip_bf16.h`'s static assert and clang
  segfaults in the device pass: 426 errors, build dead at 35 s.
- hip-runtime-amd `7.2.4-2` (patch 0002, `char4` signedness). Without it
  the build succeeds, runs at full speed, and produces garbage for any
  prompt longer than 8 tokens: `quantize_mmq_q8_1` stores into a `char4`,
  which is unsigned on a POWER host, so the MMQ path loses every negative
  activation. See `../hip-runtime/README.md`.

`validate-staged.sh` runs the staged package; `test-backend-ops` is not
packaged (`LLAMA_BUILD_TESTS=OFF`) and was built separately from the same
source tree to compare ROCm0 against the CPU backend.

## Evidence

bq: `llama.cpp-hip ... ok 117s` (589 targets) against both fixes.

`test-backend-ops test -b ROCm0 -o MUL_MAT`, 7900 XTX vs the POWER9 CPU
backend:

```
hip-runtime 7.2.4-1 headers   OK  843   FAIL 178   (all quantized, n >= 16)
hip-runtime 7.2.4-2 headers   OK 1001   FAIL  13   (all iq1_s, open)
```

Qwen3-8B-Q4_K_M, `-ngl 99`, greedy: output identical to a CPU-only run of
the same prompt (Rayleigh scattering, then red/green/blue).

```
ggml_cuda_init: found 1 ROCm devices (Total VRAM: 24560 MiB):
  Device 0: AMD Radeon RX 7900 XTX, gfx1100 (0x1100), VMM: no, Wave Size: 32
| qwen3 8B Q4_K - Medium | 4.68 GiB | 8.19 B | ROCm | 99 | 16 | pp512 | 2901.69 ± 427.19 |
| qwen3 8B Q4_K - Medium | 4.68 GiB | 8.19 B | ROCm | 99 | 16 | tg128 |    87.89 ± 1.79  |
rocm-smi during pp512: GPU use 100 %, 360 W
```

Open: the 13 `iq1_s` MUL_MAT failures, including n=1 (MMVQ). Not yet known
whether the GPU or the POWER9 CPU reference is the wrong side.
