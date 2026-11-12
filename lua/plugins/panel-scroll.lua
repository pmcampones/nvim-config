-- Mouse-wheel scrolling in the explorer (Project / Commit tabs) and the commit message box stops
-- at the edges of the content, like IntelliJ: no scrolling down past the last line, nor sideways
-- past the longest visible line (Neo-tree pads its lines, which allowed scrolling into nothing).
-- Other windows scroll as usual.
--
-- The mappings are global: the wheel scrolls the window under the mouse, which may not be the
-- focused one, and buffer-local mappings only apply to the focused one.

local function limited(win)
  if win == 0 or not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_config(win).relative ~= "" then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(win)
  return vim.bo[buf].filetype == "neo-tree" or (vim.bo[buf].filetype == "gitcommit" and vim.bo[buf].buftype == "acwrite")
end

local function step(kind) -- from 'mousescroll' (default ver:3,hor:6)
  return tonumber(vim.o.mousescroll:match(kind .. ":(%d+)")) or (kind == "ver" and 3 or 6)
end

local function scroll(win, dir, page)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  vim.api.nvim_win_call(win, function()
    local info = vim.fn.getwininfo(win)[1]
    local last = vim.api.nvim_buf_line_count(0)
    local lines = page and math.max(info.height - 2, 1) or step("ver")
    if dir == "down" then
      local n = math.min(lines, last - info.botline)
      if n > 0 then
        vim.cmd("normal! " .. n .. "\5") -- <C-e>
      end
    elseif dir == "up" then
      local n = math.min(lines, info.topline - 1)
      if n > 0 then
        vim.cmd("normal! " .. n .. "\25") -- <C-y>
      end
    else
      if vim.wo.wrap then
        return
      end
      -- widest visible line, ignoring trailing padding
      local widest = 0
      for _, line in ipairs(vim.api.nvim_buf_get_lines(0, info.topline - 1, info.botline, false)) do
        widest = math.max(widest, vim.fn.strdisplaywidth((line:gsub("%s+$", ""))))
      end
      local view = vim.fn.winsaveview()
      local max_left = math.max(0, widest - (info.width - info.textoff))
      local left = dir == "right" and math.min(view.leftcol + step("hor"), max_left)
        or math.max(view.leftcol - step("hor"), 0)
      if left == view.leftcol then
        return
      end
      -- keep the cursor inside the visible part, or Neovim scrolls back to it
      local lnum = vim.api.nvim_win_get_cursor(0)[1]
      local vcol = vim.fn.virtcol(".")
      local new = { leftcol = left }
      if vcol <= left or vcol > left + info.width - info.textoff then
        new.col = math.max(vim.fn.virtcol2col(0, lnum, left + 1) - 1, 0)
      end
      vim.fn.winrestview(new)
    end
  end)
end

for key, dir in pairs({
  ScrollWheelDown = "down",
  ScrollWheelUp = "up",
  ScrollWheelRight = "right",
  ScrollWheelLeft = "left",
  ["S-ScrollWheelDown"] = "down", -- Shift+wheel: a page at a time
  ["S-ScrollWheelUp"] = "up",
  ["C-ScrollWheelDown"] = "down",
  ["C-ScrollWheelUp"] = "up",
}) do
  local page = key:match("^[SC]%-") ~= nil
  vim.keymap.set({ "n", "v", "i" }, "<" .. key .. ">", function()
    local win = vim.fn.getmousepos().winid
    if not limited(win) then
      return "<" .. key .. ">"
    end
    vim.schedule(function() -- an expression mapping can't scroll other windows itself
      scroll(win, dir, page)
    end)
    return ""
  end, { expr = true, desc = "Scroll (stops at the end in the explorer)" })
end

return {}
