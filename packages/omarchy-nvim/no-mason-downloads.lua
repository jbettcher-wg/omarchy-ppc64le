-- Omarchy Neovim: resolve external tools from $PATH, never from mason.
--
-- mason.nvim exists to download prebuilt binaries, and the mason registry
-- publishes x86_64 and aarch64 assets only.  On any other architecture every
-- automatic install is a download that cannot succeed, and the failure is
-- reported per tool, forever.  Porting tools one at a time does not fix that;
-- turning the automatic paths off does.
--
-- Every tool LazyVim's defaults reach for is packaged natively instead
-- (lua-language-server, gopls, marksman, stylua, shfmt, taplo, ruff,
-- rust-analyzer, clangd, yaml-language-server, bash-language-server, eslint),
-- and LazyVim's conform/lint/lspconfig integrations all prefer a binary that
-- is already on $PATH.  So the tools still resolve; they just come from
-- pacman rather than from GitHub releases.
--
-- This file is architecture-neutral: on x86_64 it only means the system
-- packages win over mason's copies, which is the behaviour a distribution
-- package should have anyway.
-- Emptying ensure_installed is NOT enough, which is what this file used to do.
-- It stops mason's own bootstrap list, but LazyVim and mason-lspconfig still ask
-- mason to install a server the moment one is configured and mason cannot see it
-- locally -- so opening a Lua file produces:
--
--   Installation failed for Package(name=lua-language-server)
--   error="The current platform is unsupported."
--
-- and it repeats on every buffer. There is no configuration of mason that makes
-- it work here, because the registry has no ppc64le assets to serve; the only
-- correct state is off. LazyVim guards its mason integration behind
-- pcall(require, "mason-lspconfig"), so disabling both is supported and lspconfig
-- falls through to servers already on $PATH -- which is where ours live.
return {
  { "mason-org/mason.nvim", optional = true, enabled = false },
  { "mason-org/mason-lspconfig.nvim", optional = true, enabled = false },
}
