-- Gruvbox colorscheme (https://github.com/ellisonleao/gruvbox.nvim), used instead of
-- LazyVim's default (tokyonight). For the light variant set vim.o.background = "light".
return {
  {
    "ellisonleao/gruvbox.nvim",
    priority = 1000, -- load before other plugins so their colors are based on it
    opts = {},
  },
  {
    "LazyVim/LazyVim",
    opts = {
      colorscheme = "gruvbox",
    },
  },
}
