-- Closing a buffer (bufferline ✕, right-click on a tab, <leader>bd, "close others", …) must
-- never leave two windows showing the same file.
--
-- Snacks.bufdelete keeps the window and puts the alternate / most recently used buffer in
-- it, even when that buffer is already open in another window, so the two windows end up
-- mirrored. This wraps it: each window that shows the buffer gets a buffer that isn't
-- visible anywhere else in the tab; if there is none, the window is closed instead (as long
-- as another editor window is left, terminals don't count), and otherwise it gets an empty
-- buffer, so there is always an editor window for Claude Code to open files in.

local M = {}

--- A normal editor window: not floating, not the explorer, not a panel (Git Log, Run, …).
local function is_editor_window(win)
  local buf = vim.api.nvim_win_get_buf(win)
  return vim.api.nvim_win_get_config(win).relative == ""
    and vim.bo[buf].buftype == ""
    and vim.bo[buf].filetype ~= "neo-tree"
end

--- Whether `buf` is shown in a window of the current tab other than `win`.
local function shown_elsewhere(buf, win)
  local tab = vim.api.nvim_get_current_tabpage()
  for _, w in ipairs(vim.fn.win_findbuf(buf)) do
    if w ~= win and vim.api.nvim_win_get_tabpage(w) == tab then
      return true
    end
  end
  return false
end

--- Buffer to show in `win` instead of `buf`, or nil when every other one is already visible.
local function replacement(win, buf)
  local function usable(b)
    return b > 0 and b ~= buf and vim.api.nvim_buf_is_valid(b) and vim.bo[b].buflisted and not shown_elsewhere(b, win)
  end
  local alt = vim.api.nvim_win_call(win, function()
    return vim.fn.bufnr("#")
  end)
  if usable(alt) then
    return alt
  end
  local info = vim.fn.getbufinfo({ buflisted = 1 })
  table.sort(info, function(a, b)
    return a.lastused > b.lastused
  end)
  for _, b in ipairs(info) do
    if usable(b.bufnr) then
      return b.bufnr
    end
  end
end

--- Another editor window in the current tab besides `win`? Terminals
--- don't count: with no editor window left, terminal might open files/diffs by splitting its own
--- terminal window, which leaves two windows mirroring the same terminal.
local function has_other_editor_window(win)
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if w ~= win and is_editor_window(w) then
      return true
    end
  end
  return false
end

--- Move every window away from `buf` before it is deleted.
local function release_windows(buf)
  local tab = vim.api.nvim_get_current_tabpage()
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(win) then
      local new = replacement(win, buf)
      if new then
        vim.api.nvim_win_set_buf(win, new)
      elseif
        vim.api.nvim_win_get_tabpage(win) == tab
        and has_other_editor_window(win)
        and pcall(vim.api.nvim_win_close, win, false)
      then
        -- closed: the remaining windows keep their own files
      else
        vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(true, false))
      end
    end
  end
end

local function install()
  -- same table as Snacks.bufdelete; nil while snacks.nvim isn't on the runtimepath yet
  local ok, bufdelete = pcall(require, "snacks.bufdelete")
  if not ok or type(bufdelete) ~= "table" then
    return false
  end
  if bufdelete.ide_wrapped then
    return true
  end
  bufdelete.ide_wrapped = true
  local original = bufdelete.delete
  bufdelete.delete = function(opts)
    opts = opts or {}
    opts = type(opts) == "number" and { buf = opts } or opts
    opts = type(opts) == "function" and { filter = opts } or opts
    if type(opts.filter) == "function" then
      return original(opts) -- calls bufdelete.delete (this wrapper) once per buffer
    end
    local buf = opts.buf or 0
    if opts.file then
      buf = vim.fn.bufnr(opts.file)
    end
    buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
    if buf == -1 or not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    -- ask about unsaved changes first, so cancelling leaves the windows untouched
    if vim.bo[buf].modified and not opts.force then
      local ok, choice =
        pcall(vim.fn.confirm, ("Save changes to %q?"):format(vim.fn.bufname(buf)), "&Yes\n&No\n&Cancel")
      if not ok or choice == 0 or choice == 3 then
        return
      elseif choice == 1 then
        vim.api.nvim_buf_call(buf, vim.cmd.write)
      end
    end
    release_windows(buf)
    return original(vim.tbl_extend("force", opts, { buf = buf, file = false, force = true }))
  end
  return true
end

-- LazyVim loads config/autocmds.lua before the plugins when nvim is started with a file, so
-- snacks may not be available yet: in that case wrap it once the plugins have loaded.
function M.setup()
  if install() then
    return
  end
  vim.api.nvim_create_autocmd("User", {
    pattern = { "LazyDone", "VeryLazy" },
    group = vim.api.nvim_create_augroup("ide_bufclose", { clear = true }),
    callback = function()
      return install() -- true removes this autocmd
    end,
  })
end

return M
