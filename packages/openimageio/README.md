# `openimageio`

Arch's recipe (3.1.12.1-5) with `powerpc64le` added to `arch=()`. No source
changes.

## Why this exists

Arch POWER ships `openimageio 3.1.11.0-3`, linked against
`libopenjph.so.0.27`. This repo ships `openjph 0.31.0-1` (in `repo/`, no
recipe under `packages/` -- see below), which is the version pacman resolves
to once the `[omarchy-power9]` repo is enabled. So Arch POWER's `openimageio`
cannot load on such a system:

    blender: error while loading shared libraries: libopenjph.so.0.27:
    cannot open shared object file: No such file or directory

`[MEASURED]` on the build host, 2026-09-10, running a Blender built in bq's
sysroot. Everything that links OpenImageIO (blender, openshadinglanguage,
opencolorio tools ...) inherits that. Rebuilding OpenImageIO against
`openjph 0.31` is the fix; Arch itself already did the same (its 3.1.12.1-5
is the openjph-0.31 rebuild), so this is the same class of report as the
`libheif`/`libde265` entry in `docs/upstreamable-patches.md`: Arch POWER
lagging a soname bump, nothing for upstream.

`openjph 0.31.0-1` in `repo/` has no `packages/openjph/` recipe. That
violates `RULES.md` section 3 and is not fixed here; whoever built it should
add the recipe.

## Verification

bq: `openimageio ... ok`, `openimageio-3.1.12.1-5-powerpc64le.pkg.tar.zst`.
`packages/blender` is built against this package (bq stages our repo's
packages over Arch POWER's). bq runs makepkg `--nocheck`, so OIIO's own test
suite did not run.
