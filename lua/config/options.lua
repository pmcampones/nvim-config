-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here

-- Indent with 2 spaces everywhere (LazyVim's default), and stop Neovim's built-in
-- language style guides from switching Rust and Python back to 4 spaces.
-- Go and Makefiles keep real tabs (gofmt and make require them), shown 2 columns wide.
vim.opt.shiftwidth = 2
vim.opt.tabstop = 2
vim.opt.softtabstop = 2
vim.opt.expandtab = true
vim.g.rust_recommended_style = 0
vim.g.python_recommended_style = 0
