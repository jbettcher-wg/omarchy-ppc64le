# Chromium software-rendering crash on ppc64le (POWER9)

**Status:** root-caused and fixed by `ppc64le-seccomp-scv-return-abi.patch`,
carried in `packages/chromium` (151.0.7922.108-3) and `packages/electron43`
(43.7.0-2, Chromium 150.0.7871.250).

**Bug.** The crash is not in Skia, SwiftShader, SIMD code or an ELFv2 ABI path.
It is in the ppc64 seccomp-bpf support from the Debian chromium-team ppc64le
series (`sandbox/0001-sandbox-Enable-seccomp_bpf-for-ppc64.patch`, originally
Raptor Engineering). When the sandbox's SIGSYS trap handler emulates a system
call, it writes the result back using only the `sc` convention. glibc on POWER9
makes system calls with `scv 0`, which uses a different convention. A *denied*
emulated call then reads back in glibc as *success returning a small file
descriptor*. Chromium adopts and closes descriptors it does not own and trips
its own FD-ownership `CHECK`.

**Scope.** Anyone running Chromium or Electron on POWER9 on the software path
(`--disable-gpu` / `--use-gl=disabled`: headless CI, no accelerated driver,
AST VGA, Electron apps with hardware acceleration off) with the sandbox
enabled. It was not observed on the hardware-GPU path.

## Reproduction

Host: `omarchy-power9` / 192.168.2.24, AC922 POWER9, glibc 2.43,
`AT_PLATFORM=power9`. All runs used an isolated `--user-data-dir` with
`XDG_CONFIG_HOME` and `XDG_CACHE_HOME` redirected away from the user's profile.
The driver (`cdpdrive.js`, node 26 built-in `WebSocket`) runs a navigate +
evaluate + synthetic-click loop over CDP against
`/usr/lib/chromium/chromium --headless --disable-gpu --remote-debugging-port=0`.

Symptom (matches the bun webview sighting and the Obsidian sighting):

```
Crashing due to FD ownership violation:      <- base/files/scoped_file_linux.cc
GPU process exited unexpectedly: exit_code=133   (x3; also 139/SIGSEGV)
FATAL:content/browser/gpu/gpu_data_manager_impl_private.cc:417]
      GPU process isn't usable. Goodbye.
```

Time-to-crash varies (first GPU exit anywhere from iteration 1 to about 24).
It depends on when a call the sandbox denies happens to run in the GPU process.

## Flag matrix

Each config ran up to 40 navigate/click iterations, headless, with an isolated
profile. "Crash" means the GPU process died and the browser hit the
`GPU process isn't usable` FATAL.

| Flags (all headless)                                   | Runs | Iters ok | GPU deaths | Result | Rules out |
|-------------------------------------------------------|-----:|---------:|-----------:|--------|-----------|
| *(none; ANGLE-SwiftShader GL)*                        | 2 |   80/80  | 0 | clean  | — |
| `--use-angle=swiftshader --enable-unsafe-swiftshader` | 2 |   80/80  | 0 | clean  | SwiftShader itself |
| `--disable-gpu-compositing`                           | 2 |   80/80  | 0 | clean  | viz software compositor |
| `--disable-gpu`                                       | 2 |   21/80  | 6 | CRASH  | — |
| `--disable-gpu --disable-software-rasterizer`         | 2 |   38/80  | 6 | CRASH  | Skia software raster |
| `--disable-gpu --disable-features=SkiaGraphite,Vulkan`| 2 |   36/80  | 6 | CRASH  | Graphite / Vulkan |
| `--disable-gpu --num-raster-threads=1`                | 1 |    0/40  | — | CRASH  | raster-thread race |
| `--disable-gpu --disable-breakpad`                    | 1 |   10/40  | 3 | CRASH  | crashpad |
| `--disable-gpu --disable-features=MojoUseEventFd`     | 1 |   25/40  | 3 | CRASH  | mojo eventfd upgrade (already off on Linux) |
| `--disable-gpu --disable-features=MojoIpcz`           | 1 |    7/40  | 3 | CRASH  | mojo ipcz |
| `--disable-gpu --in-process-gpu`                      | 2 |   80/80  | 0 | clean  | (no separately sandboxed GPU process) |
| **`--disable-gpu --disable-gpu-sandbox`**             | 2 | **80/80**| **0** | **clean** | **isolates it to the sandbox** |
| **`--disable-gpu --no-sandbox`**                      | 2 | **80/80**| **0** | **clean** | **isolates it to the sandbox** |

Turning off the GPU seccomp sandbox (`--disable-gpu-sandbox`) or the whole
sandbox (`--no-sandbox`) removes the crash. Every Skia, SwiftShader, mojo,
raster and crashpad toggle leaves it in place. The matrix ran while another
build loaded the machine, which explains the spread in time-to-crash, not the
clean/crash split.

## Correctness check

Obsidian's software window was reported to render with wrong spacing, so the
software raster output was compared with the GPU path. `Page.captureScreenshot`
captured a fixed test page: text at 10/13/16/24/40 px, 1–3 px borders,
gradients, a rotated box and a flex row.

- Layout geometry (`getBoundingClientRect` of every box) is identical across
  `--disable-gpu`, default, `--use-angle=swiftshader` and
  `--disable-gpu-compositing`.
- Pixels: `--disable-gpu` vs default, AE = 0 (byte-identical).
- `--disable-gpu` vs ANGLE-SwiftShader: 119 of 480,000 pixels differ, which is
  ordinary antialiasing difference.

Headless software raster produces correct geometry. The Skia VSX `min/max`
wrappers do use `vec_min`/`vec_max`, which have different NaN semantics from
SSE (the Embree lesson), but nothing in this crash or this page reaches that.

## Core analysis (stripped binary, build-id `1925d8ad…`)

Cores from one crash burst, classified by signal, faulting thread and
`module+offset`:

| Count | Signal | Process | Thread | Fault site |
|------:|--------|---------|--------|-----------|
| 11 | SIGTRAP | gpu-process | Chrome_ChildIOT | `chromium+0xbcc40c4` |
| 11 | SIGSEGV | gpu-process | Chrome_ChildIOT | `chromium+0xbd07d2c` |
| 3  | SIGSEGV | gpu-process | Chrome_ChildIOT | `chromium+0xc295834` |
| 1  | SIGTRAP | gpu-process | VizCompositorTh | `chromium+0xbd3c2c0` |
| 8  | SIGABRT | browser     | main            | `libc` abort (the FATAL) |
| 18 | SIGTRAP | crashpad    | handler         | `chrome_crashpad_handler+0x246cb8` |

- **`chromium+0xbcc40c4` (SIGTRAP).** The function calls
  `RawLog(2 /*ERROR*/, "Crashing due to FD ownership violation:\n")`, builds a
  2 KB `StackTrace`, then `trap`. The string resolves from the TOC in the core.
  This is `CrashOnFdOwnershipViolation()` in `base/files/scoped_file_linux.cc`:
  a `close()` or `ScopedFD` acquire of an fd already owned elsewhere.
- **`chromium+0xbd07d2c` (SIGSEGV).** A `vector<scoped_refptr<T>>` element copy
  with a non-atomic `++ref_count_` and overflow `trap`, faulting on
  `lwz r5,0(r4)` with `r4 = 0x900000001`: two packed 32-bit integers, not a
  pointer. This is IPC state corrupted after descriptors were closed out from
  under it. The electron43 (Chromium 150) Obsidian core faults in the identical
  code with the identical `r4`.
- **Crashpad handler.** A stack-protector failure (canary compare, then
  `__stack_chk_fail`). It appears only in runs whose GPU process later dies,
  and disappears with the GPU sandbox off. It was not investigated further.

## Root cause

`Syscall::PutValueInUcontext()` in `sandbox/linux/seccomp-bpf/syscall.cc`, as
added by the Debian ppc64 patch:

```c
#if defined(__powerpc64__)
  // Same as MIPS, need to invert ret and set error register (cr0.SO)
  if (ret_val <= -1 && ret_val >= -4095) {
    ret_val = -ret_val;                       // r3 = +errno
    ctx->uc_mcontext.regs->ccr |= (1 << 28);  // set CR0.SO
  } else {
    ctx->uc_mcontext.regs->ccr &= ~(1 << 28);
  }
#endif
  SECCOMP_RESULT(ctx) = static_cast<greg_t>(ret_val);
```

powerpc64 has two system call conventions:

|        | trap   | error return                | success return |
|--------|--------|-----------------------------|----------------|
| `sc`   | 0xc00  | r3 = +errno, CR0.SO set     | r3 = value, CR0.SO clear |
| `scv 0`| 0x3000 | r3 = -errno                 | r3 = value (CR0.SO unused) |

The code above implements only `sc`. glibc on POWER9 uses `scv 0`: this host's
`libc.so.6` has 406 `scv` sites. So when the trap handler emulates a denial
(`-ENOENT`) for a glibc caller, it writes `r3 = 2`, and glibc returns 2 as a
valid descriptor from `open()`. Successful emulated calls happen to survive,
because a positive value reads the same in both conventions. Only error returns
are corrupted, which is why the crash is intermittent and follows denied calls.

The first-argument workaround the same patch adds to `Trap::SigSys()` (negate a
positive first argument for `openat`, `newfstatat` and six others) is also
`sc`-specific. For `scv` callers it turns a valid directory fd into a negative
one. `SIGSYSFstatatHandler()` undoes that for `fstat`.

## Reproducer

`docs/seccomp-scv-return-abi-repro.c` is self-contained and runs unprivileged.
It installs a `SECCOMP_RET_TRAP` filter on `openat` and a SIGSYS handler running
the same encoding and argument workaround as Chromium, in two variants: Debian's
and the patched one. Three callers make the calls: glibc (`scv`), a raw `sc` and
a raw `scv 0`. Each caller issues one denied call and one successful emulated
call, with `AT_FDCWD` and with a real positive dirfd. Output on this host,
condensed:

```
DEBIAN (sc-only encoding, unconditional workaround)
    glibc openat  trap=0x3000 dirfd=-100  denied  -> 2    WRONG
    glibc openat  trap=0x3000 dirfd=3     denied  -> 2    WRONG  (dirfd corrupted)
    raw sc        trap=0x0c00 dirfd=-100  denied  -> -2   ok
    raw scv 0     trap=0x3000 dirfd=3     denied  -> 2    WRONG  (dirfd corrupted)
  => INCORRECT results
FIXED  (trap-aware encoding and workaround)
    glibc openat  trap=0x3000 dirfd=-100  denied  -> -2   ok
    glibc openat  trap=0x3000 dirfd=3     denied  -> -2   ok
    raw sc        trap=0x0c00 dirfd=-100  denied  -> -2   ok
    raw scv 0     trap=0x3000 dirfd=3     denied  -> -2   ok
  => all correct
summary: DEBIAN broken, FIXED correct
```

All 12 cases per variant (3 callers × 2 dirfds × denied/success) are correct
with the fix. The exit status is 0 only if the fixed variant passes.

## Fix

`packages/chromium/ppc64le-seccomp-scv-return-abi.patch`, with an identical copy
in `packages/electron43/`. It is a standalone patch applied right after the
ppc64le patch tarball in both recipes. The trap value in the saved registers
records which instruction the caller used, and the patch uses it:

- `seccomp_macros.h`: `SECCOMP_PPC64_TRAP(ctx)` and
  `SECCOMP_PPC64_IS_SCV(ctx)` (trap `0x3000`, low bits masked).
- `Syscall::PutValueInUcontext()`: for `scv` callers, store the result as-is
  (`-errno` on error) and leave CR0.SO untouched. `sc` callers keep the existing
  encoding.
- `Trap::SigSys()`: apply the first-argument workaround only to `sc` callers,
  and record the caller's convention in a thread-local for the handler's
  duration.
- `SIGSYSFstatatHandler()`: apply its fd fixup only to `sc` callers, via the new
  `Trap::IsEmulatingScvSyscall()`.

`sc` behaviour is unchanged. The patch applies cleanly on top of both the r2
(151) and r3 (150) ppc64le tarballs. No other patch in either recipe touches
these files.

**Upstreamable:** the Debian chromium-team ppc64le series, and Chromium upstream
if the ppc64 sandbox code is carried there.

## Verification

### Builds

POWER9 builds with bq, one at a time, capped at 144 threads, each in the
buildroot its previous build used:

| Package | Buildroot | bq package time | ccache |
|---|---|---:|---|
| chromium 151.0.7922.108-3 | `/var/tmp/omarchy-bq-sweep` | 8,557 s | 0 / 45,288 (0.0%): first build into a new cache |
| electron43 43.7.0-2 | `/var/tmp/omarchy-bq` | 2,225 s | 30,311 / 36,688 (82.6%) |

The prepare log shows the patch applied after the ppc64le tarball in both.

### Smoke tests (sandbox on, run from stage dirs, not installed)

**chromium 151.0.7922.108-3**, headless `--disable-gpu` CDP click loop:
**20/20**, no GPU exits, no FD-ownership violations. The GPU process reported
`sandboxed: true`. `chrome://sandbox` reported Seccomp-BPF Yes, TSYNC Yes, and
"You are adequately sandboxed". The unfixed 151.0.7922.108-2 crashed within
1–10 iterations of the same loop in every run.

**electron43 43.7.0-2**, Obsidian with a throwaway profile and `--disable-gpu`,
driven through the main-process inspector: **15/15** minimize/restore + resize
cycles, no crash events, no `child-process-gone`, no cores, and no
`no-sandbox` / `disable-gpu-sandbox` / `disable-seccomp-filter-sandbox`
switches. Controls with the installed 43.7.0-1:

- Same harness: `Crashing due to FD ownership violation`, then
  `GPU process isn't usable. Goodbye.` at cycle 3. Cores: GPU SIGSEGV ×2,
  GPU SIGTRAP, browser SIGTRAP.
- An earlier harness version: crashed 13 cycles and 30 s in.

Harness note: the first version of the Obsidian driver attached the inspector
before Obsidian's loader swaps `app.asar` for `obsidian.asar`, and stopped runs
with SIGTERM to the process group. On the new build that produced startup and
shutdown failures unrelated to this bug: a browser SIGSEGV while handling
SIGTERM, and a GPU-unusable FATAL during the group kill, also with
`--disable-gpu-sandbox`. The driver now attaches after
`Loaded main app package`, retries context resets, quits through `app.quit()`,
and tags crash signals by phase. The runs above use it; the earlier runs were
discarded.

## Artifacts (on 192.168.2.24, under /var/tmp/swraster-crash)

- `cdpdrive.js`: CDP stress driver (records GPU `sandboxed` and `chrome://sandbox`)
- `obsdrive.js`: Obsidian/electron main-process inspector driver
- `results.jsonl`, `matrix.log`, `summ.py`: matrix data and table
- `coreclass.py`: core classifier used above
- `shots/`: software vs GPU screenshots
