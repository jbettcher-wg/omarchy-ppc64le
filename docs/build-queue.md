# The build queue

`tools/bq.py` — one engine for the mass rebuild and for AUR triage.

`makepkg` builds exactly one package and will not order a set for you. That is
the smallest of the problems. The others are that build dependencies have to
appear without root and without touching the live system, that an 858-package
run *will* be interrupted, and that a pile of failure logs is not a work queue.
So `bq` owns order, isolation, cleanup, resumption and triage, and calls
`makepkg` for the one job `makepkg` is good at.

## Why not devtools

Arch POWER ships `devtools` 1:1.5.1-1.2 and it is installed. It is unusable
here for two independent reasons:

- `makechrootpkg` calls `check_root` and re-execs under `sudo`. `sudo` on this
  box needs a password.
- the `archbuild` wrappers it installs are `extra-x86_64-build`,
  `core-x86_64-build` and friends. There is no `powerpc64le` wrapper, and
  `mkarchroot` would need to bootstrap a chroot as root anyway.

So the unprivileged `bwrap --overlay-src … --ro-overlay /usr` technique already
proven in `tools/build.sh` is what the queue uses. It was checked first, not
assumed.

## Order

Build-time dependencies are `depends + makedepends + checkdepends`, read from
`.SRCINFO` where a recipe has one and from a sourced `PKGBUILD` where it does
not. Edges are drawn **only between packages in the queue** — a dependency Arch
POWER already ships is a precondition, not an ordering constraint on us.

Kahn's algorithm, ties broken by name so the queue is reproducible. Packages
left in a cycle are appended in name order rather than dropped, and `plan`
names them.

```
$ bq plan tllist fcft foot hyprutils hyprlang libjuice libdatachannel …
   6  hyprutils            local
   8  hyprlang             local     <- after hyprutils
  10  libjuice             local
  11  libdatachannel       local     <- after libjuice
  13  tllist               local
  14  fcft                 local     <- after tllist
  15  foot                 local     <- after fcft
```

### Why "already installed" is an ordering rule, not just a shortcut

The first full-scale plan reported **595 of 622 packages as circular**. Two
separate bugs, and the second one is the interesting one.

The first was cascade over-reporting — once one real cycle blocks, everything
downstream of it never becomes ready either, so a naive "unordered means
cyclic" test indicts the whole tail. Tarjan's algorithm over the residual graph
finds the genuine strongly-connected components. That brought it to 83.

The second was that **83 was also honest**, and the largest component had ~400
members: `glibc ↔ gcc ↔ binutils ↔ bash ↔ …`. Across a whole distro's
`makedepends` the graph is simply not a DAG. Everything build-depends on the
toolchain and the toolchain build-depends on everything. A full-distro rebuild
from nothing is a bootstrap problem, and no topological sort will make it
otherwise.

But we are not building from nothing. Every package in that core is **already
installed on this host**, which makes it a precondition in exactly the sense
Arch POWER's shipped packages already were. Dropping edges to dependencies the
host already satisfies — `pacman -T`, read-only, no root — collapses the
bootstrap core completely:

```
622 packages, 0 cycles
```

and leaves an order that says something real about the packages that actually
have to be built. Verified against eleven known constraints, zero violations:

```
hyprutils (150) before hyprland (537)      fcft (79) before foot (91)
aquamarine (151) before hyprland (537)     libjuice (271) before libdatachannel (344)
localsearch (555) before nautilus (591)    nautilus (591) before nautilus-python (592)
cpptrace (235) before quickshell (481)     libgxps (256) before evince (467)
```

`--full-bootstrap` restores the from-scratch ordering, which is the right mode
for building the ISO on a machine that does not already have 1374 packages on
it. It will report the bootstrap core, correctly, as a cycle.

## Isolation

No root, and nothing installed into the live system.

Packages the queue builds are extracted into a **sysroot** under the buildroot,
and the next build sees them through a read-only bubblewrap overlay stacked
over `/usr`:

```
bwrap --dev-bind / / --overlay-src /usr --overlay-src $SYSROOT/usr --ro-overlay /usr
```

Environment variables alone are not sufficient and this is not a theoretical
point: `obs-studio` hardcodes `/usr/include/mbedtls3`, `valac` and `graphviz`
bake `/usr` into their binaries. A staged package has to appear *at the path it
will eventually be installed to*. The overlay is process-local and read-only;
the real `/usr` is untouched.

The last `--overlay-src` is the topmost layer, so `/usr` goes first and the
sysroot on top. Reversed, a staged package that also exists in the live `/usr`
is shadowed by the system copy — the opposite of the point.

`elf-pathguard.sh` runs over every `$pkgdir` the queue produces, adopted or not,
and quarantines the archive if a shipped ELF records a build-tree path. That
guard exists because `neovim` 0.12.5-1 shipped
`DT_NEEDED [$SYSROOT/usr/lib/lua/5.1/lpeg.so]` and ran fine until someone would
have deleted the sysroot.

### The host half of the overlay is a dependency

`/usr` is the *lower* layer, which means every build also sees whatever is
installed on the build machine. That is deliberate — it is how the queue avoids
staging a full toolchain — but it makes the host an undeclared build dependency,
and the failure mode is delayed: a package builds on the machine that has the
tool and fails on the one that does not, with an error that names neither.

Rebuilding six packages on a fresh install produced six failures, all of them
missing host tools and none of them a code problem:

| missing on the host | what broke, and how it read |
|---|---|
| `qemu-system-ppc` | `systemd` — `qemu-system-ppc64 -device help` failed with status 127, from a probe in `test/integration-tests/meson.build` that the recipe's `-Dinstall-tests=true` pulls in |
| `docbook-xsl`, `docbook-xml` | `libsecret`, `p11-kit`, `tinysparql` — `xsltproc` exit 5, or "Docbook stylesheet for manpages is missing" |
| `python-setuptools` | `libgsf` — `g-ir-scanner` dies with `ModuleNotFoundError: No module named 'distutils'`. `giscanner/utils.py` imports `distutils.cygwinccompiler` unguarded at module level; python 3.12 removed `distutils`, and setuptools' `distutils-precedence.pth` is what makes the import resolve. **Without it every package that generates a `.gir` fails**, not just this one. |

So install these before a mass rebuild:

```sh
sudo pacman -S --needed qemu-system-ppc docbook-xsl docbook-xml python-setuptools
```

`qemu-system-ppc` earns its place twice: `installer/test/run-guest.sh` needs it
to boot the ISO under `-machine powernv9`.

Two of these are worth reading as a warning about triage rather than a list to
memorise. bq classified the `systemd` failure as `missing-dep` on the line
`Program python3 found: NO (disabled by: bootloader)` and `p11-kit` on
`Program castxml found: NO` — both are meson reporting a *disabled optional*
lookup, several hundred lines above the actual error. The class was right by
accident and the named dependency was wrong in both cases.

### Version-locked component sets

Some upstreams release several packages as one versioned set, and mixing
versions within a set breaks in ways nothing checks for. The sonames match, so
`tools/soname-gaps.py` sees nothing; the ABI is fine; the *semantics* diverge.

The case that cost an evening: our repo carried

    glslang        1:1.4.357.0     <- moved ahead
    spirv-tools    1:1.4.350.0
    spirv-headers  1:1.4.350.0

`1.4.350.0` and `1.4.357.0` are **Vulkan SDK release tags**, and glslang,
SPIRV-Tools and SPIRV-Headers ship together against them. glslang 357 emitted
SPIR-V that SPIRV-Tools 350's `AggressiveDCEPass` walked with stale assumptions,
and every Vulkan application that compiles shaders through shaderc segfaulted:

    libSPIRV-Tools-opt.so
      spvtools::opt::AggressiveDCEPass::AddOperandsToWorkList
      <- Optimizer::Run <- libshaderc_shared.so.1 <- blender

It presented as "Blender's Vulkan backend is broken on ppc64le". It was neither
Blender nor ppc64le. Rebuilding all four in lockstep fixed it.

Sets known to need this treatment here:

| set | keep together |
|---|---|
| Vulkan SDK | `glslang`, `spirv-tools`, `spirv-headers`, `shaderc` |
| Qt 6 | every `qt6-*` module at one version -- see `packages/qt6-base` |
| Qt for Python | `pyside6` and `shiboken6` at the **same version as Qt**, generated from its headers |
| ROCm | `rocm-llvm`, `comgr`, `rocm-device-libs`, `hsa-rocr`, `hip-runtime`, `rocminfo` -- they version-check each other at runtime |
| VTK third-party | bundled `ioss` expects the bundled `fmt`; see `packages/vtk` |

Before bumping one member of a set, bump them all in the same queue. Before
concluding an application is broken on this platform, check whether we have
split a set.

## Never in a checkout

Recipes are **copied out** of their source tree into `$BUILDROOT/build/<pkgbase>`
and built there. The `~/Development/repo/archpower` checkout is read-only input.
Building in place is what leaves `src/`, `pkg/` and stray tarballs scattered
through a checkout — 6.5 GiB of it, in that tree's case — and makes the next
`git pull` awkward.

`PKGDEST` is `repo/`, `SRCDEST` is shared under the buildroot so a resumed run
does not re-download, and the whole per-package work directory is removed after
each package. That is stricter than `makepkg -c` and costs nothing, because the
recipe came from elsewhere and the downloads live in `SRCDEST`. Peak disk is one
package's build tree rather than the sum; naive accumulation across this queue
would be ~130 GiB.

Default buildroot is `/tmp/omarchy-bq` — a 221 GiB tmpfs on a 440 GiB machine.
Right for the ~850 small and medium packages, wrong for chromium/llvm/gcc: pass
`--buildroot /var/tmp/omarchy-bq` for those so they land on the NVMe. `bq`
refuses to build inside a source checkout, and defers a package when the
buildroot has less than `--min-free` GiB.

## `OPTIONS=(!debug)`

`bq` generates a `makepkg.conf` that sources the system one and overrides only
what the mass rebuild needs. `!debug` is the headline: debug packages measured
590 MiB against 338 MiB of real packages, 1.75×, for symbols nobody in this
queue is going to read.

## Resumable

State lives in `.bq-state.json` and is written **after every package**, not at
the end. A resumed run skips anything already `ok`; `--retry-failed` re-tries
failures, `--rebuild` redoes everything. There is no run that has to start from
scratch.

## `-j`: several packages at once

`bq build -j N` builds N packages concurrently. The reason is not that makepkg
compiles slowly — it is that a large fraction of a package's wall time cannot
use 176 threads at all. `./configure` probes one feature at a time, `autoreconf`
is serial, the final link is one process, and so are `strip` and the `zstd` of
the archive. Serially the box idles through all of it.

Measured on a real ten-package queue (`tomlplusplus fcft foot hyprlang
hyprcursor glaze file embree libphonenumber ngspice`, seven of which build here;
same buildroot path, same recipes, back to back):

| | wall |
|---|---|
| `-j1` | 307 s |
| `-j4`, fixed CPU slices | 178 s |
| `-j4`, CPUs allocated at dispatch | **93 s** |

Concurrency is **off by default**. `-j1` is byte-for-byte the behaviour bq had
before it existed, down to leaving `/etc/makepkg.conf`'s own `MAKEFLAGS` alone.

### What had to be made safe

**Order.** The queue already knows the dependency edges; `plan` now records them
in `queue.json` and the scheduler turns them into a wait-set. A dependent is
released when its blocker *finishes*, pass or fail — which is exactly what the
serial loop does. Only edges pointing backwards in the resolved order are
honoured: a cut cycle leaves forward edges behind, waiting on one would
deadlock, and the serial run did not honour it either.

**The sysroot**, which is shared mutable state and the hard part. Three options
were on the table. A sysroot per job is simple and far too expensive — a resumed
run stages *everything in `repo/`*, 1,327 packages and 22 GiB, and paying that
per slot costs 88 GiB and minutes of `tar` before a single package builds. A
lock around staging serialises the writers but still leaves the overlay's
lowerdir being written to while another slot has it mounted, which overlayfs
calls undefined and which shows up as intermittent `ESTALE`. So: **layer it.**
`bwrap` stacks overlay layers already, so one shared base holds what
`rehydrate_sysroot` stages and is frozen before any job starts, and each slot
gets a private layer on top that only it writes, and only before its own `bwrap`
starts. Measured on the 15-package packager sweep: 22 GiB shared, 1–2 GiB per
slot.

That layering is also why a package must not start until its dependencies have
*finished*, not merely started: the mechanism that makes a fresh dependency
visible is `stage-deps` reading it out of `repo/`, and it only lands there when
the build ends.

**MAKEFLAGS**, divided rather than duplicated — four jobs inheriting the system's
`-j144` would be 576 compilers. Each job also gets a disjoint CPU set via
`taskset`, which is not decoration: `MAKEFLAGS` only reaches make. `ninja`,
`cargo`, rustc's codegen threads and GCC's LTO partitioner all size themselves
from `sched_getaffinity()` and would each take the whole machine.

**The CPUs are allocated at dispatch, not partitioned up front.** Fixed slices
waste the machine at the tail of a queue: in the middle row of the table above,
the last 100 of those 178 seconds had one package (embree) holding 44 threads
while 132 sat idle behind an affinity mask — embree takes 47 s on the whole box
and 159 s on a quarter of it. A job now takes the free CPUs divided by the
number of jobs starting alongside it, so the last package standing gets
everything.

**Concurrent writers.** `repo-add` takes a `.lck` of its own and *aborts* rather
than waits, so it is serialised behind a lock and an `flock` (the flock because
`BQ_REPO` exists precisely so a second bq can run). The `.bq-state.json` update
is under a lock. `sysroot-fetch.sh` downloads to a private temp and renames,
because two slots wanting the same Arch POWER package would otherwise have one
of them read a half-written cache file.

### When it does not pay

A queue dominated by one very large package. Every package in the packager
sweep except chromium finished inside two minutes at `-j4`; chromium, given a
quarter of the machine, had reached 3,290 of 55,835 ninja steps in nine minutes
with the rest of the box idle. It scales to 176 threads on its own, so splitting
the box for it buys nothing and costs a factor of three. Build the giants at
`-j1` and use `-j` for the tail.

### Checking it

`tools/bq-selftest.py` checks the invariants without building anything: that no
dependent is dispatched before its dependency finishes, that packages do
overlap, that the total `-j` stays inside the budget, that CPU sets are disjoint
and cover the machine, and that the layers stack `/usr` → base → slot. Each
check can be made to fail on purpose — `--break ordering|budget|affinity` —
because a check nobody has watched fail is not evidence.

`tools/pkg-treediff.py A B` compares two directories of built packages by their
unpacked contents (path, type, mode, symlink target, sha256, with `.PKGINFO`,
`.BUILDINFO` and `.MTREE` excluded because those legitimately differ). A serial
run and a `-j4` run of the queue above produced byte-identical payloads for
seven of the eight packages. The eighth, `foot`, is simply not reproducible:
two *serial* runs at identical settings differ in `usr/bin/foot` by 415,100 of
659,504 bytes and carry different build-ids. `--self-test PKG` corrupts one hash
on purpose to prove the comparison can report a difference.

## Failure classes

The classifier turns logs into a work queue, because on POWER the class *is* the
fix:

| class | what it means |
|---|---|
| `arch-gate` | `arch=()` omits `powerpc64le`. Usually the only change needed. Detected **before** the build, not from a log. |
| `prebuilt-binary-only` | upstream ships an x86-64 binary, not source |
| `march-native` | PowerPC has no `-march=`; use `-mcpu=power9` |
| `float16-unavailable` | `_Float16` is not a type on ppc64le GCC |
| `phantom-arch-macro` | code tests `__ppc64le__` / `__PPC64LE__`, **which no compiler defines**, so the check can never fire. Real macros: `__PPC64__`, `__powerpc64__`, `__LITTLE_ENDIAN__`, `_CALL_ELF == 2` |
| `x86-asm` | genuine x86 assembly or intrinsics |
| `missing-dep` | a build dependency is absent; build it first |
| `checksum` | integrity or signature failure |
| `elf-pathguard` | shipped ELF records a build-tree path; quarantined |
| `test-failure` | `check()` failed |
| `timeout` / `disk` / `no-recipe` / `unknown` | self-explanatory |

`bq triage` writes `docs/build-queue-triage.md` grouped by class, each entry
carrying the offending log line and the path to the full log, plus a matching
`.json` for tooling.

## Pluggable sources

The AUR triage tool is this same engine with a different front end, so the
recipe source is a plugin rather than a fork:

| source | where from |
|---|---|
| `local` | `packages/<pkgbase>/` — our own recipes |
| `archpower` | `~/Development/repo/archpower/<pkgbase>/` — read-only |
| `gitlab` | `gitlab.archlinux.org/archlinux/packaging/packages/<pkgbase>` |
| `aur` | `aur.archlinux.org/<pkgbase>.git` |

Priority is `--sources local,archpower,gitlab` by default; first hit wins.

The `aur` source additionally rewrites `arch=()` and regenerates `.SRCINFO`.
That is not a convenience. **libalpm enforces the architecture guard itself**,
so `yay` and `paru` cannot be flagged past it — the recipe has to be edited
before `makepkg` ever sees it, and a stale `.SRCINFO` re-imposes the guard the
edit just removed, because helpers read the `.SRCINFO` and not the `PKGBUILD`.
`--fix-arch` applies the same rewrite to any source.

## Commands

```sh
bq plan   [targets…] [-f file] [--sources …]   # resolve order -> queue.json
bq build  [targets…] [-n N] [--force] [--retry-failed] [--fix-arch]
          [-j N|auto] [--job-budget N] [--make-jobs N] [--no-cpu-affinity]
          [--min-free GIB] [--min-mem GIB]
bq status [-v]
bq triage [-o out.md]

tools/bq-selftest.py [--break ordering|budget|affinity]   # -j invariants
tools/pkg-treediff.py A B [--self-test PKG]               # same build twice?
```

### Rebuilding something already published

Three flags, three different jobs: `--rebuild` re-queues a package bq has
recorded as done, `--force` makes makepkg overwrite an existing archive, and
`--retry-failed` re-queues one bq recorded as failed. A rebuild without
`--rebuild` queues nothing ("0/N to build").

And **bump pkgrel first.** pacman compares versions, not contents, so a
package rebuilt at the same version replaces its file in `repo/`, but
`pacman -Syu` never delivers it to a system that already has that version.
`tools/repo-publish.sh --commit` refuses to publish a file that is newer than
the db, has the same version as its db entry and a different sha256
(`ALLOW_SAME_VERSION=1` overrides that, for a package nothing has installed
yet).
