-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

vim.keymap.set("i", "jk", "<esc>", { desc = "press jk to escape", remap = true })
vim.keymap.set("i", "jk", "<cmd>noh<cr><esc>", { desc = "Escape and clear hlsearch with jk" })

local hop = require("hop")
local directions = require("hop.hint").HintDirection
vim.keymap.set("", "s", function()
  hop.hint_words({ direction = directions.AFTER_CURSOR, current_line_only = false, hint_offset = 1 })
end, { remap = true })
vim.keymap.set("", "S", function()
  hop.hint_words({ direction = directions.BEFORE_CURSOR, current_line_only = false, hint_offset = 1 })
end, { remap = true })
