-- Terminal panel at the bottom of the screen with several terminals as tabs (IntelliJ-style).
--
-- One window holds every terminal; its top bar lists them: click a tab to switch to it, ✕ to
-- close it (ends its shell) and ＋ to open a new one. Hiding the panel (footer "Terminal"
-- button, or closing the window) keeps the shells running; showing it brings them back.

local M = {}

local HEIGHT = 15

local S = {
  bufs = {}, -- terminal buffers, in tab order
  names = {}, -- buffer -> name typed when the tab was created
  current = nil, -- buffer shown in the panel
  win = nil,
}

local function valid_win()
  return S.win and vim.api.nvim_win_is_valid(S.win) and S.win or nil
end

local function forget(buf)
  S.names[buf] = nil
  for i, b in ipairs(S.bufs) do
    if b == buf then
      table.remove(S.bufs, i)
      if S.current == buf then
        S.current = S.bufs[math.min(i, #S.bufs)]
      end
      return
    end
  end
end

local function redraw_bar()
  if valid_win() then
    vim.api.nvim__redraw({ win = S.win, winbar = true })
  end
  vim.cmd.redrawstatus() -- footer button highlight
end

--- Window options of the panel. Re-applied after every buffer switch / shell start, because
--- switching buffers or starting a terminal resets them (the tab bar would disappear).
local function style_win()
  local win = valid_win()
  if not win then
    return
  end
  local function set(name, value)
    vim.api.nvim_set_option_value(name, value, { win = win, scope = "local" })
  end
  set("winbar", "%{%v:lua.IdeTerminalTabs()%}")
  set("winfixheight", true)
  set("number", false)
  set("relativenumber", false)
  set("signcolumn", "no")
end

--- Open the panel window (if needed) showing `buf`.
local function show_buf(buf, enter)
  local win = valid_win()
  if not win then
    local prev = vim.api.nvim_get_current_win()
    vim.cmd(("botright %dsplit"):format(HEIGHT))
    win = vim.api.nvim_get_current_win()
    S.win = win
    if not enter and vim.api.nvim_win_is_valid(prev) then
      vim.api.nvim_set_current_win(prev)
    end
  end
  vim.api.nvim_win_set_buf(win, buf)
  style_win()
  S.current = buf
  if enter then
    vim.api.nvim_set_current_win(win)
    vim.cmd.startinsert()
  end
  redraw_bar()
end

--- Start a terminal (in the project root) named `name` (nil: the shell's title). It takes the
--- place of the tab `replace` (the "Tab name:" prompt) when given, else it's a new tab.
local function start(name, replace)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "hide"
  S.names[buf] = name
  local at = replace and vim.tbl_contains(S.bufs, replace) and vim.fn.index(S.bufs, replace) + 1
  if at then
    S.bufs[at] = buf
  else
    table.insert(S.bufs, buf)
  end
  show_buf(buf, true) -- in the window first, so the shell starts with the panel's size
  if replace and vim.api.nvim_buf_is_valid(replace) then
    pcall(vim.api.nvim_buf_delete, replace, { force = true })
  end
  vim.api.nvim_buf_call(buf, function()
    vim.fn.jobstart(vim.o.shell, {
      term = true,
      cwd = LazyVim.root(),
      on_exit = function()
        vim.schedule(function()
          M.close(buf)
        end)
      end,
    })
  end)
  style_win()
  vim.schedule(style_win) -- also after TermOpen handlers that run later
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      forget(buf)
      vim.schedule(redraw_bar)
    end,
  })
end

--- New terminal tab. It opens with a "Tab name: " line inside the panel (no popup): what you
--- type there names the tab, and on <Enter> the tab becomes a normal terminal. An empty name
--- (or <C-c>) keeps the shell's own title.
function M.new()
  local prompt = vim.api.nvim_create_buf(false, true)
  vim.bo[prompt].buftype = "prompt"
  vim.bo[prompt].bufhidden = "hide" -- keep a half-typed name when switching tabs
  vim.fn.prompt_setprompt(prompt, "Tab name: ")
  S.names[prompt] = "…"
  local function finish(text)
    text = vim.trim(text or "")
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(prompt) then
        start(text ~= "" and text or nil, prompt)
      end
    end)
  end
  vim.fn.prompt_setcallback(prompt, finish)
  vim.fn.prompt_setinterrupt(prompt, function()
    finish(nil)
  end)
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = prompt,
    once = true,
    callback = function()
      if vim.tbl_contains(S.bufs, prompt) then
        forget(prompt)
        vim.schedule(redraw_bar)
      end
    end,
  })
  table.insert(S.bufs, prompt)
  show_buf(prompt, true)
end

--- Close one terminal tab (ends its shell). The panel closes with the last one.
function M.close(buf)
  if not vim.tbl_contains(S.bufs, buf) then
    return
  end
  forget(buf)
  local win = valid_win()
  if win and vim.api.nvim_win_get_buf(win) == buf then
    if S.current then
      vim.api.nvim_win_set_buf(win, S.current)
      style_win()
    else
      pcall(vim.api.nvim_win_close, win, true)
      S.win = nil
    end
  end
  if vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
  redraw_bar()
end

function M.select(i)
  local buf = S.bufs[i]
  if buf then
    show_buf(buf, true)
  end
end

function M.is_open()
  local win = valid_win()
  return win ~= nil and vim.tbl_contains(S.bufs, vim.api.nvim_win_get_buf(win))
end

function M.hide()
  local win = valid_win()
  if win then
    pcall(vim.api.nvim_win_close, win, false)
  end
  S.win = nil
  redraw_bar()
end

--- Footer button: show / hide the panel, starting a first terminal if there is none.
function M.toggle()
  if M.is_open() then
    M.hide()
  elseif S.current and vim.api.nvim_buf_is_valid(S.current) then
    show_buf(S.current, true)
  else
    M.new()
  end
end

local function title(buf, i)
  local t = S.names[buf]
  if not t then
    t = vim.b[buf].term_title
    t = (type(t) == "string" and not t:match("^term://")) and t or ""
    t = vim.trim((t:gsub("^[^@%s]+@[^:%s]+:?", ""))) -- drop the "user@host:" prefix shells put in the title
    if t == "" then
      t = vim.fn.fnamemodify(vim.o.shell, ":t")
    end
  end
  t = t:gsub("%%", "%%%%")
  if vim.fn.strchars(t) > 24 then
    t = "…" .. vim.fn.strcharpart(t, vim.fn.strchars(t) - 23)
  end
  return ("%d %s"):format(i, t)
end

-- Tab bar of the panel (click handlers must be reachable from v:lua).
_G.IdeTerminalTabs = function()
  local parts = {}
  for i, buf in ipairs(S.bufs) do
    local hl = buf == S.current and "%#Title#" or "%#Comment#"
    table.insert(parts, ("%s%%%d@v:lua.IdeTerminalSelect@ %s %%X%%#Comment#%%%d@v:lua.IdeTerminalClose@✕ %%X%%*"):format(hl, i, title(buf, i), i))
  end
  table.insert(parts, "%#Special#%@v:lua.IdeTerminalNew@ ＋ %X%*")
  -- ✕ at the far right closes the panel (the shells keep running; the footer button reopens it)
  return table.concat(parts, "%#Comment#│%*") .. "%=%#Comment#%@v:lua.IdeTerminalHide@ ✕ %X%*"
end
_G.IdeTerminalSelect = function(i)
  vim.schedule(function()
    M.select(i)
  end)
end
_G.IdeTerminalClose = function(i)
  vim.schedule(function()
    if S.bufs[i] then
      M.close(S.bufs[i])
    end
  end)
end
_G.IdeTerminalNew = function()
  vim.schedule(M.new)
end
_G.IdeTerminalHide = function()
  vim.schedule(M.hide)
end

-- the shell renames its tab (e.g. to the running command or directory)
vim.api.nvim_create_autocmd("TermRequest", {
  group = vim.api.nvim_create_augroup("ide_terminals", { clear = true }),
  callback = function(args)
    if vim.tbl_contains(S.bufs, args.buf) then
      vim.schedule(redraw_bar)
    end
  end,
})

return M
