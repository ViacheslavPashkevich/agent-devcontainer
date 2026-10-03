-- The devcontainer's editor default, baked into the image; see README.md
-- ("Shell, editor and clipboard"). /etc/xdg/nvim is on nvim's system
-- runtimepath and lives outside /home/dev, so the home volume cannot shadow
-- it; the operator's own ~/.config/nvim is sourced first and the guard below
-- backs off to it. A plugin/ file rather than init-level config so it loads
-- however nvim is invoked, with `nvim -u NONE` as the escape hatch.
--
-- Copy-only OSC 52: yanks to the + / * registers reach the attached terminal's
-- clipboard. Register paste is deliberately unsupported -- an OSC 52 read
-- would hang or prompt, and a local replay cache misleads (one cache per
-- session, not per register) -- so "+p / "*p fail fast with E353 and pasting
-- is the terminal's own keystroke. Set g:clipboard yourself (in
-- ~/.config/nvim) and this file backs off entirely.
if vim.g.clipboard ~= nil then
  return
end

local osc52 = require('vim.ui.clipboard.osc52')

-- The paste table is not optional: nvim rejects a g:clipboard without one
-- and the copy side stops working too. These callbacks are the minimal
-- lawful implementation -- non-blocking, never querying the terminal --
-- and their empty result makes nvim raise E353 ("Nothing in register") on
-- any register paste, which is the intended surfacing of "unsupported".
-- Only explicit "+p / "*p reach them: plain p reads the unnamed register,
-- which holds the yanked text even straight after a "+y, so ordinary
-- in-nvim yank/paste is untouched.
local function unsupported_paste()
  return { {}, '' }
end

vim.g.clipboard = {
  name = 'OSC 52 (copy only)',
  copy = {
    ['+'] = osc52.copy('+'),
    ['*'] = osc52.copy('*'),
  },
  paste = {
    ['+'] = unsupported_paste,
    ['*'] = unsupported_paste,
  },
}
