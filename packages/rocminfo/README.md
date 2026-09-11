# `rocminfo`

`rocminfo` (enumerate HSA agents) and `rocm_agent_enumerator` (the Python
helper that prints the gfx targets present, used by build systems to pick
`--offload-arch`). Links `libhsa-runtime64` from `hsa-rocr`.

## Deviation from Arch's recipe

- `arch=()` gains `powerpc64le`. **That was the only change needed.** The
  one x86 branch in its `CMakeLists.txt` (`-m64 -msse -msse2`, line 148) is
  already gated on `CMAKE_HOST_SYSTEM_PROCESSOR` and simply does not fire.

It has to be built *after* this repo's `hsa-rocr` 7.2.4 and against it, not
against the host's installed 6.2.4 -- see the `/opt` overlay note in
`../rocm-llvm/README.md`.

## Evidence

bq: `rocminfo ... ok 10s rocminfo-7.2.4-1-powerpc64le.pkg.tar.zst`.

Run against this repo's `hsa-rocr` 7.2.4 it lists the gfx1100 agent
("AMD Radeon RX 7900 XTX", 96 CUs, wave32, ISA `amdgcn-amd-amdhsa--gfx1100`)
and both CPU sockets -- the full extract is in `../hsa-rocr/README.md`.
`rocm_agent_enumerator` prints `gfx1100`.

Two things to know when running it from a staging tree rather than an
installed system: the binary has no RUNPATH and resolves
`librocprofiler-register.so.0` through `rocm-core`'s
`/etc/ld.so.conf.d/rocm.conf`, so it needs `LD_LIBRARY_PATH=/opt/rocm/lib`
under an overlay; and until `hsa-rocr` carried the vDSO fix it died in
`hsa_init()` with SIGSEGV (exit 139) -- that was `hsa-rocr`'s bug, not this
package's.
