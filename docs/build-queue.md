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

### Stale host files: opaque directories

The overlay merges directories. A staged file replaces the host file at the
same path, but a host file the staged package does **not** ship stays visible.
When a repo package is a newer build of something installed on the host,
every file the newer version dropped leaks into the build.

Two incidents, both on 2026-09-13:

- **gcc-go.** Arch POWER's gcc recipe produced `gcc-go`, which ships
  `/usr/bin/go` and `/usr/bin/gofmt` (`provides=go=1.17`). Staged from `repo/`,
  those replaced the host's real Go in every build (chromium's dawn step on
  2026-09-12). That one was a packaging decision rather than a staging bug:
  gcc-go and libgo left `repo/`, and `packaging/gcc` no longer builds the Go
  front end.
- **go 1.27.1 over host go 1.26.5.** stage-deps prefers our build over the
  installed one, so it staged 1.27.1. 1.27.1 no longer ships 165 files that
  1.26.5 has, and the merged `/usr/lib/go` held both. Every Go build then
  died compiling the standard library:
  `internal/strconv/uscale.go:82:5: uint64pow10 redeclared in this block`.

Overlayfs has a switch for this: an **opaque** directory hides everything
beneath it in lower layers. bwrap mounts its overlay with `userxattr`, so an
unprivileged `user.overlay.opaque=y` on a sysroot directory works;
`trusted.overlay.opaque` is refused without root.

`tools/sysroot-add.sh` calls `tools/sysroot-opaque.py` after extracting.
A directory is marked only if all of these hold:

| rule | why |
|---|---|
| the staged package replaces a host-installed package: same pkgname, or named in its `replaces`/`conflicts` | nothing else can leave stale files behind |
| the directory is under `usr/` or `opt/` | `bwrap_prefix` overlays nothing else |
| no installed package outside that set owns any path at or under it (pacman's local db) | keeps `/usr`, `/usr/lib`, `/usr/include` and every other shared directory merged |
| no lower sysroot layer holds anything under it that the staged package lacks | under `-j`, an opaque mark in a slot would hide the shared base too; bq passes the lower layers as `SYSROOT_LOWER` |
| it is not on a fixed list of shared roots | defence in depth, not the mechanism |

The shallowest eligible directories are marked. Across `repo/` against this
host that is 3,011 directories in 863 packages, e.g. `usr/lib/go`,
`usr/include/c++`, `usr/lib/cmake/llvm`, `usr/lib/python3.14/__pycache__`.
Indexing the host db costs about 1.7 s per `sysroot-add.sh` call.

What it does not change: the other overlaps a scan of `repo/` against the
host found are same-path overwrites of a *different* package, not stale
leftovers of the same one, and none of those packages declares
`replaces`/`conflicts` against what it overwrites:

| repo package | over host | overlap |
|---|---|---|
| `zlib-ng-compat` | `zlib` | `libz.so*` |
| `jack` | `pipewire-jack` | `libjack*.so*` |
| `linux-power9-api-headers` | `linux-api-headers` | 1,005 headers |
| `iptables-legacy` | `iptables` | 239 files |
| `bubblewrap-suid` | `bubblewrap` | `/usr/bin/bwrap` |
| `dbus-daemon-units`, `pulseaudio` | `dbus-broker-units`, `pipewire-pulse` | unit / schema files |

Those are open questions about what the sysroot *should* contain, not bugs
this mechanism can decide.

Marks persist in a sysroot. After a host upgrade that moves files between
packages, delete `<buildroot>/sysroot*`; bq rebuilds it on the next run.

### repo/ is restaged on every run

`rehydrate_sysroot()` stages two things into the base sysroot before any job
starts: packages this queue already built, and **everything in `repo/`**. The
second half is what makes a deliberate rebuild outrank the host copy for
packages nothing in the queue names directly (libheif needing our libde265,
above).

Until 2026-09-13 the function returned early when no package *of the current
run's queue* was already `ok` in the state file, and that early return skipped
the `repo/` restage too. It keyed on the queue, not on the state file being
new, so it fired for any fresh `BQ_STATE` and for any run whose targets were
all new -- which is every targeted `bq build <pkg>`. Those runs built against
only what stage-deps pulled in (declared deps, plus the `repo/` closure of our
own packages) and the host's copy of everything else.

Runs on 2026-09-13 that took that path, read from their state files:

| state file | builds | restaged repo/? |
|---|---|---|
| `/var/tmp/bq-state-toolchain.json` (new that day) | fzf, lld21, go, zig, llvm20, compiler-rt20, lld20, clang20, zig0.15, herdr | never: 10 builds, 12 names in `staged` |
| `.bq-state.json` (long-lived, 791 `ok`) | asdcontrol, cliamp, hyprland-preview-share-picker, omacalc, omacut, omawrite, tensaku | no: all seven targets were new, so the queue had nothing `ok` |
| a throwaway state for cliamp 2.0.1-2 | cliamp | no |
| `/var/tmp/bq-state-dotnet.json` (new that day) | pinta, marksman, dotnet-core | pinta no (first `ok` record); a later run in that state did, since `staged` holds 1,344 names; marksman undetermined |
| `/var/tmp/bq-state-electron.json` (new that day) | electron43 | no: 0 `ok`, 0 `staged` |

Checked whether it changed any artifact, without rebuilding:

- `repo/` against the host: of 1,346 packages, 870 are installed at the same
  version *and* the same build date, 474 are not installed at all, and two
  differ: `marksman` (repo 20260208-5, host -4) and `btop` (repo 1.4.7-1,
  host 1.4.7-2 -- `repo/` is the older one). No same-version rebuilds.
- The 27 packages built that day: no ELF has a `DT_NEEDED` whose provider
  differs between host and `repo/`. Every `repo/`-only provider they link
  (libLLVM-20, libclang-cpp, liblld for zig and zig0.15) was a declared
  dependency that stage-deps did stage.
- 63 build logs under `/var/tmp` (toolchain, .NET, Electron): no "not found"
  configure line names anything only a `repo/`-only package provides.

So the host happened to match `repo/` closely enough that nothing differs. It
would not have on a host that lags the repo, which is exactly the case the
restage exists for. Note that with the fix bq stages `repo/`'s older btop over
the host's newer one.

### Temp files stay in the buildroot

A build's scratch files follow two variables that bq now sets, both under the
buildroot:

- `CCACHE_TEMPDIR=<buildroot>/ccache-tmp`. ccache's default is
  `$XDG_RUNTIME_DIR/ccache-tmp`, i.e. `/run/user/<uid>`: a 45 GiB tmpfs that
  also holds the desktop session's sockets. zig 0.16's bootstrap compiles a
  generated 222 MiB `zig2.c`; ccache's preprocessed copy reached 48 GiB there,
  filled the tmpfs, and left `cc1` spinning with no I/O for twenty minutes.
- `TMPDIR=<buildroot>/tmp`. GCC's LTO partitions, `go build` work
  directories, rustc and every `mktemp` in a recipe otherwise land in `/tmp`,
  RAM-backed here, whatever `--buildroot` says.

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
| Qt 6 | every `qt6-*` module at one version -- see `packaging/qt6/qt6-base` |
| Qt for Python | `pyside6` and `shiboken6` at the **same version as Qt**, generated from its headers |
| ROCm | `rocm-llvm`, `comgr`, `rocm-device-libs`, `hsa-rocr`, `hip-runtime`, `rocminfo` -- they version-check each other at runtime |
| VTK third-party | bundled `ioss` expects the bundled `fmt`; see `packaging/vtk` |

Before bumping one member of a set, bump them all in the same queue. Before
concluding an application is broken on this platform, check whether we have
split a set.

## Never in a checkout

Recipes are **copied out** of the packaging tree into
`$BUILDROOT/build/<pkgbase>` and built there; the tree itself is never written
to. Building in place is what leaves `src/`, `pkg/` and stray tarballs
scattered through a checkout — 6.5 GiB of it, in the archpower tree's case —
and makes the next `git pull` awkward.

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

Concurrency is **off by default**. `-j1` schedules exactly as bq always did,
down to leaving `/etc/makepkg.conf`'s own `MAKEFLAGS` alone. (ccache, below, is
a separate switch and is on by default.)

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

## ccache

A large share of what this queue rebuilds is *identical source*. The packager
sweep rebuilt fifteen recipes only to change a metadata string. A soname bump
rebuilds dependents whose own code did not move. `--force` after a rejected
pathguard recompiles everything that already compiled. All of those go from full
cost to nearly nothing with a compiler cache, so bq turns one on. `--no-ccache`
switches it off.

`/etc/makepkg.conf` ships `BUILDENV=(!distcc color !ccache check !sign)` and is
not ours to edit, so bq writes `BUILDENV+=(ccache)` into its own generated
config after the `source /etc/makepkg.conf` line. That works because makepkg's
`in_opt_array()` walks the array backwards and returns on the first match, so
the last occurrence wins — the same mechanism `OPTIONS+=(!debug)` relies on.
makepkg then prepends `/usr/lib/ccache/bin` to `PATH`; that directory is on the
host `/usr`, which the bwrap overlay stacks *below* the sysroot, so it stays
visible, and because it is only a `PATH` entry ccache still resolves the real
compiler through the overlay and will pick a staged gcc over the host one.

Measured on four real packages (`embree hyprutils hyprlang tllist`), three
passes over the same set in the same buildroot on the same 16 CPUs:

| pass | wall | ccache |
|---|---|---|
| `--no-ccache` | 497 s | — |
| cold (empty cache) | 532 s | 4/146 hits, 2.7% |
| warm | **347 s** | 145/146 hits, 99.3% |

So the cold pass costs about 7% and the warm pass saves 30% of the whole run —
and much more than 30% of the part ccache can touch: embree's build went from
235 s to 120 s, and what is left in the warm pass is meson and cmake configure,
`stage-deps`, linking, `strip` and the zstd of the archive.

The same three passes on `mesa`, a package from the packager sweep, at `-j144`
across the whole machine (wall is the whole bq run; build is makepkg alone):

| pass | wall | build | ccache |
|---|---|---|---|
| `--no-ccache` | 372 s | 263 s | — |
| cold (empty cache) | 366 s | 274 s | 246/3268 hits, 7.5% |
| warm | **315 s** | **222 s** | 3266/3268 hits, 99.9% |

A 99.9% hit rate buys mesa only 16% of its build time. At 144 threads its
3,268 compiles were never the bulk of the wall clock. What's left is meson
configure, LTO link, strip and compression, and ccache can't touch any of that.
The cold pass's 7.5% hit rate comes from mesa compiling some of its own sources
more than once, into different drivers.

Two settings are deliberate:

- **`compiler_check=content`**, not ccache's default `mtime`. The default
  identifies a compiler by path, size and mtime, and in this tree the sysroot
  can stack a *different* gcc over the host one at the same path. Hashing the
  compiler binary itself removes the whole class, for the cost of hashing a
  ~1 MiB executable per invocation.
- **`base_dir` left unset**, so absolute paths go into the hash and a build
  under a different `--buildroot` misses rather than hits. That is the safe
  direction; rewriting paths to make it hit is the classic source of "ccache
  handed me the wrong object".

### What it does not cover

- **rustc.** There is no rustc shim and ccache does not speak Rust, so rust
  packages get neither the benefit nor the risk.
- **Recipes that disable it themselves, correctly.** `foot`'s own
  `pgo/pgo.sh` does `export CCACHE_DISABLE=1` on line 82, because
  profile-generate/profile-use and a compiler cache do not mix. A foot build
  under bq reports a 0% hit rate and that is right. This is why the summary
  line reports the measured hit rate rather than announcing that ccache was
  "enabled" — the first measurement taken here showed 0% and the reason was
  real.

### The correctness check

A cache hit that survives a flag change would be worse than no cache: a
POWER8-targeted build would silently reuse POWER9 objects. `tools/ccache-check.sh`
does not take ccache's word for it. Against a throwaway cache, inside the same
bwrap overlay bq builds in, it checks that the shim is what `gcc` resolves to,
that a cold compile misses, that an identical recompile hits and returns the
same object, and then that changing `-mcpu` **misses** and produces a
genuinely different object — verified twice over, by byte comparison and by the
`_ARCH_PWR9`-gated instruction appearing in exactly one of them.
`tools/ccache-check.sh --break` feeds the last two checks two identical
compilations instead, and they must then fail; that is what shows they are live.

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

## Sources

There is **one** local source of build scripts, and it is the only one in the
default `--sources`:

| source | where from |
|---|---|
| `packaging` | `$OMARCHY_PACKAGING/**/<pkgbase>/` — the packaging tree, found recursively (default `~/Development/omarchy-ppc64le-packaging`) |

Arch POWER and Arch are trees we **import from**, not trees anything reads at
build time. `tools/fetch.sh <pkgbase>` (or `--aur`) brings a build script into
the packaging tree, in the right category, where it is reviewed and committed.
The git sources stay registered — the AUR triage tool is this same engine with
a different front end — but are reachable only by naming them explicitly:

| source | where from | |
|---|---|---|
| `gitlab` | `gitlab.archlinux.org/archlinux/packaging/packages/<pkgbase>` | import |
| `aur` | `aur.archlinux.org/<pkgbase>.git` | import, AUR triage |

Naming one in `--sources` builds straight from upstream without the recipe ever
entering the packaging tree, which is exactly the drift this layout removes:
the POWER8 builder once took KF6 6.30 from GitLab while the POWER9 box had
built 6.29 from a tree, and 41 packages failed.

Within a source, selection is by version: the newest recipe wins, `packaging`
takes a tie, and anything older than what our repo database already ships is
refused and logged unless `--allow-downgrade` is passed. The floor is merged
across **every** live repo database in `repo/`, so a package that shipped from
one db is not read as "never shipped" against another. A pkgbase claimed by two
directories in the tree is an error, never resolved by picking one. Every
resolution is logged as `bq: recipe <pkgbase> -> <source> <path> <version>`, so
a fall-through to GitLab is visible in the run log instead of being silent.

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
          [--no-ccache] [--ccache-dir DIR] [--ccache-size SIZE]
bq status [-v]
bq triage [-o out.md]

tools/bq-selftest.py [--break ordering|budget|affinity]   # -j invariants
tools/pkg-treediff.py A B [--self-test PKG]               # same build twice?
tools/ccache-check.sh [--break]                           # no hit across -mcpu
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
