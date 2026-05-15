-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

local map = vim.keymap.set

vim.keymap.set("i", "jk", "<esc>", { desc = "press jk to escape", remap = true })
vim.keymap.set("i", "jk", "<cmd>noh<cr><esc>", { desc = "Escape and clear hlsearch with jk" })

-- Resize window using Alt + hjkl
map("n", "<M-k>", "<cmd>resize +2<cr>", { desc = "Increase Window Height" })
map("n", "<M-j>", "<cmd>resize -2<cr>", { desc = "Decrease Window Height" })
map("n", "<M-h>", "<cmd>vertical resize -2<cr>", { desc = "Decrease Window Width" })
map("n", "<M-l>", "<cmd>vertical resize +2<cr>", { desc = "Increase Window Width" })

-- Resize window using <C-w><C-h/l/j/k> (hold Ctrl while pressing direction after C-w)
map("n", "<C-w><C-h>", "<cmd>vertical resize -4<cr>", { desc = "Decrease Window Width" })
map("n", "<C-w><C-l>", "<cmd>vertical resize +4<cr>", { desc = "Increase Window Width" })
map("n", "<C-w><C-j>", "<cmd>resize -4<cr>", { desc = "Decrease Window Height" })
map("n", "<C-w><C-k>", "<cmd>resize +4<cr>", { desc = "Increase Window Height" })

-- Database UI toggle
map("n", "<leader>D", "<cmd>DBUI<cr>", { desc = "Open Database UI" })

-- Find Files (cwd) overrides live in lua/plugins/snacks.lua so they win over LazyVim's lazy keys.

-- local hop = require("hop")
-- local directions = require("hop.hint").HintDirection
-- vim.keymap.set("", "s", function()
--   hop.hint_words({ direction = directions.AFTER_CURSOR, current_line_only = false, hint_offset = 1 })
-- end, { remap = true })
-- vim.keymap.set("", "S", function()
--   hop.hint_words({ direction = directions.BEFORE_CURSOR, current_line_only = false, hint_offset = 1 })
-- end, { remap = true })
