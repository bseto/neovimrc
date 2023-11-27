-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

vim.keymap.set("i", "jk", "<esc>", { desc = "press jk to escape", remap = true })
vim.keymap.set("i", "jk", "<cmd>noh<cr><esc>", { desc = "Escape and clear hlsearch with jk" })
