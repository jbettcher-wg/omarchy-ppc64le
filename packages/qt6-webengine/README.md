# qt6-webengine on ppc64le

`qt6-webengine` is the last blocker in `kaccounts-integration` -> `signon-ui` ->
`qt6-webengine`. No ppc64le repository anywhere ships it.

## The short version

It is buildable, and the port is **not** the ppc64le chromium work in this
tree. Two different Chromium trees are involved:

| | Chromium version |
|---|---|
| `chromium-151.0.7922.108-1-powerpc64le.pkg.tar.zst` (built here) | **151.0.7922.108** |
| `qtwebengine-everywhere-src-6.11.2`, `src/3rdparty/chromium/chrome/VERSION` | **140.0.7339.225** |

Eleven major releases apart. The Arch POWER chromium recipe's
`chromium-ppc64le-patches-r2.tar.gz` (41 applied patches) is a quilt series
rebased onto 151. Measured, by `patch -p1 --dry-run` of every patch in
`debian-series` against a pristine `src/3rdparty/chromium` from
`qtwebengine-everywhere-src-6.11.2`:

    clean = 24    rejected = 17

and the rejects are the load-bearing ones -- `0001-sandbox-Enable-seccomp_bpf-for-ppc64`,
`0001-Add-PPC64-support-for-boringssl` (4 failed hunks + a missing file),
`crashpad/0001-Implement-support-for-PPC64-on-Linux` (6 missing files),
`skia-vsx-instructions` (9 failed hunks + 3 missing files),
`0003-third_party-libvpx-Add-ppc64-generated-config` (7 failed hunks), and all
five of `fixes/*`. Each patch was dry-run independently against the pristine
tree, so this is a *lower* bound: applied as a series, the first reject stops
the run and later patches that depend on it fail too.

What *does* transfer is the upstream of both: Raptor Engineering's
`openpower-patches`. Fedora maintains a rebase of that series against exactly
the Chromium fork Qt 6.11 bundles, in `rpms/qt6-qtwebengine`, and Fedora's spec
tracks the same `6.11.2` this tree packages. That is the patch set used here.

## Provenance

`ppc64le-patches/` is copied verbatim from
`https://src.fedoraproject.org/rpms/qt6-qtwebengine.git`; the exact commit is
recorded in `ppc64le-patches/PROVENANCE-fedora-commit.txt`.
`series.ppc64` and `prepare-ppc64.sh` are Fedora's own regeneration recipe and
are kept for the next rebase -- they say which upstream Raptor patches were
concatenated into the big patch and which hunks were dropped (tests for files
Qt's fork does not carry).

## What each patch does

| Patch | Scope |
|---|---|
| `qtwebengine-6.9-ppc64.patch` | `cmake/QtToolchainHelpers.cmake`: maps Qt's `power64` architecture string onto GN's `ppc64`. Three lines, and nothing configures without it. |
| `qtwebengine-chromium-ppc64.patch` | The port. 17k lines, 134 files: `partition_alloc.gni` 64-bit pointers, `sandbox/features.gni` seccomp-bpf enable, the ppc64 syscall/ucontext system headers and the whole seccomp-bpf policy set, boringssl ppc64le asm + runtime `AT_HWCAP2` dispatch, crashpad/breakpad ppc64 contexts, dawn detection, angle, libaom/libvpx ppc64 configs. |
| `qtwebengine-chromium-ppc64-highway.patch` | Google Highway `ppc_vsx-inl.h`: GCC 15 removed `__builtin_vsx_xvcvspsxds`; this routes to `vec_signedo`/`vec_signede`. Required on gcc 16. |
| `qtwebengine-chromium-ppc64-skia-musttail.patch` | skcms: `clang::musttail` is advertised by GCC's `__has_cpp_attribute` but does not work on powerpc64. |
| `qtwebengine-chromium-ppc64-crashpad.patch` | `pt_regs` grew `exit_flags` in kernel 7.2 headers; this box runs 7.2.2. |
| `qtwebengine-chromium-ppc64-libvpx.patch` / `-libaom.patch` | Regenerated `linux/ppc64` configs for the bundled libvpx/libaom (system libvpx is off because VA-API is on). |

Applied on every architecture because this host needs them, not because of
ppc64le:

| Patch | Why |
|---|---|
| `qtwebengine-fix-build-against-gcc16.patch` | missing `<cstdint>` in `base/strings/to_string.h`; gcc 16.1.1 here |
| `qtwebengine-chromium-141-glibc-2.42-SYS_SECCOMP.patch` | glibc 2.43 defines `SYS_SECCOMP` as an enumerator; Chromium's `#define` collides |
| `qtwebengine-codegen-...-growbuffer.patch` | upstream V8 fix, touches only `v8/src/codegen/{ppc,s390}` |
| `qtwebengine-SIOCGSTAMP.patch` | `SIOCGSTAMP` renamed `SIOCGSTAMP_OLD` in kernel headers |
| `qtwebengine-fix-delay-signature.patch` | blink audio `Delay::ProcessARateVector` scalar fallback -- only compiled when the arch is neither x86 nor NEON, so it bit-rots and only ppc64le/riscv64 notice |

## Recipe deltas from Arch's `qt6-webengine`

* `arch=(x86_64 powerpc64le)`.
* Source is the official `qtwebengine-everywhere-src-6.11.2.tar.xz` release
  tarball instead of `git+code.qt.io/qt/qtwebengine` plus the
  `qtwebengine-chromium` submodule. Same tree, ~25 GiB less history, and it is
  the layout Fedora's patches are cut against.
* `options=(!lto)`. This host's `makepkg.conf` has `lto` in `OPTIONS`
  globally; the archpower chromium recipe disables it for the same reason
  (Chromium's GN build makes its own LTO decisions).
* `-DQT_FEATURE_pdf_v8=OFF` on ppc64le only. Carried straight from Fedora,
  whose spec says "ppc64le builds currently fail with V8/XFA enabled (qt
  6.9.0)". Not independently re-tested here -- it is plausible that 6.11.2 no
  longer needs it, and dropping it is the cheapest experiment on the list.
  QtPdf is still built, without JavaScript form support; this is the one
  functional regression against the x86_64 package.

## Trap: the Qt module version floor

WebEngine's optional Qt dependencies are looked up as
`find_package(Qt6X ${PROJECT_VERSION})`, i.e. **>= 6.11.2**. The system had
`qt6-webchannel`, `qt6-positioning`, `qt6-websockets` and `qt6-tools` at
6.11.1, so the first configure ran to completion and reported

```
Build QtWebEngineCore ................ yes
  WebChannel support ..................... no
  Geolocation ............................ no
```

-- a package that builds, installs and silently has no `QWebChannel` and no
geolocation. Nothing in the build fails. Rebuild `qt6-webchannel`,
`qt6-positioning`, `qt6-websockets` and `qt6-tools` at 6.11.2 before building
this, and check the configure summary rather than the exit code.

## What was actually verified

Measured on the AC922 (gcc 16.1.1, glibc 2.43, kernel 7.2.2, cmake 4.4.0,
ninja 1.13.2, node 26.4.0), not inferred:

* All 12 patches apply to `qtwebengine-everywhere-src-6.11.2` with zero failed
  hunks and zero fuzz -- 134 files patched, only line offsets.
* `src/3rdparty/chromium/chrome/VERSION` in that tarball is
  `MAJOR=140 MINOR=0 BUILD=7339 PATCH=225`.
* The full build completes: 22905 ninja targets, 0 `FAILED:` lines, 2399 s
  wall on 176 threads, peak build tree 17.16 GiB, and
  `tools/elf-pathguard.sh` reports `clean (15 ELF, 0 script files)`. Every
  RUNPATH is `$ORIGIN`-relative; none points into the build root.
* `readelf -d libQt6WebEngineCore.so.6.11.2` lists `libQt6WebChannel.so.6`
  and `libQt6Positioning.so.6` as `NEEDED` -- the WebChannel and geolocation
  support really is linked in, not just reported by configure.
* The package is 139,680,783 bytes and carries all seven shared libraries
  (`libQt6WebEngineCore.so.6.11.2` alone is 264 MB unstripped-of-content),
  `QtWebEngineProcess`, `webenginedriver`, `qwebengine_convert_dict`, `gn`,
  the QML plugins, `v8_context_snapshot.bin`, all four `.pak` resource files
  and the locale paks. `ldd` on every shipped ELF reports no missing sonames.
* `webenginedriver --version` runs and prints
  `WebEngineDriver 140.0.7339.225 (...refs/branch-heads/7339@{#2521})`.
* A `QWebEnginePage` smoke test (`QT_QPA_PLATFORM=offscreen`,
  `--no-sandbox --disable-gpu`) loads HTML, spawns its renderer processes,
  executes JavaScript in V8 and returns the DOM text:

      loadFinished ok=1 title="webengine-smoke"
      text="ppc64le-ok"
      EXIT=0

  One benign diagnostic on every start:
  `ERROR:content/app/content_main_runner_impl.cc:436] Failed to initialize cpuinfo`
  -- Chromium's `third_party/cpuinfo` has no ppc64 backend. Nothing downstream
  of it fails.

* The same smoke test passes with the Chromium sandbox **enabled** (only
  `--disable-gpu`): the renderer logs itself as `[1:1:...]`, i.e. it is PID 1
  in its own PID namespace, so the zygote/namespace sandbox engaged and the
  page still loaded and ran JavaScript. `sandbox/features.gni` is patched to
  set `use_seccomp_bpf` for `current_cpu == "ppc64"`, so this is the ppc64
  seccomp-bpf policy running, not a fallback.

* File-list diff against Arch's own `extra/x86_64/qt6-webengine` (618
  entries, from `archlinux.org/.../files/json/`): the ppc64le package has 608
  entries and the difference is **exactly ten**, all of them the Qt Designer
  plugin --

      usr/lib/qt6/plugins/designer/libqwebengineview.so
      usr/lib/cmake/Qt6Designer/Qt6QWebEngineViewPlugin*.cmake   (7 files)
      the two directories holding them

  Nothing else is missing and nothing extra is shipped. The Designer plugin is
  absent because `Qt6Designer` is 6.11.1 here, not because of ppc64le (see
  below).

One cosmetic blemish, not a linkage problem: 45 absolute
`/var/tmp/qtwe2/build/...` strings survive in `libQt6WebEngineCore.so` and one
in `qwebengine_convert_dict`. They are `__FILE__` literals from `Q_ASSERT` /
`qWarning` in Qt's own `src/core/*.cpp`, reachable only in assertion and log
messages. They are not in RUNPATH, RPATH or NEEDED, which is why
`elf-pathguard` passes. [INFERRED] Arch's x86_64 build bakes its own
`/build/qt6-webengine/src/...` in exactly the same places; this was not
checked against their binary.

Not verified: GPU/VA-API acceleration (headless offscreen only), whether
`pdf_v8` could now be re-enabled, and any x86_64 build of this recipe (the
non-ppc64le path is unchanged from Arch's apart from the tarball source and
the four toolchain patches).

## Verifying a build

Exit code alone is not evidence -- see the version-floor trap above.

```sh
# 1. configure summary: these must all be yes
grep -E 'Build QtWebEngineCore|WebChannel support|Geolocation|Support X11 on qpa-xcb' \
  /var/tmp/qtwe/logs/qt6-webengine.log

# 2. the package must carry the four core libraries, the QML plugin and the
#    sandbox helper process
bsdtar tf repo/qt6-webengine-*.pkg.tar.zst \
  | grep -E 'libQt6WebEngine(Core|Quick|QuickDelegatesQml|Widgets)\.so|QtWebEngineProcess|qtwebengine_resources\.pak|v8_context_snapshot\.bin'

# 3. no unresolved sonames (extract, then ldd against the staged sysroot)
ldd /path/to/extracted/usr/lib/libQt6WebEngineCore.so.6 | grep 'not found'

# 3b. runtime, headless. Extract the package plus qt6-webchannel/qt6-positioning
#     6.11.2 into one prefix, then build and run a QWebEnginePage that loads
#     inline HTML and runs JavaScript. See "What was actually verified".

# 4. no build-root paths baked into shipped ELF headers -- bq runs
#    tools/elf-pathguard.sh over $pkgdir automatically, and the recipe calls it
#    from package() as well; check the bq log for its verdict
grep -i pathguard /var/tmp/qtwe/logs/qt6-webengine.log
```

## Known gap: the Qt Designer plugin

`qt6-tools` could not be rebuilt at 6.11.2, so `Qt6Designer` stays at 6.11.1
and WebEngine's Designer plugin is not built. The cause is unrelated to
ppc64le: `qttools`' bundled `qlitehtml` wants litehtml's newer API
(`litehtml::pixel_t`, `font_description`, `background_layer`) while the build
picks up `/usr/include/litehtml0.9` from ArchPOWER's `litehtml0.9` compat
package. Building `litehtml` 0.10 into `repo/` did not displace it -- the 0.9
package still wins the cmake lookup. Fixing that is a `qt6-tools` /
`litehtml0.9` packaging job, and closing it adds those ten files with no
change to this recipe.

## Downstream

`kaccounts-integration-26.08.0-1` is already in `repo/` with an unsatisfied
runtime dependency on `signon-ui`. `signon-ui` has an Arch recipe
(`gitlab.archlinux.org/archlinux/packaging/packages/signon-ui`, `arch=(x86_64)`
so it needs `--fix-arch`); it is a small Qt widgets app whose only hard blocker
is `qt6-webengine`.
