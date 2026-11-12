-- Closing editor tabs (bufferline) with the mouse, IntelliJ-style:
--   * the close button is 3 cells wide (the icon plus a space on each side), not one tiny glyph
--   * a file with unsaved changes shows ● where the close button was: clicking it closes too
--     (you're asked whether to save)
--   * middle click on a tab closes it
--   * right click opens a menu: Close, Close All Except This One, Close All Tabs to the Left / Right, Close All,
--     Copy Path, Reveal in Explorer (it used to close the tab straight away)

local CLOSE = "v:lua.___bufferline_private.handle_close"

--- Close buffer `n` (asks to save unsaved changes). Scheduled: running it inside the tabline's
--- click callback leaves the tab bar half-redrawn.
local function close(n)
  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(n) then
      Snacks.bufdelete(n)
    end
    vim.cmd.redrawtabline()
  end)
end

--- Buffers in tab order.
local function tab_ids()
  local ok, res = pcall(function()
    return require("bufferline").get_elements().elements
  end)
  local ids = {}
  for _, e in ipairs(ok and res or {}) do
    table.insert(ids, e.id)
  end
  return ids
end

--------------------------------------------------------------------------------
-- Wider / always-present close button: rewrite the tab bar bufferline draws
--------------------------------------------------------------------------------

local function widen(line)
  -- 1) close button: start the click region one space earlier and end it one space later
  --    "%#Pad# <pad> %#Close#%N@close@ICON%X " -> "%#Pad# <pad>%N@close@ %#Close#ICON %X"
  line = line:gsub("( ?)(%%#[%w_]+#)(%%(%d+)@" .. CLOSE:gsub("%p", "%%%0") .. "@)(.-)%%X( ?)",
    function(before, hl, _, id, icon, after)
      return ("%%%s@%s@%s%s%s%s%%X"):format(id, CLOSE, before, hl, icon, after)
    end)

  -- 2) unsaved changes: the ● replaces the close button and isn't clickable; make it close the
  --    tab of the buffer whose click region it is in
  local out, pos, current = {}, 1, nil
  while true do
    local s, e, hl, icon = line:find("(%%#BufferLineModified[%w_]*#)([^%%]+)", pos)
    if not s then
      table.insert(out, line:sub(pos))
      break
    end
    local chunk = line:sub(pos, s - 1)
    for id in chunk:gmatch("%%(%d+)@v:lua%.___bufferline_private%.handle_click@") do
      current = id
    end
    if current and vim.trim(icon) ~= "" then
      -- the space before the ● is part of the button too
      local before = chunk:match(" $") and " " or ""
      table.insert(out, chunk:sub(1, #chunk - #before))
      -- keep the trailing click region of the tab going after %X
      table.insert(out, ("%%%s@%s@%s%s%s%%X%%%s@v:lua.___bufferline_private.handle_click@")
        :format(current, CLOSE, before, hl, icon, current))
    else
      table.insert(out, chunk .. hl .. icon)
    end
    pos = e + 1
  end
  return table.concat(out)
end

local function wrap_tabline()
  pcall(require, "bufferline") -- defines _G.nvim_bufferline
  if _G.IdeBufferlineWrapped or type(_G.nvim_bufferline) ~= "function" then
    return
  end
  local orig = _G.nvim_bufferline
  _G.nvim_bufferline = function(...)
    local line = orig(...)
    if type(line) ~= "string" then
      return line
    end
    local ok, res = pcall(widen, line)
    return ok and res or line
  end
  _G.IdeBufferlineWrapped = true
end

--------------------------------------------------------------------------------
-- Right-click menu
--------------------------------------------------------------------------------

local target -- buffer the menu was opened on

_G.IdeTabMenu = function(action)
  local n = target
  if not (n and vim.api.nvim_buf_is_valid(n)) then
    return
  end
  local ids = tab_ids()
  local idx = vim.fn.index(ids, n) + 1
  local function close_all(list)
    for _, id in ipairs(list) do
      if vim.api.nvim_buf_is_valid(id) then
        Snacks.bufdelete(id)
      end
    end
    vim.cmd.redrawtabline()
  end
  if action == "close" then
    close(n)
  elseif action == "others" then
    close_all(vim.tbl_filter(function(id)
      return id ~= n
    end, ids))
  elseif action == "left" then
    close_all(vim.list_slice(ids, 1, idx - 1))
  elseif action == "right" then
    close_all(vim.list_slice(ids, idx + 1))
  elseif action == "all" then
    close_all(ids)
  elseif action == "copy" then
    local path = vim.api.nvim_buf_get_name(n)
    vim.fn.setreg("+", path)
    vim.fn.setreg('"', path)
    vim.notify("Copied " .. path)
  elseif action == "reveal" then
    vim.cmd("Neotree reveal_file=" .. vim.fn.fnameescape(vim.api.nvim_buf_get_name(n)))
  end
end

pcall(vim.cmd, "aunmenu ]EditorTab")
vim.cmd([[
  anoremenu ]EditorTab.Close                     <Cmd>lua IdeTabMenu("close")<CR>
  anoremenu ]EditorTab.Close\ All\ Except\ This\ One             <Cmd>lua IdeTabMenu("others")<CR>
  anoremenu ]EditorTab.Close\ All\ Tabs\ to\ the\ Left  <Cmd>lua IdeTabMenu("left")<CR>
  anoremenu ]EditorTab.Close\ All\ Tabs\ to\ the\ Right <Cmd>lua IdeTabMenu("right")<CR>
  anoremenu ]EditorTab.Close\ All                <Cmd>lua IdeTabMenu("all")<CR>
  anoremenu ]EditorTab.-sep1-                    <Nop>
  anoremenu ]EditorTab.Copy\ Path                <Cmd>lua IdeTabMenu("copy")<CR>
  anoremenu ]EditorTab.Reveal\ in\ Explorer      <Cmd>lua IdeTabMenu("reveal")<CR>
]])

local function open_menu(n)
  target = n
  local ids = tab_ids()
  local idx = vim.fn.index(ids, n) + 1
  local function set(item, on)
    pcall(vim.cmd, ("amenu %s ]EditorTab.%s"):format(on and "enable" or "disable", item))
  end
  set([[Close\ All\ Except\ This\ One]], #ids > 1)
  set([[Close\ All\ Tabs\ to\ the\ Left]], idx > 1)
  set([[Close\ All\ Tabs\ to\ the\ Right]], idx > 0 and idx < #ids)
  local named = vim.api.nvim_buf_get_name(n) ~= ""
  set([[Copy\ Path]], named)
  set([[Reveal\ in\ Explorer]], named)
  -- scheduled: a popup can't open from inside the tabline's click callback
  vim.schedule(function()
    vim.cmd("popup ]EditorTab")
  end)
end

return {
  {
    "akinsho/bufferline.nvim",
    opts = function(_, opts)
      opts.options = opts.options or {}
      opts.options.close_command = close
      opts.options.middle_mouse_command = close
      opts.options.right_mouse_command = open_menu
      -- (opts are resolved when the plugin loads, so bufferline can be required here)
      wrap_tabline()
    end,
  },
}
