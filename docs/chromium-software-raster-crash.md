# Chromium software-rendering crash on ppc64le (POWER9)

**Status:** root-caused. **Not** a Skia/SwiftShader/SIMD bug and **not** an ELFv2
ABI bug. The crash is in the **seccomp-bpf sandbox return path** carried by the
Debian ppc64le patch set: it encodes an emulated syscall's return value using the
legacy `sc` error ABI, but glibc on POWER9 issues syscalls with `scv 0`, which
uses the opposite convention. A *denied* syscall is then read back by glibc as
*success returning a small file descriptor*, which corrupts FD ownership and
trips Chromium's deliberate `CHECK`/crash.

Applies to our `chromium` 151.0.7922.108-2 and, by the same patch, to
`electron43` 43.7.0-1 (Chromium 150). Affects anyone running Chromium/Electron on
POWER with the software path (`--disable-gpu` / `--use-gl=disabled`, i.e. headless
CI, no accelerated driver, AST VGA) on a glibc+kernel new enough to use `scv`
(glibc ≥ 2.33, kernel ≥ 5.9). The hardware-GPU path is unaffected because its GPU
process reaches steady state without routing the affected syscalls through the
sandbox trap.

## Reproduction

Host: `omarchy-power9` / 192.168.2.24, AC922 POWER9, kernel 7.2.2-64k, glibc
2.43, `AT_PLATFORM=power9`. All work under `/var/tmp/swraster-crash`, isolated
`--user-data-dir`, `XDG_CONFIG_HOME`/`XDG_CACHE_HOME` redirected out of the user's
profile. Driver: `cdpdrive.js` (node 26, built-in `WebSocket`), navigate +
evaluate + synthetic click loop over CDP against
`/usr/lib/chromium/chromium --headless --disable-gpu --remote-debugging-port=0`.

Symptom (matches bun sighting 1 and the Obsidian sighting exactly):

```
Crashing due to FD ownership violation:      <- base/files/scoped_file_linux.cc
...
GPU process exited unexpectedly: exit_code=133   (x3; also 139/SIGSEGV)
FATAL:content/browser/gpu/gpu_data_manager_impl_private.cc:417]
      GPU process isn't usable. Goodbye.
```

Time-to-crash is non-deterministic (first GPU exit anywhere from iteration 1 to
~24) because it depends on when a *failing* file probe (font/mime/config lookup
that the broker denies) happens to be issued after the sandbox is sealed.

## Flag matrix

Each config = 2 runs × up to 40 navigate/click iterations (headless, isolated
profile). "Crash" = GPU process died and the browser hit the `GPU isn't usable`
FATAL.

| Flags (all headless)                                   | Iters ok | GPU deaths | Result | Rules out |
|-------------------------------------------------------|---------:|-----------:|--------|-----------|
| *(none — default; ANGLE-SwiftShader GL)*              |   80/80  | 0          | clean  | — |
| `--use-angle=swiftshader --enable-unsafe-swiftshader` |   80/80  | 0          | clean  | SwiftShader itself |
| `--disable-gpu-compositing`                           |   80/80  | 0          | clean  | viz sw compositor |
| `--disable-gpu`                                       |   ~10/40 | 6          | CRASH  | — |
| `--disable-gpu --disable-software-rasterizer`         |   ~19/40 | 6          | CRASH  | Skia sw raster |
| `--disable-gpu --disable-features=SkiaGraphite,Vulkan`|   ~10/40 | 6          | CRASH  | Graphite / Vulkan |
| `--disable-gpu --num-raster-threads=1`                |   crash  | —          | CRASH  | raster-thread race |
| `--disable-gpu --disable-breakpad`                    |   ~6/40  | 3          | CRASH  | crashpad |
| `--disable-gpu --disable-features=MojoUseEventFd`     |   ~4/40  | 3          | CRASH  | mojo eventfd upgrade |
| `--disable-gpu --disable-features=MojoIpcz`           |   ~4/40  | 3          | CRASH  | mojo ipcz |
| `--disable-gpu --in-process-gpu`                      |   80/80  | 0          | clean  | (no separate sandboxed GPU proc) |
| **`--disable-gpu --disable-gpu-sandbox`**             | **80/80**| **0**      | **clean** | **isolates to the sandbox** |
| **`--disable-gpu --no-sandbox`**                      | **80/80**| **0**      | **clean** | **isolates to the sandbox** |

Turning off **either** the GPU seccomp sandbox (`--disable-gpu-sandbox`) or the
whole sandbox (`--no-sandbox`) eliminates the crash entirely, while every
Skia/SwiftShader/mojo/raster/crashpad toggle leaves it in place. `--in-process-gpu`
is clean because there is then no separate GPU process for the GPU seccomp policy
to seal.

## Correctness check (Skia VSX ruled out for the crash)

Per the coordinator's note that Obsidian's software window also *rendered* wrong.
Captured `Page.captureScreenshot` of a fixed text/border/flex test page (text at
10/13/16/24/40 px, thin 1–3 px borders, gradients, a rotated box) under software
vs GPU raster and compared:

- Layout geometry (`getBoundingClientRect` of every box) is **identical**
  across `--disable-gpu`, default, `--use-angle=swiftshader`, and
  `--disable-gpu-compositing`.
- Pixel diff `--disable-gpu` vs default: **AE = 0** (byte-identical).
- `--disable-gpu` vs ANGLE-SwiftShader WebGL: AE ≈ 2.5e-4 (sub-pixel AA on the
  GL-composited layer only).

So the software rasterizer is producing correct geometry and pixels here; there
is **no** VSX min/max NaN-semantics divergence in this path (unlike the Embree
`xvminsp` case). Obsidian's "wrong spacing" is most plausibly the crash
interrupting paint mid-frame, or a font-config lookup being denied by the same
sandbox bug (denied `openat` mis-read as a bad fd), not a Skia arithmetic error.

## Core analysis (stripped binary)

`coredumpctl` over one crash burst, classified by signal + faulting thread +
`module+offset` (build-id `1925d8ad…`):

| Count | Signal | Process | Thread | Fault site |
|------:|--------|---------|--------|-----------|
| many  | SIGTRAP | gpu-process | Chrome_ChildIOT | `chromium+0xbcc40c4` |
| many  | SIGSEGV | gpu-process | Chrome_ChildIOT | `chromium+0xbd07d2c` |
| some  | SIGSEGV | gpu-process | Chrome_ChildIOT | `chromium+0xc295834` |
| every | SIGABRT | browser     | main            | `libc+abort` (the FATAL) |
| every | SIGTRAP | crashpad    | handler         | `chrome_crashpad_handler+0x246cb8` |

Disassembly at the two GPU faults:

- **`chromium+0xbcc40c4` (SIGTRAP)** — immediately preceded by two `bl` calls and
  a load of a message string; the site is `trap` guarded by the string
  *"Crashing due to FD ownership violation:"* (confirmed: the RAW_LOG string at
  that TU resolves to `…8830f…`, and `chrome_crashpad_handler` carries the same
  literal). This is `base::internal::…CrashOnFdOwnershipViolation()` →
  `ImmediateCrash()` from `base/files/scoped_file_linux.cc`.
- **`chromium+0xbd07d2c` (SIGSEGV)** — a reference-count adjust on a corrupted
  handle:
  ```
  ld   r4,8(r4)          ; walk a list
  ...
  =>lwz  r5,0(r4)        ; r4 = 0x900000001  (garbage), faults SEGV_MAPERR
    addi r5,r5,1
    stw  r5,0(r4)
  ```
  `r4 = 0x900000001` is a bogus pointer built from a small integer where a real
  object pointer was expected — the downstream effect of an fd/handle that was
  fabricated from a mis-decoded syscall return.

Both are consequences of the same corruption; the browser then declares the GPU
process unusable and aborts.

## Root cause

`third_party/.../chromium-ppc64le-patches-r2.tar.gz →
ppc64le-patches/sandbox/0001-sandbox-Enable-seccomp_bpf-for-ppc64.patch`
(Raptor Engineering / Debian chromium-team) adds the ppc64 seccomp support. Its
syscall-return encoding, in `sandbox/linux/seccomp-bpf/syscall.cc
Syscall::PutValueInUcontext`, is **`sc`-only**:

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

This is the classic PowerPC `sc` ABI: on error the kernel returns `+errno` in r3
and sets CR0.SO. glibc's old `sc` path then negates r3 when SO is set.

But POWER9 glibc (≥ 2.33) issues syscalls via **`scv 0`**, whose ABI is the
inverse of `sc`: the result is `-errno` **directly in r3** and **CR0.SO is not
used**. This host's `libc.so.6` contains 406 `scv` sites and 0 relevant `sc`
syscall sites; kernel 7.2.2 supports `scv`.

So when the sandbox traps a syscall that glibc issued with `scv` and emulates a
denial (`-ENOENT`), `PutValueInUcontext` writes `r3 = +2` and sets SO. Under the
`scv` convention glibc reads `r3 = 2` as a **successful return value** — for
`openat`, a valid low file descriptor. Chromium then wraps fd 2 (or another
fabricated low fd) in a `base::ScopedFD`; its FD-ownership tracker
(`scoped_file_linux.cc`) sees an fd it believes is already owned being adopted or
closed and deliberately crashes via `CrashOnFdOwnershipViolation()`. Successful
brokered opens (positive fd, SO clear) survive by luck; only the **error**
returns are corrupted, which is why the crash is intermittent and correlates with
denied file probes (fonts, `mime.cache`, config).

### Minimal reproducer

`scv_sigsys_repro.c` (in `/var/tmp/swraster-crash`, self-contained, unprivileged;
installs a seccomp `SECCOMP_RET_TRAP` on `openat` and a `SIGSYS` handler that
runs the exact Debian encoding). Output on this host:

```
DEBIAN (always sc-style) SIGSYS return encoding:
  glibc openat()   trap=0x3000  r3_in_handler=-100 SO_in=0 -> caller got 2  ** valid fd (fd is open) **
  raw sc           trap=0x0c00  r3_in_handler=100  SO_in=1 -> caller got -2 (ENOENT)
  raw scv 0        trap=0x3000  r3_in_handler=-100 SO_in=0 -> caller got 2  ** valid fd **
FIXED (trap-aware) SIGSYS return encoding:
  glibc openat()   trap=0x3000  r3_in_handler=-100 SO_in=0 -> caller got -1 (ENOENT)
  raw sc           trap=0x0c00  r3_in_handler=100  SO_in=1 -> caller got -2 (ENOENT)
  raw scv 0        trap=0x3000  r3_in_handler=-100 SO_in=0 -> caller got -2 (ENOENT)
```

`trap=0x3000` marks an `scv`-issued syscall in the interrupt frame; `trap=0x0c00`
marks `sc`. The Debian encoding turns a denied `openat` into "fd 2" for every
`scv` caller (i.e. all of glibc). The fix below restores correct `-ENOENT`.

## Proposed fix

Make the sandbox return encoding **trap-aware**: if the trapped syscall was
issued via `scv` (interrupt-frame `trap` value `0x3000`), use the `scv`
convention — put `-errno` in r3 and leave CR0.SO alone; otherwise keep the `sc`
convention. In `sandbox/linux/seccomp-bpf/syscall.cc Syscall::PutValueInUcontext`:

```c
#if defined(__powerpc64__)
  struct pt_regs* regs = ctx->uc_mcontext.regs;
  bool issued_via_scv = (regs->trap & 0xfff0) == 0x3000;
  if (issued_via_scv) {
    // scv ABI: r3 already holds signed -errno / result; SO is unused.
    regs->ccr &= ~(1 << 28);
  } else if (ret_val <= -1 && ret_val >= -4095) {   // legacy sc ABI
    ret_val = -ret_val;
    regs->ccr |= (1 << 28);
  } else {
    regs->ccr &= ~(1 << 28);
  }
#endif
  SECCOMP_RESULT(ctx) = static_cast<greg_t>(ret_val);
```

The same `trap`-aware guard should be applied to the ppc64 hunk in
`sandbox/linux/seccomp-bpf/trap.cc` (the "accidentally negate the first
parameter" workaround) and to `SIGSYSFstatatHandler` in
`seccomp-bpf-helpers/sigsys_handlers.cc`; those workarounds exist only to paper
over this same `sc`/`scv` sign confusion and can be scoped to the `sc` case.

**Patch location:** the ppc64le seccomp patch, i.e. the Debian chromium-team
series (`salsa.debian.org/chromium-team/chromium` `debian/patches/ppc64le/
sandbox/0001-sandbox-Enable-seccomp_bpf-for-ppc64.patch`), mirrored into our
`packages/chromium/chromium-ppc64le-patches-r2.tar.gz` and
`packages/electron43/chromium-150-ppc64le-patches-r3.tar.gz`. Upstream Chromium
has no ppc64le target, so this is the correct upstreamable home. Not a change to
Skia, SwiftShader, or the ELFv2 ABI.

**Verification plan for the fix:** rebuild `chromium` with the amended patch and
re-run the flag matrix; `--disable-gpu` should reach 40/40 clean like
`--no-sandbox` does today. The C reproducer already validates the encoding logic
in isolation.

## Cross-impact: electron43 (Chromium 150)

`packages/electron43/chromium-150-ppc64le-patches-r3.tar.gz` ships the **same**
`sc`-only encoding (`ccr |= (1 << 28)`, `SyscallAsm` using `sc`, same
`accidentally negate` workaround). The Obsidian crash signature — GPU
`--use-gl=disabled` SIGSEGV, two `SIGTRAP` CHECKs, then a browser CHECK on a
surface change — is this same bug. The fix must be applied to the electron43
patch tarball as well.

## Artifacts (on 192.168.2.24, under /var/tmp/swraster-crash)

- `cdpdrive.js` — CDP stress/screenshot driver
- `results.jsonl`, `matrix.log` — matrix data; `summ.py` prints the table
- `coreclass.py` — core classifier used above
- `scv_sigsys_repro.c` — minimal root-cause reproducer
- `shots/` — software vs GPU screenshots and diff
