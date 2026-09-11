# `freecad`

Local copy of Arch's recipe. The only reason this directory exists is history,
and that history is worth keeping because the obvious conclusion was wrong.

## The ospray detour

`ospray` was removed from `makedepends` on 2026-09-10 on the grounds that it
could not exist on ppc64le: its chain is `embree ispc openimagedenoise openvkl
rkcommon`, and **ispc** is Intel's SPMD compiler, which was believed to emit
only x86 SIMD (plus an ARM/NEON backend).

That was wrong. **ispc 1.31.0 shipped an experimental ppc64le/VSX backend**
(`PPC64_ENABLED`, `--arch=ppc64le`, `vsx-i32x4`) — upstream just does not ship
it in released binaries. The whole stack was subsequently built and tested here:
`vklTestsCPU` 47/47 (310,680,004 assertions), `oidnTest` 16/16, and upstream's
`ospTutorial.c` rendering end-to-end reporting `ISA: VSX`. See
`packages/{ispc,rkcommon,embree,openvkl,openimagedenoise,ospray}/README.md` and
`docs/upstreamable-patches.md` §4-8.

So `ospray` is restored, and this recipe is now identical to Arch's.

## Why the removal did nothing either way

Worth recording, because it means the detour cost nothing but also gained
nothing on its own: Arch POWER's `vtk` 9.5.0-5 is built **without** OSPRay, so
`libvtkRenderingRayTracing.so` does not exist and FreeCAD's ray-tracing path was
unreachable regardless of what this recipe declared. Arch's own `vtk` recipe
(9.6.2-7) does enable it — `ospray` and `openimagedenoise` in makedepends,
`-DVTKOSPRAY_ENABLE_DENOISER=ON` — which is why VTK was rebuilt here too.

The chain that actually has to hold is:

    ispc(VSX) -> embree + openvkl + oidn -> ospray -> vtk(RenderingRayTracing) -> freecad

Delete this directory once Arch POWER ships a `vtk` built with ray tracing; at
that point nothing here deviates from upstream and the file is pure overhead.
