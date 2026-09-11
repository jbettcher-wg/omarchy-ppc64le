# `adios2`

Arch's recipe with CUDA and the Python bindings disabled.

Arch builds ADIOS2 with `-DADIOS2_USE_CUDA=ON` and `cuda` in `makedepends`.
There is no CUDA toolkit for ppc64le, so cmake dies at

    Could not find `nvcc` executable in any searched paths

Everything else in the configure step succeeded — MPI, UCX and yaml-cpp all
resolved — so `-DADIOS2_USE_CUDA=OFF` plus dropping the `CMAKE_CUDA_*` knobs
handles that part.

The Python bindings are off for a different reason. They use `nanobind`, whose
cmake config does `find_dependency(tsl-robin-map)`, and `tsl-robin-map` is in no
Arch POWER repository — it would have to be packaged too, for bindings nothing
here consumes. `vtk`'s `IOADIOS2` module links ADIOS2's **C++** API, so
`-DADIOS2_USE_Python=OFF` costs us nothing and removes both `nanobind` and
`tsl-robin-map` from the closure.

Re-enable if something ever wants `import adios2`; that means packaging
`tsl-robin-map` (header-only, so it should be trivial) first.

## Why it is in our repo at all

`vtk`'s `IOADIOS2` module needs it, and Arch POWER's `adios2` could not be
staged: it depends on `mgard`, which pins `libprotobuf.so=34.1.0` while our repo
ships protobuf 35, so `pacman -Sp adios2` fails to resolve the whole closure.
`mgard` was rebuilt here against protobuf 35 (`mgard 1.6.0-12`), but a rebuilt
`mgard` only helps once pacman's *sync* database sees it — and building `adios2`
into our repo sidesteps that entirely, because `stage-deps` stages our own
packages directly instead of resolving them through pacman.

See `packages/vtk/README.md` for the module that wants this.
