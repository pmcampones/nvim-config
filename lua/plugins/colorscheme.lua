-- Gruvbox colorscheme (https://github.com/ellisonleao/gruvbox.nvim), used instead of
-- LazyVim's default (tokyonight). For the light variant set vim.o.background = "light".
--
-- Inside Kitty the background is transparent, so Kitty's background image (configured in
-- ~/.config/kitty/kitty.conf, from lua/resources/) shows behind the code. Floating windows
-- and popup menus keep a solid background so they stay readable.

local in_kitty = vim.env.KITTY_WINDOW_ID ~= nil

-- Panels that otherwise paint their own background over the image
local CLEAR_BG = {
  "Normal", "NormalNC", "SignColumn", "FoldColumn", "LineNr", "CursorLineNr", "EndOfBuffer",
  "NeoTreeNormal", "NeoTreeNormalNC", "NeoTreeEndOfBuffer", "WinBar", "WinBarNC",
  "StatusLine", "StatusLineNC", "TabLineFill",
}

local function clear_backgrounds()
  for _, group in ipairs(CLEAR_BG) do
    local hl = vim.api.nvim_get_hl(0, { name = group, link = false })
    hl.bg = nil
    hl.ctermbg = nil
    vim.api.nvim_set_hl(0, group, hl)
  end
  -- keep floating windows (hover docs, pickers, notifications) solid over the image
  local float_bg = vim.o.background == "light" and "#ebdbb2" or "#3c3836"
  for _, group in ipairs({ "NormalFloat", "FloatBorder", "FloatTitle" }) do
    local hl = vim.api.nvim_get_hl(0, { name = group, link = false })
    hl.bg = float_bg
    vim.api.nvim_set_hl(0, group, hl)
  end
end

if in_kitty then
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("kitty_transparent_bg", { clear = true }),
    callback = clear_backgrounds,
  })
end

return {
  {
    "ellisonleao/gruvbox.nvim",
    priority = 1000, -- load before other plugins so their colors are based on it
    opts = {
      transparent_mode = in_kitty,
    },
  },
  {
    "LazyVim/LazyVim",
    opts = {
      colorscheme = "gruvbox",
    },
  },
}
