-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here

vim.g.mapleader = ","
vim.opt.colorcolumn = "80,100"
vim.g.snacks_animate = false
vim.keymap.set("n", "<C-w>.", "<C-w><", { noremap = true, silent = true })
vim.keymap.set("n", "<C-w>,", "<C-w>>", { noremap = true, silent = true })
