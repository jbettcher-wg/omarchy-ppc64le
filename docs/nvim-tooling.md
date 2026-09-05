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

## Related

- `package-status.md` — the full Omarchy package gap analysis.
- `../packages/neovim/` — the neovim package itself.
- `../../powerpc64le-handbook/docs/luajit-ppc64le-jit-backend.md` — the LuaJIT
  work underneath all of this. Note that the LuaJIT currently shipped lacks
  `string.buffer`, which snacks.nvim uses unguarded.
