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

---

That is the *only* one, after 78 packages built and verified across Perl,
Python, Lua, Rust, Go, C and C++. Every other diff in `packages/` is in a
PKGBUILD, and the large majority of those are `arch=()` alone.

This is the arch-gating pattern from the handbook, holding at scale: the
substrate is first class, and what breaks is code and metadata that was never
told the architecture was allowed. It is also the handbook's other prediction
holding — that when something *does* break, it is a generic fallback branch that
nobody has ever taken.

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

## Not portability problems at all — they would fail on x86_64 too

Worth separating, because they look like port failures in a build log and are
not. Each of these reproduces on any architecture with the same toolchain and
distro state.

| Package | Symptom | Actual cause |
|---|---|---|
| `evince` | `conflicting types for 'getenv'; have 'char *(void)'` | gcc 16 defaults to C23, where `()` means `(void)`. texlive's kpathsea headers still use the K&R form. Pinned to `-D c_std=gnu17`. |
| `websocketpp` | `Could not find boost_system` | Boost removed the separate `boost_system` library in 1.90. Only its test suite needs it; built with `-DBUILD_TESTS=OFF`. |
| `sushi` | signature check fails | the tag's signing key is not retrievable from any keyserver, WKD or DANE. The git source's own b2sum still pins the tree, so `--skippgpcheck` loses nothing here. |
| `luarocks`, `fzf`, `system-config-printer`, `gexiv2`, `evince` | `unknown public key` | keys simply not in the local keyring; `gpg --recv-keys` and continue. |

## Checksum refreshes — neither

`inxi` and `fcft` both fetch `archive/<tag>.tar.gz` from Codeberg, which
generates those tarballs on demand and not reproducibly, so Arch's recorded
hashes no longer match what the server serves. Tarball contents were verified
before the hashes were updated. This would equally affect an x86_64 rebuild
today; it has nothing to do with the architecture.
