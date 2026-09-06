/*
 * seccomp SECCOMP_RET_TRAP -> SIGSYS -> emulate -> resume, the way chromium's
 * syscall broker does it. Control test for "is the kernel's seccomp trap path
 * broken on ppc64le". On kernel 7.2.2 (AC922) this runs clean:
 *   ./sx 16 200000   ->  OK: survived, handled=3200000
 *
 * NOTE: do NOT advance NIP in the handler. On a seccomp trap the kernel has
 * already stepped past the sc instruction; advancing again skips a live
 * instruction and produces a spurious "nip 0 lr 0" crash that looks exactly
 * like a register-restore bug. Chromium does not advance NIP either.
 *
 * gcc -O2 -o sx seccomp-sigsys-ppc64le.c -lpthread
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <pthread.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <ucontext.h>

#define TRAPPED_NR __NR_getcpu
static volatile unsigned long long handled = 0;

static void sigsys_handler(int sig, siginfo_t *si, void *vctx) {
    ucontext_t *uc = (ucontext_t *)vctx;
    uc->uc_mcontext.gp_regs[PT_R3]   = 0;
    uc->uc_mcontext.gp_regs[PT_CCR] &= ~0x10000000UL;
    __sync_fetch_and_add(&handled, 1);
}

static void fault_handler(int sig, siginfo_t *si, void *vctx) {
    ucontext_t *uc = (ucontext_t *)vctx;
    char b[512];
    int n = snprintf(b, sizeof b,
      "FAULT sig=%d addr=%p nip=%lx lnk=%lx ctr=%lx r0=%lx r1=%lx r2=%lx r3=%lx r9=%lx r10=%lx r11=%lx r12=%lx handled=%llu\n",
      sig, si->si_addr,
      (unsigned long)uc->uc_mcontext.gp_regs[PT_NIP],
      (unsigned long)uc->uc_mcontext.gp_regs[PT_LNK],
      (unsigned long)uc->uc_mcontext.gp_regs[PT_CTR],
      (unsigned long)uc->uc_mcontext.gp_regs[0],
      (unsigned long)uc->uc_mcontext.gp_regs[1],
      (unsigned long)uc->uc_mcontext.gp_regs[2],
      (unsigned long)uc->uc_mcontext.gp_regs[3],
      (unsigned long)uc->uc_mcontext.gp_regs[9],
      (unsigned long)uc->uc_mcontext.gp_regs[10],
      (unsigned long)uc->uc_mcontext.gp_regs[11],
      (unsigned long)uc->uc_mcontext.gp_regs[12],
      handled);
    write(2, b, n);
    _exit(43);
}

static int install_filter(void) {
    struct sock_filter f[] = {
        BPF_STMT(BPF_LD|BPF_W|BPF_ABS, offsetof(struct seccomp_data, arch)),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, AUDIT_ARCH_PPC64LE, 1, 0),
        BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ALLOW),
        BPF_STMT(BPF_LD|BPF_W|BPF_ABS, offsetof(struct seccomp_data, nr)),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, TRAPPED_NR, 0, 1),
        BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_TRAP),
        BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ALLOW),
    };
    struct sock_fprog prog = { .len = sizeof(f)/sizeof(f[0]), .filter = f };
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)) { perror("no_new_privs"); return -1; }
    if (syscall(__NR_seccomp, SECCOMP_SET_MODE_FILTER, SECCOMP_FILTER_FLAG_TSYNC, &prog)) {
        perror("seccomp"); return -1;
    }
    return 0;
}

static long iters = 5;
static void *worker(void *arg) {
    unsigned cpu, node;
    for (long i = 0; i < iters; i++)
        syscall(TRAPPED_NR, &cpu, &node, NULL);
    return NULL;
}

int main(int argc, char **argv) {
    int nthreads = argc > 1 ? atoi(argv[1]) : 1;
    if (argc > 2) iters = atol(argv[2]);
    struct sigaction sa, sv;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = sigsys_handler;
    sa.sa_flags = SA_SIGINFO | SA_NODEFER;
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGSYS, &sa, NULL)) { perror("sigaction"); return 1; }
    memset(&sv, 0, sizeof(sv));
    sv.sa_sigaction = fault_handler;
    sv.sa_flags = SA_SIGINFO;
    sigemptyset(&sv.sa_mask);
    sigaction(SIGSEGV, &sv, NULL);
    sigaction(SIGBUS,  &sv, NULL);
    sigaction(SIGILL,  &sv, NULL);
    if (install_filter()) return 1;
    fprintf(stderr, "start: %d threads x %ld iters\n", nthreads, iters);
    pthread_t t[256];
    for (int i = 0; i < nthreads; i++) pthread_create(&t[i], NULL, worker, NULL);
    for (int i = 0; i < nthreads; i++) pthread_join(t[i], NULL);
    fprintf(stderr, "OK: survived, handled=%llu\n", handled);
    return 0;
}
