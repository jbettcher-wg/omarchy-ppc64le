-- Neovim's startup is run-once code, and LuaJIT's default policy is wrong for it.
--
-- LuaJIT begins recording a trace as soon as a loop or a function passes
-- `hotloop' (56).  Loading LazyVim's 52 plugins does that 273 times: 173
-- traces compiled and 100 recordings aborted, and almost none of that code
-- is entered again in the same session.  Measured on POWER9 with the
-- packaged neovim 0.12.5 and Omarchy's LazyVim: compilation costs 7.8 ms of
-- a 36.9 ms headless start and 7.0 ms of a 37.4 ms TUI start -- about 20 %,
-- and startup is the first thing a user sees.  Hot-counting itself is only
-- 0.3 ms of that; the rest is the compiler, running on code that is entered
-- once or twice and never pays it back.
--
-- So the JIT is off while the configuration loads and on again as soon as it
-- has.  Nothing that is hot later loses anything: the traces that matter
-- (the fuzzy matcher, the picker, treesitter, string.buffer) are compiled on
-- first use, where they are 6-118x faster than the interpreter.
--
-- This belongs in the configuration, not in LuaJIT.  `hotloop=56' is a good
-- default for a program that runs and a bad one for a program that starts,
-- and only the embedder knows which phase it is in.  Raising `hotloop'
-- globally was measured as the alternative: it recovers the same startup
-- time and costs 13-26 % on short-loop workloads, which is the wrong trade
-- for an editor that also runs a pure-Lua fuzzy matcher.
--
-- Usage, in init.lua:
--     local ljit = require("config.jit_startup")
--     ljit.off()
--     require("config.lazy")
--     ljit.on()
--
-- on() is also armed on VimEnter, so the JIT comes back even if init.lua
-- errors out before reaching it.
local M = { armed = false }

function M.off()
  if jit and jit.status and jit.status() then
    jit.off()
    M.armed = true
    vim.api.nvim_create_autocmd("VimEnter", {
      once = true,
      callback = function() M.on() end,
    })
  end
end

function M.on()
  if M.armed then
    M.armed = false
    jit.on()
  end
end

return M
