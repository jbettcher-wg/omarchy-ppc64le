# Arch POWER chromium 150 build adjustments

Applied on top of upstream Arch's chromium PKGBUILD (git commit d8dd314,
150.0.7871.128-1), plus the Debian chromium-team ppc64le patch set
(salsa.debian.org/chromium-team/chromium, ppc64le/*, 43 patches applied
in series order).

## PKGBUILD changes
See 01-pkgbuild-archpower.diff. Summary:
- arch=('x86_64' 'powerpc64le')
- _manual_clone=0 (depot_tools/cipd cannot bootstrap on ppc64le; the
  `-lite.tar.xz` official Google source drop works fine)
- Conditional ppc64le patch loop in prepare(), driven by the Debian
  series file
- Strip -mcpu=/-mtune= from CFLAGS/CXXFLAGS on ppc64le for the same
  reason aarch64/riscv64 strip -march= (per-TU arch selection in
  libvpx/skia/pffft)
- Prefer a locally-built gn (bootstrapped from upstream
  gn.googlesource.com/gn) via $startdir/../gn-newer/gn — the Arch
  `gn` 0.2324 package predates several dotfile/tool attributes used
  by Chromium 150 (`expand_directory_allowlist`, `expand_directory`,
  `inputs =` on rust_* tools, `c_additional_outputs` on config()).
  Once the Arch `gn` package is refreshed, this override can be
  removed.
- Defensive seds in prepare() to strip the same three constructs from
  the chromium source, in case anyone builds without the newer gn.
  These are no-ops with a modern gn.

## Debian ppc64le patch set
The whole `ppc64le/` subtree from Debian salsa was copied verbatim.
See ppc64le-patches/ in the sibling directory. The `debian-series`
file is Debian's `debian/patches/series` file used as the ordering
source.
