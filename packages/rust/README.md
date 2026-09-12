# `rust`

Arch POWER's recipe (`rust 1:1.97.1-1`, their `packages/rust`), moved to
**1.98.1** (upstream stable, 2026-09-03) and narrowed to little-endian POWER9.
Bootstrapped from the installed `rust 1:1.97.1-1` -- the supported N-1 path,
`rustc = /usr/bin/rustc` in `bootstrap.toml` as in Arch POWER's recipe -- and
the compiler that ships is built `-C target-cpu=pwr9`.

## Deviations from Arch POWER's recipe

- **`arch=(powerpc64le)`**, was `(powerpc64le powerpc espresso)`. The two
  32-bit branches that only existed for `powerpc` are gone with it: the
  `options+=(!debug)` line, `_lto="off"` in `prepare()`, and the
  `RUSTFLAGS="-C opt-level=1"` case in `build()`. Nothing that was reachable
  for `powerpc64le` changed.
- **`hotfix-abi.powerpc64.elfv2.patch` dropped.** It flips the *big-endian*
  `powerpc64-unknown-linux-gnu` target from ELFv1 to ELFv2 (callconv and
  target spec). Arch POWER needs that for their BE tree; `powerpc64le` is
  ELFv2 in upstream rustc already and the patch never touches it. It also no
  longer applies to 1.98.1 (`[MEASURED]`; 0001-0006 apply cleanly). The
  unreferenced `0007-bootstrap-Workaround-for-system-stage0.patch` (a stale
  duplicate of 0003 that Arch POWER carries but never lists in `source=`) is
  gone too.
- **Source is the `.tar.xz`**, not the `.tar.gz`. Upstream signs both with the
  same key; `keys/pgp/` and `validpgpkeys` are unchanged and
  `makepkg --verifysource` passes the signature check `[MEASURED]`
  (bq itself runs `--skippgpcheck`, so that was checked by hand).
  `b2sums` updated; sha256 of the tarball is
  `be1816e7f6c40abb90245ad6e024bed2a7e88d7dda4561e4d5470207df616b9f`, matching
  upstream's `.sha256` file.
- **`description = "Omarchy ppc64le rust ..."`** in `bootstrap.toml`, so
  `rustc -vV` names this build rather than Arch POWER's.
- **`rustflags = ["-Ctarget-cpu=pwr9"]`** in the
  `[target.powerpc64le-unknown-linux-gnu]` section of `bootstrap.toml`, and
  `x.py install -vv` so every rustc command line is in the log. The rest of
  this file is about that.

## The shipped compiler is POWER9 code

### Why the recipe carries the flag itself

`/etc/makepkg.conf.d/rust.conf` on the build box says
`RUSTFLAGS="-C target-cpu=pwr9 -C force-frame-pointers=yes"`, so it is
tempting to assume every Rust build here is already POWER9 code. Two things
say otherwise, both `[MEASURED]`:

1. **Arch POWER's own `rust 1:1.97.1-1` is plain POWER8 code.** Disassembling
   the installed `/usr/lib/librustc_driver-f851201be9316ba7.so` (87 MB) under
   objdump's POWER8 and POWER9 dialects gives the same 6,281 undecodable
   words either way -- zero ISA 3.0 instructions -- and the same for its
   `libstd-*.so` (18 and 18). The positive control is fine: a small program
   built by that same rustc with `-C target-cpu=pwr9` shows `lxv`, `stxv`,
   `lxvx`, `mtvsrws`, `vextuwrx` (31 instructions the POWER8 dialect cannot
   decode) and the generic build shows none. So the flag reaches nothing on
   Arch POWER's builder; `rust.conf` on this box is a local edit
   (`pacman -Qkk` reports it modified from the packaged default).
2. **Under bq the flag reaches nothing here either.** makepkg loads
   `$MAKEPKG_CONF.d/*.conf` -- the `.d` next to the config it was *given*
   (`/usr/share/makepkg/util/config.sh:40`). bq runs
   `makepkg --config /var/tmp/rust-bq/makepkg.conf`, which `source`s
   `/etc/makepkg.conf` but has no `makepkg.conf.d`, so `rust.conf` is never
   read:

   ```
   load_makepkg_config /etc/makepkg.conf             -> RUSTFLAGS=[-C target-cpu=pwr9 -C force-frame-pointers=yes]
   load_makepkg_config /var/tmp/rust-bq/makepkg.conf -> RUSTFLAGS=[]
   ```

   (Same test shows `CFLAGS` intact both ways -- that one lives in the main
   file.) The build log agrees: the stage-0-compiled `rustc` lines of the
   first build carried `-Cforce-frame-pointers=true` from `bootstrap.toml` and
   nothing from `rust.conf`.

So the recipe sets the flag itself and does not depend on which
`makepkg.conf` it is built under.

### How the flag is applied, and why per target rather than per stage

bootstrap (`src/bootstrap/src/core/builder/cargo.rs`) assembles
`CARGO_ENCODED_RUSTFLAGS` for each cargo run from: its own flags, the
`[target.<triple>] rustflags` of the target being compiled
(`extra_rustflags`, cargo.rs:454), then the environment's `RUSTFLAGS` and
`RUSTFLAGS_BOOTSTRAP` (build compiler is stage 0, plus `--cfg=bootstrap`) or
`RUSTFLAGS_NOT_BOOTSTRAP` (stage >= 1) (`propagate_rustflag_envs`,
cargo.rs:460). Nothing overrides anything; they concatenate.

`x.py install` is stage 2 (`config.rs`: `Subcommand::Install => ...
unwrap_or(2)`), `full-bootstrap` is off, and out-dirs are named by the
*product's* stage (`lib.rs`, `stage_out`: `stageN-rustc` is built *by* stage
N-1, `stageN-std` *by* stage N). So:

| out-dir | built by | ships? |
|---|---|---|
| `stage1-rustc` | stage 0 = system 1.97.1 | no (throwaway stage-1 compiler) |
| `stage1-std` | stage 1 | yes, uplifted as the stage-2 std |
| `stage2-rustc` | stage 1 | yes, this is `/usr/bin/rustc` |
| `stage2-tools` | stage 1 | yes (cargo, clippy, rustfmt, ...) |

The obvious way to hit exactly the three shipped rows is
`RUSTFLAGS_NOT_BOOTSTRAP`, and the first 1.98.1 build here used it. It did
reach the right stages `[MEASURED]`: `stage1-rustc` 0 of 315 rustc lines with
`pwr9`, `stage1-std` 139 of 149, `stage2-rustc` 234 of 315, `stage2-tools`
554 of 717 (the remainder are build scripts, proc-macros and their host-only
dependencies, which cargo never gives `RUSTFLAGS` to and which never ship).
But it is not target-scoped, and this recipe also builds std for five
`wasm32` targets. 112 of those lines carried `-C target-cpu=pwr9` too, and
the log had 24,662 copies of

```
'pwr9' is not a recognized processor for this target (ignoring processor)
```

"Ignoring" is not harmless. With an unrecognised CPU, LLVM applies no
CPU-implied features, and rustc's view of the target follows: the shipped
compiler with `--target wasm32-unknown-unknown --print cfg` lists six
`target_feature`s (`bulk-memory`, `multivalue`, `mutable-globals`,
`nontrapping-fptoint`, `reference-types`, `sign-ext`); with
`-C target-cpu=pwr9` added it lists **none**, and the same crate compiles to
different object code (204 vs 358 bytes, `[MEASURED]`). The shipped std
shows it directly: the `target_features` custom section of the first build's
`wasm32-unknown-unknown` `libstd` object says only `-shared-mem`; the
shipped build's says `+bulk-memory +bulk-memory-opt +call-indirect-overlong
+multivalue +mutable-globals +nontrapping-fptoint +reference-types +sign-ext
-shared-mem` (`llvm-objdump -s -j target_features`, `[MEASURED]`). So the
first build's `rust-wasm` std was MVP-only code, quietly unlike upstream's.
That build is kept in `/var/tmp/rust1981/build1/` on the AC922, for the
record; it was never published.

`[target.<triple>] rustflags` is the target-scoped knob bootstrap offers. It
is not stage-scoped -- the throwaway stage-1 compiler gets it as well -- but
that compiler only ever runs on this box, so the cost is nil, and the wasm32
targets see nothing. That is what ships.

### Evidence from the shipped build, `[MEASURED]`

`rustc` command lines in the makepkg log (`x.py -vv` hands cargo `-v`), by
out-dir, with and without `-C target-cpu=pwr9`; the "without" lines are
build scripts, proc-macros and their host-side dependencies:

| out-dir (`--target powerpc64le-*`) | with `pwr9` | without | of which build-script / proc-macro / their host deps |
|---|---:|---:|---|
| `stage1-rustc` (stage 0 -> 1, throwaway) | 234 | 81 | 30 / 17 / 34 |
| `stage1-std` | 27 | 10 | 8 / 0 / 2 |
| `stage2-rustc` | 234 | 81 | 30 / 17 / 34 |
| `stage2-tools` | 554 | 163 | 76 / 28 / 59 |
| any `--target wasm32-*` | 0 | 112 | -- |

`'pwr9' is not a recognized processor` in the log: 0 (24,662 in the first
build). Both `rustc_driver` lines carry the flag; the shipped one, trimmed of
`-L`/`--extern`/metadata and with the source dir as `$src`:

```
Running `$src/build/bootstrap/debug/rustc $src/build/bootstrap/debug/rustc --crate-name rustc_driver
  --edition=2024 compiler/rustc_driver/src/lib.rs --crate-type dylib --emit=dep-info,link -C prefer-dynamic
  -C opt-level=3 -C embed-bitcode=no -C codegen-units=1
  --out-dir $src/build/powerpc64le-unknown-linux-gnu/stage2-rustc/powerpc64le-unknown-linux-gnu/release/build/rustc_driver/64bd4f2c1843170d/out
  --target powerpc64le-unknown-linux-gnu -C linker=powerpc64le-unknown-linux-gnu-gcc --cfg=windows_raw_dylib
  -Zannotate-moves -Zunstable-options -Zmacro-backtrace -Csplit-debuginfo=off -Cforce-frame-pointers=true
  -Cllvm-args=-import-instr-limit=10 -Clink-arg=-Wl,--compress-debug-sections=zlib -Alinker-messages
  -Zon-broken-pipe=kill -Zdylib-lto -Clto=fat -Cembed-bitcode=yes -Ctarget-cpu=pwr9 -Z binary-dep-depinfo`
```

And the packaged artefacts, same disassembly probe as above
(`powerpc64le-handbook/probes/isa30scan.sh`, `objdump -M power8` against
`-M power9`):

| object | undecodable as POWER8 | top ISA 3.0 mnemonics |
|---|---:|---|
| Arch POWER 1.97.1 `librustc_driver` | 0 | -- |
| this package `librustc_driver-64bd4f2c1843170d.so` | 495,742 | `lxv` x167,571, `lxvx` x51,469, `cnttzd` x15,928, `maddld` x4,885, `mfvsrld` x276, `modud` x89 |
| Arch POWER 1.97.1 `libstd` | 0 | -- |
| this package `libstd-a7ae983885b4c39b.so` | 3,837 | `lxv` x1,268, `lxvx` x404, `maddld` x88, `cnttzw` x10 |
| this package `/usr/bin/cargo` | 213,204 | `lxv` x74,473, `lxvx` x24,212, `cnttzd` x3,880, `maddld` x231 |

The ppc64le counts are identical to the first build's, as they should be:
the flag on that target did not change, only its leak into wasm32 did. The
wasm32 side is above: six `target_feature`s from the shipped compiler, the
std objects carrying the upstream feature set, and a 358-byte object for
the control crate where the flag-leaked compiler produced 204.

### What it costs

`-C target-cpu=pwr9` on `libstd` means every program linked against this
package's std needs POWER9. That is already true of everything else in this
repo (`CFLAGS=-mcpu=power9` in `/etc/makepkg.conf`), and the Omarchy ppc64le
target is the AC922. There is no POWER8 story here.

No compile-time benchmark was taken; the 10-20 % figure that motivated this is
the user's, not measured here.

## Verification `[MEASURED]`

The package was extracted to a scratch directory and run from there with
`PATH`/`LD_LIBRARY_PATH`, nothing installed:

- `rustc -vV`: `rustc 1.98.1 (48a229cea 2026-09-01) (Omarchy ppc64le rust
  1:1.98.1-1)`, host `powerpc64le-unknown-linux-gnu`, LLVM 22.1.8 (the
  system `llvm-libs`, `link-shared = true` as in Arch POWER's recipe).
  `cargo 1.98.1 (797e8a9bc 2026-08-05) (Omarchy ppc64le rust 1:1.98.1-1)`.
- A control program (stdin parse, iterator sum/max, `u128` multiply, a
  1 KiB `Copy` struct) built `-O` and `-O -C target-cpu=pwr9`, both run and
  print the expected values.
- `cargo build --release` of a fresh `cargo init` crate with the extracted
  cargo/rustc: builds and runs.
- `rust-wasm`: `rustc --target wasm32-unknown-unknown --crate-type cdylib
  -C linker=wasm-ld` gives a 372-byte MVP module; `--target wasm32-wasip1`
  a 249,117-byte `println!` binary. Both inside bq's overlay, because the
  host has no `lld` (see Open).

## Build

Two bq runs on the AC922, 176 threads, `x.py install -j 176`:

| build | flag mechanism | wall | peak tree | log |
|---|---|---:|---:|---:|
| 1 (discarded) | `RUSTFLAGS_NOT_BOOTSTRAP` | 3,729 s | 16.4 GiB | 16.2 MB |
| 2 (shipped) | `[target.*] rustflags` | 3,771 s | 17.0 GiB | 12.1 MB |

Roughly a third of that is the single-threaded fat-LTO codegen of
`rustc_driver` (`codegen-units = 1`, as in Arch POWER's recipe): the box sits
at load 1-3 for twenty-odd minutes in the middle of each run.

```
BQ_STATE=/var/tmp/rust-bq.json python3 tools/bq.py --buildroot /var/tmp/rust-bq build \
  --fix-arch --sources local,archpower,gitlab --repo-db "" --rebuild --retry-failed --force \
  --timeout 43200 rust
```

(`--timeout` raised from bq's 4 h default; not needed in the event, but a
first build has no number to go on.)

## Open

- **`rust-wasm` cannot link without `-C linker=wasm-ld`** -- on Arch POWER
  too, this recipe did not change it. rustc's wasm32 targets default to
  `rust-lld` (`compiler/rustc_target/src/spec/base/wasm.rs:75`); Arch POWER
  builds with `lld = false`, so no `rust-lld` ships in `rust`, and their `lld`
  package has no `rust-lld` either (the staged one has `ld.lld ld64.lld lld
  lld-link wasm-ld`). The recipe's per-target `default-linker = "wasm-ld"`
  lines only matter when a compiler is built *for* that target, which it
  never is. Result: `error: linker 'rust-lld' not found` `[MEASURED]`, and
  `-C linker=wasm-ld` links fine. Fix belongs in `lld` (a `rust-lld`
  symlink, as some distros do) or in this recipe (`lld = true` ships
  `rust-lld` in the sysroot); not done here.
- bq's generated `makepkg.conf` never loads `/etc/makepkg.conf.d/*.conf`
  (`[MEASURED]` above), so a Rust package built through bq today gets none of
  `rust.conf`'s `RUSTFLAGS` unless its recipe sets them. Not every Rust
  package in `repo/` is affected, though: `bat-0.26.1-2`'s binary has 696
  POWER9-only instructions (`lxv`, `lxvx`, `maddld`, `extswsli`) and its
  PKGBUILD sets no `RUSTFLAGS`, so whatever built it did see `rust.conf`.
  Which of the repo's Rust packages were built which way is worth a scan;
  the fix (have `write_makepkg_conf` source the `.d` files, or pass the
  system config and override through the environment) belongs in
  `tools/bq.py`, not here.
