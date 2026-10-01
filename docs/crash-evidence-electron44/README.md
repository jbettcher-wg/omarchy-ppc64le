# electron44 44.4.5-1 GPU-process crashes, 2026-09-29

Two crashes running obsidian 1.13.7-2 with `--use-gl=disabled`, ten minutes
apart, both on the GPU process's `Chrome_ChildIOT` thread. Kept because they are
the only hard evidence and systemd-coredump rotates.

| time | pid | signal | detail |
|---|---|---|---|
| 16:57:08 | 3288859 | SIGTRAP TRAP_BRKPT | V8 IMMEDIATE_CRASH `trap`; r3=r4=0x69c679f9a8519000 |
| 17:06:27 | 3323521 | SIGSEGV SEGV_MAPERR | `lwz r5,0(r4)` refcount increment; r4=0x900000001 |

The binary is stripped (no `.symtab`), so frames do not symbolize. The one symbol
that does resolve, `node::inspector::protocol::Object::AppendSerialized`, is
nearest-preceding attribution and is not the real frame -- do not read anything
into it.

Ruled out: OOM (376 GiB available), and no seccomp denial appears in the journal
for either crash.

## What the evidence shows

Both faulting values carry garbage in the upper word with a small value in the
lower one (`0x9_0000_0001`). Neither resembles an errno or a file descriptor.
The second crash faults on a refcount increment (`lwz`/`addi`/`cmplwi`) through
that pointer.

## Hypotheses

1. **seccomp/scv return ABI.** Initially favoured, because the trigger is the GPU
   process under `--disable-gpu`, which is exactly what
   `ppc64le-seccomp-scv-return-abi.patch` exists for -- Debian's ppc64 seccomp
   support writes an emulated syscall result back with the `sc` convention only,
   and glibc uses `scv` on POWER9, so a denied broker call reads back as success.
   **Weakened by the register values:** that mechanism would produce
   small-integer confusion (`-ENOENT` arriving as fd 2), not corrupted 64-bit
   words.
2. **Value or pointer corruption.** Truncation, bad sign extension, or two 32-bit
   fields read as one 64-bit. Fits the register shapes better. Adjacent to the
   electron43 V8 patches deliberately dropped for this build: the 64-bit overflow
   check / `andc` pair, and the Maglev 32-bit overflow synthesis.

## The discriminating test

electron44 `44.4.5-2` adds the scv patch and changes nothing else.

- Crashes stop -> hypothesis 1, and the patch is the fix.
- Crashes continue -> hypothesis 2, the scv patch is unrelated here, and the
  dropped V8 patches need review rather than the dismissal they were given.

Reproduction rate was two crashes in ten minutes of ordinary use, so absence of
crashes over a comparable period is meaningful; a single clean launch is not.

## Both initial hypotheses eliminated (2026-09-29, later)

**1. seccomp/scv return ABI -- ruled out on evidence.** That mechanism makes a
denied syscall read back as success, which produces small-integer confusion
(`-ENOENT` arriving as fd 2). Both faults here carry corrupted 64-bit words
(`0x69c679f9a8519000`, `0x900000001`). Wrong shape. `44.4.5-2` adds the patch
anyway because packages/chromium carries it for a separately diagnosed reason and
it is five sandbox files, but it is not expected to fix this.

**2. The dropped electron43 V8 patches -- ruled out by construction.** These were
developed after testing obsidian with its default GPU acceleration disabled, so
the trigger matches, and `chromium/ppc64le-v8-power8-loadpc.patch` accumulated
all of them (LoadPC fallback, 32-bit overflow synthesis, the `andc` fix, Maglev
32-bit overflow synthesis -- commits 67b74584, eb020edc, 54a3d00b, aefbd2d3).

But every change in that patch is ISA-gated: `#if defined(_ARCH_PWR9)` at compile
time and `CpuFeatures::IsSupported(PPC_9_PLUS)` at run time. Its own header
states it "dispatches MoveToCrFromXer dynamically: uses mcrxrx on POWER9+ and
mcrxr + cror on POWER8" and gates SIMD128 behind `_ARCH_PWR9`. On a POWER9 build
running POWER9 hardware every path falls through to upstream, so applying it here
would be a no-op. Those bugs were found on the POWER8 machine, which is where
chromium pkgrel 8 was validated.

## Therefore

This is a **new finding**: a ppc64le fault in Chromium 152's GPU-process IPC path
on POWER9, addressed by neither Debian's series nor any patch we already carry.

Next avenues, in rough order of cost:

1. Confirm the prediction -- `44.4.5-2` should still crash. If it does not, (1)
   above was wrong and the scv mechanism deserves another look.
2. Get symbols. The package is stripped; a build with `!strip` in OPTIONS, or
   keeping `out/Release` from the build tree, would make the backtrace readable
   and likely identify the subsystem outright.
3. Check whether chromium 153 shows the same fault under `--disable-gpu` on
   POWER9. It shares the GPU/IPC code and carries more of our patches; if it is
   clean, diffing the two patch sets is the shortest path.
4. Check whether Debian or Fedora have a ppc64le bug open against the GPU process
   with GL disabled.

## RESOLVED: it was the scv/seccomp ABI (2026-09-29, evening)

`electron44 44.4.5-2` adds `ppc64le-seccomp-scv-return-abi.patch` and changes
nothing else. Result: **no crashes, no coredumps, and the rendering flicker under
`--use-gl=disabled` also disappeared.** Reproduction rate before the patch was two
crashes in ten minutes of ordinary use, so a clean session is meaningful evidence.

Hypothesis 1 was correct. The "elimination" written above it is wrong and is kept
only to record the mistake.

### Why the register values misled me

I ruled the mechanism out because `r4 = 0x900000001` and
`r3 = r4 = 0x69c679f9a8519000` are not errno- or fd-shaped, and the scv bug makes
a denied syscall read back as success. That reasoning demanded the cause's
fingerprint at the site of the symptom.

It does not work that way. The bad return does not fault at the syscall. It faults
downstream: code takes the false success, proceeds with a handle or struct field
that was never populated, and only then dereferences garbage. `0x900000001` --
small value in the low word, junk in the high -- is exactly a partially
initialised 64-bit field. Both faults were two crash sites sharing one cause,
which is also why the same thread produced SIGTRAP once (a CHECK caught it) and
SIGSEGV the other time (nothing did).

The flicker is the corroboration I should have anticipated. Broker calls are how
the GPU process obtains shared memory and dma-buf descriptors; silently failing
ones produce rendering artifacts *and* eventual death, and both stopped together.

### Consequence for the recipe

`ppc64le-seccomp-scv-return-abi.patch` is **load-bearing for electron on POWER9**,
not defensive. It is not in Debian's series, so any future electron bump must
carry it forward. The same applies to the other three ppc64le fixes Debian lacks:
the dawn `cipd_deps.py` arch detection, the `_cipd_arch` go symlink path, and the
swiftshader XCOFF sources against llvm-10.0.

The electron43 V8 patches remain correctly excluded -- they are gated behind
`_ARCH_PWR9` and `CpuFeatures::IsSupported(PPC_9_PLUS)` and are inert on a POWER9
build. That part of the analysis stands.

### Still unknown

Whether the POWER8 VM build needs anything further. The scv patch addresses
glibc's use of `scv` on POWER9; on POWER8 glibc uses `sc`, so this particular bug
should not arise there -- but that is reasoning, not a measurement, and the VM
build has not been run.
