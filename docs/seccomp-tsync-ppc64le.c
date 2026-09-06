/*
 * Does SECCOMP_FILTER_FLAG_TSYNC work for multi-threaded processes on this
 * kernel? Chromium renderers are multi-threaded and must use TSYNC, and no
 * successful TSYNC install appears in any chromium trace -- so this was a
 * suspect. It is not: TSYNC installs succeed on 7.2.2 both single-threaded and
 * with 8 spinning threads, alone and combined with SPEC_ALLOW.
 *
 * gcc -O2 -o tsync seccomp-tsync-ppc64le.c -lpthread ; ./tsync 8
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <pthread.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>

static volatile int go = 0;
static void *spin(void *a) { while (!go) sched_yield(); for (int i=0;i<200000;i++) getpid(); return NULL; }

static int try_install(unsigned flags, const char *name) {
    struct sock_filter f[] = {
        BPF_STMT(BPF_LD|BPF_W|BPF_ABS, offsetof(struct seccomp_data, arch)),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, AUDIT_ARCH_PPC64LE, 1, 0),
        BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ALLOW),
        BPF_STMT(BPF_LD|BPF_W|BPF_ABS, offsetof(struct seccomp_data, nr)),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, __NR_getcpu, 0, 1),
        BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_TRAP),
        BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ALLOW),
    };
    struct sock_fprog prog = { .len = sizeof(f)/sizeof(f[0]), .filter = f };
    errno = 0;
    long r = syscall(__NR_seccomp, SECCOMP_SET_MODE_FILTER, flags, &prog);
    printf("  seccomp(SET_MODE_FILTER, %s, prog) = %ld  errno=%d (%s)\n",
           name, r, errno, r ? strerror(errno) : "ok");
    return r == 0 ? 0 : -1;
}

int main(int argc, char **argv) {
    int nthreads = argc > 1 ? atoi(argv[1]) : 8;
    /* probe, exactly as chromium's KernelSupportsSeccompTsync() does */
    errno = 0;
    long p = syscall(__NR_seccomp, SECCOMP_SET_MODE_FILTER, SECCOMP_FILTER_FLAG_TSYNC, NULL);
    printf("TSYNC probe: ret=%ld errno=%d (%s)  -> chromium reads EFAULT as 'supported'\n",
           p, errno, strerror(errno));

    pthread_t t[256];
    for (int i = 0; i < nthreads; i++) pthread_create(&t[i], NULL, spin, NULL);
    printf("process now has %d extra threads\n", nthreads);
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)) { perror("no_new_privs"); return 1; }

    printf("multi-threaded install attempts:\n");
    try_install(SECCOMP_FILTER_FLAG_TSYNC | SECCOMP_FILTER_FLAG_SPEC_ALLOW, "TSYNC|SPEC_ALLOW");
    try_install(SECCOMP_FILTER_FLAG_TSYNC, "TSYNC");
    try_install(SECCOMP_FILTER_FLAG_SPEC_ALLOW, "SPEC_ALLOW");
    go = 1;
    for (int i = 0; i < nthreads; i++) pthread_join(t[i], NULL);
    printf("done\n");
    return 0;
}
