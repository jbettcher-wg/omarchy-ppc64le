# `ospray`

Arch's recipe plus `ospray-ppc64le.patch`, minus the Intel GPU bits.

OSPRay's CPU module is ISPC kernels; its ISA list is derived from what
Embree and Open VKL were built with and only knows the x86 and NEON names.
The patch adds `VSX`: enabled when Embree reports its SSE4.2 kernels
(that is what `packages/embree` builds, on VSX) and Open VKL reports
`OPENVKL_ISA_VSX`; mapped to ispc's `vsx-i32x4`; exempt from the
"add a dummy second target" rule like NEON, since our Embree is single-ISA;
and named in the startup ISA report. OSPRay drives ispc through its own
copy of ispcrt's helper (`cmake/compiler/ispc.cmake`), which hard-codes
`--arch=x86-64` on every non-ARM host, so that gets a `ppc64le` branch too
(the same fix as `packages/ispc`'s ispcrt patch). Upstreamable; see
`docs/upstreamable-patches.md`.

## Deviations from Arch's recipe

- `level-zero-headers` / `level-zero-loader` makedepends dropped (Intel GPU).
- Everything else as Arch: `OSPRAY_BUILD_ISA=ALL` (resolves to VSX here),
  denoiser module on (`openimagedenoise`), MPI module on (`openmpi` from
  Arch POWER), ctest in `check()` (bq runs makepkg `--nocheck`, so only
  under a hand `makepkg`).

## Verification (2026-09-10)

Upstream's `apps/ospTutorial/ospTutorial.c` compiled against the packaged
headers/libraries from bq's sysroot and run: OSPRay loads the `cpu` module,
Open VKL reports `ISA: VSX`, and both `firstFrame.ppm` and
`accumulatedFrame.ppm` (1024x768) come out with ~200k pixels of the two
rendered triangles against the background. That exercises ospray -> embree
(SSE4.2-on-VSX) -> openvkl -> rkcommon -> ispc VSX kernels end to end.
bq: ok 56 s. Not run: `ospTestSuite` image regressions (need upstream's
baseline images, which Arch's `check()` does not fetch either).

## What this does and does not give FreeCAD

Arch's `freecad` lists `ospray` in `makedepends` because Arch's `vtk` is
built with the OSPRay ray-tracing module and `find_package(VTK)` then needs
`ospray` to resolve. **Arch POWER's `vtk` 9.5.0-5 is built without OSPRay**
(`pacman -Si vtk`: no ospray in Depends). So on ppc64le FreeCAD does not
need this package, and having it does not light up ray tracing in FreeCAD
until `vtk` is rebuilt with `VTK_MODULE_ENABLE_VTK_RenderingRayTracing=YES`.
`packages/freecad/README.md` has the current position.
