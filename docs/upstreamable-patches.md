# Upstreamable patches

Changes made in this repo that are **portability fixes other people would
want**, as opposed to local packaging workarounds. Kept separate deliberately:
the ratio between the two columns is the most honest measure of how ready
ppc64le actually is.

## Source patches worth sending upstream

### 1. rnnoise — `src/vec.h`'s scalar fallback has never compiled

`packaging/rnnoise/0001-vec.h-fix-the-scalar-fallback-path.patch`

`vec.h` dispatches three ways: AVX/SSE2, ARM NEON, and a generic scalar `#else`.
The scalar branch does not compile on any architecture. It includes
`"os_support.h"`, which does not exist in the rnnoise source tree, and calls
`OPUS_CLEAR()`, which is not defined in it either. Both are leftovers from Opus,
which rnnoise vendored the code from; rnnoise renamed the macro to `RNN_CLEAR`
in `src/common.h` and dropped the header, but missed this branch because nothing
had ever built it. Every platform rnnoise has been compiled on matched either
the SSE2 or the NEON arm.

The patch applies the rename that was missed. `RNN_CLEAR` is already in scope
via `arch.h` → `common.h`, so no new include is needed.

**Not ppc64le-specific.** riscv64, s390x and mips hit it identically. ppc64le is
simply where somebody finally took the `else` branch.

Send to: <https://gitlab.xiph.org/xiph/rnnoise>.

### 2. marksman — the Makefile's arch table silently produces an invalid .NET RID

`packaging/marksman/0001-Makefile-recognise-ppc64le-riscv64-and-s390x.patch`

The Makefile builds a .NET runtime identifier as `$(OS_ID)-$(ARCH_ID)`, mapping
`uname -m` through a list of `ifeq` cases: x86_64, amd64, x86, arm, arm64,
aarch64. Anything else leaves `ARCH_ID` empty and the RID becomes `linux-`. The
build then fails a long way downstream with

    error NETSDK1083: The specified RuntimeIdentifier 'linux-' is not recognized

which does not mention the Makefile at all.

.NET is not the limitation: on this machine `dotnet --info` reports
`RID: linux-ppc64le`. Only marksman's table is missing the entry.

The patch adds ppc64le, riscv64 and s390x, and — the more useful half — turns
the silent-empty case into a `$(error)` naming the unrecognised machine, so the
next architecture gets a message pointing at the table rather than NETSDK1083.

**Not ppc64le-specific.**

Send to: <https://github.com/artempyanykh/marksman>.

### 3. neovim -- `FindLpeg.cmake` bakes lpeg's build-time path into the binary

`packaging/neovim/0001-findlpeg-link-by-name-not-absolute-path.patch`

`cmake/FindLpeg.cmake` resolves lpeg with `find_library` and hands the absolute
result to the linker through an `UNKNOWN IMPORTED` target -- deliberately, to
keep CMake from rewriting the link path (neovim#23395). But `lua51-lpeg` ships
`/usr/lib/lua/5.1/lpeg.so` with **no `DT_SONAME`**, and GNU ld records a
SONAME-less shared object in `DT_NEEDED` under the exact spelling it was given on
the command line. The absolute path is copied into the executable verbatim.

Arch's own x86_64 `neovim` shows the benign form of this:

    NEEDED [/usr/lib/lua/5.1/lpeg.so]

which works only because the path it happens to name is also the install path.
Any build that resolves lpeg anywhere else ships a `DT_NEEDED` pointing there.
This repo's `neovim 0.12.5-1` shipped

    NEEDED [/home/jbettcher/omarchy-work/sysroot/usr/lib/lua/5.1/lpeg.so]

and stopped starting the moment that scratch directory was renamed -- verified by
renaming it, not inferred.

The patch emits `-L<dir> -l:<file>` plus an rpath for the same directory, so ld
records `NEEDED [lpeg.so]` and the loader resolves it through `RUNPATH`. Static
archives keep the direct-path link, which records nothing.

**Not ppc64le-specific.** Every distro build of neovim carries the absolute
`DT_NEEDED`; it is invisible only while the build prefix and the install prefix
are the same directory.

Send to: <https://github.com/neovim/neovim>.

---

Those are the *only* three, after 87 packages built and verified across Perl,
Python, Lua, Rust, Go, C and C++. Every other diff in `packaging/` is in a
PKGBUILD, and 59 of the 87 are `arch=()` alone.

The first two are the arch-gating pattern from the handbook, holding at scale:
the substrate is first class, and what breaks is code and metadata that was never
told the architecture was allowed -- a generic fallback branch nobody had ever
taken. The third is a different animal and worth naming as such: not an
architecture bug at all, but a latent defect every distro ships and none notices,
because on an ordinary builder the wrong answer and the right answer are the same
string. It took an unprivileged sysroot build to pull them apart.

### 4. ispc -- the ispcrt CMake helper does not know about the new ppc64le backend

`packaging/ispc/ispcrt-cmake-ppc64le.patch`

ispc 1.31.0 added an experimental ppc64le backend (`PPC64_ENABLED`,
`--arch=ppc64le`, `vsx-*` targets) but did not teach `ispcrt/cmake/ispc.cmake`
about it. That file is installed as `/usr/lib/cmake/ispcrt-*/ispc.cmake` and is
what OSPRay uses to drive the compiler: it hard-codes `--arch=x86-64` for every
non-ARM host and only defines ISA options for x86. On a ppc64le host every
consumer therefore runs `ispc --arch=x86-64 --target=sse4`, which a
ppc64le-only ispc rejects.

The patch detects `ppc64le` in `ispc --help`'s architecture list, adds an
`ISPC_TARGET_VSX` option (default `vsx-i32x4`) and passes `--arch=ppc64le`.

Send to: <https://github.com/ispc/ispc>.

### 4b. rkcommon -- three x86 leftovers behind `#else`

`packaging/rkcommon/rkcommon-ppc64le.patch`

rkcommon is portable C++ except for three spots guarded by `#else` rather than
an architecture test, so any target that is neither x86 nor NEON falls into
them and dies in GCC's `xmmintrin.h` `#error`: `math/rkmath.h` (`rcp`/`rsqrt`
on `_mm_rcp_ss`/`_mm_rsqrt_ss`), `memory/malloc.cpp` (`_mm_malloc`), and
`tasking/detail/tasking_system_init.cpp` (MXCSR FTZ/DAZ per worker thread).
The patch uses the compiler's SSE-on-VSX headers for the first (public header,
so `NO_WARN_X86_INTRINSICS` is defined there), the existing `posix_memalign`
path for the second, and no-ops for the third (no MXCSR on POWER).

**Not ppc64le-specific**: riscv64 and s390x fall into the same branches.

Send to: <https://github.com/RenderKit/rkcommon>.

### 5. embree -- ppc64le port on the compiler's SSE-to-VSX headers

`packaging/embree/embree-ppc64le.patch`

Embree's kernels are SSE intrinsics selected by the `__SSE*__` macros. GCC
(>= 8) and clang ship `<xmmintrin.h>` .. `<nmmintrin.h>` for powerpc64le that
implement SSE through SSE4.2 on VSX, gated behind `-DNO_WARN_X86_INTRINSICS`.
Embree already has exactly this shape for AArch64 (`sse2neon.h`): an
`EMBREE_ARM` CMake switch, per-ISA flag sets that *define* `__SSE4_2__` rather
than pass `-msse4.2`, and an emulation header. The patch adds the POWER
equivalent: `EMBREE_PPC64LE`, flag sets, `__64BIT__` on `__powerpc64__`, a
fixed SSE4.2+POPCNT feature report in `sysinfo.cpp`, and a 90-line
`common/simd/ppc/emulation.h` covering what the compat headers lack
(`_mm_getcsr`/`_mm_setcsr` and the MXCSR macros as no-ops, `_mm_dp_ps`,
`_mm_insert_ps`, `_mm_popcnt_u32/u64`, `_mm_stream_load_si128`).

Verified on POWER9 with GCC 16: builds both SSE2 and SSE4.2 tiers,
`rtcIntersect1` and `rtcIntersect4` return correct hits, misses and `tfar`.

**Nobody ships this today**: Fedora `ExclusiveArch: x86_64 aarch64`, Void
`archs="aarch64* x86_64*"`, Godot disables its bundled Embree on PPC.

Send to: <https://github.com/RenderKit/embree>.

### 5b. embree -- a native VSX backend for the 4-wide SIMD layer

`packaging/embree/embree-ppc64le-vsx.patch` (applies on top of 5)

The compat-header port in 5 runs SSE code through `<xmmintrin.h>`: every
`_mm_shuffle_ps` is a control-vector permute (`vpermr`), every blend an
`xxsel`, every lane insert an `xxinsertw`. This patch writes the four
4-wide types (`vfloat4`, `vint4`, `vuint4`, `vboolf4`) and the SSE-backed
math types (`Vec3fa`/`Vec3fx`, `Vec3ia`, `Vec3ba`, `Vec2fa`, `Color`) on
`__vector float`/`int` storage, GCC vector extensions and altivec builtins,
as `common/simd/*_vsx.h` and `common/math/*_vsx.h`, selected by a new CMake
option `EMBREE_PPC64LE_NATIVE_VSX` (default ON; OFF is the port in 5). No
x86 SIMD intrinsic exists in that build, so any leftover `_mm_*` is a
compile error; the only x86 spellings kept are the non-SIMD platform hints
Embree's system layer calls by name (`_mm_pause`, `_mm_mfence`,
`_mm_prefetch`, `_mm_malloc`, MXCSR). It mirrors what upstream did for
AArch64 with the `#if defined(__aarch64__)` branches, but as separate files
in the shape of the `*_sycl.h` split, which is why it is 3,466 lines and
touches 13 existing files by one `#elif` each.

Design points upstream would want to review: `movemask` is one `vbpermq`;
`all/any/none` are record-form compares; `madd/msub/nmadd/nmsub` are fused
(as on AVX2/NEON), and `node_intersector{1,_packet}.h` take the fused
traversal shape; float `min/max` keep SSE `minps/maxps` NaN semantics via
compare+select because `xvminsp/xvmaxsp` return the non-NaN operand and
`OBBNode::clear()` marks empty children with NaN transforms
(`embree_verify`'s `regression_static` crashes otherwise -- a portability
trap any minNum-semantics ISA will hit).

Verified on POWER9 with GCC 16: `embree_verify` 2126 passed / 0 failed / 16
failed-and-ignored, identical to the compat build; an operation-level
differential probe (`powerpc64le-handbook/probes/embree_vsx_probe.cpp`)
against the compat build: 29,470 of 32,067 records bit-identical, 661 within
the fused/estimate tolerances, 0 mismatches; Blender BMW27 renders at parity
(`packaging/embree/README.md`); a `-mcpu=power8` build contains no ISA 3.0
instruction. Packaged library: 1,896,754 -> 1,735,670 instructions,
control-vector permutes 22,472 -> 2,750, fused FMAs 54,200 -> 58,651.

Send to: <https://github.com/RenderKit/embree>, together with 5.

### 6. openvkl -- add a VSX ISA

`packaging/openvkl/openvkl-ppc64le.patch`

CMake only. Open VKL's ISA selection knows x86 and NEON and passes
`--arch=x86-64` or `aarch64`. The patch adds `OPENVKL_ISA_VSX` (one 4-wide
device from `vsx-i32x4`, no `-msse4.2` width flag, `--arch=ppc64le`) and
exports it from `openvklConfig.cmake` for OSPRay, plus a `VKL_ISPC_TARGET_VSX`
enum value so the device reports `ISA: VSX` (it said `UNKNOWN`). Requires
ispc >= 1.31 built with `PPC64_ENABLED`. Verified: `vklTestsCPU` passes all 47
cases (310,680,004 assertions) on POWER9.

Send to: <https://github.com/RenderKit/openvkl>.

### 7. openimagedenoise -- `OIDN_ARCH=PPC64LE`

`packaging/openimagedenoise/oidn-ppc64le.patch`

OIDN's CPU device is ISPC kernels; the x86-only parts (cpuid, AMX, DNNL) are
already gated behind `OIDN_ARCH_X64` and AArch64 takes the generic ISPC path.
The patch adds `PPC64LE` beside `ARM64`: `vsx-i32x8` / `vsx-i16x16` targets
(same widths as NEON, so the same channel-block size and conv blocking
constants), `--arch=ppc64le`, and a `CPUArch::VSX` value on both the ISPC and
C++ side -- without it `getCPUArch()` is `#error`, and a stub would make the
device enumerate as `Unknown` and register nothing.

One link-time wrinkle worth upstream's attention: ispc lowers `float16` on the
VSX targets through LLVM's soft-float helpers (`__extendhfsf2`,
`__truncsfhf2`, ...), which libgcc does not provide on POWER (GCC has no
`_Float16` there). The device module then links but fails `dlopen(RTLD_NOW)`
with `undefined symbol: __extendhfsf2` and OIDN sees no CPU device. The patch
links compiler-rt's builtins archive into the module on PPC64LE
(`OIDN_PPC64LE_RT_BUILTINS`, auto-detected). Verified: `oidnTest` passes all
16 cases on POWER9.

Send to: <https://github.com/RenderKit/oidn>.

### 8. ospray -- add a VSX ISA

`packaging/ospray/ospray-ppc64le.patch`

OSPRay derives its ISPC target list from the ISAs Embree and Open VKL report
and only knows the x86 and NEON names. The patch adds `VSX` (Embree SSE4.2 +
`OPENVKL_ISA_VSX` -> `vsx-i32x4`), exempts it from the dummy-second-target
rule like NEON, names it in the ISA report, and teaches OSPRay's private copy
of ispcrt's helper (`cmake/compiler/ispc.cmake`, same defect as #4) to pass
`--arch=ppc64le`. Verified: upstream's `ospTutorial.c` renders through the
whole stack on POWER9.

Send to: <https://github.com/RenderKit/ospray>.

### 11. blender -- a native VSX Cycles CPU kernel (and the SSE kernel through the compat headers)

`packaging/blender/cycles-vsx.patch`

Cycles compiles one 4-wide CPU kernel per ISA: SSE4.2 (the x86-64 baseline),
AVX2, and on ARM the SSE4.2 kernel through `sse2neon`. `util/optimization.h`
sets `__KERNEL_SSE__`..`__KERNEL_SSE42__` for x86-64 and `__ARM_NEON &&
WITH_SSE2NEON`, and nothing else -- so on POWER every kernel was scalar. The
patch adds `CYCLES_PPC64LE_SIMD=VSX|SSE2VSX|SCALAR`:

- **VSX** (default): the vector layer written on VSX. `float4`/`float3` hold
  a `__vector float`, `int4`/`int3` a `__vector int`, and every gated
  operation in `util/{types,math}_{float4,float3,int4,int3}.h`, `transform.h`,
  `math_intersect.h`, `math_fast.h` has a `__KERNEL_VSX__` implementation:
  `__builtin_shuffle` with constant masks (single-op permutes where they
  exist), `vec_sld` rotations for the reductions, `vec_madd`/`vec_msub` (GCC
  fuses nothing vector under `-ffp-contract=on`), `vec_insert(0,a,3)` to
  drop w, `vctsxs` truncating conversions like the scalar `(int)` casts,
  an 8-op merge transpose + three FMAs for `transform_point`. No x86
  intrinsic is used or emulated; nothing includes a compat header, so the
  build itself proves completeness.
- **SSE2VSX**: the x86 kernel unchanged through GCC's/clang's
  `<xmmintrin.h>`..`<nmmintrin.h>` for powerpc64le (`__KERNEL_SSE2VSX__`),
  the technique Embree was ported with (#5), plus the one intrinsic they
  lack, `_mm_dp_ps`.
- Common: `__builtin_ctz/clz` bit scans for any GCC/clang target (the
  generic fallback loops up to 64 times and shifts `1 << bit` as an `int` in
  `bitscan(uint64_t)`); `"VSX"` / `"SSE4.2 on VSX"` in
  `device_cpu_capabilities()`.

Verified on POWER9, GCC 16: an 8,967-operation probe against the scalar
definitions (handbook `probes/cycles_vsx_probe.cpp`) -- 8,276 bit-identical,
688 within rounding-order tolerance, 3 documented differences (`round`
ties-to-even as SSE; `xvminsp/xvmaxsp` return the non-NaN operand), 0
mismatches; BMW27 / Classroom render to PSNR 59 / 49 dB against the scalar
kernel, the same as the SSE kernel scores. Kernel object: 895 control-vector
permutes and 2,194 fused vector multiply-adds vs 10,675 and 6 for the compat
build. Render time versus the scalar kernel is not yet measured on an idle
machine; the procedure is in `packaging/blender/README.md`.

Two upstream-relevant side findings: the x86 SSE kernel's `make_int4(float4)`
rounds to nearest while every other path truncates (the probe shows 184
records differing from the scalar definition on x86 semantics alone); and
`cross(float4)` with a fused `msub` leaves a rounding residual in w, which
the VSX path clears explicitly.

Send to: <https://projects.blender.org/blender/blender> (Cycles module).
Nobody has a POWER kernel for Cycles.

### 12. blender -- OIDN is hidden behind an x86 cpuid check

`packaging/blender/oidn-ppc64le-supported.patch`

Cycles' `openimagedenoise_supported()` and the compositor Denoise node's
`is_oidn_supported()` return `true` on Apple and ARM64 and otherwise fall
through to an SSE4.2 cpuid probe (`system_cpu_support_sse42()` /
`BLI_cpu_support_sse42()`), which is always false on POWER. A Blender linked
against `libOpenImageDenoise` therefore still reports
`_cycles.with_openimagedenoise == False`, the render-time denoiser sets
"OpenImageDenoiser is not supported on this CPU: missing SSE 4.1 support",
and the node draws "Unsupported CPU". The patch adds a `__powerpc64__ &&
__VSX__` branch beside the ARM64 one in both places.

Only meaningful together with the OIDN port (#7): upstream OIDN has no POWER
CPU device, so upstream Blender is right to say no until that lands. Send
both, in that order.

## Reports that belong to Omarchy upstream

### 13. `omarchy-nvim` declares `arch=any` while vendoring two x86-64 binaries

`packaging/ours/omarchy-nvim/PKGBUILD`

`omarchy-nvim` is published as `arch=any`. It is not. Of the 7,934 files in
upstream's `2026.8.13-1` package (63 MB unpacked), all but two are shell, Lua,
TOML, JSON, desktop entries and images — and those two are ELF `x86-64`
executables, installed into every user's home through `/etc/skel`:

```
etc/skel/.local/share/nvim/mason/packages/shfmt/shfmt_v3.13.1_linux_amd64
etc/skel/.local/share/nvim/mason/packages/stylua/stylua
```

They are mason's vendored copies of `shfmt` and `stylua`. On any non-x86-64
machine the package installs cleanly, and then the two formatters fail at
runtime with `Exec format error` — the failure lands on the user, at the point
of use, rather than on the package manager at install time, which is precisely
what `arch=` exists to prevent.

Both tools are packaged natively for every architecture Arch and Arch POWER
build. So the fix does not require a port and does not require per-arch
packages:

1. Drop the two vendored binaries from the tree.
2. Add `shfmt` and `stylua` to `depends=()`.
3. Point mason's `bin/` symlinks at `/usr/bin/shfmt` and `/usr/bin/stylua`,
   which keeps mason's own receipts consistent with what actually runs.

The package is then genuinely `arch=any`, and the architecture dependence lives
where it belongs — in `depends=()`, resolved by pacman. This is what
`packaging/ours/omarchy-nvim/PKGBUILD` does here, and its `check()` fails the build if
a third ELF ever appears, rather than shipping a foreign one.

A second, related point for the same package: mason's registry has **no ppc64le
assets at all**, so its automatic installs cannot succeed here. We ship a
drop-in (`no-mason-downloads.lua`) that disables them and lets every tool
resolve from `$PATH`. On x86-64 that is a preference; on any other architecture
it is the only configuration that works. Worth upstreaming as an arch-conditional
default rather than a ppc64le patch.

Send to: <https://github.com/basecamp/omarchy>. Note that upstream publishes
built packages only — `pkgs.omarchy.org` carries no PKGBUILD — so there is no
recipe in the tree to patch. Fixing this properly means the build recipe has to
exist somewhere a second architecture can build from, which is the same
structural change an official ppc64le arch needs anyway.

## Reports that belong to Arch POWER, not upstream

### `libheif` is built against a newer `libde265` than the repo ships

Arch POWER ships `libheif 1.23.1-1` and `libde265 1.0.18-1`. That libheif has an
undefined reference to `de265_get_security_limits`, which `libde265 1.0.18` does
not export — it arrived later, and Arch proper is on `libde265 1.1.2`.

Consequence: *anything* linking libheif fails at link time under
`-Wl,--no-undefined`, which is Arch's default. We hit it building `imv`;
obs-studio, the GNOME apps and any gdk-pixbuf thumbnailer path would hit it too.

Not a portability bug — it reproduces on any architecture with that pair of
packages. It is a repo-consistency bug, and the fix is for Arch POWER to build
`libde265 1.1.2`. We carry `packaging/libde265/` (Arch's PKGBUILD plus
`powerpc64le` in `arch()`) in the meantime.

### `openimageio` is built against `openjph 0.27`, and `blender` against ffmpeg 8

Arch POWER ships `openimageio 3.1.11.0-3` linked to `libopenjph.so.0.27`
(their `openjph` is `0.27.0-1`). This repo's `repo/` carries `openjph
0.31.0-1` -- with no `packaging/openjph/` recipe, which is its own problem --
so on a system with `[omarchy-power9]` enabled pacman resolves the newer
openjph and everything linking OpenImageIO fails to load
(`libopenjph.so.0.27: cannot open shared object file`). Arch proper already
rebuilt (`openimageio 3.1.12.1-5` is the 0.31 rebuild); `packaging/openimageio/`
is that recipe with the arch gate lifted.

Same shape: Arch POWER's `blender 17:5.1.0-2` links `libavcodec.so.62`
(ffmpeg 8) while their repo now ships ffmpeg 9 (`libavcodec.so.63`), so the
package they ship does not start. `packaging/blender/` carries Arch's
`ffmpeg-9.patch` and builds against ffmpeg 9.

### 9. hsa-rocr — the HSA runtime's device-visibility fences are x86 intrinsics with no other-arch definition

`packaging/hsa-rocr/0001-ppc64le-fences-spin-hint-and-image-support.patch`

`runtime/hsa-runtime/core/util/utils.h` includes `<x86intrin.h>` only on x86,
yet `amd_aql_queue.cpp` (the doorbell write), `amd_blit_kernel.cpp` and
`intercept_queue.cpp` (device-memory ring headers) and `amd_gpu_agent.h`
(`PcieWcFlush`) call `_mm_sfence()`/`_mm_mfence()` with no arch guard, and
`locks.h` spins on `_mm_pause()`. The portable atomics layer next to them
(`atomic_helpers.h`) is properly `#if`-gated; these sites were simply never
compiled anywhere but x86 (and, since 7.x, loongarch64, which got an empty
branch in `image/util.h` and nothing here — so it cannot build either).

The patch adds a `__powerpc64__` branch defining the four names (the fences,
`_mm_pause()`, and `_mm_clflush()` as `dcbf` per line -- `FlushCacheLines()`
already strides by `sysconf(_SC_LEVEL1_DCACHE_LINESIZE)`). The non-obvious
part is the barrier: both fences are a full `sync`, **not** the
`lwsync` that GCC's own powerpc `<xmmintrin.h>` compat header would give for
`_mm_sfence()`. Every call site orders cacheable stores ahead of a store to a
KFD mapping that is caching-inhibited on POWER, and Power ISA 3.0B Book II
4.6.1 excludes Caching Inhibited storage from `lwsync`'s ordering — the same
reason powerpc `writel()` is `sync; stw`. A release fence would compile and
leave the AQL packet body racing the doorbell. Two more hunks: the
`#error "Processor not identified"` in `image/util.h` admits `__powerpc64__`,
and `IMAGE_SUPPORT` defaults on for `ppc64le|powerpc64le` — CLR refuses an
agent without the image extension, so OFF is not a degraded build but no HIP
device at all.

The last hunk is the one a green build never shows. Both
`dl_iterate_phdr()` callbacks (`os_linux.cpp` `GetLoadedToolsLib()`,
`amd_hsa_loader.cpp`) skip the vDSO by testing `dlpi_name` for
`"vdso.so"`. The soname is `linux-vdso.so.1` on x86/aarch64 but
`linux-vdso64.so.1` on ppc64, so the filter misses; the vDSO's `_DYNAMIC`
is the one object whose entries ld.so does not relocate in place, so the
walk reads the link-time `DT_STRTAB` offset (`0x2d8`) through
`ABS_ADDR() == (ptr)` and `strcmp()`s it. Every `hsa_init()` segfaulted.
Match `"vdso"`.

**Not ppc64le-specific in shape**: any weakly-ordered host (riscv64, s390x,
the loongarch64 port upstream has already started) needs the same
definitions with its own barrier and spin hint, and the vDSO test is wrong
on every architecture whose soname is not exactly `linux-vdso.so.1`.

Send to: <https://github.com/ROCm/rocm-systems> (`projects/rocr-runtime`).

### 10. CLR — `top.hpp` classifies hosts as ARM or x86 only; kernarg flush fences are unguarded

`packaging/hip-runtime/0001-clr-ppc64le-arch-fences-and-spin-hint.patch`

`rocclr/include/top.hpp` defines `ATI_ARCH_ARM` or `ATI_ARCH_X86` and nothing
for any other host. Mostly that is silent (`Os::spinPause()` becomes a no-op)
but `device/rocm/rocvirtual.cpp` and `hipamd/src/hip_graph_internal.cpp` call
`_mm_sfence()`/`_mm_mfence()` unguarded around the large-BAR kernarg
write-and-read-back, so the build fails there. The patch adds
`ATI_ARCH_PPC64`, defines the two fences as a full `sync` (same reasoning as
above: the buffer is caching-inhibited device memory), and gives
`spinPause()` the powerpc kernel's `cpu_relax()` (`or 1,1,1; or 2,2,2`).

Send to: <https://github.com/ROCm/rocm-systems> (`projects/clr`).

### 11. clang — the PowerPC target defines no `__bf16`, so HIP's bf16 header cannot be compiled on a ppc64le host

`packaging/rocm-llvm/0002-clang-PowerPC-give-__bf16-a-storage-type-and-soft-arithmetic.patch`

`clang/lib/Basic/Targets/PPC.h` never sets `BFloat16Width/Align/Format` or
`HasBFloat16`. On powerpc64le `__bf16` is therefore "not supported on this
target" in C++ and, under HIP's CUDA-style relaxed type checking, a
zero-width type. `hip/amd_detail/amd_hip_bf16.h` static-asserts
`sizeof(__bf16) == sizeof(unsigned short)` in the host pass and gives
`__hip_bfloat16` a `__bf16` member; every `.cu` in llama.cpp's ggml-hip
includes it. Result on a ppc64le host: the assert fails in the host pass
and the device pass (`-aux-triple powerpc64le`) segfaults in `ParseAST` on
the aux target's zero-width bf16.

The clang half mirrors X86 without AVX512-BF16: 16-bit storage, BFloat
format, `HasBFloat16` (soft arithmetic), no `HasFullBFloat16`. That alone is
not enough: once clang emits `bf16`, compiler-rt builds
`truncsfbf2.c`/`truncdfbf2.c` for powerpc64le and the backend has no actions
for the nodes ("Cannot select: f32 = bf16_to_fp"). The llvm half, in
`PPCISelLowering`, sets bf16 extending loads and truncating stores to
Expand, `BF16_TO_FP` to Expand (it is a shift), and `FP_TO_BF16` to Custom,
a libcall to `__truncsfbf2`/`__truncdfbf2`. It's Custom rather than Expand
because the generic expansion truncates instead of rounding and emits
`FCANONICALIZE`, which this backend marks Legal for f32 but cannot select.
That's a separate latent bug, not touched here. The patch header has the
details; `packaging/rocm-llvm/bf16-ppc64le-roundtrip.c` checks rounding bit
for bit against a round-to-nearest-even reference.

GCC has no `__bf16` on PowerPC, so there is no ABI boundary to break.
**Not ppc64le-specific in shape**: any clang target that leaves the bf16
fields unset (s390x, mips, sparc) fails HIP host compilation the same way,
and PyTorch's ROCm build includes the same header.

Send to: <https://github.com/llvm/llvm-project> (clang + PowerPC backend).

### 12. CLR — `char1`..`char4` are plain `char`, so unsigned on a POWER host; CUDA's are `signed char`

`packaging/hip-runtime/0002-clr-char-vectors-signed-on-unsigned-char-hosts.patch`

`amd_hip_vector_types.h` builds the char vectors with
`__MAKE_VECTOR_TYPE__(char, char)`. CUDA's `vector_types.h` uses `signed
char`, and HIP's own `make_char1..4` already take `signed char`. Plain char
is unsigned on ppc64le, and the HIP device pass inherits the host's
signedness (`-fno-signed-char` on the `-aux-triple powerpc64le` cc1 line),
so on the GPU `char4` is four unsigned bytes. CUDA-ported code that stores a
negative value into a member performs a float-to-unsigned conversion, which
AMDGPU clamps to 0.

This compiles cleanly and runs at full speed, with wrong results. llama.cpp's
`quantize_mmq_q8_1` does `char4 q; q.x = roundf(v)` with v in [-127, 127],
so every quantized matmul wider than 8 columns (the MMQ path) zeroed all
negative activations. Qwen3-8B on the RX 7900 XTX generated garbage at
100 tok/s. `test-backend-ops -o MUL_MAT` failed 178 of 1,021 cases, all
quantized types with n >= 16; MMVQ (n <= 8, `int8_t`) passed. With the
patch, 13 fail, all `iq1_s`, which `-fsigned-char` leaves failing too, so
that's a separate issue. The model output then matches the CPU backend word for word.

Conditional on `__CHAR_UNSIGNED__`, so x86 keeps `char4`'s type identity
and C++ mangling. `math_fwd.h`'s `__ockl_sdot4` declaration takes `char4`'s
native vector and follows it (extern "C", ockl takes `<4 x i8>`).
**Affects aarch64 hosts identically.**

Send to: <https://github.com/ROCm/rocm-systems> (`projects/clr`). Worth a
note to llama.cpp as well: `int8_t` instead of `char4` in `quantize.cu`
would not depend on the header's choice.

## Packaging substitutions — local, not upstreamable

These are correct for this port and wrong to send anywhere. They exist because a
build-time tool is missing from Arch POWER, not because anything is broken.

| Package | Substitution | Why |
|---|---|---|
| `eza` | `pandoc` → `go-md2man` for man pages | Arch POWER has no `ghc` at all; pandoc would mean bootstrapping a Haskell compiler to typeset three man pages |
| `foot` | PGO training `full-headless-sway` → `partial` | `sway` is missing and would pull in `wlroots0.20`, also missing. foot's own pgo.sh supports compositor-free training, so PGO is kept, not lost |
| `bat` | drop `cargo-edit` from makedepends | not in Arch POWER, and the PKGBUILD never invokes it |
| `obs-studio` | `-DENABLE_BROWSER=OFF`, and the `obs-studio-plugin-browser` split package is not produced | CEF publishes no ppc64le build, and building it means building Chromium |
| `rnnoise` | `--enable-x86-rtcd` made conditional on `CARCH` | x86 run-time SIMD dispatch; no VSX backend exists. Costs performance, not correctness |
| `marksman` | `global.json` removed; framework-dependent publish instead of self-contained | Arch POWER's .NET 9 SDK is a prerelease, which `rollForward` can never select; and Microsoft publishes no ppc64le runtime pack, so self-contained publishing is impossible |
| `plymouth` | Arch logo files made optional | Arch POWER's `filesystem` ships `/usr/share/pixmaps` empty |

## Not portability problems at all — they would fail on x86_64 too

Worth separating, because they look like port failures in a build log and are
not. Each of these reproduces on any architecture with the same toolchain and
distro state.

| Package | Symptom | Actual cause |
|---|---|---|
| `evince` | `conflicting types for 'getenv'; have 'char *(void)'` | gcc 16 defaults to C23, where `()` means `(void)`. texlive's kpathsea headers still use the K&R form. Pinned to `-D c_std=gnu17`. |
| `websocketpp` | `Could not find boost_system` | Boost removed the separate `boost_system` library in 1.90. Only its test suite needs it; built with `-DBUILD_TESTS=OFF`. |
| `sushi` | signature check fails | the tag's signing key is not retrievable from any keyserver, WKD or DANE. The git source's own b2sum still pins the tree, so `--skippgpcheck` loses nothing here. |
| `luarocks`, `fzf`, `system-config-printer`, `gexiv2`, `evince`, `pnpm` | `unknown public key` | keys simply not in the local keyring; `gpg --recv-keys` and continue. |
| `dua-cli` | `bsdtar: Pathname can't be converted from UTF-8 to current locale` | non-interactive ssh lands in the POSIX locale. Environment, not package. |

## Blocked by prebuilt binaries that do not exist for ppc64le

The one category that is neither a portability bug nor a packaging choice: an
ecosystem that ships compiled artifacts per platform and has not built ours.

| Package | Missing artifact | Note |
|---|---|---|
| `obs-studio` (browser source) | CEF | building it means building Chromium; `-DENABLE_BROWSER=OFF` |
| `marksman` (self-contained) | `Microsoft.AspNetCore.App.Runtime.linux-ppc64le` | framework-dependent publish instead |
| `prettier` 3.8.1 | `@oxc-parser/binding-linux-ppc64-gnu` at 0.99.0 | the binding **is** published — from 0.104.0. A version window, closing on its own. |
| `typescript-language-server` | `@pnpm/exe.linux-ppc64` | pnpm 9 works but rejects the v11 lockfile |
| `obsidian`, `localsend` | Electron / Flutter runtimes | FEX, or drop |

This is the same structural issue `nvim-tooling.md` identifies with mason, and
it is the honest answer to "how ready is ppc64le": the compilers are ready, and
the binary-distribution habits of the JavaScript and .NET ecosystems are not.

## Checksum refreshes — neither

`inxi` and `fcft` both fetch `archive/<tag>.tar.gz` from Codeberg, which
generates those tarballs on demand and not reproducibly, so Arch's recorded
hashes no longer match what the server serves. Tarball contents were verified
before the hashes were updated. This would equally affect an x86_64 rebuild
today; it has nothing to do with the architecture.

## powerpc: `interrupt_exit_user_restart()` loses accumulated `_TIF_RESTOREALL`

**File:** `arch/powerpc/kernel/interrupt.c` (kernel 7.2.x)
**Class:** portability/correctness fix, **upstreamable**
**Relationship:** sibling of the already-in-review
`0002-powerpc-syscall_exit_restart-return-accumulated-exit_result.patch`,
same file, same bug class, different function. Found while investigating the
chromium sandbox failure (`docs/chromium-sandbox-ppc64le.md`); **not yet proven
to be that failure's cause**, but wrong on its own terms.

### Background

powerpc selects `CONFIG_GENERIC_ENTRY` as of 7.2 (`arch/powerpc/Kconfig:209`).
The return value of the `*_exit_*` C helpers is what the assembly in
`arch/powerpc/kernel/interrupt_64.S` uses to choose between a full GPR restore
and a fast path:

```asm
	SANITIZE_RESTORE_NVGPRS()
	cmpdi	r3,0
	bne	.Lsyscall_restore_regs
	/* Zero volatile regs that may contain sensitive kernel data */
	ZEROIZE_GPR(0)
	ZEROIZE_GPRS(4, 12)
	mtctr	r0
```

`ZEROIZE_GPRS(4, 12)` includes **r12**, which under ELFv2 holds the function
entry point at a global entry so the callee can derive its TOC in r2. Losing
`_TIF_RESTOREALL` therefore does not merely clobber scratch registers; it
produces a garbage TOC and a segfault somewhere unrelated. That is exactly the
already-fixed `syscall_exit_restart()` bug.

### The defect

`interrupt_exit_user_restart()` is written as if it accumulates:

```c
notrace unsigned long interrupt_exit_user_restart(struct pt_regs *regs)
{
	...
	regs->exit_result |= interrupt_exit_user_prepare(regs);
	return regs->exit_result;
}
```

but the callee overwrites the very field the caller is OR-ing into:

```c
notrace unsigned long interrupt_exit_user_prepare(struct pt_regs *regs)
{
	...
	/* Clear exit_flags so only flags set during this exit are visible */
	current_thread_info()->exit_flags = 0;
	...
	ret = current_thread_info()->exit_flags & _TIF_RESTOREALL;
#ifdef CONFIG_PPC64
	regs->exit_result = ret;          /* <-- destroys the accumulation */
#endif
	return ret;
}
```

Sequence on a restart:

1. `interrupt_exit_user_prepare()` zeroes `exit_flags`, discarding the
   `_TIF_RESTOREALL` that `arch_do_signal_or_restart()`
   (`arch/powerpc/kernel/signal.c:359`) set during the first pass;
2. `ret` is therefore 0;
3. `regs->exit_result = 0` overwrites the value the first pass accumulated;
4. the caller's `|= 0` is a no-op;
5. 0 is returned, the asm takes the fast path, and r4-r12 are zeroed on a
   return that required a full restore.

The `|=` in the caller is the tell: accumulation was clearly intended there and
is silently defeated.

### Proposed fix

Same shape as the accepted `syscall_exit_restart()` fix -- preserve the
accumulated value across the call rather than changing `..._prepare()`, which
is also called on the non-restart path where `regs->exit_result` is stale:

```c
 notrace unsigned long interrupt_exit_user_restart(struct pt_regs *regs)
 {
+	unsigned long accumulated = regs->exit_result;
+
 	__hard_irq_disable();
 	local_paca->irq_happened |= PACA_IRQ_HARD_DIS;
 	...
-	regs->exit_result |= interrupt_exit_user_prepare(regs);
-
+	accumulated |= interrupt_exit_user_prepare(regs);
+	regs->exit_result = accumulated;
 	return regs->exit_result;
 }
```

### Status / caveats

- Reviewed by reading 7.2.2 source; **not compiled or booted**. The kernel is
  the daily-driver boot path and was not rebuilt.
- `~/Development/linux-7.2.2` is a plain tree with no `.git`, so
  `git log v7.1..v7.2` could not be run there to date the change or find the
  introducing commit. A clone would be needed.
- Worth sending alongside the `syscall_exit_restart()` patch already in review,
  since it is the same reviewer, same file, same argument.

## powerpc/eeh: `pci_rescan_remove_lock` self-deadlock in `eeh_rmv_device()`

Patch: `0006-powerpc-eeh-fix-pci_rescan_remove_lock-self-deadlock-in-eeh_rmv_device.patch`
(carried in `packaging/ours/linux-power9`, applied to `~/Development/linux-7.2.2`).

Since `1010b4c012b0` ("powerpc/eeh: Make EEH driver device hotplug safe"),
`eeh_handle_normal_event()` takes `pci_rescan_remove_lock` on entry and holds it
across `eeh_reset_device()`. A later fix, `815a8d2feb56`, removed the recursive
acquisition in `eeh_pe_bus_get()` but left the one in `eeh_rmv_device()`, which
still wraps `pci_stop_and_remove_bus_device()` in the same non-recursive mutex.
Every caller already holds it, so the first PE reset involving a device whose
driver has no EEH error handlers deadlocks `eehd` against itself. The fix drops
the lock/unlock pair — `pci_stop_and_remove_bus_device()` asserts the caller
holds it.

`Cc: stable@vger.kernel.org # v6.17+`.

### Confirmed in the field, 2026-09-10

This is the strongest evidence we have for any patch here: the bug reproduced on
this machine, on the exact device the commit message cites, and the fix held.

PHB 0030 carries an AMD `1022:43f4/43f5` PCIe switch with both NVMe drives *and*
the SATA controller behind it, so a PE freeze there takes the root disk with it.
A freeze hit at t=2610s under heavy parallel build I/O, during `diffutils`'
test suite — shortly after `MAKEFLAGS=-j144` was enabled, which is the first
thing on this box to drive that many concurrent readers — and went straight down
the path that deadlocks:

```
EEH: Reset without hotplug activity
EEH: Removing 0030:0f:00.0 without EEH sensitive driver
EEH: Removing 0030:10:00.0 without EEH sensitive driver
```

`0030:0f:00.0` is the same device named in the upstream commit message, and
`0030:10:00.0` is the AMD 600-series SATA controller — `ahci`, one of the
drivers the message calls out by name.

With the patch, recovery completed in ~16 seconds:

```
EEH: Beginning: 'slot_reset'
  0030:0d:00.0  nvme2 (root)    -> 'recovered'
  0030:0e:00.0  nvme1 (1TB)     -> 'recovered'
EEH: Finished:'slot_reset' with aggregate recovery state:'recovered'
EEH: Finished:'resume'
EEH: Recovery successful.
```

No hung-task or soft-lockup warnings, and no filesystem damage: the two
in-flight reads that failed came back `sct 0x3 / sc 0x71` (Path Related Status /
Transient Transport Error — the PCIe transport, not media), the block layer
retried them after recovery, and `btrfs device stats` reports zeros across the
board on both mounted filesystems.

Without the patch this would have been a 122-second blocked `eehd`, a PE that is
never reset, and the global rescan/remove lock held for the remaining uptime.

### Status

- **Applied, booted, and now exercised in production.** Unlike the
  `interrupt_exit_user_restart()` patch above, this one is not a
  read-the-source review — it is running in `linux-power9 7.2.2-17`.
- Ready to send. The reproduction above is worth including in the submission:
  it is a real EEH event on a Witherspoon AC922, not a synthetic injection.

## Mono (dotnet/runtime): ppc64le ELFv2 small-struct returns and arguments

`packaging/dotnet/dotnet-core/mono-ppc64le-elfv2-small-aggregates.patch` (paths relative
to `src/runtime`, so it applies to dotnet/runtime as is).

Mono's ppc64 JIT returned every struct through a hidden pointer in r3, the old
ppc32 rule. ELFv2 returns aggregates of 16 bytes or less in r3/r4, and
homogeneous float/double aggregates of up to 8 members in f1-f8, so every real
argument of a P/Invoke returning a small struct landed one register late.
`PPC_RETURN_SMALL_STRUCTS_IN_REGS` and `is_struct_returnable_via_regs()` already
existed in `mini-ppc.c` but `get_call_info()` never used them. A second bug:
structs under 8 bytes were loaded as a full word, so the upper half of the
register carried stack garbage where GCC expects zero or sign extension.

Any GirCore/GTK application (Pinta) dies at its first signal connect without
it: `g_signal_connect_closure_by_id` returns `CULong`, a one-field struct.
Present in IBM's 10.0.111 ppc64le build and in dotnet/runtime `main`; no
upstream issue existed as of 2026-09-13. Tested against GCC 16 on 50 cases
(integer, mixed, HFA 1-9 members, nested, packed 17-byte, callbacks): stock
4/50, patched 50/50.

Send to: dotnet/runtime (precedent for Mono ppc64le fixes: PR #98923).

## Blender Cycles: CPU name from `/proc/cpuinfo` on POWER

`packaging/blender/cycles-power-cpu-name.patch`. `system_cpu_brand_string()`
reads `model name`, which POWER's cpuinfo does not have, so Cycles lists
"Unknown CPU". The patch reads the `cpu` field ("POWER9, altivec supported")
instead. That half is a plain portability fix; the "(VSX)" kernel suffix only
makes sense together with `cycles-vsx.patch`.

## Chromium (Debian ppc64le series): seccomp-bpf trap returns use the `sc` convention for `scv` callers

`packaging/chromium/ppc64le-seccomp-scv-return-abi.patch` (identical copy in
`packaging/electron43/`). Applies after the Debian ppc64le tarball, on top of
`sandbox/0001-sandbox-Enable-seccomp_bpf-for-ppc64.patch`.

The ppc64 seccomp-bpf support in the Debian chromium-team series (from Raptor
Engineering) writes the result of a system call emulated in the SIGSYS trap
handler back using only the `sc` convention: `+errno` in r3 with CR0.SO set.
glibc on POWER9 makes system calls with `scv 0`, whose convention is `-errno` in
r3 with no SO bit. So every emulated *error* reads back in glibc as a positive
*success*: a broker-denied `open()` returns file descriptor 2. Chromium adopts
and closes descriptors it does not own. The ppc64 first-argument workaround in
`Trap::SigSys()` is `sc`-specific in the same way, and negates valid directory
fds for `scv` callers.

Seen as the GPU process dying on the software path (`--disable-gpu`: headless,
no accelerated driver, Electron apps with hardware acceleration off):
"Crashing due to FD ownership violation", then
"GPU process isn't usable. Goodbye.". `--no-sandbox` hides it. The patch reads
the trap value from the saved registers (`0x3000` means `scv`). It encodes
results, and applies the argument workarounds, in the caller's convention.
`sc` behaviour is unchanged.

Reproducer: `docs/seccomp-scv-return-abi-repro.c`. With Debian's encoding every
`scv` error case is wrong; with the patch all 12 cases are correct for glibc,
raw `sc` and raw `scv` callers. Full write-up:
`docs/chromium-software-raster-crash.md`.

Send to: the Debian chromium-team ppc64le series
(<https://salsa.debian.org/chromium-team/chromium>, `debian/patches/ppc64le/`),
and Chromium upstream if the ppc64 sandbox code is carried there.

## Mono (dotnet/runtime): static virtual methods constrained to an interface

`packaging/dotnet/dotnet-core/mono-static-virtual-interface-constraint.patch`

When generic code calls a static virtual method through a type parameter that
is itself an interface (`TSender.GetGType()` where `TSender` is an interface
implementing a base interface's static abstract member), Mono's
`get_method_constrained()` and the matching shortcut in generic sharing
resolve to the base declaration, which has no body. CoreCLR resolves to the
interface's implementation. Depending on sharing, Mono asserts in
`mini-generic-sharing.c`, throws `BadImageFormatException` ("Method has no
body"), or silently calls the wrong override.

Not ppc64le-specific: every architecture running Mono is affected. It is the
bug behind Pinta (GirCore) failing silently while building its main window, so
New, Open and dialogs did nothing. Reported upstream as dotnet/runtime #82217,
which was closed as a duplicate of #79331 (a different, still-open reflection
issue); `main` is unchanged. Tested: 9 static-virtual cases correct (stock Mono
fails all of them), no regression in the 50-case ELFv2 suite, and Pinta's New,
Open and About all work.

Send to: dotnet/runtime, referencing #82217.
