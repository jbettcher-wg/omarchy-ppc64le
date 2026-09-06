# Upstreamable patches

Changes made in this repo that are **portability fixes other people would
want**, as opposed to local packaging workarounds. Kept separate deliberately:
the ratio between the two columns is the most honest measure of how ready
ppc64le actually is.

## Source patches worth sending upstream

### 1. rnnoise — `src/vec.h`'s scalar fallback has never compiled

`packages/rnnoise/0001-vec.h-fix-the-scalar-fallback-path.patch`

`vec.h` dispatches three ways: AVX/SSE2, ARM NEON, and a generic scalar `#else`.
The scalar branch does not compile on any architecture. It includes
`"os_support.h"`, which does not exist in the rnnoise source tree, and calls
`OPUS_CLEAR()`, which is not defined in it either. Both are leftovers from Opus,
which rnnoise vendored the code from; rnnoise renamed the macro to `RNN_CLEAR`
in `src/common.h` and dropped the header, but missed this branch because nothing
had ever built it. Every platform rnnoise has been compiled on matched either
the SSE2 or the NEON arm.

The patch applies the rename that was missed. `RNN_CLEAR` is already in scope
via `arch.h` → `common.h`, so no new include is needed.

**Not ppc64le-specific.** riscv64, s390x and mips hit it identically. ppc64le is
simply where somebody finally took the `else` branch.

Send to: <https://gitlab.xiph.org/xiph/rnnoise>.

### 2. marksman — the Makefile's arch table silently produces an invalid .NET RID

`packages/marksman/0001-Makefile-recognise-ppc64le-riscv64-and-s390x.patch`

The Makefile builds a .NET runtime identifier as `$(OS_ID)-$(ARCH_ID)`, mapping
`uname -m` through a list of `ifeq` cases: x86_64, amd64, x86, arm, arm64,
aarch64. Anything else leaves `ARCH_ID` empty and the RID becomes `linux-`. The
build then fails a long way downstream with

    error NETSDK1083: The specified RuntimeIdentifier 'linux-' is not recognized

which does not mention the Makefile at all.

.NET is not the limitation: on this machine `dotnet --info` reports
`RID: linux-ppc64le`. Only marksman's table is missing the entry.

The patch adds ppc64le, riscv64 and s390x, and — the more useful half — turns
the silent-empty case into a `$(error)` naming the unrecognised machine, so the
next architecture gets a message pointing at the table rather than NETSDK1083.

**Not ppc64le-specific.**

Send to: <https://github.com/artempyanykh/marksman>.

### 3. neovim -- `FindLpeg.cmake` bakes lpeg's build-time path into the binary

`packages/neovim/0001-findlpeg-link-by-name-not-absolute-path.patch`

`cmake/FindLpeg.cmake` resolves lpeg with `find_library` and hands the absolute
result to the linker through an `UNKNOWN IMPORTED` target -- deliberately, to
keep CMake from rewriting the link path (neovim#23395). But `lua51-lpeg` ships
`/usr/lib/lua/5.1/lpeg.so` with **no `DT_SONAME`**, and GNU ld records a
SONAME-less shared object in `DT_NEEDED` under the exact spelling it was given on
the command line. The absolute path is copied into the executable verbatim.

Arch's own x86_64 `neovim` shows the benign form of this:

    NEEDED [/usr/lib/lua/5.1/lpeg.so]

which works only because the path it happens to name is also the install path.
Any build that resolves lpeg anywhere else ships a `DT_NEEDED` pointing there.
This repo's `neovim 0.12.5-1` shipped

    NEEDED [/home/jbettcher/omarchy-work/sysroot/usr/lib/lua/5.1/lpeg.so]

and stopped starting the moment that scratch directory was renamed -- verified by
renaming it, not inferred.

The patch emits `-L<dir> -l:<file>` plus an rpath for the same directory, so ld
records `NEEDED [lpeg.so]` and the loader resolves it through `RUNPATH`. Static
archives keep the direct-path link, which records nothing.

**Not ppc64le-specific.** Every distro build of neovim carries the absolute
`DT_NEEDED`; it is invisible only while the build prefix and the install prefix
are the same directory.

Send to: <https://github.com/neovim/neovim>.

---

Those are the *only* three, after 87 packages built and verified across Perl,
Python, Lua, Rust, Go, C and C++. Every other diff in `packages/` is in a
PKGBUILD, and 59 of the 87 are `arch=()` alone.

The first two are the arch-gating pattern from the handbook, holding at scale:
the substrate is first class, and what breaks is code and metadata that was never
told the architecture was allowed -- a generic fallback branch nobody had ever
taken. The third is a different animal and worth naming as such: not an
architecture bug at all, but a latent defect every distro ships and none notices,
because on an ordinary builder the wrong answer and the right answer are the same
string. It took an unprivileged sysroot build to pull them apart.

## Reports that belong to Arch POWER, not upstream

### `libheif` is built against a newer `libde265` than the repo ships

Arch POWER ships `libheif 1.23.1-1` and `libde265 1.0.18-1`. That libheif has an
undefined reference to `de265_get_security_limits`, which `libde265 1.0.18` does
not export — it arrived later, and Arch proper is on `libde265 1.1.2`.

Consequence: *anything* linking libheif fails at link time under
`-Wl,--no-undefined`, which is Arch's default. We hit it building `imv`;
obs-studio, the GNOME apps and any gdk-pixbuf thumbnailer path would hit it too.

Not a portability bug — it reproduces on any architecture with that pair of
packages. It is a repo-consistency bug, and the fix is for Arch POWER to build
`libde265 1.1.2`. We carry `packages/libde265/` (Arch's PKGBUILD plus
`powerpc64le` in `arch()`) in the meantime.

## Packaging substitutions — local, not upstreamable

These are correct for this port and wrong to send anywhere. They exist because a
build-time tool is missing from Arch POWER, not because anything is broken.

| Package | Substitution | Why |
|---|---|---|
| `eza` | `pandoc` → `go-md2man` for man pages | Arch POWER has no `ghc` at all; pandoc would mean bootstrapping a Haskell compiler to typeset three man pages |
| `foot` | PGO training `full-headless-sway` → `partial` | `sway` is missing and would pull in `wlroots0.20`, also missing. foot's own pgo.sh supports compositor-free training, so PGO is kept, not lost |
| `bat` | drop `cargo-edit` from makedepends | not in Arch POWER, and the PKGBUILD never invokes it |
| `obs-studio` | `-DENABLE_BROWSER=OFF`, and the `obs-studio-plugin-browser` split package is not produced | CEF publishes no ppc64le build, and building it means building Chromium |
| `rnnoise` | `--enable-x86-rtcd` made conditional on `CARCH` | x86 run-time SIMD dispatch; no VSX backend exists. Costs performance, not correctness |
| `marksman` | `global.json` removed; framework-dependent publish instead of self-contained | Arch POWER's .NET 9 SDK is a prerelease, which `rollForward` can never select; and Microsoft publishes no ppc64le runtime pack, so self-contained publishing is impossible |
| `plymouth` | Arch logo files made optional | Arch POWER's `filesystem` ships `/usr/share/pixmaps` empty |

## Not portability problems at all — they would fail on x86_64 too

Worth separating, because they look like port failures in a build log and are
not. Each of these reproduces on any architecture with the same toolchain and
distro state.

| Package | Symptom | Actual cause |
|---|---|---|
| `evince` | `conflicting types for 'getenv'; have 'char *(void)'` | gcc 16 defaults to C23, where `()` means `(void)`. texlive's kpathsea headers still use the K&R form. Pinned to `-D c_std=gnu17`. |
| `websocketpp` | `Could not find boost_system` | Boost removed the separate `boost_system` library in 1.90. Only its test suite needs it; built with `-DBUILD_TESTS=OFF`. |
| `sushi` | signature check fails | the tag's signing key is not retrievable from any keyserver, WKD or DANE. The git source's own b2sum still pins the tree, so `--skippgpcheck` loses nothing here. |
| `luarocks`, `fzf`, `system-config-printer`, `gexiv2`, `evince`, `pnpm` | `unknown public key` | keys simply not in the local keyring; `gpg --recv-keys` and continue. |
| `dua-cli` | `bsdtar: Pathname can't be converted from UTF-8 to current locale` | non-interactive ssh lands in the POSIX locale. Environment, not package. |

## Blocked by prebuilt binaries that do not exist for ppc64le

The one category that is neither a portability bug nor a packaging choice: an
ecosystem that ships compiled artifacts per platform and has not built ours.

| Package | Missing artifact | Note |
|---|---|---|
| `obs-studio` (browser source) | CEF | building it means building Chromium; `-DENABLE_BROWSER=OFF` |
| `marksman` (self-contained) | `Microsoft.AspNetCore.App.Runtime.linux-ppc64le` | framework-dependent publish instead |
| `prettier` 3.8.1 | `@oxc-parser/binding-linux-ppc64-gnu` at 0.99.0 | the binding **is** published — from 0.104.0. A version window, closing on its own. |
| `typescript-language-server` | `@pnpm/exe.linux-ppc64` | pnpm 9 works but rejects the v11 lockfile |
| `obsidian`, `localsend` | Electron / Flutter runtimes | FEX, or drop |

This is the same structural issue `nvim-tooling.md` identifies with mason, and
it is the honest answer to "how ready is ppc64le": the compilers are ready, and
the binary-distribution habits of the JavaScript and .NET ecosystems are not.

## Checksum refreshes — neither

`inxi` and `fcft` both fetch `archive/<tag>.tar.gz` from Codeberg, which
generates those tarballs on demand and not reproducibly, so Arch's recorded
hashes no longer match what the server serves. Tarball contents were verified
before the hashes were updated. This would equally affect an x86_64 rebuild
today; it has nothing to do with the architecture.
