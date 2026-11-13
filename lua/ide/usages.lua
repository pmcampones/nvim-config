-- IntelliJ-style "Find Usages": every place in the project where the function / variable /
-- field / type under the cursor is used, through the file's language server (gopls for Go,
-- jdtls for Java, lua_ls…), so it works for any language with one.
--
-- The results open in a panel at the bottom, grouped by file:
--   Enter or double-click  go to that usage (the panel stays open)
--   q                      close the panel

local M = {}

local ns = vim.api.nvim_create_namespace("ide_usages")
local panel = { win = nil, buf = nil, entries = {} } -- entries[line] = { path, lnum, col }

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Find Usages" })
end

--- The language server that can find references in this buffer, or nil.
function M.client(bufnr)
  for _, c in ipairs(vim.lsp.get_clients({ bufnr = bufnr or 0 })) do
    if c:supports_method("textDocument/references") then
      return c
    end
  end
end

--- Text of line `lnum` (1-based) of `path`: from the buffer when it's open (unsaved edits),
--- else from disk. `cache` holds files already read.
local function line_text(path, lnum, cache)
  if not cache[path] then
    local buf = vim.fn.bufnr(path)
    if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
      cache[path] = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    else
      local ok, lines = pcall(vim.fn.readfile, path)
      cache[path] = ok and lines or {}
    end
  end
  return cache[path][lnum] or ""
end

--- A normal editor window to open a usage in (not the explorer, not a panel).
local function editor_window()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if win ~= panel.win and vim.api.nvim_win_get_config(win).relative == "" and vim.bo[buf].buftype == ""
      and vim.bo[buf].filetype ~= "neo-tree" then
      return win
    end
  end
end

--- Go to the usage on line `row` of the panel.
local function jump(row)
  local e = panel.entries[row]
  if not e then
    return
  end
  local win = editor_window()
  if not win then
    vim.api.nvim_set_current_win(panel.win)
    vim.cmd("aboveleft split")
    win = vim.api.nvim_get_current_win()
  end
  vim.api.nvim_set_current_win(win)
  if vim.api.nvim_buf_get_name(0) ~= e.path then
    vim.cmd.edit(vim.fn.fnameescape(e.path))
  end
  pcall(vim.api.nvim_win_set_cursor, win, { e.lnum, e.col })
  vim.cmd("normal! zvzz") -- open folds, center the line
end

function M.close()
  if panel.win and vim.api.nvim_win_is_valid(panel.win) then
    pcall(vim.api.nvim_win_close, panel.win, true)
  end
  panel.win = nil
end

_G.IdeUsagesClose = function()
  vim.schedule(M.close)
end

--- Show the usages: `items` = { { path, lnum, col, end_col } } (1-based line, 0-based cols).
local function show(name, items, root)
  -- group by file, files and lines in order
  local files, by_file = {}, {}
  for _, it in ipairs(items) do
    if not by_file[it.path] then
      by_file[it.path] = {}
      table.insert(files, it.path)
    end
    table.insert(by_file[it.path], it)
  end
  table.sort(files)

  local lines, hls, entries, cache = {}, {}, {}, {}
  for _, path in ipairs(files) do
    local list = by_file[path]
    table.sort(list, function(a, b)
      return a.lnum < b.lnum or (a.lnum == b.lnum and a.col < b.col)
    end)
    local rel = (root and vim.startswith(path, root .. "/")) and path:sub(#root + 2) or vim.fn.fnamemodify(path, ":~")
    table.insert(lines, ("%s (%d)"):format(rel, #list))
    entries[#lines] = { path = path, lnum = list[1].lnum, col = list[1].col }
    table.insert(hls, { #lines - 1, 0, #rel, "Directory" })
    table.insert(hls, { #lines - 1, #rel, -1, "Comment" })
    for _, it in ipairs(list) do
      local text = line_text(path, it.lnum, cache)
      local indent = #(text:match("^%s*"))
      local prefix = ("    %4d  "):format(it.lnum)
      table.insert(lines, prefix .. text:sub(indent + 1))
      entries[#lines] = { path = path, lnum = it.lnum, col = it.col }
      table.insert(hls, { #lines - 1, 0, #prefix, "LineNr" })
      local s = #prefix + it.col - indent
      if it.col >= indent and it.end_col > it.col then
        table.insert(hls, { #lines - 1, s, s + it.end_col - it.col, "Search" })
      end
    end
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "ide-usages"
  for _, h in ipairs(hls) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, h[1], h[2], { end_col = h[3] == -1 and #lines[h[1] + 1] or h[3], hl_group = h[4] })
  end

  if panel.win and vim.api.nvim_win_is_valid(panel.win) then
    vim.api.nvim_win_set_buf(panel.win, buf)
  else
    vim.cmd("botright 12split")
    panel.win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(panel.win, buf)
  end
  panel.buf, panel.entries = buf, entries
  local wo = vim.wo[panel.win]
  wo.number, wo.relativenumber, wo.signcolumn, wo.statuscolumn = false, false, "no", ""
  wo.wrap, wo.cursorline, wo.winfixheight, wo.foldcolumn = false, true, true, "0"
  local summary = ("%d usage%s in %d file%s"):format(#items, #items == 1 and "" or "s", #files, #files == 1 and "" or "s")
  wo.winbar = ("%%#Title# USAGES OF %%*%%#Special#'%s'%%* %%#Comment#%s · Enter / double-click opens · q closes %%*%%=%%#Special#%%@v:lua.IdeUsagesClose@ ✕ Close %%X%%*")
    :format((name:gsub("%%", "%%%%")), summary)
  pcall(vim.api.nvim_win_set_cursor, panel.win, { math.min(2, #lines), 0 })

  local function opts(desc)
    return { buffer = buf, nowait = true, silent = true, desc = desc }
  end
  vim.keymap.set("n", "<CR>", function()
    jump(vim.api.nvim_win_get_cursor(0)[1])
  end, opts("Go to usage"))
  vim.keymap.set("n", "<2-LeftMouse>", function()
    local pos = vim.fn.getmousepos()
    if pos.winid == panel.win and pos.line > 0 then
      jump(pos.line)
    end
  end, opts("Go to usage"))
  vim.keymap.set("n", "q", M.close, opts("Close"))
  -- focus the panel (like IntelliJ's Find window) so Enter / arrows work right away
  vim.api.nvim_set_current_win(panel.win)
end

--- Find the usages of the symbol under the cursor in the current buffer.
function M.find()
  local bufnr = vim.api.nvim_get_current_buf()
  local client = M.client(bufnr)
  if not client then
    return notify("No language server here that can find usages", vim.log.levels.WARN)
  end
  local name = vim.fn.expand("<cword>")
  local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
  params.context = { includeDeclaration = false } -- usages only, like IntelliJ
  local root = client.root_dir or vim.fn.getcwd()
  notify(("Searching for usages of '%s'…"):format(name))
  client:request("textDocument/references", params, function(err, result)
    if err then
      return notify("The language server couldn't find usages: " .. (err.message or tostring(err)), vim.log.levels.ERROR)
    end
    local items, outside = {}, 0
    for _, loc in ipairs(result or {}) do
      local uri = loc.uri or loc.targetUri
      local range = loc.range or loc.targetSelectionRange
      if uri and range and uri:match("^file:") then
        local path = vim.uri_to_fname(uri)
        local text = line_text(path, range.start.line + 1, {})
        -- LSP columns may be UTF-16: convert to bytes for highlighting / the cursor
        local function byte(c)
          local ok, b = pcall(vim.str_byteindex, text, client.offset_encoding, c, false)
          return ok and b or c
        end
        local end_col = range["end"].line == range.start.line and byte(range["end"].character) or #text
        table.insert(items, { path = path, lnum = range.start.line + 1, col = byte(range.start.character), end_col = end_col })
      else
        outside = outside + 1 -- e.g. inside a library jar (jdt://)
      end
    end
    if #items == 0 then
      M.close() -- don't leave the results of a previous search looking like these
      -- a language server that is still indexing (e.g. jdtls importing a project) finds nothing yet
      local busy = vim.trim(vim.lsp.status() or "") ~= ""
      if busy then
        return notify(("No usages of '%s' found yet: the language server is still loading the project. Try again in a moment."):format(name),
          vim.log.levels.WARN)
      end
      return notify(("No usages of '%s' found in the project"):format(name)
        .. (outside > 0 and (" (%d in libraries)"):format(outside) or ""))
    end
    show(name, items, root)
  end, bufnr)
end

return M
