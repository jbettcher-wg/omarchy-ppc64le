# `blender`

Blender 5.1.0 for ppc64le with **Cycles on the CPU, Embree BVH traversal and
the OpenImageDenoise denoiser**, all three of which Arch POWER's
`blender 17:5.1.0-2` lacks. Its recipe (`~/Development/repo/archpower/blender`)
takes the `*)` branch of a `case "${CARCH}"` and passes
`-D WITH_CYCLES=OFF -D WITH_CYCLES_EMBREE=OFF -D WITH_CYCLES_OSL=OFF`, because
neither `embree` nor `openimagedenoise` existed for POWER. Verified on the
shipped package, not the recipe `[MEASURED]`: the extracted
`blender-17:5.1.0-2-powerpc64le.pkg.tar.zst` has no
`scripts/addons_core/cycles/` directory (12 core add-ons, Cycles not among
them) and its binary links neither `libembree4` nor `libOpenImageDenoise`.
So "before" is not "Cycles without acceleration"; it is **no Cycles at all**
-- EEVEE and Workbench only. That package also links `libavcodec.so.62`
while Arch POWER now ships ffmpeg 9 (`libavcodec.so.63`), so it does not
start on a current Arch POWER system either.

Recipe base: Arch POWER's PKGBUILD (which is Arch's plus the arch gate), then
the deviations below. Patches: `ffmpeg-9.patch` (Arch's), `cycles-vsx.patch`,
`oidn-ppc64le-supported.patch` and `cycles-power-cpu-name.patch` (ours;
headers explain each hunk). The last one is cosmetic: Cycles read the CPU
name from cpuinfo's `model name`, which POWER lacks, and listed "Unknown CPU";
the Cycles device list now shows `IBM POWER9 (VSX)` `[MEASURED]`.

## What is and is not accelerated

| | state | evidence |
|---|---|---|
| Cycles CPU device | **on** | `_cycles` module imports; `bpy.app.build_options.cycles == True`; BMW27 and Classroom render `[MEASURED]` |
| BVH build + ray traversal | **Embree 4.4.1, SSE4.2 kernels on VSX** (`packages/embree`) | `ldd`: `libembree4.so.4`; `_cycles.with_embree == True` `[MEASURED]` |
| Cycles shading/integrator kernel | **native VSX 4-wide kernel** via `cycles-vsx.patch` (see below); the SSE-through-compat-headers kernel and scalar are build-time alternatives | `_cycles.system_info()` -> `CPU device capabilities: VSX`; 2,194 fused vector multiply-adds and 895 control-vector permutes in the kernel object vs 6 and 10,675 for the compat kernel `[MEASURED]` |
| Denoiser | **OpenImageDenoise 2.4.1 CPU device** (`packages/openimagedenoise`) | `ldd`: `libOpenImageDenoise.so.2`; `_cycles.with_openimagedenoise == True` `[MEASURED]` |
| Open Shading Language | on | `_cycles.with_osl == True` `[MEASURED]` |
| Path guiding (Open PGL) | **off** -- `openpgl` is not packaged for ppc64le; it is Embree-based and portable, a later job | |
| USD / Hydra | **off** -- `usd` is not packaged for ppc64le | |
| GPU: HIP | **compiled in, dormant** -- see "GPU" below | `HIPEW initialization failed: Error opening HIP dynamic library` at startup; `_cycles.get_device_types()` reports HIP `[MEASURED]` |
| GPU: CUDA / OptiX / oneAPI | off; no such stack exists for POWER | |

## Deviations from Arch POWER's recipe

- `arch=(powerpc64le)`; `epoch=17 pkgver=5.1.0 pkgrel=3` so it outranks
  Arch POWER's `-2`.
- **Source is the release tarball** (`download.blender.org/source/`, md5
  matches upstream's `.md5sum`; sha512 in the PKGBUILD) instead of Arch's
  `git+https://...#tag=v5.1.0` plus `git lfs fetch`. Same tree, no
  `git`/`git-lfs`/`subversion` makedepends, no multi-GB clone. Consequences:
  no `git revert` of the two oneAPI commits Arch reverts (oneAPI is off
  here) and `build_hash` reports `unknown` (buildinfo.cmake handles a
  tree without `.git`).
- `WITH_CYCLES=ON WITH_CYCLES_EMBREE=ON WITH_CYCLES_OSL=ON
  WITH_OPENIMAGEDENOISE=ON`; `embree` and `openimagedenoise` added to
  `depends` (Arch keeps them in `depends_x86_64`).
- `WITH_CYCLES_PATH_GUIDING=OFF WITH_USD=OFF WITH_HYDRA=OFF`: `openpgl`,
  `usd` not packaged for POWER. Arch keeps them in `depends_x86_64`.
- `WITH_CYCLES_DEVICE_HIP=ON WITH_CYCLES_HIP_BINARIES=OFF
  WITH_CYCLES_DEVICE_HIPRT=OFF`, set explicitly; CUDA/OptiX/oneAPI off.
- `WITH_LINKER_MOLD=OFF`, `mold` dropped from makedepends: mold 2.x on this
  host cannot parse GCC 16's `libatomic_asneeded.so` linker script
  (`INPUT ( AS_NEEDED ( -latomic ) )` -> `library not found: AS_NEEDED`),
  and the very first link (`bin/datatoc`) fails `[MEASURED]`.
- `WITH_SYSTEM_GFLAGS=ON WITH_SYSTEM_GLOG=ON`, `gflags` and `google-glog`
  added to depends. Blender bundles gflags/glog for libmv but links Arch
  POWER's `ceres-solver`, which pulls the system `libglog.so.2` /
  `libgflags.so.2.2`. With both present the binary aborts before `main`
  does anything: `ERROR: flag 'logtostderr' was defined more than once (in
  files '/build/google-glog/src/glog-0.7.1/src/flags.cc' and
  'extern/glog/src/logging.cc')` `[MEASURED]`. One glog, the system's, fixes
  it. (Arch POWER's shipped binary carries no `extern/glog` strings at all,
  so their build resolved this differently; their recipe does not say how.)
- `ffmpeg-9.patch`: Arch POWER ships ffmpeg 9 (libavcodec 63);
  `AVCodec::sample_fmts` is gone and `extern/audaspace` fails to compile.
  This is Arch's own patch from the blender 5.2.1 recipe; it applies to
  5.1.0 unchanged.
- `level-zero-headers` / `level-zero-loader` dropped (Intel oneAPI, x86).
- The manpage `LD_LIBRARY_PATH` sed and the `!lto` option are kept as in
  Arch's recipe.

## `cycles-vsx.patch` -- the Cycles kernel on VSX

Cycles has one 4-wide CPU kernel, written against SSE intrinsics and selected
by `__KERNEL_SSE__`..`__KERNEL_SSE42__` in `util/optimization.h`; ARM
compiles the same code through `sse2neon`. Nothing set those macros on
POWER, so every kernel was scalar. The patch adds two ways to have one,
chosen with `_cycles_vsx=` in the PKGBUILD (`CYCLES_PPC64LE_SIMD` in cmake):

| `_cycles_vsx` | what | marker |
|---|---|---|
| `native` (default) | the vector layer written on VSX: `float4`/`float3` hold a `__vector float`, `int4`/`int3` a `__vector int`, every operation is `vec_*` or a GCC vector-extension expression. No x86 intrinsic used or emulated -- no compat header is included, so any leftover `_mm_*` is a compile error | `__KERNEL_VSX__` |
| `sse` | the x86 SSE4.2 kernel unchanged, through GCC's `<xmmintrin.h>`..`<nmmintrin.h>` for powerpc64le (the Embree technique), plus a 15-line `_mm_dp_ps` they lack | `__KERNEL_SSE2VSX__` |
| `scalar` | no SIMD kernel | -- |

Both SIMD modes also define the `__KERNEL_SSE*__` macros: that is what the
kernel tests for "a 4-wide kernel exists" (`svm/noise.h`, `hash.h`,
`color.h`, `transform.h`), and those sites use only the `float4`/`int4` API.
`_cycles.system_info()` reports `VSX` or `SSE4.2 on VSX` accordingly.

### What the native layer does differently, and why (all `[MEASURED]` on the disassembly, GCC 16, `-mcpu=power9`)

- **Shuffles.** SSE encodes lane selection in an immediate; VSX has no such
  instruction, so the compat header loads a control vector and `xxperm`s for
  every shuffle. The native layer uses `__builtin_shuffle` with a constant
  mask, which lets GCC emit the single-op permute where one exists
  (`xxswapd`, `xxmrghd/ld`, `xxspltw`, `xxmrghw/lw`), and rotates with
  `vec_sld(a, a, 12|8)` (one `vsldoi`, no control vector) in every horizontal
  reduction. Kernel object: `xxperm`+`vperm` 10,675 -> 895.
- **FMA.** With Cycles' `-ffp-contract=on`, GCC does not fuse `a * b + c`
  written with vector operators (it fuses the scalar kernel's expressions,
  and it fuses under `-ffp-contract=fast`). `madd`/`msub` are `vec_madd`/
  `vec_msub`: fused vector ops 6 -> 2,194.
- **Registers.** Both the compat and the native kernel objects already use
  all 64 VSRs; spill traffic is the same within noise. The emulation tax was
  permutes and un-fused math, not register pressure.
- **Reductions.** `dot()` sums `(a0+a1)+(a2+a3)`, the scalar association;
  `float3` reductions zero the w lane with `vec_insert(0, a, 3)`
  (`xxspltib`+`xxinsertw`, ISA 3.0, no memory constant).
- **Conversions.** `make_int4(float4)` truncates (`vctsxs`) like the scalar
  `(int)` casts; SSE's `cvtps` rounds to nearest, a difference the x86
  kernel carries against its own scalar path. `float3 / float` multiplies by
  the reciprocal as the scalar code does.
- **Transforms.** `transform_point/direction` transpose the three rows with
  `vec_mergeh/mergel` + `xxmrghd/xxmrgld` (8 ops) and apply three `vec_madd`
  of `xxspltw`-splatted components, the shape of the SSE path.
- **Single instructions** for `neg`, `abs`, `sqrt`, `floor`, `ceil`,
  `trunc`, `select` (`xxsel`), compares (`xvcmp*sp`).
- **Two documented semantic differences** from the scalar definitions:
  `round()` is `vrfin`, ties to even (as SSE's `roundps`; scalar `roundf` is
  ties-away); `min/max` are `xvminsp/xvmaxsp`, which return the non-NaN
  operand (scalar `(a<b)?a:b` returns `b`). Both are listed by name in the
  probe.

Kernel object (`kernel/device/cpu/kernel.cpp`): 296,749 / 336,909 / 303,769
instructions scalar / sse / native; the full census is in the handbook,
`docs/cycles-native-vsx-kernel.md`.

**Parity before timing.** Two levels `[MEASURED]`:

1. Operation level: the handbook's `probes/cycles_vsx_probe.cpp` compiles the
   real patched headers twice (scalar, native), dumps 8,967 operation results
   over identical inputs and compares: 8,276 bit-identical, 688 within an
   operand-scaled rounding tolerance (GCC contracts the *scalar* reference
   into FMAs; cancellation in transforms), 3 documented differences, 0
   mismatches. The same probe against the `sse` layer reports 217 deviations
   from the scalar definitions -- all of them x86-SSE semantics (rounding
   `make_int4`, dividing `float3/float`, `fast_rint`), not bugs.
2. Render level, below: BMW27 PSNR 59.0 dB and Classroom 48.9 dB against the
   scalar kernel, the same as the `sse` kernel scores.

The native kernel is what the package ships (`_cycles_vsx=native`).

## Parity, and the benchmark that is still outstanding

Everything below was run from bq's sysroot overlay (`bwrap --overlay-src /usr
--overlay-src <sysroot>/usr --ro-overlay /usr`) with the scenes from
<https://download.blender.org/demo/test/> -- `BMW27_2.blend.zip` ->
`bmw27/bmw27_cpu.blend` (1920x1080 at 50%, 1225 samples, no adaptive
sampling, no denoising, seed 0) and `classroom.zip` -> `classroom/classroom.blend`
(1920x1080 at 100%, 300 samples, seed 1). Nothing in the files was changed.
The three binaries come from one scratch tree with this recipe's cmake
options, differing in exactly one variable each:

| binary | Cycles kernel | BVH |
|---|---|---|
| `blender-A` | scalar (`_cycles_vsx=scalar`) | Embree |
| `blender-B` | SSE4.2 through the compat headers (`sse`) | Embree |
| `blender-C` | SSE4.2 through the compat headers | Cycles' own BVH2 (`WITH_CYCLES_EMBREE=OFF`) |
| `blender-N` | **native VSX** (`native`, what the package ships) | Embree |

Render command, for every binary and scene:

    blender -b <scene.blend> -E CYCLES -o out/<label>-#### -F PNG -f 1 -- --cycles-device CPU --cycles-print-stats

(`--cycles-print-stats` makes Cycles print its per-kernel CPU-time profile
at the end.) Images compared with OpenImageIO's `idiff` (default
thresholds; it reports mean/RMS error, PSNR, and the pixel count over 1e-6).

**Determinism control** `[MEASURED]`: the same binary rendering BMW27 twice
differs in 9-21 pixels of 518,400 (PSNR 97-98 dB) -- the renderer is
deterministic to thread-scheduling noise, so any A/B difference below is the
kernel, not the run.

**Sampling-noise floor** `[MEASURED]`: `blender-A` at seed 0 vs seed 1 on
BMW27: mean error 3.2e-3, PSNR 42.7 dB, 69.6% of pixels differ. That is what
"a different but equally correct render" looks like.

**Scalar vs SIMD kernels** `[MEASURED]`:

| scene | pair | mean error | PSNR | pixels over 1e-6 |
|---|---|---|---|---|
| BMW27 | A vs B (sse) | 6.5e-05 | 60.4 dB | 1.63% (max 0.082, one headlight pixel) |
| BMW27 | A vs N (native) | 7.3e-05 | 59.0 dB | 1.61% |
| BMW27 | B vs N | 6.2e-05 | 59.6 dB | 1.38% |
| Classroom | A vs B (sse) | 1.3e-03 | 48.9 dB | 37.2% |
| Classroom | A vs N (native) | 1.3e-03 | 48.9 dB | 37.2% |

BMW27: 18 dB below the sampling-noise floor, 98.4% of pixels bit-identical;
the amplified diff is scattered noise in the headlight highlights. Classroom
(300 spp, glossy chrome chair legs) shows more pixels touched, still at
rounding amplitude with no structure; its own seed-to-seed floor was not
measured (the run was stopped, see below). The differences are the same
kind x86 gets between its scalar and SSE kernels: `_mm_rcp_ps` is an
approximate reciprocal on both ISAs, and the compat headers' `vec_re`
returns different low bits than x86's `rcpps`.

**VSX kernel with and without Embree (B vs C)** `[MEASURED]`: BMW27 mean
error 1.0e-4, PSNR 54.3 dB, 1.71% of pixels -- two different BVH builders
with different traversal order agree to rounding.

**OIDN** `[MEASURED]`: BMW27 at 32 samples with `use_denoising=True,
denoiser='OPENIMAGEDENOISE'` logs `Loading denoising kernels`, no error, and
the denoised frame is 10.7 dB closer to the 1225-sample reference than the
noisy 32-sample frame (PSNR 39.3 dB vs 28.6 dB).

**Timing, shipped package, idle box** `[MEASURED]` 2026-09-11: the installed
`blender 17:5.1.0-4` (native VSX kernel, `CPU device capabilities: VSX`),
`bmw27_cpu.blend` unchanged, `-- --cycles-device CPU`, threads auto (176),
first run started at load 0.37, three back-to-back runs:

    Time: 01:13.30   01:13.10   01:13.63      (wall 74.3 / 74.1 / 74.6 s)

That is the headline number. The A/B/C/N comparison below is still open; it
would say how much of the 73 s the kernel choice is worth.

**Timing during the parity runs: discarded.** Every render above ran while two other package
queues (rocm-llvm, thunderbird) held the machine at load 84-490 on 176
threads; the wall-clock and per-kernel CPU times that came out were
discarded, not averaged. Cycles' own profile did show where the time goes
in shape -- `Intersect Closest` + `Intersect Shadow` (Embree) and `Shade
Surface` (the VSX-or-scalar kernel) are the two halves -- but no number from
those runs is reported here. To measure on an idle box:

    cd /var/tmp/blender-bq/bench          # blender-A / -B / -C and stageB/ are still there
    export BLENDER_SYSTEM_RESOURCES=/var/tmp/blender-bq/bench/stageB/usr/share/blender/5.1
    ../scratch/in-overlay.sh ./final.sh   # interleaved A,B,C x2 on BMW27 -> results-final.tsv + out/F-*.log
                                           # add blender-N (native) to the loop in final.sh for the four-way comparison

`final.sh` records wall time, Blender's own `Time:` line and the 1-minute
load before each run; the `Kernel statistics:` block in each log is the
per-kernel profile. Whether the VSX kernel is faster than the scalar one on
POWER9 is an open question: the SSE code gains 4-wide `xvmulsp`/`xvaddsp`
but also ~23k lane-shuffle instructions (`xxinsertw`, `vperm`, `xxsldwi`)
that x86 addressing forms get for free, and the scalar build already keeps
its float math in VSX registers (`xsmulsp`). If it turns out slower, the
recipe builds any of the three kernels with `_cycles_vsx=native|sse|scalar`
-- parity holds for all of them.

## GPU: HIP is compiled in and dormant

`WITH_CYCLES_DEVICE_HIP=ON` is set explicitly, not left to cmake. Blender
reaches HIP through `extern/hipew`, which `dlopen`s the runtime at startup
instead of linking it -- verified in the built binary, not the cmake
summary: `strings` shows `libamdhip64.so`, `libamdhip64.so.6`,
`libamdhip64.so.7`, `hiprtcCompileProgram`, `hiprtcLinkCreate`; startup logs
`HIPEW initialization failed: Error opening HIP dynamic library`; and
`_cycles.get_device_types()` returns `(cuda=False, optix=False, hip=True,
metal=False, oneapi=False, hiprt=False)` `[MEASURED]`.

`WITH_CYCLES_HIP_BINARIES=OFF`: no precompiled `gfx*` kernels (that needs
`hipcc` at build time). Cycles then compiles its GPU kernel at runtime, from
the kernel sources the package installs under
`/usr/share/blender/5.1/scripts/addons_core/cycles/source/`.

**To activate the GPU later, with no Blender rebuild**, the system needs:

1. `libamdhip64.so` (`.so.6` or `.so.7`) on the loader path or in
   `/opt/rocm/lib` -- `hip-runtime-amd`;
2. `hipcc` (and the ROCm LLVM behind it) for the runtime kernel compile --
   Cycles looks in `$HIP_PATH`/`/opt/rocm/bin`; `libhiprtc.so` for the
   in-process path;
3. a supported AMD GPU with the `amdgpu` kernel driver.

A ROCm/HIP port for ppc64le is being worked on separately; nothing here was
tested against it. Until it lands, Cycles lists CPU only. HIPRT (hardware
ray tracing) is off because it needs the HIP RT SDK at build time; enabling
it later is a rebuild.

## Not in this recipe

- `openpgl` (path guiding): portable (Embree + TBB), not packaged. Later.
- `usd`: not packaged for POWER.
- Arch's `check()` does not exist upstream either; bq runs `--nocheck`.
  Verification is the runtime probe above (`/var/tmp/blender-bq/bench/features.py`
  during the port; the commands are reproduced in "Measurements").
