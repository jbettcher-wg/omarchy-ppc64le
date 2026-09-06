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
bq status [-v]
bq triage [-o out.md]
```
