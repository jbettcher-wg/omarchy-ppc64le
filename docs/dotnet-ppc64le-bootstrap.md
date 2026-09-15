# Bootstrapping .NET on ppc64le from source

How to get a source-built .NET 10 SDK on a ppc64le Linux machine that has no
.NET yet, and how to stop depending on anyone else's binaries after the first
build. Written from the Arch POWER recipe in `packages/dotnet/dotnet-core`, but nothing
here is specific to Arch: the same steps apply on Debian, Fedora, Void, Gentoo
or a bare `./build.sh` checkout.

## Why a seed is unavoidable

.NET is built from the VMR, `github.com/dotnet/dotnet`. A source-build of
version N needs two things from version N-1, **for the same CPU architecture**:

1. **A working .NET SDK.** MSBuild, Roslyn and NuGet are .NET programs. There is
   no C/C++-only path to the first SDK.
2. **`Private.SourceBuilt.Artifacts.<N-1>.<rid>.tar.gz`.** The NuGet packages
   the previous source-build produced: Arcade, the reference packs, ILAsm and
   ILDAsm, the runtime packs. The build restores from it instead of nuget.org.

The source tag names its N-1 in `eng/Versions.props`:

```xml
<PrivateSourceBuiltSdkVersion>10.0.111-servicing.26373.116</PrivateSourceBuiltSdkVersion>
<PrivateSourceBuiltArtifactsVersion>10.0.111-servicing.26373.116</PrivateSourceBuiltArtifactsVersion>
```

That is tag `v10.0.112`, which is .NET runtime 10.0.12 and SDK 10.0.112.

On x86_64 and aarch64, `prep-source-build.sh` downloads both from Microsoft
(`builds.dotnet.microsoft.com/dotnet/source-build/`). **Microsoft publishes
neither for ppc64le.** An x86_64 SDK cannot serve as the seed: the build runs
the SDK natively, and the artifacts must contain `linux-ppc64le` runtime and
host packs.

## Mono, not CoreCLR

CoreCLR has no ppc64le JIT. `src/runtime/eng/Subsets.props` marks ppc64le and
s390x as not CoreCLR-capable, so the primary runtime flavor becomes **Mono**.
Pass `--use-mono-runtime` to `build.sh` anyway, as IBM and Fedora do: it also
stops `repo-projects/runtime.proj` from trying to build every runtime pack.

Don't judge the flavor by file names. The Mono shared framework ships Mono
**as `libcoreclr.so`**, so the host (`libhostpolicy.so`) can load it the way it
loads CoreCLR. Check the symbols instead:

```sh
lib=shared/Microsoft.NETCore.App/10.0.12/libcoreclr.so
nm -D --defined-only $lib | grep -c ' mono_'      # >1000 on Mono, 0 on CoreCLR
ls shared/Microsoft.NETCore.App/10.0.12/ | grep clrjit   # CoreCLR only; empty on Mono
```

In the 10.0.12 build here that gives 1,304 exported `mono_*` symbols
(`mono_jit_init` among them), a `coreclr_initialize` hosting shim, and no
`libclrjit.so`. IBM's 10.0.111 seed has the same layout.

Consequences worth knowing:

- The built SDK's `packs/` holds only `Microsoft.NETCore.App.Ref`,
  `Microsoft.AspNetCore.App.Ref` and `Microsoft.NETCore.App.Host.<rid>`. There
  is no Crossgen2 or ILCompiler pack, so ReadyToRun and NativeAOT publishing
  aren't available offline. Code is JIT-compiled by Mono at run time.
- Framework-dependent apps are the normal case. The native apphost works: a
  `dotnet new console` app runs both through `dotnet run` and as
  `bin/Debug/net10.0/<name>`.

### Mono's ppc64 JIT and native structs (patch needed)

Stock Mono (at least through dotnet/runtime `main` in September 2026) gets two
ELFv2 rules wrong on ppc64le, and IBM's builds carry the same code:

- **Small aggregate returns.** Every struct return goes through a hidden
  pointer in r3. ELFv2 returns structs of 16 bytes or less in r3/r4, and
  homogeneous float/double aggregates of up to 8 members in f1..f8. Any
  P/Invoke or `[UnmanagedCallersOnly]` callback returning such a struct gets
  every argument shifted one register. A `CULong` return counts, since `CULong`
  is a struct.
- **Small struct arguments.** A struct of under 8 bytes is loaded as a whole
  doubleword, so the bytes after it land in the register. GCC callees rely on
  64-bit extension of narrow integers, and bindings wrap C scalars in one-field
  structs.

GirCore-based GTK apps (pinta) die at startup on both, with "Could not connect to
event OnStartup" and then "... OnActivate". The fix is
`packages/dotnet/dotnet-core/mono-ppc64le-elfv2-small-aggregates.patch`. It applies to
dotnet/runtime `src/mono` as well as to the VMR's `src/runtime`, is written to be
sent upstream, and its header lists the rules and the GCC-checked test matrix.
Apply it on any ppc64le source-build of .NET 10.

### Mono and static virtual members implemented by interfaces (all architectures)

With the ELFv2 patch, pinta starts but New, Open and About do nothing. The
cause is not ppc64le-specific. GirCore makes binding interfaces implement a
static member of another interface: `Gtk.SelectionModel` implements
`GObject.GTypeProvider.GetGType()`. `Signal<TSender, …>.GetId()` then calls
`TSender.GetGType()` with `TSender` set to that interface.

Mono resolves a constrained call whose type argument is an interface to the
declaration, which for a static abstract member has no body:

- `BadImageFormatException: Method has no body` in non-shared code
- an assertion abort in `mini_instantiate_gshared_info` in shared generic code
- silently the base body when a static virtual default is overridden

Pinta hits the first one while building its main window, before it creates its
action handlers, and no error dialog exists yet to report it. This is
dotnet/runtime #82217, closed as a duplicate of the still-open #79331 and
unfixed in `main`.
`packages/dotnet/dotnet-core/mono-static-virtual-interface-constraint.patch` resolves
the implementation from the constraining interface's MethodImpls. Any Mono-based
.NET (Android, iOS, wasm, s390x, ppc64le) running GirCore apps needs it.

## Where the seed comes from: IBM

IBM builds .NET for s390x **and ppc64le** and publishes each release at

    https://github.com/IBM/dotnet-s390x/releases

The repository name says s390x. The releases carry ppc64le assets too. Release
`v10.0.111` (2026-08-19) carries, among others:

| asset | sha256 |
|---|---|
| `dotnet-sdk-10.0.111-linux-ppc64le.tar.gz` | `0e887493a69ff21d4bf9bbdb7e2487f5995c8a772271c47ecf065b732b55cf3b` |
| `Private.SourceBuilt.Artifacts.10.0.111-servicing.linux-ppc64le.tar.gz` | `1c39b88c0056176075c040af4b2ab2dc4cee68ecba60d8f69f5d468dfb25b263` |

**Verification.** IBM publishes no signatures, no checksum files and no release
notes for these assets. The only integrity information is the SHA-256 digest
GitHub computes when an asset is uploaded, exposed by the releases API:

```sh
curl -s https://api.github.com/repos/IBM/dotnet-s390x/releases/tags/v10.0.111 \
  | jq -r '.assets[] | "\(.digest)  \(.name)"'
```

The values above were downloaded, hashed locally and matched against that
field. This proves the files are the ones on the release page. It does not
prove who built them. That is the reason to use the seed exactly once and then
self-host.

IBM's seed is a **portable** build (`linux-ppc64le` RID, `-p:PortableBuild=true`,
Mono). Its artifacts tarball already contains `Microsoft.NETCore.App.Runtime.linux-ppc64le`,
`Microsoft.NETCore.App.Host.linux-ppc64le`, `Microsoft.AspNetCore.App.Runtime.linux-ppc64le`
and the `runtime.linux-ppc64le.*` ILAsm/ILDAsm/AppHost packages. So
`prep-source-build.sh`'s "bootstrap" step, which re-downloads Microsoft-built
portable packs from nuget.org, is both unnecessary and impossible. Skip it with
`--no-bootstrap`.

## Picking the right seed

The seed must match the source tag's `PrivateSourceBuiltSdkVersion` prefix:

| building tag | runtime / SDK | needs N-1 | IBM release |
|---|---|---|---|
| `v10.0.112` | 10.0.12 / 10.0.112 | 10.0.111 | `v10.0.111` |
| `v10.0.113` | 10.0.13 / 10.0.113 | 10.0.112 | `v10.0.112`, or your own 10.0.112 build |

Read it from the tag you intend to build:

```sh
curl -fsSL https://raw.githubusercontent.com/dotnet/dotnet/v10.0.112/eng/Versions.props \
  | grep PrivateSourceBuiltSdkVersion
```

A feature-band mismatch (for example seeding 10.0.2xx with a 10.0.1xx SDK) is
not supported. Within a band, the artifacts' `PackageVersions.props` is what
the build actually consumes, so use the matching release rather than "close
enough".

## The build, distro-neutral

```sh
git clone https://github.com/dotnet/dotnet.git && cd dotnet
git checkout v10.0.112

# seed
mkdir -p ../stage0-sdk prereqs/packages/archive
tar -xzf ../dotnet-sdk-10.0.111-linux-ppc64le.tar.gz -C ../stage0-sdk
ln -s "$PWD/../Private.SourceBuilt.Artifacts.10.0.111-servicing.linux-ppc64le.tar.gz" \
      prereqs/packages/archive/

# no SDK download, no nuget.org bootstrap; removes non-allowed binaries
./prep-source-build.sh --no-sdk --no-bootstrap --with-sdk "$PWD/../stage0-sdk"

./build.sh --source-build --clean-while-building --online \
           --use-mono-runtime --with-sdk "$PWD/../stage0-sdk"
```

Outputs, in `artifacts/assets/Release/`:

- `dotnet-sdk-10.0.112-<rid>.tar.gz`: the SDK, runtime, ASP.NET Core runtime and packs.
- `Private.SourceBuilt.Artifacts.10.0.112-<...>.<rid>.tar.gz`: **your** seed for 10.0.13.

Notes:

- **The stage-0 SDK is written to** during the build. Give it a copy, never
  `/usr/share/dotnet` or `/usr/lib64/dotnet` directly.
- **The RID** is non-portable by default, `<ID>[.<VERSION_ID>]-ppc64le` from
  `/etc/os-release` (see `eng/common/native/init-distro-rid.sh`). Rolling
  distros drop the version: Arch POWER (`ID=arch`) gets `arch-ppc64le`. The
  build adds that RID to the RID graph it ships, with `linux-ppc64le` as its
  parent. Override with `--rid` / `/p:TargetRid=` if your `ID` is something
  unhelpful.
- **Compiler.** Native parts build with clang. `eng/common/native/init-compiler.sh`
  accepts clang up to a date-derived maximum (23 in September 2026). Clang 21
  and newer add warnings to `-Wall` that the runtime's `-Werror` trips on. Pass
  `-Wno-unknown-warning-option -Wno-jump-misses-init -Wno-implicit-void-ptr-cast -Wno-implicit-int-enum-cast`
  through `EXTRA_CFLAGS` / `EXTRA_CXXFLAGS`, as Fedora does.
- **`-fstack-clash-protection`** must be removed from CFLAGS (breaks the runtime),
  and `_FORTIFY_SOURCE=3` lowered to 2 (`malloc_usable_size`).
- **`--online`** lets NuGet reach nuget.org for the few prebuilts the tag still
  allows. An offline build needs `Private.SourceBuilt.Prebuilts` as well, if the
  tag names one.
- Keep `HOME` pointed somewhere disposable. The SDK writes `~/.dotnet`,
  `~/.nuget` and `~/.local/share/NuGet`.

## After the first build: self-hosting

Install (or just unpack somewhere) the SDK tarball you built, and keep your
artifacts tarball. From now on, build N+1 with **your** N:

```sh
mkdir -p ../stage0-sdk
cp -a /usr/share/dotnet/. ../stage0-sdk/        # your 10.0.112, copied
ln -s /usr/share/dotnet/source-built-artifacts/Private.SourceBuilt.Artifacts.10.0.112-*.tar.gz \
      prereqs/packages/archive/
./prep-source-build.sh --no-sdk --no-bootstrap --with-sdk "$PWD/../stage0-sdk"
./build.sh --source-build --clean-while-building --online --use-mono-runtime --with-sdk "$PWD/../stage0-sdk"
```

IBM is then out of the chain. Lose your N and you need a seed again. Keep the
artifacts tarball packaged. Arch installs it as `dotnet-source-built-artifacts`
under `/usr/share/dotnet/source-built-artifacts/`, and Fedora under
`%{_libdir}/dotnet/source-built-artifacts/`.

If you skip a release (have 10.0.112, want 10.0.115), build the intermediate
tags in order, or seed from the matching IBM release again.

## How the Arch recipe automates this

`packages/dotnet/dotnet-core/PKGBUILD` has a `_bootstrap` switch, default `auto`,
evaluated when the PKGBUILD is sourced:

| host state | `auto` becomes | effect |
|---|---|---|
| `/usr/share/dotnet/sdk/$_seed_sdkver/` **and** `source-built-artifacts/Private.SourceBuilt.Artifacts.$_seed_sdkver-*.tar.gz` | `0`, self-host | `makedepends+=(dotnet-sdk dotnet-source-built-artifacts)`, no external downloads |
| no 10.0 SDK and no artifacts tarball | `1`, seed | IBM's two tarballs added to `source=()` with pinned sha256 and b2 sums |
| a 10.0 SDK or artifacts tarball of **another** version | hard error | names the version needed; never silently builds with a mismatched SDK |

Override from the environment: `_bootstrap=1 makepkg` forces the seed,
`_bootstrap=0 makepkg` forces self-hosting (and fails in `prepare()` if the
toolchain is missing). `_seed_sdkver` is pinned in the recipe because the
source tag is not available at sourcing time. `prepare()` checks it against
`eng/Versions.props` and refuses to continue on a mismatch.

What was checked, not assumed: with no .NET SDK on the host (only an old
9.0 runtime), `auto` picks the seed. Against the fake 10.0.111 toolchain it
picks self-hosting. Against the real 10.0.112 output of the first build
(`sdk/10.0.112/` and `Private.SourceBuilt.Artifacts.10.0.112-servicing.arch-ppc64le.tar.gz`)
it hard-errors for tag `v10.0.112` and names 10.0.111. That's the right answer
for rebuilding this version, and the same files are what `auto` will find
when building `v10.0.113`.

**Rebuilding the same version** (a `pkgrel` bump) is therefore always a
`_bootstrap=1` build once that version's SDK exists anywhere `auto` can see it.
That includes build sandboxes. This repo's `tools/bq.py` restages every package
in `repo/` into its sysroot overlay, so the first 10.0.12 package makes
`/usr/share/dotnet/sdk/10.0.112/` visible to the next 10.0.12 build. The
pkgrel-2 rebuild here stopped with exactly the hard error above and was rerun as
`_bootstrap=1`. A source-build cannot seed itself from its own version.

Because `auto` reads the host, `source=()` and `makedepends=()`, and therefore
`.SRCINFO`, differ between machines. Generate a `.SRCINFO` on a machine without
.NET (or with `_bootstrap=1`), since that matches a fresh machine.

Seed checksums stay enforced: they are ordinary `source=()` entries, so a
changed or corrupt download fails `makepkg --verifysource` before `prepare()`.
A deliberately altered sha256 was checked to produce `FAILED` / `One or more
files did not pass the validity check!`.

To move the recipe to a new version:

1. bump `pkgver`, update the git `b2sums` entry (`makepkg -g`);
2. set `_seed_sdkver` to the new tag's `PrivateSourceBuiltSdkVersion` prefix;
3. if you will seed from IBM rather than self-host, replace the two seed
   checksums with that release's asset digests.
