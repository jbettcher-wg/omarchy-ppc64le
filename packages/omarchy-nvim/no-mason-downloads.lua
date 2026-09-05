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
return {
  {
    "mason-org/mason.nvim",
    optional = true,
    opts = function(_, opts)
      opts.ensure_installed = {}
    end,
  },
  {
    "mason-org/mason-lspconfig.nvim",
    optional = true,
    opts = function(_, opts)
      opts.ensure_installed = {}
      opts.automatic_installation = false
    end,
  },
}
