# Neovim tooling on ppc64le

What Omarchy's editor needs beyond `neovim` itself, and why most of it is a
PKGBUILD rather than a port.

## The finding

`omarchy-nvim` is declared `arch=any`, but it is not. Unpacking
`omarchy-nvim-2026.8.13-1-any.pkg.tar.zst` from `pkgs.omarchy.org`:

| Path | Size | Contents |
|---|---:|---|
| `usr/share/omarchy-nvim/config` | 304K | pure Lua — portable |
| `etc/skel/.local/share/nvim/lazy` | 157M | vendored plugin clones — pure Lua, portable |
| `etc/skel/.local/share/nvim/mason` | 11M | **vendored x86-64 binaries** |

Every ELF object in the package is x86-64, and there are only two of them:

| Tool | Vendored as | Language | ppc64le |
|---|---|---|---|
| `stylua` | `mason/packages/stylua/stylua` | Rust | builds |
| `shfmt` | `mason/packages/shfmt/shfmt_v3.13.1_linux_amd64` | Go | builds; already in Arch `extra` |

So the entire binary surface of Omarchy's default editor is **two tools, both in
languages with first-class ppc64le backends**. Rebuild them, mark the package
`arch=(x86_64 powerpc64le)`, and the default configuration is portable.

The enabled LazyVim extras are minimal — `lazyvim.json` lists exactly one,
`lazyvim.plugins.extras.editor.neo-tree` — so the default install pulls no
language packs and therefore no further tooling.

## The structural problem, which is not per-tool

Mason exists to **download prebuilt binaries**, and its registry publishes
x86_64 and aarch64 assets only. Any LazyVim extra a user enables later will make
mason reach for an asset that does not exist for this architecture. Porting tools
one at a time does not fix that; it just delays it.

The durable fix is configuration, not packaging: disable mason's automatic
installation and let the tools resolve from `PATH`, so system packages satisfy
them. LazyVim uses a language server if its binary is already present.

## Tooling likely to be wanted, by build system

None of these are ports. They are builds — the languages all target ppc64le.

| Tool | Language | Notes |
|---|---|---|
| `stylua`, `taplo`, `ruff`, `rust-analyzer`, `tree-sitter-cli` | Rust | `tree-sitter-cli` is already in Omarchy's base list |
| `shfmt`, `gopls` | Go | |
| `lua-language-server` | C++ / Lua | |
| `clangd` | C++ | ships with LLVM, already present |
| `typescript-language-server`, `vtsls`, `yaml-language-server`, `bash-language-server`, `prettier`, `eslint` | Node | architecture-independent JS; needs only a working node, which exists |
| `black`, `isort` | Python | architecture-independent |
| `marksman` | .NET | the one genuine question mark — a runtime is packaged for ppc64le, but this tool is untested |

## Why this is cheap

Every one of these languages has a maintained ppc64le backend, so the work is
`arch=()` plus a compile. That is the same pattern as the rest of this port: the
substrate is first class, and what breaks is code that was never told the
architecture is allowed.

The exception is `marksman`, and the exception proves the rule — it is the only
entry whose *toolchain* is in question rather than its packaging.

## Status: built and verified

Every tool in the table above now exists as a native ppc64le package in
`../repo/`, except three. All were verified by running them.

| Tool | Version | Change needed |
|---|---|---|
| `stylua` | 2.5.2 | `arch()` |
| `shfmt` | 3.13.1 | `arch()` |
| `taplo-cli` | 0.10.0 | `arch()` |
| `gopls` | 0.23.0 | `arch()` |
| `lua-language-server` | 3.19.1 | `arch()` |
| `marksman` | 2026-02-08 | see below |
| `yaml-language-server` | 1.24.0 | none — `arch=any` |
| `bash-language-server` | 5.6.0 | none — `arch=any` |
| `eslint` | 10.10.0 | none — `arch=any` |
| `ruff`, `rust-analyzer`, `python-black`, `python-isort`, `tree-sitter-cli`, `clangd` | — | already in Arch POWER |

### marksman: the question mark, answered

It works. Arch POWER packages .NET 9 for powerpc64le and `dotnet --info` reports
`RID: linux-ppc64le`, so the runtime is genuinely there. Three things stood
between that and a working package, and only one was a portability bug:

1. **`global.json` pins SDK `9.0.100` with `rollForward: latestFeature`.** Arch
   POWER's newest is `9.0.100-rc.2`, and a prerelease sorts *below* the matching
   release, so rollForward — which only rolls forward — can never reach it, and
   `allowPrerelease` does not help. `global.json` is removed; the project targets
   `net9.0` and the SDK is a 9.0.1xx, so the real constraint still holds.
2. **The Makefile maps `uname -m` to a .NET RID and has no ppc64le case**, so
   `RID` became `linux-` and the build died with `NETSDK1083` far downstream.
   Fixed by `0001-Makefile-recognise-ppc64le-riscv64-and-s390x.patch`, which is
   worth sending upstream.
3. **Self-contained publishing is impossible here.** `make publish` asks for a
   trimmed single-file binary, which makes NuGet fetch
   `Microsoft.AspNetCore.App.Runtime.linux-ppc64le` from nuget.org. Microsoft
   publishes no ppc64le runtime pack — Arch POWER's .NET is a community build —
   so the package does a framework-dependent publish instead and depends on
   `dotnet-runtime`. That is a real difference from the x86_64 package, not a
   workaround for a bug.

### Parked

| Tool | Why | Size of the remaining problem |
|---|---|---|
| `prettier` 3.8.1 | its pinned `oxc-parser` 0.99.0 has no ppc64le native binding. **The binding exists** — `@oxc-parser/binding-linux-ppc64-gnu` is published on npm — but only from 0.104.0 onward. | wait for a prettier that pins oxc-parser ≥ 0.104, or override the resolution and accept the API drift. Not a porting problem; a version-window problem that closes on its own. |
| `typescript-language-server` 6.0.0 | needs `pnpm` 11 for its lockfile. pnpm 11 ships as a per-platform native executable and resolves `@pnpm/exe.linux-ppc64`, which does not exist. pnpm 9 runs fine (pure JS) but rejects the v11 lockfile as `ERR_PNPM_LOCKFILE_CONFIG_MISMATCH`. | needs a ppc64le `@pnpm/exe`, or regenerating the lockfile under pnpm 9. Circular rather than hard. |
| `vtsls` | not packaged by Arch at all | out of scope here |

Note the shape of both parked cases: neither is a compiler or an architecture
problem. Both are *prebuilt-binary distribution* problems in the npm ecosystem —
the same structural issue as mason, described above, one layer down.

## Outcome: the durable fix is in the package

`omarchy-nvim` is now built for this repo, and both halves of the finding above
are acted on rather than described:

- The two vendored x86-64 binaries are gone. `mason/packages/stylua/stylua` and
  `mason/packages/shfmt/shfmt_v3.13.1_linux_amd64` are now symlinks to
  `/usr/bin/stylua` and `/usr/bin/shfmt`, so mason's own `bin/` links still
  resolve and its receipts still describe the world it thinks it is in, but
  what runs is the native build. The package contains **zero** ELF objects, so
  `arch=any` is now true rather than a claim, and the architecture dependence
  lives in `depends=(stylua shfmt)`.
- `no-mason-downloads.lua` ships in both copies of the config the package owns
  (`/etc/skel/.config/nvim/lua/plugins/` and
  `/usr/share/omarchy-nvim/config/lua/plugins/`) and empties mason's
  `ensure_installed` and turns `automatic_installation` off. Tools then resolve
  from `$PATH`, where every packaged language server and formatter already is.

Verified from the built package, in a real pty session: `stylua 2.5.2` and
`shfmt v3.13.1` resolve through mason's `bin/` links to the native binaries,
`:checkhealth mason-lspconfig` is clean, and `lua-language-server` attaches to
a Lua buffer from `$PATH` and answers hover and `documentSymbol`.

`check()` in the PKGBUILD fails the build if upstream ever vendors a third
binary, so this does not silently rot.

### Still parked

`prettier` and `typescript-language-server` are unchanged from the analysis
above — both are npm prebuilt-binary distribution problems, not architecture
problems, and neither is on LazyVim's default path with only the `neo-tree`
extra enabled.

## Related

- `package-status.md` — the full Omarchy package gap analysis.
- `../packages/neovim/` — the neovim package itself.
- `../../powerpc64le-handbook/docs/luajit-ppc64le-jit-backend.md` — the LuaJIT
  work underneath all of this. As of the `luajit` package in this repo,
  `jit.status()` is true inside neovim and `string.buffer` is present, so
  snacks.nvim's unguarded `require("string.buffer")` is satisfied.
