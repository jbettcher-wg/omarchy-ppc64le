# `rocm-llvm` (produces `rocm-llvm`, `rocm-device-libs`, `comgr`)

AMD's LLVM fork -- clang, lld, flang, mlir, compiler-rt, libc++ -- installed
to `/opt/rocm/lib/llvm`; the device bitcode libraries (`ocml`, `ockl`,
`opencl`, `hip` ...) in `/opt/rocm/amdgcn/bitcode`; and `libamd_comgr`, the
Code Object Manager that HIP uses to compile and link at runtime. Arch builds
all three from one checkout, so this repo does too.

## Which ROCm version, and why 7.2.4

Arch POWER ships a mixed set: `hsa-rocr` 6.2.4, `rocm-core` and
`rocm-device-libs` 6.4.4, `rocm-smi-lib` 6.3.2 -- and nothing for
`rocm-llvm`, `comgr`, `hipcc` or the HIP runtime, so those cannot be
"matched"; they have to be chosen. The brief framed it as 6.2.4 vs 6.4.4.
Neither is the right answer:

- Arch's recipes for the stack as it is packaged *today* are 7.2.4:
  `rocm-llvm` is a split package that also produces `rocm-device-libs` and
  `comgr` from the same tree, and `hip-runtime-amd` comes from a
  `hip-runtime` pkgbase whose `hipcc` is built out of that same llvm-project
  checkout. The 6.x-era recipes for `comgr` and `hip-runtime-amd` as
  standalone pkgbases are dead branches on Arch's gitlab (last touched at
  6.0.2), and `hipcc` never had one.
- ROCm components version-check each other: `comgr` is built against a
  specific fork of LLVM, `hip-runtime` against a specific `comgr` ABI,
  `hsa-rocr` 7.x absorbed `hsakmt-roct`. Mixing 6.2.4 `hsa-rocr` under a
  7.x HIP is not a supported combination and would be a new set of bugs to
  chase on top of the port.
- The port therefore rebuilds the *entire* stack at **7.2.4** in one queue:
  `rocm-core`, `rocm-llvm` (+ device-libs + comgr), `hsa-rocr`, `rocminfo`,
  `hip-runtime`. Nothing installed on the host is used or touched; the
  host's 6.x packages only ever sit *under* the staged 7.2.4 tree in bq's
  overlay.

## Deviations from Arch's recipe

- `arch=()` gains `powerpc64le`. `LLVM_TARGETS_TO_BUILD='AMDGPU;NVPTX;Native'`
  resolves `Native` to PowerPC and `LLVM_HOST_TRIPLE=$CHOST` to
  `powerpc64le-unknown-linux-gnu` (Arch POWER's `makepkg.conf` does `export
  CHOST=...`; grep for it without a `^` anchor).
- **`LLVM_ENABLE_PROJECTS='clang;lld'`**, down from Arch's
  `clang;lld;clang-tools-extra;mlir;flang`, and `flang-rt` dropped from
  `LLVM_ENABLE_RUNTIMES`. Arch builds the Fortran frontend so that
  `amdflang` and `rocm-openmp` exist. Nothing on the HIP path uses it:
  device-libs need `clang`, `llvm-link` and `opt`; comgr links LLVM, clang
  and lld libraries; hipcc and the HIP runtime need the `clang` driver. The
  first (untrimmed) build here spent more wall-clock in flang, mlir and
  flang-rt than in everything HIP needs, and a Fortran frontend is a second
  frontend's worth of ppc64le exposure for a package whose job is to
  compile HIP. With them go the FFLAGS filtering, the `HLFIRDialect
  CUFDialect` pre-build, the `clang-tidy` target, the `amdflang` symlink
  (and the `amdflang` wrapper `CLANG_ENABLE_AMDCLANG` installs regardless,
  which would exec a flang that is not there), the `rocm-openmp` optdepend
  and the flang/flang-rt/mlir/clang-tools-extra licence files.
  `compiler-rt` stays: `CLANG_DEFAULT_RTLIB=compiler-rt` makes every hipcc
  host link want its builtins, and on POWER libgcc has no `__extendhfsf2`
  family for the `_Float16` the HIP headers use (the same reason
  `openimagedenoise` in this repo needed compiler-rt).

## What had to change in `bq`, not in the recipe

Every package in this stack installs under `/opt/rocm` and finds the
previous one there by absolute path: `hsa-rocr` runs
`/opt/rocm/lib/llvm/bin/clang` to build its blit kernels, `rocminfo` and
`hip-runtime` `find_package` against `/opt/rocm/lib/cmake`. bq's isolation
is a bubblewrap overlay of the staged sysroot over **`/usr` only**; the
staged `opt/` tree was extracted and never visible. `tools/bq.py`
`bwrap_prefix()` now adds a second `--ro-overlay /opt` whenever
`<sysroot>/opt` exists, same layering as `/usr` (live below, staged on
top). Without it `rocminfo` links the host's 6.2.4 `hsa-rocr` and
`hsa-rocr` cannot find a compiler.

Two more environment facts, both bq-level:

- `TMPDIR` must point into the `/var/tmp` buildroot. The first attempt died
  in CMake's compiler probe with `Cannot create temporary file in /tmp/: No
  space left on device` -- `/tmp` had 1,048,576 of 1,048,576 inodes in use
  from another queue's restage, exactly the failure the brief warned about,
  and cc1plus/ld scratch files land in `$TMPDIR`.
- Pre-cloning `https://github.com/ROCm/llvm-project` as a bare mirror at
  `<buildroot>/srcdest/rocm-llvm` is worth doing before the queue runs: it
  is 4.5 GiB and makepkg's own clone is single-threaded.

## A clang bug this layout exposes (not patched, worked around by rocm-core)

`clang/lib/Driver/ToolChains/AMDGPU.cpp` `DeduceROCmPath()` walks up from
the clang binary stripping `bin` and `llvm`, so from
`/opt/rocm/lib/llvm/bin` it arrives at `/opt/rocm/lib` and stops; the HIP
detector then accepts that candidate because its version probe also looks
in the *parent's* `share/hip/version`. Result, with no `ROCM_PATH` in the
environment:

```
Found HIP installation: /opt/rocm/lib, version 7.2.53211
ignoring nonexistent directory "/opt/rocm/lib/include"
fatal error: 'hip/hip_runtime.h' file not found
```

With `ROCM_PATH=/opt/rocm` exported -- which `rocm-core`'s
`/etc/profile.d/rocm.sh` does on every installed system, and which hipcc
turns into the right paths -- the same `hipcc` line compiles. This is not
ppc64le-specific and Arch x86_64 has the identical layout; it only bit here
because the validation ran in a bwrap overlay without `/etc`. Recorded so
nobody spends an hour on it again; `packages/hip-runtime/validate-staged.sh`
sets the variable.

## Evidence

bq, trimmed recipe, three other queues running (load 170-250):

```
[1/1] rocm-llvm ... ok  1941s  rocm-llvm-2:7.2.4-2-powerpc64le.pkg.tar.zst
                               rocm-device-libs-2:7.2.4-2-powerpc64le.pkg.tar.zst
                               comgr-2:7.2.4-2-powerpc64le.pkg.tar.zst
bq: 1 ok, 0 failed, peak build tree 31.68 GiB
```

Zero `FAILED:` lines in the build log; the only pathological object was
`lib/Target/AMDGPU/MCTargetDesc/AMDGPUMCCodeEmitter.cpp` (12+ min of CPU
on its own, serial at the tail of the first ninja pass -- the generated
code-emitter table, not a POWER problem).

The staged compiler, run under bq's overlay:

```
AMD clang version 22.0.0git (.../rocm-llvm f58b06dce1f9c15707c5f808fd002e18c2accf7e)
Target: powerpc64le-unknown-linux-gnu      Host CPU: pwr9
  Registered Targets: amdgcn - AMD GCN GPUs ; ppc64le - PowerPC 64 LE
/opt/rocm/lib/llvm/bin/clang-22: ELF 64-bit LSB pie executable, 64-bit PowerPC, OpenPOWER ELF V2 ABI
lib/clang/22/lib/powerpc64le-unknown-linux-gnu/: libclang_rt.builtins-powerpc64le.a, asan, ...
```

`hipcc --offload-arch=gfx1100` produces a two-pass compile (`-triple
amdgcn-amd-amdhsa -aux-triple powerpc64le-unknown-linux-gnu`, then the host
pass the other way round) and a ppc64le PIE linking `libamdhip64.so.7`.
What that binary did on the GPU is in `../hip-runtime/README.md`.
