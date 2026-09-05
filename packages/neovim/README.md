# neovim

Placeholder — not yet packaged.

Omarchy does not use Arch's `neovim`; it ships its own `nvim` package plus
`omarchy-nvim` (the LazyVim configuration). Both come from Omarchy's own package
repo, so neither has an Arch or AUR PKGBUILD to start from — see
`../../docs/package-status.md`.

This is the package that consumes our LuaJIT work: neovim embeds LuaJIT, and on
this machine that is currently the JIT-less 2017 fork. Sequencing is therefore:

1. Land the rebased LuaJIT (`../luajit`) — done as interpreter+FFI on a 2026 core.
2. Implement the ppc64le JIT backend in `../../../luajit-ppc64le`.
3. Package Omarchy's `nvim` against it, and verify `jit.status()` is true from
   inside neovim, not just from the `luajit` binary.

Watch for: `gamescope-git` already depends on `luajit`, so an ABI or soname
change to that package has a downstream consumer on this box.
