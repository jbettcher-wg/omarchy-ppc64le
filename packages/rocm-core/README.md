# `rocm-core`

ROCm's version-stamp package: `librocm-core.so` (which answers
`getROCmVersion()`), `/opt/rocm/.info/version`, and Arch's `ld.so.conf`,
`profile.d` and fish snippets that put `/opt/rocm/{bin,lib}` on the path.
Nothing in it is architecture-specific.

## Deviation from Arch's recipe

- `arch=()` gains `powerpc64le`. **That was the only change needed.**

## Why 7.2.4, when Arch POWER ships 6.4.4

This is the bottom of the ROCm stack this repo builds (`rocm-core`,
`rocm-llvm` + `rocm-device-libs` + `comgr`, `hsa-rocr`, `rocminfo`,
`hip-runtime`), and all of it is pinned to **7.2.4** together. The reasoning
is in `../rocm-llvm/README.md`; the short version is that 7.2.4 is the only
version for which Arch's recipes for the *whole* stack exist and agree with
each other, and the ROCm components check each other's versions at runtime.

## Evidence

bq: `rocm-core ... ok 8s rocm-core-7.2.4-1-powerpc64le.pkg.tar.zst`.
