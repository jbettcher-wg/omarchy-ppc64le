# powerpc exit-path series, ready to send

`git format-patch` output for the three powerpc kernel patches carried in
`ours/linux-omarchy` and `ours/linux-power9`. Generated against pristine
7.2.6; all three apply cleanly to it and pass `checkpatch.pl` with zero
errors and zero warnings.

| here | packaging tree | touches |
|---|---|---|
| 0001 | `0002-powerpc-syscall_exit_restart-...` | `kernel/interrupt.c` |
| 0002 | `0004-powerpc-syscall-keep-seccomp-...` | `kernel/syscall.c` |
| 0003 | `0005-powerpc-interrupt-clear-exit_flags-...` | `include/asm/entry-common.h`, `kernel/interrupt.c` |

`0001`/`0003` are not in the packaging tree's numbering — the xhci patches
occupy 0001 and 0003 there and are unrelated.

## Send

Recipients are already in the headers, from `get_maintainer.pl`: Madhavan
Srinivasan to:, with Ellerman, Piggin, Leroy, linuxppc-dev and LKML cc'd.

```sh
git send-email --annotate docs/kernel-patches-upstream/*.patch
```

Reply-all to the cover letter thread for v2s. linuxppc-dev tracks patches at
<http://patchwork.ozlabs.org/project/linuxppc-dev/list/>.

## Before sending — two things to settle

1. **Is 0001 already upstream?** `docs/upstreamable-patches.md` describes the
   `syscall_exit_restart()` fix as "already in review" and elsewhere as
   "accepted". If it landed, drop it and send a 2-patch series; 0003 does not
   depend on it textually, only the packaging tree's apply order does.
2. **No `Fixes:` tags.** These were developed against a release tarball, so
   the introducing commits were never identified. A clone of mainline and
   `git log -S` on the moved lines would settle all three; they most likely
   date from the generic-entry conversion. The cover letter says so plainly
   rather than guessing.

## Evidence

- All three are in the running kernel: `linux-power9 7.2.6-2`, 7.2.6-64k,
  built 2026-09-16, daily driver on the AC922 since.
- 0002 has a reproducer: `../seccomp-ret-errno-ppc64le.c`. Five errno values
  through both glibc `scv 0` and raw `sc`; all correct with the patch, all
  ENOSYS without it. Worth offering as a seccomp selftest.
- 0001 and 0003 have no targeted reproducer. The mechanism is legible in the
  source, but the evidence is "the machine runs correctly with them" rather
  than a demonstrated failure without. The cover letter states this.
