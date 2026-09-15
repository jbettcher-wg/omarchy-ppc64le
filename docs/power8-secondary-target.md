# POWER8 as a secondary target

Scoping document. **The shape is decided:** POWER9 stays as it is — `-mcpu=power9
-mtune=power9`, ISA 3.0, no lowering. POWER8 (ISA 2.07) becomes a *second
builder over the same recipe set*, differing only in flags and in a small number
of per-recipe toggles. Two builders, one recipe tree.

Motivation: hobbyists picking up cheap POWER8 boxes, and one concrete
co-developer (`daedalao`, IBM 8335-GCA, POWER8, 2x Radeon Pro V620 / gfx1030)
who already has a POWER8 ROCm drop but no POWER8 Omarchy repo behind it. What
they need is *a package repo and an ISO that work on their machine*.

Nothing here has been built at scale. This is the report and the decided build
method, not a repo.

---

## 1. The headline finding: the distro floor is already POWER8

The single fact that makes this cheap.

Arch POWER's own packages are built to a POWER8 baseline. 26 upstream packages
from the local pacman cache (signature-bearing, i.e. downloaded from
`repo.archlinuxpower.org`, not built here) were scanned for ISA 3.0 encodings:

| result | packages |
|---|---|
| zero ISA 3.0 | `boost-libs` (46 ELFs), `grub` (23), `hdf5` (27), `opencascade` (71 ELFs, 3 words), `openvdb`, `opensubdiv`, `lapack`, `tcl`, `tk`, `doxygen`, `espeak-ng`, `nmap`, `ruff`, `rust-analyzer`, **`rust 1.97.1`**, `python-wxpython`, `python-matplotlib`, `python-fonttools`, `glm` (any) |
| small residue (1–3 words) | `cmake` 1, `materialx` 1, `opencascade` 3 — the counts and the shape match the jump-table artifact documented in `~/co-dev-v620/README.md` (opcode-63 quad-precision mnemonics over `0xffXXXXXX` negative displacements). Not individually re-decomposed in this pass. |
| genuinely non-zero | `python-numpy` 35,317; `nodejs` 459; `smbclient` 310; `go` 220; `vtk` 3,290 |

The non-zero upstream cases are the runtime-dispatch class (numpy's
`cpu_dispatch` VSX3 kernels, V8 in nodejs) or upstream-specific — see §5. They
are Arch POWER's problem to answer, not ours, and they do not change the
conclusion:

**A POWER8 repo does not require rebuilding the world. It requires rebuilding
what *we* build.** Everything under `[base]` / `[base-any]` already runs on a
POWER8.

Cross-check on the same axis: `go env GOPPC64` on this machine reports
`power8`. Go's default ISA level is POWER8, so every Go recipe we carry
(`aether bat dua-cli eza fd fzf gopls lazydocker lazygit mise prettier shfmt
stylua taplo-cli ttfx tzupdate usage yay zoxide` — the Go half of that list)
is already POWER8 and needs nothing. That is also the "what everyone else does"
data point: the ecosystem default is POWER8, and POWER9 is the local deviation.

---

## 2. What we build is POWER9, comprehensively

Sampled scan of the shipped packages in `repo/`. **This is a sample, not a
census** — 52 packages completed from a size-ordered sweep that was cut short
deliberately, plus 10 targeted at recipes with local patches or hardcoded ISA
choices. It is enough to characterise the failure rate and name the offenders;
it is not a full pass over all 153 recipes, and nobody should later read it as
one.

Every package built here from a recipe with compiled code carried ISA 3.0:

| package | ISA 3.0 instructions | package | ISA 3.0 instructions |
|---|---:|---|---:|
| `vtk` 9.5.0-6 | 1,956,107 | `chromium` | 2,027,127 |
| `kicad` | 1,101,519 | `rust` 1.98.1 | 879,233 |
| `freecad` | 595,570 | `blender` | 520,546 |
| `clang` | 350,949 | `mariadb` | 315,249 |
| `embree` | 182,529 | `qt6-declarative` | 175,304 |
| `qt6-base` | 157,015 | `mesa` | 156,807 |
| `llvm` | 140,179 | `opencl-mesa` | 127,934 |
| `hyprland` | 103,422 | `vulkan-intel` | 100,398 |
| `ffmpeg` | 98,173 | `inkscape` | 72,869 |
| `kdenlive` | 71,986 | `systemd` | 59,139 |
| `binutils` | 38,530 | `rocblas` | 36,017 |
| `obs-studio` | 34,416 | `openssl` | 23,572 |
| `ispc` | 22,218 | `leancrypto` | 20,383 |
| `qemu-user-static` | 19,862 | `neovim` | 19,088 |
| `openvkl` | 9,303 | `python` | 9,667 |
| `mise` | 9,708 | `qt6-webengine` | 7,015 |
| `ospray` | 14,817 | `openimagedenoise` | 4,591 |
| `plocate` | 832 | `foot` | 548 |
| `dotnet-runtime` | 384 | `docker-compose` | 51 |
| `lazygit` | 40 | `hsa-rocr` | 5,166 |

Zero-hit entries in the repo sample (`samba` 211 ELFs, `util-linux` 130 ELFs,
`boost`, `libreoffice-fresh` 245 ELFs / 95 words, `dotnet-sdk`) were checked
against `.BUILDINFO` and are **upstream Arch POWER builds mirrored into
`repo/`**, packager Alexander Baldeck — not ours. That is consistent with §1,
not a counter-example.

Three of our own packages did come out clean, and each for a reason worth
keeping:

* **`luajit` — 0.** The recipe deliberately floors the VM at `-mcpu=power8`
  (see §4). Proof that a recipe-level floor holds against the host's
  `-mcpu=power9`.
* **`eza` — 0** and **`blink-cmp-fuzzy` — 0.** Rust packages built before
  `packages/rust` 1.98.1 landed, so they link Arch POWER's POWER8 `libstd`.
  Their exposure is new, not absent — see §4, `rust`.

### The scan method, and the control that proves it can fail

Method is not new: `~/co-dev-v620/build-overrides/isa30-pkgscan.sh`, the
package-level wrapper around
`~/Development/powerpc64le-handbook/probes/isa30scan.sh`, used unchanged.
Disassemble every ppc64le ELF in a package with objdump's POWER8 dialect and
with its POWER9 dialect; anything only POWER9 decodes comes out as `.long`
under `-M power8` and is an ISA 3.0 encoding.

A scan with no control is worthless. Three controls were run, and they fail in
both directions:

1. **Positive, synthetic.** An object assembled `as -mpower9` containing 23
   ISA 3.0 instructions (`mcrxrx xxbrd darn cnttzd cnttzw modud modsd moduw
   setb extswsli mtvsrdd mfvsrld lxv stxv lxvx stxvx lxvb16x lxvwsx xxspltib
   maddld vcmpnezb vextublx xsmaxcdp`) → **all 23 flagged**, none missed.
   This also clears the blind spot recorded in
   `powerpc64le-handbook/tests/isa30-blindspots.txt`: `as -mpower8` silently
   re-encodes `lxvx`/`stxvx` as `lxvd2x`/`stxvd2x`, so the *assembler* oracle
   is blind to them — objdump's POWER8 **decoder** is not, and flags both.
2. **Negative, synthetic.** An object of 13 genuine ISA 2.07 instructions,
   including the near-miss forms `lxvd2x stxvd2x mtvsrd mfvsrd xsmaxdp
   xxlorc lqarx vaddudm` → **0 flagged**. The scan does not simply flag
   everything vector-shaped.
3. **Differential, real packages.** Same recipe, same version, same machine,
   differing only in `-mcpu`:

   | package | POWER8 build (`~/co-dev-v620`) | POWER9 build (`repo/`) |
   |---|---:|---:|
   | `hsa-rocr` 7.2.4-1 | **0** | 5,166 |
   | `rocminfo` 7.2.4-1 | **0** | 51 |

Control 3 is the one that matters: it shows the scan reporting zero on a
package that is genuinely clean and thousands on the same package built one
flag differently.

---

## 3. The decided build method

Nothing in `tools/bq.py` needs to change. Commit `58a36bd` already added the two
variables a second target needs, and `~/co-dev-v620/build-overrides/build-v620.sh`
is a *working, already-shipped* instance of exactly this pattern — the whole
ROCm stack was built POWER8 through it without editing a single recipe.

What isolates a second target, all already present:

| axis | knob | default |
|---|---|---|
| package pool | `BQ_REPO` | `repo/` — read by `bq.py`, `sysroot-add.sh`, `stage-deps.sh` |
| run state | `BQ_STATE` | `.bq-state.json` |
| build tree | `BQ_BUILDROOT` | `/tmp/omarchy-bq` |
| staging sysroot | `--sysroot`, defaults to `<buildroot>/sysroot` | follows `BQ_BUILDROOT` automatically |
| output dir | `--pkgdest` | follows `BQ_REPO` |
| **compiler flags** | `<buildroot>/makepkg.conf.d/*.conf` | — see below |

The flags knob needs no code either. `bq.py` generates
`<buildroot>/makepkg.conf`, and makepkg sources `<config>.d/*.conf` **after**
the config it was given — so a drop-in placed in `<buildroot>/makepkg.conf.d/`
overrides `/etc/makepkg.conf` and `/etc/makepkg.conf.d/*.conf` for that build
only, touching nothing global.

**Verified this pass**, not assumed. With the drop-in below in place,
`makepkg --config <buildroot>/makepkg.conf` resolved to:

```
CFLAGS    = -O2 -pipe -mcpu=power8 -mtune=power8 -fexceptions -Wp,-D_FORTIFY_SOURCE=2 ...
RUSTFLAGS = -C target-cpu=pwr8 -C force-frame-pointers=yes
FFLAGS    = -O2 -pipe -mcpu=power8 ... -mtune=power8
```

### The drop-in

`<buildroot>/makepkg.conf.d/00-power8.conf` — substitution, not restatement, so
the host's hardening flags survive, and an assert so a config rewrite fails the
build instead of quietly shipping POWER9 code:

```bash
#!/hint/bash
# shellcheck disable=2034
# 00-power8.conf -- POWER8 (ISA 2.07) codegen for the secondary target.
CFLAGS="${CFLAGS//power9/power8}"
CXXFLAGS="${CXXFLAGS//power9/power8}"
# /etc/makepkg.conf.d/fortran.conf already says -mcpu=power8 but sets no -mtune.
FFLAGS="${FFLAGS//power9/power8} -mtune=power8"
FCFLAGS="$FFLAGS"
RUSTFLAGS="${RUSTFLAGS//pwr9/pwr8}"

for _p8 in CFLAGS CXXFLAGS FFLAGS FCFLAGS; do
	case "${!_p8}" in *-mcpu=power8*) ;;
		*) printf 'power8 drop-in: %s has no -mcpu=power8: %s\n' "$_p8" "${!_p8}" >&2; exit 1 ;;
	esac
	case "${!_p8}" in *power9*|*pwr9*)
		printf 'power8 drop-in: %s still names power9: %s\n' "$_p8" "${!_p8}" >&2; exit 1 ;;
	esac
done
unset _p8
case "$RUSTFLAGS" in *pwr9*)
	printf 'power8 drop-in: RUSTFLAGS still names pwr9: %s\n' "$RUSTFLAGS" >&2; exit 1 ;;
esac
```

This file belongs in the **buildroot**, not in `/etc`. `/etc/makepkg.conf.d/`
stays POWER9 because the POWER9 builder is the default and the machine is a
POWER9. Nothing about the secondary target requires a `sudo` or a write under
`/etc`.

### Invocation

Modelled directly on `build-v620.sh`; a `tools/build-power8.sh` would be that
script with the ROCm-specific queue removed.

```sh
export BQ_BUILDROOT=/var/tmp/omarchy-bq-power8
export BQ_STATE=$BQ_BUILDROOT/state.json
export BQ_REPO=$HOME/Development/omarchy-ppc64le/repo-power8
export TMPDIR=$BQ_BUILDROOT/tmp
mkdir -p "$BQ_REPO" "$TMPDIR" "$BQ_BUILDROOT/makepkg.conf.d" "$BQ_BUILDROOT/srcdest"
cp tools/makepkg.conf.d/00-power8.conf "$BQ_BUILDROOT/makepkg.conf.d/"   # refuse to build without it

python3 tools/bq.py --buildroot "$BQ_BUILDROOT" build \
    -q "$BQ_BUILDROOT/queue.json" --pkgdest "$BQ_REPO" --repo-db "" \
    --timeout 21600
```

Two things a second *published* repo needs that are not parameterised today.
Neither blocks building; both are one-line edits when it comes to publishing:

* `tools/repo-publish.sh` hardcodes `DB=$REPO/omarchy-power9.db.tar.gz`. It
  already honours `REPO=`; the DB basename needs to follow the repo name.
* The repo name `omarchy-power9` is baked into `iso/build.sh` (5 sites),
  `iso/profile/pacman.conf`, `tools/repo-gaps.py` and `tools/soname-gaps.py`.
  `installer/p9-install` already takes `--repo-name`, so the installer side is
  fine.

---

## 4. Which recipes need a toggle

Most of the 153 are plain rebuilds: `-mcpu=power8` in the builder's config is
the whole story. The minority below hardcode an ISA decision *inside the recipe
or a patch*, where a flags-only change is not enough. This is the real
maintenance surface.

### The template already exists

`packages/chromium/` is the pattern to generalise. `power9-toggle.patch` adds a
single `_power8_compat` switch to Arch POWER's chromium PKGBUILD, default `0`
(POWER9); `_power8_compat=1 makepkg -e` produces the POWER8-legal artifact. Its
`README.md` states the policy, and it is the right one for the whole second
target:

> Source stays POWER8-compliant either way. No POWER9-only instruction is
> written into any source file. The difference is compiler flags and which
> build-system feature gates get set — the LuaJIT model of a POWER8 ISA floor
> with ISA 3.0 selected at build or runtime.

That README also documents a **live instance of the failure this whole exercise
guards against**: the `-mcpu` strip was dropped in chromium's 150→151 rebase, GN's
unbundle toolchain appends `$CFLAGS` last, so the host's `-mcpu=power9` wins and
the "POWER8-legal" recipe silently emits ISA 3.0. Confirmed here — the shipped
`chromium 151.0.7922.108-1` scans at **2,027,127 ISA 3.0 instructions**. A
recipe that claims POWER8-legality is not evidence; the scan is.

### The list

| recipe | what is hardcoded | needed for POWER8 |
|---|---|---|
| **`rust`** | `bootstrap.toml` sets `rustflags = ["-Ctarget-cpu=pwr9"]` per target, *deliberately not* from makepkg's `RUSTFLAGS`. | **A toggle, and it is the highest-impact one.** Measured this pass: the shipped `libstd-*.rlib` in `repo/rust-1:1.98.1-1` contains **3,171 ISA 3.0 instructions**. `libstd` is statically linked into every Rust binary, so consumer `RUSTFLAGS` cannot undo it. Demonstrated below. |
| **`chromium`** | `_power8_compat` (default 0); `skia-vsx-instructions.patch` injects `-mcpu=power9` into all of skia. | Already has the toggle — the POWER8 builder passes `_power8_compat=1`. |
| **`llama.cpp-hip`** | `-DGGML_CPU_POWERPC_CPUTYPE=power9`, plus `-DGPU_TARGETS=gfx1100`. | A `_cpu`-style switch, same shape as `rocblas`'s existing `ROCBLAS_GPU_TARGETS` env override. |
| **`linux-power9`** | `CONFIG_POWER9_CPU=y`, `CONFIG_TARGET_CPU="power9"` in both `config.4k` and `config.64k`. | See §6. |
| **`ispc`** | Builds the LLVM PowerPC backend (`PPC64_ENABLED=ON`) and emits VSX object code ahead of time. Its output does not respond to `CFLAGS`. Scans at 22,218 ISA 3.0 instructions itself, and its consumers — `openimagedenoise` 4,591, `openvkl` 9,303, `ospray` 14,817 — carry ISA-3.0-heavy ispc-generated kernels (`lxvb16x`, `vclzlsbb`, `xsmincdp`, `xxspltib`). | Needs its own investigation: the ispc target CPU level, not a compiler flag. Do not assume the drop-in covers these three. |
| `luajit` | Rewrites `-mcpu=power9`→`power8` for the VM on purpose. | **Nothing.** Already correct on both targets; see §5. |
| `embree` | `EMBREE_IGNORE_CMAKE_CXX_FLAGS=OFF` — deliberately lets makepkg's `CXXFLAGS` through, and the native VSX layer is written with no `_ARCH_PWR9` conditionals. | **Nothing** beyond the drop-in. Scanning at 182,529 today is purely inherited `-mcpu=power9`. |
| `blender` | `cycles-vsx.patch` mentions `-mcpu=power9` only in comments about measured codegen; `_cycles_vsx=native` is a kernel selection, not an ISA pin. | **Nothing** beyond the drop-in (unverified by a POWER8 build). |

So: **three recipes need a toggle written (`rust`, `llama.cpp-hip`,
`linux-power9`), one already has one (`chromium`), and one family needs
investigation rather than a toggle (`ispc` and its three consumers).**

### The `rust` finding, demonstrated

Two packages were built POWER8 in isolation to test the method
(`BQ_REPO`/`BQ_STATE`/`BQ_BUILDROOT` under `/var/tmp/power8-scope`, drop-in
above in force, nothing touching `repo/`):

| package | POWER8 side build | POWER9 copy in `repo/` |
|---|---:|---:|
| `libde265` 1.1.2-1 (C++, SIMD-heavy) | **0** | 1,799 |
| `fd` 10.5.0-3 (Rust) | **2,676** | 0 |

`libde265` is the expected result and confirms the whole mechanism end to end.
`fd` is inverted, and that is the finding: built with `-C target-cpu=pwr8`
correctly applied, it still came out with 2,676 ISA 3.0 instructions, whose
mnemonic profile (`lxv` x952, `stxv` x1006, `lxvx` x259, `stxvx` x257, `setb`
x6, `modud` x1, `moduw` x1, `cnttzw` x10) is a subset of the shipped
`libstd`'s. The repo's `fd` is clean only because it predates `packages/rust`
1.98.1 and linked Arch POWER's POWER8 `libstd`.

**A POWER8 Rust toolchain has to be built first; it is a prerequisite for all
18 Rust recipes, not a per-package fix.**

---

## 5. What the scan cannot see: runtime code generation

**A static scan of shipped objects cannot see code a JIT emits at runtime.** A
package containing a JIT or a runtime code generator can pass an objdump scan
perfectly and still execute ISA 3.0 on a POWER8 box, because the instructions
do not exist until the process is running.

**The general rule, which will outlive this pass:** a POWER8 build is only as
sound as the weakest of

1. compile flags,
2. hardcoded flags in recipes and patches,
3. runtime code generation.

Sections 2–4 cover (1) and (2). Only (3) is listed here, and only by *class and
dispatch mechanism* — internals were not audited.

| package | runtime codegen / dispatch | gated on? |
|---|---|---|
| **`luajit`** | Full ppc64 JIT. | **Capability check — verified.** `src/lib_jit.c:712-720` reads `getauxval(AT_HWCAP2)` and tests `PPC_FEATURE2_ARCH_3_00` (`0x00800000`), setting `JIT_F_ISA30`; `LUAJIT_PPC_ISA30=0` forces it off. Exactly **one** ISA 3.0 opcode exists in the whole backend — `PPCI_MCRXRX` (`lj_target_ppc.h:372`), emitted at exactly one site (`lj_asm_ppc.h:2618`) behind that flag, with the ISA 2.07 path as the floor. The VM itself is floored at `-mcpu=power8` by the PKGBUILD because `LJ_ARCH_VERSION` derives from `_ARCH_PWR*`, and the shipped package scans **0**. The forced-off path runs correctly on this box. **No toggle needed; this is the model.** |
| `neovim`, `luarocks`, `libluv`, `lua-language-server`, `omarchy-nvim` | Link LuaJIT; inherit its gate. | Safe via LuaJIT. (`neovim`'s own 19,088 ISA 3.0 words are compiled C, covered by the drop-in.) |
| `chromium`, `qt6-webengine` | V8 JIT; BoringSSL's ppc64 assembly. | BoringSSL is `.machine "any"` with a runtime `getauxval(AT_HWCAP2)` / `PPC_FEATURE2_HAS_VCRYPTO` gate — the LuaJIT pattern, safe, per `packages/chromium/README.md`. **V8's ppc64 `CpuFeatures` was not audited.** Must be confirmed to be `AT_HWCAP2`-driven, not build-time, before a POWER8 repo ships chromium. |
| `python` + numpy (upstream) | numpy `cpu_dispatch` runtime kernel selection. | Upstream numpy's dispatch is a runtime CPU check; its 35,317 ISA 3.0 words are in dispatched VSX3 kernels. Behaviour on POWER8 is Arch POWER's answer, and it is already shipping this to POWER8 users. Not re-verified here. |
| `mesa`, `opencl-mesa`, `vulkan-*` | LLVM JIT for llvmpipe / gallivm. | LLVM selects the host CPU at runtime (`sys::getHostCPUName` via auxv/`AT_PLATFORM`), so it self-limits on a POWER8. Not verified here. |
| `dotnet-runtime` | RyuJIT. | Not audited. ppc64le is not a first-class .NET target; treat as unknown. |
| `qemu-user`, `qemu-user-static` | TCG — generates host code at runtime. | TCG's ppc64 backend has `have_isa_3_00` style runtime feature detection. Not verified here. |
| `ispc` | AOT, not runtime — but see §4; its output ignores `CFLAGS`. | Build-time assumption, **not** gated. Needs a target-level answer. |

Go binaries are not in this class: Go emits at build time and `GOPPC64` defaults
to `power8`.

### Forward note: JSC / WebKit

Not in this repo yet, but the same class and worth writing down now. The
ppc64le JavaScriptCore port under construction is a JIT that emits code at
runtime. The recent f32 work confirmed its VSX instruction selection stays
within ISA 2.07, checked with `as -mpower8` — the right answer — but **nothing
currently enforces it**, so it can regress silently the moment someone reaches
for `lxvx` or `xxbrd`. Before a POWER8 repo ships anything containing JSC it
wants one of: a LuaJIT-style `AT_HWCAP2` / `PPC_FEATURE2_ARCH_3_00` gate around
any ISA 3.0 emission, or an assembler-level floor check in CI that fails the
build when an emitted encoding is rejected by `as -mpower8`. The handbook's
`tests/lib/isa-scan.sh` already implements the latter as a reusable oracle, with
its blind-spot list.

---

## 6. The ISO

`iso/build.sh` builds an archiso profile (`iso/profile/packages.ppc64le`, 136
packages) with the kth5/archiso fork for `openpower.grub`, and injects `repo/`
onto the medium at `p9repo/omarchy-power9/`, which `p9-install` reads with
`P9_REPO_SERVER=file:///run/archiso/bootmnt/p9repo/omarchy-power9`.

A POWER8 ISO needs three things beyond a POWER8 package repo:

1. **A POWER8 kernel. This is the blocker.** `packages/ours/linux-power9` sets, in
   *both* `config.4k` and `config.64k`:

   ```
   CONFIG_POWER9_CPU=y
   CONFIG_TARGET_CPU_BOOL=y
   CONFIG_TARGET_CPU="power9"
   ```

   That compiles the kernel `-mcpu=power9`. A POWER8 will not boot it — it will
   take an illegal instruction long before there is a console to say so. The
   fix is `CONFIG_POWER8_CPU=y` / `CONFIG_TARGET_CPU="power8"` (or
   `CONFIG_GENERIC_CPU=y`) in a POWER8 config variant.

   Everything else in the config is fine for POWER8. `CONFIG_PPC_64S_HASH_MMU=y`
   is set alongside `CONFIG_PPC_RADIX_MMU=y`, and POWER8 (no radix) falls back
   to hash cleanly; `CONFIG_PPC_POWERNV=y` covers the 8335-GCA, which is an
   OpenPOWER machine booting through petitboot/OPAL exactly as the AC922 does.
   No other POWER9-only option is set.

   Mechanically this is the existing 4k/64k split again: the recipe already
   produces two pkgbases (`linux-power9`, `linux-power9-64k`) from one PKGBUILD
   driven by which config is selected, so a POWER8 config is a third selection
   rather than a new recipe. The package *name* is the awkward part — a
   `linux-power8` pkgbase, or a rename of the family. **Any POWER8 config must
   be derived from the existing hand-set `config.4k`/`config.64k`, not
   regenerated**, or the hand-set options and the seven carried patches are
   lost.

2. **Repo name plumbing.** The five `omarchy-power9` sites in `iso/build.sh`
   plus `iso/profile/pacman.conf` (§3).

3. **Nothing else.** The bootloader path (`openpower.grub`, petitboot) is
   identical, and every other package on the medium comes from Arch POWER,
   which is already POWER8 (§1).

---

## 7. `fortran.conf`

Currently `/etc/makepkg.conf.d/fortran.conf` says `-mcpu=power8` with no
`-mtune`, while `CFLAGS` says `-mcpu=power9 -mtune=power9`. That inconsistency
was a wart. With POWER8 a real target it is a question with an answer:

**Raise it. The POWER9 builder's `fortran.conf` should say
`-mcpu=power9 -mtune=power9`, matching `CFLAGS`.** The POWER8 builder wants it
left at `power8` — which the drop-in in §3 already guarantees, and which also
adds the missing `-mtune=power8`.

Reasoning:

* A builder should have **one** ISA level. Two levels inside one repo means a
  package with mixed C and Fortran objects has no single answer to "what does
  this run on", and the low half is invisible — the current `-mcpu=power8` in
  `FFLAGS` is not protecting anyone, because the C objects in the same `.so`
  are POWER9 anyway. It buys zero compatibility and costs codegen.
* Fortran's reach here is small — `adios2`, `hipblas`, `rocblas` are the only
  recipes of ours that declare `gcc-fortran`, plus upstream `lapack` in the
  closure — so raising it is low-risk.
* Under the two-builder model the ISA level belongs to the *builder*, not to
  the language. Any per-language exception is a place for the two targets to
  drift.

The change (the user's to make; it is under `/etc`):

```sh
sudo sed -i 's/-mcpu=power8/-mcpu=power9 -mtune=power9/' /etc/makepkg.conf.d/fortran.conf
```

giving:

```bash
FFLAGS="-O2 -pipe -mcpu=power9 -mtune=power9 \
        -Wp,-D_FORTIFY_SOURCE=3 -fstack-clash-protection \
        -fno-omit-frame-pointer"
FCFLAGS="$FFLAGS"
```

The POWER8 drop-in's `${FFLAGS//power9/power8}` handles the new spelling
without modification, and its assert catches it if it ever stops matching.

---

## 8. What the co-developer would get, and what would still be missing

**Would get:** the whole Omarchy package set — Hyprland and its stack, foot,
neovim/LuaJIT, the fonts and themes, the AUR-tail ports — running on an
8335-GCA, on top of an Arch POWER base that already works there. Plus an ISO
that installs it, once the kernel config above exists. Their existing
POWER8/gfx1030 ROCm drop slots underneath unchanged.

**Would still be missing:**

* **A POWER8 Rust toolchain**, until `packages/rust` gets its toggle — and
  without it, 18 Rust recipes silently ship POWER9 `libstd` (§4).
* **`ispc` and its three consumers** (`openimagedenoise`, `openvkl`, `ospray`),
  and therefore the parts of `blender` and `freecad` that lean on them, until
  the ispc target level is answered (§4).
* **`chromium` and `qt6-webengine`** until V8's ppc64 feature detection is
  confirmed runtime-gated (§5).
* **GPU targets.** Everything ROCm here defaults to `gfx1100`; theirs is
  `gfx1030`. `rocblas` already reads `ROCBLAS_GPU_TARGETS`; `llama.cpp-hip`
  hardcodes `-DGPU_TARGETS=gfx1100`. Orthogonal to ISA, but it lands in the
  same builder config.
* **Any runtime validation at all.** Every claim in this document is static
  disassembly and source reading on a POWER9. Nothing has been executed on a
  POWER8.

---

## 9. Artifacts from this pass

Two packages were built POWER8 to test the method, and are kept in
`repo-power8/` (a holding folder — **no repo database, not published**):

| file | flags | ISA 3.0 | status |
|---|---|---:|---|
| `repo-power8/libde265-1.1.2-1-powerpc64le.pkg.tar.zst` | POWER8 drop-in in force (`-mcpu=power8 -mtune=power8`) | **0** | genuine POWER8 package |
| `repo-power8/needs-rebuild/fd-10.5.0-3-powerpc64le.pkg.tar.zst` | POWER8 drop-in in force (`-C target-cpu=pwr8`) | **2,676** | **not POWER8-legal** — statically linked POWER9 `libstd`; held apart deliberately. Rebuild after `packages/rust` gets its POWER8 toggle. |

Both carry `arch = powerpc64le` and this machine's packager line. Neither
inherited the host's `-mcpu=power9`: the drop-in was verified in force before
either build (§3), and `libde265`'s zero against its POWER9 counterpart's 1,799
proves it took effect.

Scan working tree, controls and partial sweep output: `/var/tmp/power8-scope/`
(scratch; nothing there is needed to reproduce — the scanners are
`~/co-dev-v620/build-overrides/isa30-pkgscan.sh` and
`~/Development/powerpc64le-handbook/probes/isa30scan.sh`).
