/*
 * SECCOMP_RET_ERRNO must deliver the filter's errno, not ENOSYS.
 *
 * Reproducer for the powerpc syscall-exit defect fixed by
 * "powerpc/syscall: keep the seccomp/ptrace return value when the syscall is
 * skipped".  When a filter skips a syscall, do_syscall_trace_enter() returns
 * -1 and the return value has already been placed in pt_regs by
 * syscall_set_return_value().  powerpc then discarded it and returned
 * -ENOSYS, so every SECCOMP_RET_ERRNO(x) arrived in userspace as ENOSYS.
 *
 * Both syscall conventions are exercised, because they report errors
 * differently and the kernel has to get both right:
 *   sc    -- +errno in r3, CR0.SO set
 *   scv 0 -- -errno in r3, no SO bit   (what glibc uses on POWER9)
 *
 * Expected on a FIXED kernel:   all cases report the filter's errno.
 * On an UNPATCHED kernel:       every case reports ENOSYS (38).
 *
 * The syscall under test is getpid(), invoked through syscall(2) and through
 * raw asm so glibc's cached getpid cannot answer instead of the kernel.
 *
 *   gcc -O2 -o rerrno seccomp-ret-errno-ppc64le.c && ./rerrno
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>

/* Raw "sc": returns +errno in r3 and sets CR0.SO on error. */
static long raw_sc(long nr, long *so_out)
{
	register long r0 __asm__("r0") = nr;
	register long r3 __asm__("r3") = 0;
	long cr;

	__asm__ volatile("sc\n\t"
			 "mfcr %1"
			 : "+r"(r3), "=r"(cr), "+r"(r0)
			 :
			 : "r4", "r5", "r6", "r7", "r8", "r9", "r10", "r11",
			   "r12", "ctr", "memory");
	*so_out = !!(cr & 0x10000000);	/* CR0.SO */
	return r3;
}

static int install_errno_filter(int err)
{
	struct sock_filter f[] = {
		BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
			 offsetof(struct seccomp_data, nr)),
		BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_getpid, 0, 1),
		BPF_STMT(BPF_RET | BPF_K,
			 SECCOMP_RET_ERRNO | (err & SECCOMP_RET_DATA)),
		BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
	};
	struct sock_fprog p = { .len = sizeof(f) / sizeof(f[0]), .filter = f };

	if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0))
		return -1;
	return syscall(__NR_seccomp, SECCOMP_SET_MODE_FILTER, 0, &p);
}

/* Each case runs in its own child: a filter cannot be removed. */
static int run_case(int want)
{
	pid_t pid = fork();
	int status;

	if (pid < 0) { perror("fork"); exit(2); }
	if (pid == 0) {
		long so = 0, sc_r3, libc_r;
		int bad = 0;

		if (install_errno_filter(want)) { perror("seccomp"); _exit(2); }

		errno = 0;
		libc_r = syscall(SYS_getpid);
		if (libc_r != -1 || errno != want) {
			dprintf(2, "    scv/glibc: ret=%ld errno=%d (%s), want -1/%d\n",
				libc_r, errno, strerror(errno), want);
			bad = 1;
		}

		sc_r3 = raw_sc(__NR_getpid, &so);
		if (!so || sc_r3 != want) {
			dprintf(2, "    raw sc  : r3=%ld SO=%ld, want r3=%d SO=1\n",
				sc_r3, so, want);
			bad = 1;
		}
		_exit(bad);
	}
	if (waitpid(pid, &status, 0) < 0) { perror("waitpid"); exit(2); }
	return WIFEXITED(status) ? WEXITSTATUS(status) : 2;
}

int main(void)
{
	static const int errs[] = { EPERM, EACCES, EINVAL, EAGAIN, ENOMEM };
	int i, fail = 0;

	puts("SECCOMP_RET_ERRNO on ppc64le: filter errno must survive to userspace");
	for (i = 0; i < (int)(sizeof(errs) / sizeof(errs[0])); i++) {
		int r = run_case(errs[i]);

		printf("  %-8s (%2d) : %s\n", strerror(errs[i]), errs[i],
		       r == 0 ? "ok" : "MISMATCH");
		if (r) fail = 1;
	}
	if (fail)
		puts("\nFAIL -- if every case reports ENOSYS (38), this kernel is missing\n"
		     "the powerpc syscall-skip fix.");
	else
		puts("\nOK -- all filter errnos delivered, for both sc and scv callers.");
	return fail;
}
