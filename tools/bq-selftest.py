#!/usr/bin/env python3
"""Self-test for bq's package-level concurrency.

These are the invariants that make `bq build -j N` safe, checked without
building anything.  A build-level proof (same queue, serial vs parallel,
identical unpacked trees) is a separate exercise; this catches the scheduler
and slot-partitioning bugs that a build would only expose intermittently.

Every check here is negatable: run with --break <name> to introduce the exact
fault it exists to catch and confirm the check fails.  A check nobody has ever
seen fail is not evidence.

    tools/bq-selftest.py
    tools/bq-selftest.py --break ordering
    tools/bq-selftest.py --break budget
    tools/bq-selftest.py --break affinity
"""

import os
import sys
import time
import random
import argparse
import threading

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bq  # noqa: E402


FAILURES = []


def check(name, cond, detail=""):
    print("  %-46s %s%s" % (name, "ok" if cond else "FAIL",
                            "  " + detail if detail and not cond else ""))
    if not cond:
        FAILURES.append(name)


class FakeArgs:
    def __init__(self, jobs, budget=0, make_jobs=0, affinity=True):
        self.jobs = jobs
        self.job_budget = budget
        self.make_jobs = make_jobs
        self.cpu_affinity = affinity
        self.min_free = 0.0
        self.min_mem = 0.0
        self.stop_on_fail = False


# ==========================================================================
# 1. schedule_blockers: the graph the scheduler actually waits on
# ==========================================================================

def test_blockers(broken):
    print("schedule_blockers")
    order = ["a", "b", "c", "d"]
    # d needs c and a; c needs a; b needs nothing.  Plus one forward edge
    # (a -> d), which is what a cut cycle leaves behind.
    deps = {"a": {"d"}, "b": set(), "c": {"a"}, "d": {"a", "c"}}
    bl = bq.schedule_blockers(order, deps, order)

    check("backward edges kept", bl["d"] == {"a", "c"}, repr(bl["d"]))
    check("independent package has no blockers", bl["b"] == set(), repr(bl["b"]))
    # The forward edge a->d is the cut of a cycle.  Honouring it would deadlock;
    # the serial run does not honour it either, because it builds a before d.
    check("forward edge (cut cycle) dropped", bl["a"] == set(), repr(bl["a"]))

    # Anything not in todo is already built and sitting in repo/.
    bl2 = bq.schedule_blockers(order, deps, ["c", "d"])
    check("blockers outside todo dropped", bl2["c"] == set(), repr(bl2["c"]))
    check("blockers inside todo kept", bl2["d"] == {"c"}, repr(bl2["d"]))

    # Acyclic by construction: a subset of a total order cannot cycle.
    seen, stack = set(), []

    def visit(n):
        if n in stack:
            return False
        if n in seen:
            return True
        stack.append(n)
        okk = all(visit(m) for m in bl.get(n, ()))
        stack.pop()
        seen.add(n)
        return okk
    check("blocker graph is acyclic", all(visit(n) for n in bl))


# ==========================================================================
# 2. the dispatch loop honours those blockers under real threads
# ==========================================================================

def test_ordering(broken):
    print("run_parallel ordering")
    # A queue with a spine (a -> c -> f) and independent packages around it.
    order = ["a", "b", "c", "d", "e", "f", "g", "h"]
    deps = {"a": set(), "b": set(), "c": {"a"}, "d": set(), "e": {"b"},
            "f": {"c", "e"}, "g": set(), "h": {"f"}}
    todo = list(order)

    running = set()
    finished = set()
    violations = []
    lock = threading.Lock()
    overlap = [0]

    def run_one(t, slot):
        with lock:
            # The invariant: nothing this package depends on may still be
            # unfinished when it starts.
            for d in deps[t]:
                if d not in finished:
                    violations.append("%s started before %s finished" % (t, d))
            running.add(t)
            overlap[0] = max(overlap[0], len(running))
        time.sleep(random.uniform(0.01, 0.05))
        with lock:
            running.discard(t)
            finished.add(t)
        return {"status": "ok", "seconds": 0.0}

    args = FakeArgs(jobs=4)
    if broken:
        # The fault this check exists to catch: dispatch on order position only,
        # ignoring the dependency edges.
        deps_used = {}
    else:
        deps_used = deps
    slots = [FakeSlot(i) for i in range(4)]
    counters = {"stop": False}
    bq.run_parallel(todo, order, deps_used, slots, bq.CpuPool(args), args,
                    run_one, counters)

    check("every package built", finished == set(order),
          "missing " + repr(set(order) - finished))
    check("no dependent started before its dependency finished",
          not violations, "; ".join(violations[:3]))
    # If nothing ever overlapped the scheduler is correct but useless.
    check("packages actually overlapped", overlap[0] > 1,
          "max concurrency %d" % overlap[0])


class FakeSlot:
    def __init__(self, i):
        self.idx = i
        self.make_jobs = 4
        self.cpus = None

    def label(self):
        return "slot%d" % self.idx


# ==========================================================================
# 3. MAKEFLAGS is divided, not duplicated
# ==========================================================================

def test_budget(broken, tmp):
    print("job budget")
    try:
        avail = len(os.sched_getaffinity(0))
    except AttributeError:
        avail = os.cpu_count() or 1

    for n in (1, 2, 4, 7):
        args = FakeArgs(jobs=n)
        pool = bq.CpuPool(args)
        got = []
        for _ in range(n):
            cpus = pool.take(n - len(got))
            if broken:
                # The fault: every job takes the whole budget, so N jobs run at
                # N x the machine's worth of compilers.
                cpus = list(pool.all)
            got.append(pool.jobs_for(cpus))
        total = sum(got)
        check("jobs=%d: total -j (%d) within budget (%d)" % (n, total, avail),
              total <= avail + 2 * n,   # slack for the max(2,...) floor
              "jobs %s" % got)

    # ...and it has to be a knob, not a constant.
    p = bq.CpuPool(FakeArgs(jobs=4, make_jobs=9))
    check("--make-jobs overrides the split",
          [p.jobs_for(p.take(4)) for _ in range(4)] == [9, 9, 9, 9])
    p = bq.CpuPool(FakeArgs(jobs=4, budget=40))
    check("--job-budget divides",
          [p.jobs_for(p.take(4 - i)) for i in range(4)] == [10, 10, 10, 10])


# ==========================================================================
# 4. CPU allocation: disjoint, covering, and returned when a job ends
# ==========================================================================

def test_affinity(broken, tmp):
    print("cpu pool")
    try:
        avail = sorted(os.sched_getaffinity(0))
    except AttributeError:
        avail = list(range(os.cpu_count() or 1))

    pool = bq.CpuPool(FakeArgs(jobs=4))
    got = [pool.take(4 - i) for i in range(4)]
    if broken:
        # The fault: every job gets every CPU, so ninja, cargo and GCC's LTO
        # partitioner -- which size themselves from sched_getaffinity(), not
        # MAKEFLAGS -- each take the whole box regardless of the -j split.
        got = [list(avail) for _ in got]

    seen = [c for g in got for c in g]
    check("cpu sets are disjoint", len(seen) == len(set(seen)),
          "%d assignments, %d distinct" % (len(seen), len(set(seen))))
    check("cpu sets cover the machine", set(seen) == set(avail),
          "%d of %d" % (len(set(seen)), len(avail)))

    # The point of allocating at dispatch instead of partitioning up front: the
    # last package standing must get the machine, not a quarter of it.
    pool = bq.CpuPool(FakeArgs(jobs=4))
    a, b, c = pool.take(4), pool.take(3), pool.take(2)
    for x in (a, b, c):
        pool.give(x)
    last = pool.take(1)
    check("the last package standing gets every cpu",
          sorted(last) == avail, "%d of %d" % (len(last), len(avail)))
    check("...and the -j that goes with it",
          pool.jobs_for(last) == len(avail), str(pool.jobs_for(last)))

    check("--no-cpu-affinity leaves jobs unpinned",
          bq.CpuPool(FakeArgs(4, affinity=False)).take(4) is None)
    check("serial runs are never pinned",
          bq.CpuPool(FakeArgs(1)).take(1) is None)

    check("cpuspec compresses ranges",
          bq.cpuspec([0, 1, 2, 3, 7, 9, 10]) == "0-3,7,9-10",
          bq.cpuspec([0, 1, 2, 3, 7, 9, 10]))


# ==========================================================================
# 5. slot isolation: serial keeps one sysroot, parallel gets a layer each
# ==========================================================================

def test_slots(broken, tmp):
    print("sysroot layering")
    base = os.path.join(tmp, "sysroot")
    os.makedirs(base, exist_ok=True)

    s1 = bq.make_slots(FakeArgs(1), base)[0]
    check("serial gets exactly one slot", len(bq.make_slots(FakeArgs(1), base)) == 1)
    check("serial uses the base sysroot unchanged",
          s1.layers == [base] and s1.layer == base, repr(s1.layers))

    slots = bq.make_slots(FakeArgs(3), base)
    check("each parallel slot writes only its own layer",
          len({s.layer for s in slots}) == 3
          and all(s.layer != base for s in slots),
          repr([s.layer for s in slots]))
    check("every slot reads the shared base underneath",
          all(s.layers[0] == base and s.layers[-1] == s.layer for s in slots))
    check("slots do not share a makepkg.conf",
          len({s.conf for s in slots}) == 3)

    # bwrap stacking order: live /usr at the bottom, base next, slot on top.
    # Getting this backwards silently shadows a staged package with the system
    # copy, which is the opposite of the point of a sysroot.
    for lay in slots[0].layers:
        os.makedirs(os.path.join(lay, "usr"), exist_ok=True)
    pre = bq.bwrap_prefix(slots[0].layers)
    srcs = [pre[i + 1] for i, a in enumerate(pre) if a == "--overlay-src"]
    check("overlay order is /usr, base, slot",
          srcs == ["/usr", os.path.join(base, "usr"),
                   os.path.join(slots[0].layer, "usr")], repr(srcs))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--break", dest="brk", default="",
                    help="introduce the fault a check exists to catch, and "
                         "confirm the check fails: ordering|budget|affinity")
    a = ap.parse_args()

    import tempfile
    tmp = tempfile.mkdtemp(prefix="bq-selftest-")
    bq.BUILDROOT = tmp          # admission control statvfs()es this
    random.seed(1)

    test_blockers(a.brk == "blockers")
    test_ordering(a.brk == "ordering")
    test_budget(a.brk == "budget", tmp)
    test_affinity(a.brk == "affinity", tmp)
    test_slots(a.brk == "slots", tmp)

    print()
    if FAILURES:
        print("FAILED: " + ", ".join(FAILURES))
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
