-- Faded image behind the code while Neovim runs in Kitty (lua/resources/though_cabinet.jpg).
--
-- Neovim draws it itself with Kitty's graphics protocol, *below* the text and every colored
-- cell (z-index under the cell backgrounds), so it only shows where Neovim's background is
-- transparent (see plugins/colorscheme.lua). No Kitty remote control is needed, and the image is
-- gone as soon as Neovim exits (it lives on Neovim's alternate screen).
--
-- Kitty can't fade images itself, so a faded copy is made once with ImageMagick and cached.
-- :KittyBackground redraws it if it ever disappears (e.g. after :redraw!).

local IMAGE = vim.fn.stdpath("config") .. "/lua/resources/though_cabinet.jpg"
local FADE = 85 -- % blended toward the background color: higher = fainter image, easier reading
local BG = "#282828" -- gruvbox dark background
local CELL_ASPECT = 2.1 -- terminal cell height / width (used to crop the image to the window)
local ID = 4242 -- Kitty image id

if not vim.env.KITTY_WINDOW_ID or vim.fn.executable("magick") == 0 or not vim.uv.fs_stat(IMAGE) then
  return {} -- not in Kitty, no ImageMagick, or no image
end

local faded -- { path, width, height }

local function send(keys, payload)
  local seq = "\27_G" .. keys .. (payload and (";" .. payload) or "") .. "\27\\"
  pcall(vim.api.nvim_ui_send, seq)
end

--- Faded, downscaled PNG of IMAGE (cached by image, size and fade).
local function prepare(cb)
  local stat = vim.uv.fs_stat(IMAGE)
  local key = vim.fn.sha256(IMAGE .. stat.mtime.sec .. stat.size .. FADE .. BG):sub(1, 12)
  local out = vim.fn.stdpath("cache") .. "/kitty-background-" .. key .. ".png"
  local function measure()
    local res = vim.system({ "magick", "identify", "-format", "%w %h", out }, { text = true }):wait()
    local w, h = (res.stdout or ""):match("(%d+) (%d+)")
    if w then
      faded = { path = out, width = tonumber(w), height = tonumber(h) }
      cb()
    end
  end
  if vim.uv.fs_stat(out) then
    return measure()
  end
  vim.system({ "magick", IMAGE, "-resize", "2560x2560>", "-fill", BG, "-colorize", FADE .. "%", out }, {}, function(res)
    if res.code == 0 then
      vim.schedule(measure)
    end
  end)
end

--- (Re)draw the image over the whole window, cropped to cover it (like a wallpaper).
local function place()
  if not faded then
    return
  end
  local cols, rows = vim.o.columns, vim.o.lines
  local target = cols / (rows * CELL_ASPECT) -- window width / height
  local iw, ih = faded.width, faded.height
  local x, y, w, h = 0, 0, iw, ih
  if iw / ih > target then
    w = math.floor(ih * target)
    x = math.floor((iw - w) / 2)
  else
    h = math.floor(iw / target)
    y = math.floor((ih - h) / 2)
  end
  send(("a=d,d=i,i=%d,q=2"):format(ID)) -- remove the previous placement (keeps the image data)
  -- save cursor, go to the top-left corner, place without moving the cursor, restore cursor
  pcall(vim.api.nvim_ui_send, "\0277\27[1;1H")
  send(("a=T,t=f,f=100,i=%d,q=2,C=1,z=-1073741825,c=%d,r=%d,x=%d,y=%d,w=%d,h=%d"):format(ID, cols, rows, x, y, w, h),
    vim.base64.encode(faded.path))
  pcall(vim.api.nvim_ui_send, "\0278")
end

local function hide(forget)
  -- d=I also frees the image data; d=i only removes it from the screen
  send(("a=d,d=%s,i=%d,q=2"):format(forget and "I" or "i", ID))
end

--- Draw after Neovim has finished redrawing (a full redraw clears the screen, which removes images).
local function place_later(delay)
  vim.defer_fn(place, delay or 80)
end

local group = vim.api.nvim_create_augroup("kitty_background_image", { clear = true })
vim.api.nvim_create_autocmd("UIEnter", {
  group = group,
  callback = function()
    prepare(function()
      place_later(150)
    end)
  end,
})
vim.api.nvim_create_autocmd({ "VimResized", "VimResume", "ShellCmdPost", "TermLeave" }, {
  group = group,
  callback = function()
    place_later()
  end,
})
vim.api.nvim_create_autocmd("VimSuspend", {
  group = group,
  callback = function()
    hide(false)
  end,
})
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = group,
  callback = function()
    hide(true)
  end,
})
vim.api.nvim_create_user_command("KittyBackground", function()
  if faded then
    place()
  else
    prepare(place)
  end
end, { desc = "Redraw the background image" })

return {}
