-- Gruvbox colorscheme (https://github.com/ellisonleao/gruvbox.nvim), used instead of
-- LazyVim's default (tokyonight). For the light variant set vim.o.background = "light".
--
-- While the background image is on (Kitty; ENABLED in plugins/kitty-background.lua) the
-- background is transparent so the image shows behind the code; floating windows and popup
-- menus keep a solid background so they stay readable. With the image off, the theme's own
-- background is used.

local function image_on()
  return vim.g.kitty_background_image == true
end

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

-- (checked every time a colorscheme is applied, so :KittyBackground on/off can switch it)
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("kitty_transparent_bg", { clear = true }),
  callback = function()
    if image_on() then
      clear_backgrounds()
    end
  end,
})

return {
  {
    "ellisonleao/gruvbox.nvim",
    priority = 1000, -- load before other plugins so their colors are based on it
    opts = function(_, opts)
      -- evaluated when the theme loads, after plugins/kitty-background.lua set the flag
      opts.transparent_mode = image_on()
    end,
  },
  {
    "LazyVim/LazyVim",
    opts = {
      colorscheme = "gruvbox",
    },
  },
}
