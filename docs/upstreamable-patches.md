# Upstreamable patches

Changes made in this repo that are **portability fixes other people would
want**, as opposed to local packaging workarounds. Kept separate deliberately:
the ratio between the two columns is the most honest measure of how ready
ppc64le actually is.

## Source patches worth sending upstream

### 1. rnnoise — `src/vec.h`'s scalar fallback has never compiled

`packages/rnnoise/0001-vec.h-fix-the-scalar-fallback-path.patch`

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

`packages/marksman/0001-Makefile-recognise-ppc64le-riscv64-and-s390x.patch`

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

`packages/neovim/0001-findlpeg-link-by-name-not-absolute-path.patch`

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
Python, Lua, Rust, Go, C and C++. Every other diff in `packages/` is in a
PKGBUILD, and 59 of the 87 are `arch=()` alone.

The first two are the arch-gating pattern from the handbook, holding at scale:
the substrate is first class, and what breaks is code and metadata that was never
told the architecture was allowed -- a generic fallback branch nobody had ever
taken. The third is a different animal and worth naming as such: not an
architecture bug at all, but a latent defect every distro ships and none notices,
because on an ordinary builder the wrong answer and the right answer are the same
string. It took an unprivileged sysroot build to pull them apart.

### 4. ispc -- the ispcrt CMake helper does not know about the new ppc64le backend

`packages/ispc/ispcrt-cmake-ppc64le.patch`

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

`packages/rkcommon/rkcommon-ppc64le.patch`

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

`packages/embree/embree-ppc64le.patch`

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

### 6. openvkl -- add a VSX ISA

`packages/openvkl/openvkl-ppc64le.patch`

CMake only. Open VKL's ISA selection knows x86 and NEON and passes
`--arch=x86-64` or `aarch64`. The patch adds `OPENVKL_ISA_VSX` (one 4-wide
device from `vsx-i32x4`, no `-msse4.2` width flag, `--arch=ppc64le`) and
exports it from `openvklConfig.cmake` for OSPRay, plus a `VKL_ISPC_TARGET_VSX`
enum value so the device reports `ISA: VSX` (it said `UNKNOWN`). Requires
ispc >= 1.31 built with `PPC64_ENABLED`. Verified: `vklTestsCPU` passes all 47
cases (310,680,004 assertions) on POWER9.

Send to: <https://github.com/RenderKit/openvkl>.

### 7. openimagedenoise -- `OIDN_ARCH=PPC64LE`

`packages/openimagedenoise/oidn-ppc64le.patch`

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

`packages/ospray/ospray-ppc64le.patch`

OSPRay derives its ISPC target list from the ISAs Embree and Open VKL report
and only knows the x86 and NEON names. The patch adds `VSX` (Embree SSE4.2 +
`OPENVKL_ISA_VSX` -> `vsx-i32x4`), exempts it from the dummy-second-target
rule like NEON, names it in the ISA report, and teaches OSPRay's private copy
of ispcrt's helper (`cmake/compiler/ispc.cmake`, same defect as #4) to pass
`--arch=ppc64le`. Verified: upstream's `ospTutorial.c` renders through the
whole stack on POWER9.

Send to: <https://github.com/RenderKit/ospray>.

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
`libde265 1.1.2`. We carry `packages/libde265/` (Arch's PKGBUILD plus
`powerpc64le` in `arch()`) in the meantime.

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
