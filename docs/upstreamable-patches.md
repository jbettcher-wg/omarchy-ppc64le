# Upstreamable patches

Changes made in this repo that are **portability fixes other people would
want**, as opposed to local packaging workarounds. Kept separate deliberately:
the ratio between the two columns is the most honest measure of how ready
ppc64le actually is.

## Source patches worth sending upstream

**None yet.**

That is the headline finding, not an omission. Through clumps 1-4 —
25 packages built and verified, across Perl, Python, Lua, Rust, Go, C and C++ —
**not one line of any upstream project's source code needed changing.** Every
diff in `packages/` is in the PKGBUILD, and almost every one of those is
`arch=()`.

This is the arch-gating pattern from the handbook, holding at scale: the
substrate is first class, and what breaks is code and metadata that was never
told the architecture was allowed.

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
| `obs-studio` | `-DENABLE_BROWSER=OFF` (planned) | no ppc64le CEF exists |

## Checksum refreshes — neither

`inxi` and `fcft` both fetch `archive/<tag>.tar.gz` from Codeberg, which
generates those tarballs on demand and not reproducibly, so Arch's recorded
hashes no longer match what the server serves. Tarball contents were verified
before the hashes were updated. This would equally affect an x86_64 rebuild
today; it has nothing to do with the architecture.
