# packages

One directory per package: the `PKGBUILD`, plus any `.patch` files and install
hooks it needs. This is the source-controlled part — build output goes to
`../repo/` and is gitignored.

## Layout

The tree mirrors Arch POWER's. They nest most of their recipes under category
directories and keep the rest at the top level, so we do the same:

| Where | What |
|---|---|
| `<category>/<pkgbase>/` | a recipe Arch POWER nests under that category — `kf6/`, `kf5/`, `kde/`, `plasma/`, `qt6/`, `xorg/`, `python/`, `go/`, `dotnet/` and so on. Use the same category they do. |
| `<pkgbase>/` | a recipe Arch POWER keeps at its top level, which is also where Arch's own flat GitLab namespace maps. |
| `ours/<pkgbase>/` | a recipe no upstream carries: absent from both Arch POWER and Arch's GitLab, so this tree is its primary source. |

The rule exists so nothing gets missed. `tools/bq.py` finds recipes by pkgbase
anywhere in the tree, and when a pkgbase is in more than one tree it picks by
version rather than by source order. A layout that matches Arch POWER's is what
makes "do they carry this, and is theirs newer?" answerable at all.

One pkgbase must resolve to exactly one directory. Two directories claiming one
pkgbase is reported as an error, never resolved by picking one.

## Conventions

- **Start from upstream.** For a package Arch already ships, copy the official
  PKGBUILD (or Arch POWER's, from `../../repo/archpower/`) and keep the diff
  minimal, so rebasing onto a new upstream version stays cheap.
- **Record why.** Every patch gets a header comment saying what it fixes and
  whether it is a ppc64le portability fix (a candidate to send upstream) or a
  local workaround (not).
- **`arch=()`.** Many ports need no more than adding `powerpc64le`. Say so
  explicitly in the PKGBUILD when that genuinely was the only change — it keeps
  the packages that needed real work visible.
- **Endianness and word size are the usual culprits.** x86 assumptions show up as
  hardcoded `x86_64` triplets, SSE intrinsics, `-m64`, and little-endian struct
  punning. POWER9 is little-endian, which removes a whole class of bugs the
  historic big-endian ppc64 ports hit — do not assume old ppc64 patches apply
  unchanged.

## Status

Tracked in `../docs/package-status.md`.
