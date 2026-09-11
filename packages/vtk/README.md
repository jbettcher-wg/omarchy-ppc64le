# `vtk`

Arch's recipe pinned to the **9.5.0-5** tag, with three features disabled.

## Why this exists

Arch POWER ships `vtk 9.5.0-5` built **without** OSPRay. Its cmake probes for
ospray, does not find it, and silently omits `libvtkRenderingRayTracing.so`.
FreeCAD's ray-tracing path was therefore dead on this platform regardless of
what FreeCAD's own recipe declared — the module was not in the VTK it linked.

Arch's recipe has always supported it: `ospray` and `openimagedenoise` are in
`makedepends` and it passes `-DVTKOSPRAY_ENABLE_DENOISER=ON`. Nothing needed
patching for ray tracing. The dependency simply did not exist for ppc64le until
the OSPRay stack was ported here — see `packages/ospray/README.md` and
`docs/upstreamable-patches.md` §4-8.

## Why the tag and not `main`

`main` is at **9.6.2-7**, which adds four makedepends Arch POWER does not carry:
`anari-sdk`, `java-environment`, `onnxruntime`, `viskores`. `onnxruntime` alone
is enormous and exists to serve `libvtkFiltersONNX.so`, which nothing here
wants. Pinning to 9.5.0-5 also keeps the same soname as Arch POWER's build, so
this is a drop-in replacement rather than a version bump.

## The three disabled features

9.5.0-5 wants `anari-sdk`, `java-environment` and `viskores`, none of which
exist for ppc64le.
`adios2` is **not** disabled — it is built and bundled (see
`packages/adios2/README.md`), along with a `mgard` rebuilt against our protobuf
35, since Arch POWER's `mgard` pins `libprotobuf.so=34.1.0` and made the whole
`adios2` closure unresolvable. The other three are switched off; none relate to
ray tracing.

| dropped | switched off with |
|---|---|
| `java-environment=11` | `-DVTK_WRAP_JAVA=OFF`, and the `package()` hunk that relocates `vtk.jar` and `vtk-Linux-$CARCH/*.so` is removed — with wrapping off those files are never produced and the `mv` would fail |
| `anari-sdk` | `-DVTK_MODULE_ENABLE_VTK_RenderingAnari=NO` |
| `viskores` | `-DVTK_MODULE_ENABLE_VTK_vtkviskores=NO` and `_vtkvtkm=NO`, plus the modules that link them: `AcceleratorsVTKm{Core,DataModel,Filters}`, `fides`, `IOFides` |

The module names matter and are not the directory names. `ThirdParty/viskores`
declares `NAME VTK::vtkviskores`, so the option is
`VTK_MODULE_ENABLE_VTK_vtkviskores`; `VTK_MODULE_ENABLE_VTK_viskores` is
silently ignored, `VTK_BUILD_ALL_MODULES=ON` then enables the module anyway, and
the build dies in `ThirdParty/viskores/CMakeLists.txt` on a missing `Viskores`
package. Read the `NAME` field out of each `vtk.module` rather than guessing:

    tar -xzOf VTK-9.5.0.tar.gz VTK-9.5.0/ThirdParty/viskores/vtk.module

Matching `optdepends` entries are dropped too. Everything else, including
`VTK_BUILD_ALL_MODULES=ON`, is upstream's.

FreeCAD uses none of the three. ANARI is an alternative ray-tracing backend we
do not need now that OSPRay works; Viskores is accelerator offload; the Java
bindings are Java bindings.

Retire this directory when Arch POWER ships a vtk built with ray tracing, or
when there is a reason to move to 9.6.x and build its new dependencies.

## One more deviation: bundled fmt

`-DVTK_MODULE_USE_EXTERNAL_VTK_fmt=OFF`, joining the `exprtk`/`ioss`/`pegtl`/
`scn`/`token` exceptions the recipe already carries.

Our repo ships **fmt 12.2.0** (Arch POWER's base has 12.1.0). `fmt::localtime`
does not survive that bump, and VTK 9.5.0's vendored ioss still calls it:

    ThirdParty/ioss/vtkioss/Ioss_Utils.C:165:54:
      error: 'localtime' is not a member of 'fmt'

Three ioss translation units fail that way, 3588 targets into the build. The
recipe already bundles ioss, so it was compiling vendored ioss against a system
fmt two minor versions newer than it expects. Bundling fmt as well keeps the
pair consistent. VTK mangles its vendored copy to `vtkfmt`, so this does not
collide with the system `libfmt.so.12` that other libraries in the process use.

Revisit if VTK updates its vendored ioss for current fmt, or if our fmt ever
moves back in line with Arch POWER's.
