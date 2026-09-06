# Chromium's sandbox breaks page loading on ppc64le (kernel 7.2)

**Symptom.** Chromium 151.0.7922.108-1 launches normally, but every tab stays
blank. `--no-sandbox` makes it work. Running permanently with `--no-sandbox` is
the current workaround and costs the machine its renderer sandbox.

**Status.** Narrowed to chromium's seccomp-bpf layer, on kernel 7.2 only. The
exact failing check is **not yet named** — that needs a chromium build with
symbols. Several plausible causes were tested and *refuted*; those are recorded
below so nobody re-runs them.

Host: AC922, Arch POWER, kernel 7.2.2 (self-built, `CONFIG_GENERIC_ENTRY=y`).

## What is established

All of the following is from direct experiment on the box, with an isolated
`--user-data-dir` under `/tmp` and a headless/Xvfb display.

1. **It is the seccomp-bpf layer, not the setuid/namespace layer.**

   | run | result |
   |---|---|
   | default (sandbox on) | renderer + GPU die, no page |
   | `--no-sandbox` | page renders |
   | `--disable-seccomp-filter-sandbox` | **page renders** |
   | `--disable-setuid-sandbox` | still dies |
   | `--disable-gpu-sandbox` | GPU survives, renderer still dies, no page |

   So layer-1 (setuid + namespaces) is innocent. Disabling only the seccomp
   filter is sufficient to fix it.

2. **Renderer and GPU die the same death.** Both dump core with SIGTRAP
   (`exit_code=133`) at the *identical* address `chromium + 0xea2ef58`, reached
   through one common helper from each process type's `main`:

   ```
   renderer:    #0 chromium+0xea2ef58  #1 chromium+0xea2e378  #2 +0x10c16614 ...
   gpu-process: #0 chromium+0xea2ef58  #1 chromium+0xea2e378  #2 +0x108a7d44 ...
   ```

   That address is a compiler-emitted `trap` (`7fe00008`) at the end of a
   pointer-walk loop -- i.e. chromium's own `IMMEDIATE_CRASH()`, which is what a
   failed `CHECK` compiles to in a release build. It is **not** a seccomp
   `SIGSYS` kill. `dmesg` shows it as `unhandled trap (5)`.

3. **The renderer never finishes sandbox initialization.** With verbose logging
   the only process type that ever reaches

   ```
   sandbox/policy/linux/sandbox_linux.cc:78] Activated seccomp-bpf sandbox for process type: utility.
   ```

   is `utility` -- 25 times in one run. `renderer` and `gpu-process` never log
   it. They die inside `SandboxLinux::InitializeSandbox()`.

4. **Utility processes install their filters fine.** `strace` shows successful
   installs of 771-, 777- and 781-instruction BPF programs.

5. **Kernel audit is off** (`audit_enabled=0`), which is why no seccomp denial
   ever appears in `dmesg`. Do not read the absence of audit records as absence
   of denials.

6. **The only `SIGSYS` chromium actually takes are its own broker traps** --
   2x `__NR_newfstatat`, `si_code=SYS_SECCOMP`, `si_arch=AUDIT_ARCH_PPC64LE`.
   That is chromium's `SIGSYSFstatatHandler` working as designed, not a denial.

## Hypotheses tested and REFUTED

Recording these because each looked strong and each is now closed.

- **"Chromium's ppc64le seccomp policy is missing syscalls"** (the Ladybird
  precedent: missing `AUDIT_ARCH_PPC64LE`, PowerPC's pre-socketcall
  `__NR_send`/`__NR_recv`/`__NR__llseek`, the `F_GETLK` 12/13/14-vs-5/6/7
  mismatch). The shipped patch
  `ppc64le-patches/sandbox/0001-sandbox-Enable-seccomp_bpf-for-ppc64.patch`
  is comprehensive -- it covers `seccomp_macros.h`, `syscall_sets.cc`,
  `linux_syscall_ranges.h`, `ppc64_linux_syscalls.h`, `ppc64_linux_ucontext.h`,
  `baseline_policy.cc`, `trap.cc`, `syscall_wrappers.cc` and the renderer and
  utility policies. Not the shape of a missing-entry bug. **And the decisive
  argument is temporal: the same chromium binary worked on kernel 7.1.**

- **"The kernel's seccomp `SIGSYS` trap-and-emulate path is broken."** Tested
  with a standalone 90-line C program (`seccomp-sigsys-ppc64le.c`, alongside
  this doc) that installs a `SECCOMP_RET_TRAP` filter, emulates the syscall in a
  `SIGSYS` handler exactly as chromium does, and resumes.
  **3,200,000 trap/handle/resume cycles across 16 threads, zero failures.**

  One caveat worth writing down, because it cost an hour: an early version of
  that reproducer *did* crash instantly, with `nip 0 lr 0 ctr 0` -- a perfect
  match for the "fast path zeroed the registers" signature. It was wrong. It
  advanced `NIP += 4` in the handler, but on a seccomp trap the kernel has
  **already** stepped past the `sc` instruction, so the extra advance skipped a
  live instruction. Chromium does not advance NIP. With the correct semantics
  the path is clean. A reproducer that confirms your hypothesis on the first try
  deserves a control run.

- **"`SECCOMP_FILTER_FLAG_TSYNC` fails for multi-threaded renderers."**
  Renderers are multi-threaded and must use TSYNC, and no successful TSYNC
  install appears in any chromium trace. Tested directly
  (`seccomp-tsync-ppc64le.c`): TSYNC installs succeed on this kernel both
  single-threaded and with 8 spinning threads, alone and with `SPEC_ALLOW`.

## One real gap found in the chromium patch

`0001-sandbox-Enable-seccomp_bpf-for-ppc64.patch` adds ppc64 handling to
`sandbox/policy/linux/bpf_renderer_policy_linux.cc` and
`bpf_utility_policy_linux.cc`, but touches **no GPU policy file** -- there is no
`bpf_gpu_policy_linux.cc` hunk anywhere in it (`grep -n gpu` on the patch
returns nothing). That is a genuine hole worth fixing upstream regardless.

It is probably not the whole story, since the renderer and the GPU process die
at the same instruction, and the renderer policy *is* patched.

## What would finish this

In rough order of cost:

1. **A chromium build with symbols** (`options=(!strip)` or a `-debug`
   package). The crash address is known and stable; symbolizing
   `chromium+0xea2ef58` names the failing `CHECK` outright. Everything else
   here is inference around a stripped binary.
2. **Boot the packaged `linux 7.1.5.arch1-1`** -- already installed, not
   running -- and confirm the sandbox works there. That converts "the user
   reports it worked on 7.1" into a bisection window. Cheap, but needs a reboot
   of a machine in daily use.
3. Bisect 7.2-rc4..rc5 if 2 confirms.

## Why the kernel remains the prime suspect

powerpc **selects `CONFIG_GENERIC_ENTRY` in 7.2** (`arch/powerpc/Kconfig:209`),
moving syscall entry/exit into `kernel/entry/`. `arch/powerpc/kernel/syscall.c`
is down to 1600 bytes and `interrupt.c` now calls the generic
`syscall_exit_to_user_mode()`. The generic code was written by and for
architectures where **r12 is an ordinary register**; ELFv2 requires r12 to hold
the function entry point at a global entry so the callee can derive its TOC.
That invariant has already been dropped once in this migration -- see
`docs/upstreamable-patches.md`.

So the working theory stands: a PowerPC invariant lost at the generic/arch
boundary, on a path a sandboxed browser hammers and little else does. What the
experiments above establish is that it is **not** the seccomp `SIGSYS`
mechanism itself, which is the part everyone reaches for first.
