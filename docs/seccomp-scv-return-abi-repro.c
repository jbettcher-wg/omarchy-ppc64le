// Reproducer for the ppc64le Chromium seccomp-bpf trap-return bug.
//
// Chromium's SIGSYS path on ppc64 (Debian/Raptor patch
// sandbox/0001-sandbox-Enable-seccomp_bpf-for-ppc64.patch) writes an emulated
// syscall's result into the interrupted context using the `sc` convention
// only: r3 = +errno with CR0.SO set on error. glibc on POWER9 issues syscalls
// with `scv 0`, whose convention is r3 = -errno with no SO bit, so the caller
// reads an emulated error as a successful small return value.
//
// This program installs a SECCOMP_RET_TRAP filter on openat and runs the same
// encoding logic Chromium does, in two variants:
//   DEBIAN  -- the shipped sc-only encoding and argument workaround
//   FIXED   -- ppc64le-seccomp-scv-return-abi.patch: both chosen by the trap
//              value in the saved registers (0x3000 = scv, else sc)
// against three kinds of caller: glibc (scv), a raw `sc`, and a raw `scv 0`.
// Each caller makes two calls: one the handler denies (-ENOENT) and one it
// emulates successfully (returns a real fd). For each call it also records the
// dirfd the handler hands to the emulation after the argument workaround.
//
// Build: gcc -O2 -Wall -o seccomp-scv-return-abi-repro seccomp-scv-return-abi-repro.c
// Run:   ./seccomp-scv-return-abi-repro     (unprivileged; exit status 0 iff FIXED passes)
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <sys/ucontext.h>
#include <unistd.h>
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <asm/ptrace.h>

// raw syscall entry points: nr in r3, args in r4..r6; both return -errno on error
long raw_sc(long nr, long a1, long a2, long a3);
long raw_scv(long nr, long a1, long a2, long a3);
__asm__(
    ".text\n"
    ".globl raw_sc\n.type raw_sc,@function\n"
    "raw_sc:\n"
    "  mr 0,3\n  mr 3,4\n  mr 4,5\n  mr 5,6\n"
    "  sc\n"
    "  bnslr\n"
    "  neg 3,3\n"
    "  blr\n"
    ".size raw_sc,.-raw_sc\n"
    ".globl raw_scv\n.type raw_scv,@function\n"
    "raw_scv:\n"
    "  mflr 11\n  std 11,16(1)\n  stdu 1,-32(1)\n"
    "  mr 0,3\n  mr 3,4\n  mr 4,5\n  mr 5,6\n"
    "  scv 0\n"
    "  addi 1,1,32\n  ld 11,16(1)\n  mtlr 11\n"
    "  blr\n"
    ".size raw_scv,.-raw_scv\n");

// ---- the logic under test, as in the patch -------------------------------
#define SECCOMP_PPC64_TRAP(_ctx) ((_ctx)->uc_mcontext.regs->trap & ~0x1fUL)
#define SECCOMP_PPC64_IS_SCV(_ctx) (SECCOMP_PPC64_TRAP(_ctx) == 0x3000)

static int fixed;  // 0 = DEBIAN, 1 = FIXED

// Syscall::PutValueInUcontext
static void put_value_in_ucontext(long ret_val, ucontext_t *ctx) {
  if (!fixed || !SECCOMP_PPC64_IS_SCV(ctx)) {
    if (ret_val <= -1 && ret_val >= -4095) {
      ret_val = -ret_val;
      ctx->uc_mcontext.regs->ccr |= (1UL << 28);
    } else {
      ctx->uc_mcontext.regs->ccr &= ~(1UL << 28);
    }
  }
  ctx->uc_mcontext.regs->gpr[3] = (unsigned long)ret_val;
}

// Trap::SigSys's ppc64 first-argument workaround (openat is in its list)
static void first_arg_workaround(ucontext_t *ctx) {
  if (fixed && SECCOMP_PPC64_IS_SCV(ctx)) return;
  if ((int)ctx->uc_mcontext.regs->gpr[3] > 0)
    ctx->uc_mcontext.regs->gpr[3] = -ctx->uc_mcontext.regs->gpr[3];
}
// ---------------------------------------------------------------------------

static const char kDenied[] = "/nonexistent/scv-sigsys-probe";
static volatile unsigned long seen_trap;
static volatile long seen_dirfd;

static void sigsys(int sig, siginfo_t *si, void *vctx) {
  (void)sig;
  (void)si;
  ucontext_t *ctx = vctx;
  seen_trap = SECCOMP_PPC64_TRAP(ctx);
  first_arg_workaround(ctx);
  seen_dirfd = (long)ctx->uc_mcontext.regs->gpr[3];
  const char *path = (const char *)ctx->uc_mcontext.regs->gpr[4];
  long rc;
  if (strcmp(path, kDenied) == 0)
    rc = -ENOENT;  // a broker denial
  else
    rc = raw_sc(__NR_dup, 0, 0, 0);  // an emulated success: a fresh real fd (seccomp allows dup)
  put_value_in_ucontext(rc, ctx);
}

enum caller { GLIBC, RAW_SC, RAW_SCV };
static const char *caller_name[] = {"glibc openat", "raw sc", "raw scv 0"};

// returns -errno on error, fd on success
static long do_openat(enum caller c, int dirfd, const char *path) {
  long r;
  switch (c) {
    case GLIBC: errno = 0; r = openat(dirfd, path, O_RDONLY); return r < 0 ? -errno : r;
    case RAW_SC: return raw_sc(__NR_openat, dirfd, (long)path, O_RDONLY);
    default: return raw_scv(__NR_openat, dirfd, (long)path, O_RDONLY);
  }
}

static int check(enum caller c, int dirfd, const char *path, int expect_success) {
  int fd_before_probe = dup(0);  // lowest free fd; a correct success returns an fd >= this
  close(fd_before_probe);
  long r = do_openat(c, dirfd, path);
  int ok;
  if (expect_success)
    ok = r >= fd_before_probe;
  else
    ok = r == -ENOENT;
  // The patch claims intact arguments for scv callers. For sc callers it keeps
  // Debian's first-argument workaround unchanged (AT_FDCWD is restored; a
  // positive dirfd is negated and SIGSYSFstatatHandler undoes that for fstat),
  // so a positive dirfd from an sc caller is reported but not scored.
  int sc_unchanged = (c == RAW_SC && dirfd >= 0);
  int dirfd_ok = sc_unchanged || seen_dirfd == dirfd;
  printf("    %-13s trap=0x%04lx dirfd=%-5d handler_saw_dirfd=%-5ld %-7s -> %-4ld %s%s\n",
         caller_name[c], seen_trap, dirfd, seen_dirfd, expect_success ? "success" : "denied",
         r, ok ? "ok" : "WRONG",
         dirfd_ok ? (sc_unchanged ? "  (sc workaround, unchanged)" : "") : "  (dirfd corrupted)");
  if (r >= 0 && r != 0 && r != 1 && r != 2 && r != dirfd) close((int)r);
  return ok && dirfd_ok;
}

int main(void) {
  struct sock_filter filter[] = {
      BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, arch)),
      BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, AUDIT_ARCH_PPC64LE, 1, 0),
      BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
      BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
      BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_openat, 0, 1),
      BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_TRAP),
      BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
  };
  struct sock_fprog prog = {.len = sizeof(filter) / sizeof(filter[0]), .filter = filter};
  struct sigaction sa = {0};
  sa.sa_sigaction = sigsys;
  sa.sa_flags = SA_SIGINFO;
  sigaction(SIGSYS, &sa, NULL);
  setvbuf(stdout, NULL, _IONBF, 0);
  // A real positive dirfd to pass (a directory the emulation never uses).
  int dirfd = open("/", O_RDONLY | O_DIRECTORY);
  if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) || prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &prog)) {
    perror("seccomp");
    return 2;
  }
  int fixed_pass = 1, debian_pass = 1;
  for (fixed = 0; fixed <= 1; fixed++) {
    printf("%s\n", fixed ? "FIXED  (trap-aware encoding and workaround)" : "DEBIAN (sc-only encoding, unconditional workaround)");
    int pass = 1;
    for (enum caller c = GLIBC; c <= RAW_SCV; c++) {
      for (int d = 0; d < 2; d++) {
        int df = d ? dirfd : AT_FDCWD;
        pass &= check(c, df, kDenied, 0);
        pass &= check(c, df, "/emulated/success", 1);
      }
    }
    printf("  => %s\n", pass ? "all correct" : "INCORRECT results");
    if (fixed) fixed_pass = pass; else debian_pass = pass;
  }
  printf("summary: DEBIAN %s, FIXED %s\n", debian_pass ? "correct" : "broken", fixed_pass ? "correct" : "broken");
  return fixed_pass ? 0 : 1;
}
