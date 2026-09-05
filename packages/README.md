# packages

One directory per package: the `PKGBUILD`, plus any `.patch` files and install
hooks it needs. This is the source-controlled part — build output goes to
`../repo/` and is gitignored.

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
