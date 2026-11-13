-- IntelliJ-style "Git Log" panel at the bottom of the screen, in three parts:
--   GIT LOG        : commit graph (all branches) with branch/tag labels, author and date
--   CHANGED FILES  : tree of the files the selected commit added / modified / deleted / renamed
--   COMMIT DETAILS : message, hash, author, date, branches and stats of the selected commit
-- Selecting a commit fills the Changed Files tree; selecting a file there shows its diff for
-- that commit (before | after) in the editor area above. Closing the panel closes the diff and
-- puts back the file you were editing.
-- Keys: y copy hash, R refresh, q close (in the diff: q closes the diff).

local M = {}

local S = {
  root = nil,
  entries = {}, -- parsed `git log --graph` lines
  items = {}, -- log lines: { kind = "commit"|"graph"|"info", entry }
  files = {}, -- hash -> list of { status, path, old }
  details = {}, -- hash -> lines
  selected = nil, -- commit entry shown in Changed Files / Details
  tree_items = {}, -- Changed Files lines: { kind = "dir"|"file"|"info", path, file }
  collapsed = {}, -- dir path -> true (Changed Files)
  list_buf = nil,
  list_win = nil,
  files_buf = nil,
  files_win = nil,
  det_buf = nil,
  det_win = nil,
  diff = nil, -- { left, right, origin_win, origin_buf, key }
}

local ns = vim.api.nvim_create_namespace("ide_gitlog")
local MAX_COMMITS = 1000
local SEP = "\31"

--------------------------------------------------------------------------------
-- Highlights
--------------------------------------------------------------------------------

local GRAPH_COLORS = { "#6897BB", "#629755", "#CC7832", "#9876AA", "#D1675A", "#BBB529" }

local function set_highlights()
  local light = vim.o.background == "light"
  for i, c in ipairs(GRAPH_COLORS) do
    vim.api.nvim_set_hl(0, "IdeGitLogGraph" .. i, { fg = c })
  end
  vim.api.nvim_set_hl(0, "IdeGitLogAdded", { fg = light and "#067D17" or "#629755" })
  vim.api.nvim_set_hl(0, "IdeGitLogModified", { fg = light and "#0032A0" or "#6897BB" })
  vim.api.nvim_set_hl(0, "IdeGitLogDeleted", { fg = "#808080" })
  vim.api.nvim_set_hl(0, "IdeGitLogBranch", { fg = light and "#067D17" or "#A5C25C", bold = true })
  vim.api.nvim_set_hl(0, "IdeGitLogRemote", { fg = light and "#7A3E9D" or "#9876AA", bold = true })
  vim.api.nvim_set_hl(0, "IdeGitLogTag", { fg = light and "#9E6A03" or "#E5C07B", bold = true })
  vim.api.nvim_set_hl(0, "IdeGitLogHead", { fg = light and "#B00000" or "#FF6B68", bold = true })
  vim.api.nvim_set_hl(0, "IdeGitLogAuthor", { link = "Identifier" })
  vim.api.nvim_set_hl(0, "IdeGitLogDate", { link = "Comment" })
  vim.api.nvim_set_hl(0, "IdeGitLogDim", { link = "Comment" })
  vim.api.nvim_set_hl(0, "IdeGitLogDir", { link = "Directory" })
end
set_highlights()
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("ide_gitlog_colors", { clear = true }),
  callback = set_highlights,
})

local STATUS_HL = {
  A = "IdeGitLogAdded",
  C = "IdeGitLogAdded",
  M = "IdeGitLogModified",
  R = "IdeGitLogModified",
  T = "IdeGitLogModified",
  D = "IdeGitLogDeleted",
}

--------------------------------------------------------------------------------
-- Git data
--------------------------------------------------------------------------------

local function git(args)
  local res = vim.system(vim.list_extend({ "git" }, args), { cwd = S.root, text = true }):wait()
  return res.code == 0 and res.stdout or nil, res
end

local function load_entries()
  S.entries = {}
  local out = git({
    "log", "--graph", "--branches", "--remotes", "--tags", "HEAD", "--date-order", "-n", tostring(MAX_COMMITS),
    "--date=format:%Y-%m-%d %H:%M",
    "--format=" .. SEP .. table.concat({ "%H", "%h", "%P", "%an", "%ad", "%D", "%s" }, SEP),
  })
  for _, line in ipairs(vim.split(out or "", "\n", { trimempty = true })) do
    local graph, rest = line:match("^([^" .. SEP .. "]*)" .. SEP .. "(.*)$")
    if graph then
      local f = vim.split(rest, SEP, { plain = true })
      table.insert(S.entries, {
        kind = "commit",
        graph = graph,
        hash = f[1],
        short = f[2],
        parents = vim.split(f[3] or "", " ", { trimempty = true }),
        author = f[4],
        date = f[5],
        refs = f[6] ~= "" and vim.split(f[6], ", ", { plain = true }) or {},
        subject = f[7] or "",
      })
    else
      table.insert(S.entries, { kind = "graph", graph = line })
    end
  end
end

local function commit_files(entry)
  if S.files[entry.hash] then
    return S.files[entry.hash]
  end
  local out
  if #entry.parents > 1 then -- merge: changes brought in, compared with the first parent
    out = git({ "diff", "--name-status", "-M", entry.parents[1], entry.hash })
  else
    out = git({ "show", "--format=", "--name-status", "-M", entry.hash })
  end
  local files = {}
  for _, line in ipairs(vim.split(out or "", "\n", { trimempty = true })) do
    local parts = vim.split(line, "\t", { plain = true })
    local status = parts[1]:sub(1, 1)
    if status == "R" or status == "C" then
      table.insert(files, { status = status, old = parts[2], path = parts[3] })
    else
      table.insert(files, { status = status, path = parts[2] })
    end
  end
  S.files[entry.hash] = files
  return files
end

local function commit_details(entry)
  if S.details[entry.hash] then
    return S.details[entry.hash]
  end
  local out = git({ "show", "-s", "--date=format:%Y-%m-%d %H:%M:%S", "--format=%an%x1f%ae%x1f%ad%x1f%cn%x1f%ce%x1f%P%x1f%B", entry.hash }) or ""
  local f = vim.split(out, SEP, { plain = true })
  local lines = vim.split(vim.trim(f[7] or ""), "\n")
  table.insert(lines, "")
  table.insert(lines, entry.hash)
  table.insert(lines, ("Author:    %s <%s>"):format(f[1] or "", f[2] or ""))
  table.insert(lines, ("Date:      %s"):format(f[3] or ""))
  if (f[4] or "") ~= (f[1] or "") then
    table.insert(lines, ("Committer: %s <%s>"):format(f[4] or "", f[5] or ""))
  end
  if #entry.parents > 1 then
    table.insert(lines, "Merge of:  " .. table.concat(vim.tbl_map(function(p)
      return p:sub(1, 8)
    end, entry.parents), ", "))
  end
  if #entry.refs > 0 then
    table.insert(lines, "Branches:  " .. table.concat(entry.refs, ", "))
  end
  local stat = git(#entry.parents > 1 and { "diff", "--shortstat", entry.parents[1], entry.hash }
    or { "show", "--format=", "--shortstat", entry.hash })
  if stat and vim.trim(stat) ~= "" then
    table.insert(lines, "")
    table.insert(lines, vim.trim(stat))
  end
  S.details[entry.hash] = lines
  return lines
end

--------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------

local function valid_win(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
end

local function hl(buf, lnum, s, e, group)
  pcall(vim.api.nvim_buf_set_extmark, buf, ns, lnum - 1, s, { end_col = e, hl_group = group })
end

local function truncate(text, width)
  if width <= 1 then
    return ""
  end
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  local chars = vim.fn.strchars(text)
  while chars > 0 and vim.fn.strdisplaywidth(vim.fn.strcharpart(text, 0, chars)) > width - 1 do
    chars = chars - 1
  end
  return vim.fn.strcharpart(text, 0, chars) .. "…"
end

local function icon_for(kind, name)
  local ok, icons = pcall(require, "mini.icons")
  if ok then
    local icon, group = icons.get(kind, name)
    return icon, group
  end
  return kind == "directory" and "" or "", kind == "directory" and "IdeGitLogDir" or "Normal"
end

--------------------------------------------------------------------------------
-- GIT LOG list
--------------------------------------------------------------------------------

local GRAPH_CHARS = { ["*"] = "●", ["|"] = "│", ["/"] = "╱", ["\\"] = "╲" }

--- Converts git's ASCII graph into box-drawing characters, colored per column.
local function draw_graph(graph)
  local parts, hls, bytes = {}, {}, 0
  for i = 1, #graph do
    local ch = graph:sub(i, i)
    local out = GRAPH_CHARS[ch] or ch
    if ch ~= " " then
      table.insert(hls, { bytes, bytes + #out, "IdeGitLogGraph" .. (math.floor((i - 1) / 2) % #GRAPH_COLORS + 1) })
    end
    table.insert(parts, out)
    bytes = bytes + #out
  end
  return table.concat(parts), hls
end

local function ref_labels(refs)
  local labels = {}
  for _, ref in ipairs(refs) do
    local branch = ref:match("^HEAD %-> (.+)$")
    if branch then
      table.insert(labels, { "HEAD", "IdeGitLogHead" })
      table.insert(labels, { branch, "IdeGitLogBranch" })
    elseif ref:match("^tag: ") then
      table.insert(labels, { "🏷 " .. ref:sub(6), "IdeGitLogTag" })
    elseif ref == "HEAD" then
      table.insert(labels, { "HEAD", "IdeGitLogHead" })
    elseif ref:find("/", 1, true) then
      table.insert(labels, { ref, "IdeGitLogRemote" })
    else
      table.insert(labels, { ref, "IdeGitLogBranch" })
    end
  end
  return labels
end

local function render_list()
  if not (S.list_buf and vim.api.nvim_buf_is_valid(S.list_buf)) then
    return
  end
  local width = valid_win(S.list_win) and vim.api.nvim_win_get_width(S.list_win) or 120
  local cur_hash = S.selected and S.selected.hash

  local lines, marks = {}, {}
  S.items = {}
  if #S.entries == 0 then
    table.insert(lines, "  No commits yet")
    table.insert(S.items, { kind = "info" })
    marks[1] = { hls = { { 0, #lines[1], "IdeGitLogDim" } } }
  end
  for _, e in ipairs(S.entries) do
    local text, hls = draw_graph(e.graph)
    local virt
    if e.kind == "commit" then
      text = text .. " "
      virt = { { e.author, "IdeGitLogAuthor" }, { "  " }, { e.date, "IdeGitLogDate" }, { " " } }
      local room = width - vim.fn.strdisplaywidth(text) - vim.fn.strdisplaywidth(e.author .. "  " .. e.date .. " ") - 2
      -- branch/tag labels first (they matter most), then the subject in the remaining room
      for _, label in ipairs(ref_labels(e.refs)) do
        local l = truncate(label[1], math.max(room, 0))
        if l == "" then
          break
        end
        table.insert(hls, { #text, #text + #l, label[2] })
        text = text .. l .. " "
        room = room - vim.fn.strdisplaywidth(l) - 1
      end
      text = text .. truncate(e.subject, room)
    end
    table.insert(lines, text)
    table.insert(S.items, { kind = e.kind, entry = e })
    marks[#lines] = { hls = hls, virt = virt }
  end

  set_lines(S.list_buf, lines)
  for lnum, m in pairs(marks) do
    for _, h in ipairs(m.hls or {}) do
      hl(S.list_buf, lnum, h[1], h[2], h[3])
    end
    if m.virt then
      vim.api.nvim_buf_set_extmark(S.list_buf, ns, lnum - 1, 0, { virt_text = m.virt, virt_text_pos = "right_align" })
    end
  end
  -- keep the cursor on the selected commit
  if cur_hash and valid_win(S.list_win) then
    for i, item in ipairs(S.items) do
      if item.entry and item.entry.hash == cur_hash then
        vim.api.nvim_win_set_cursor(S.list_win, { i, 0 })
        break
      end
    end
  end
end

--------------------------------------------------------------------------------
-- CHANGED FILES tree
--------------------------------------------------------------------------------

--- Builds a folder tree; folders that only contain one folder are compacted ("a/b/c").
local function build_tree(files)
  local root = { dirs = {}, files = {} }
  for _, f in ipairs(files) do
    local node = root
    local parts = vim.split(f.path, "/", { plain = true })
    for i = 1, #parts - 1 do
      node.dirs[parts[i]] = node.dirs[parts[i]] or { dirs = {}, files = {} }
      node = node.dirs[parts[i]]
    end
    table.insert(node.files, f)
  end
  return root
end

local function render_files()
  if not (S.files_buf and vim.api.nvim_buf_is_valid(S.files_buf)) then
    return
  end
  local lines, marks = {}, {}
  S.tree_items = {}
  local function add(text, item, hls)
    table.insert(lines, text)
    table.insert(S.tree_items, item)
    marks[#lines] = hls
  end

  local entry = S.selected
  local files = entry and entry.hash and commit_files(entry) or {}
  if not entry or not entry.hash then
    add("  Select a commit", { kind = "info" }, { { 0, 18, "IdeGitLogDim" } })
  elseif #files == 0 then
    add("  No file changes", { kind = "info" }, { { 0, 17, "IdeGitLogDim" } })
  end

  local function walk(node, prefix_path, depth)
    local names = vim.tbl_keys(node.dirs)
    table.sort(names)
    for _, name in ipairs(names) do
      local child, label = node.dirs[name], name
      while vim.tbl_count(child.dirs) == 1 and #child.files == 0 do -- compact single-folder chains
        local only = next(child.dirs)
        label = label .. "/" .. only
        child = child.dirs[only]
      end
      local path = (prefix_path ~= "" and (prefix_path .. "/") or "") .. label
      local open = not S.collapsed[path]
      local indent = string.rep("  ", depth)
      local icon, icon_hl = icon_for("directory", label)
      local text = indent .. (open and "▾ " or "▸ ") .. icon .. " " .. label
      local s = #indent
      add(text, { kind = "dir", path = path }, {
        { s, s + #"▾ ", "IdeGitLogDim" },
        { s + #"▾ ", s + #"▾ " + #icon, icon_hl },
        { #text - #label, #text, "IdeGitLogDir" },
      })
      if open then
        walk(child, path, depth + 1)
      end
    end
    table.sort(node.files, function(a, b)
      return a.path < b.path
    end)
    for _, f in ipairs(node.files) do
      local indent = string.rep("  ", depth) .. "  "
      local name = vim.fn.fnamemodify(f.path, ":t")
      local icon, icon_hl = icon_for("file", name)
      local text = indent .. icon .. " " .. name
      local group = STATUS_HL[f.status] or "Normal"
      local hls = { { #indent, #indent + #icon, icon_hl }, { #text - #name, #text, group } }
      if f.old then
        local s = #text
        text = text .. "  ← " .. f.old
        table.insert(hls, { s, #text, "IdeGitLogDim" })
      end
      add(text, { kind = "file", file = f }, hls)
    end
  end
  walk(build_tree(files), "", 0)

  set_lines(S.files_buf, lines)
  for lnum, hls in pairs(marks) do
    for _, h in ipairs(hls or {}) do
      hl(S.files_buf, lnum, h[1], h[2], h[3])
    end
  end
  if valid_win(S.files_win) then
    vim.wo[S.files_win].winbar = ("%%#Title# CHANGED FILES %%*%%#IdeGitLogDim#%s%%*"):format(
      entry and entry.hash and ("%d in %s"):format(#files, entry.short) or ""
    )
  end
end

--------------------------------------------------------------------------------
-- COMMIT DETAILS
--------------------------------------------------------------------------------

local function render_details()
  if not (S.det_buf and vim.api.nvim_buf_is_valid(S.det_buf)) then
    return
  end
  local entry = S.selected
  if not (entry and entry.hash) then
    set_lines(S.det_buf, { "" })
    return
  end
  local lines = commit_details(entry)
  set_lines(S.det_buf, lines)
  hl(S.det_buf, 1, 0, #lines[1], "Title")
  for i, l in ipairs(lines) do
    local label = l:match("^(%u%l+:)%s")
    if label then
      hl(S.det_buf, i, 0, #label, "IdeGitLogDim")
    elseif l == entry.hash then
      hl(S.det_buf, i, 0, #l, "IdeGitLogTag")
    end
  end
end

--- Shows `entry` in Changed Files and Commit Details (when it isn't already).
local function select_commit(entry)
  if not entry or entry == S.selected then
    return
  end
  S.selected = entry
  S.collapsed = {}
  render_files()
  render_details()
end

--------------------------------------------------------------------------------
-- Diff in the editor area
--------------------------------------------------------------------------------

local function scratch(lines, name, ft)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  pcall(vim.api.nvim_buf_set_name, buf, name)
  if ft then
    vim.bo[buf].filetype = ft
  end
  vim.keymap.set("n", "q", function()
    M.close_diff()
  end, { buffer = buf, nowait = true, desc = "Close diff" })
  return buf
end

local function file_at(rev, path)
  local out = git({ "show", rev .. ":" .. path }) or ""
  local lines = vim.split(out, "\n")
  if lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

local PANEL_FT = { ["ide-gitlog"] = true, ["ide-gitlog-files"] = true, ["ide-gitlog-details"] = true }

--- A normal editor window to show the diff in (not the explorer, not this panel).
local function editor_window()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    local ft = vim.bo[buf].filetype
    if vim.api.nvim_win_get_config(win).relative == "" and ft ~= "neo-tree" and not PANEL_FT[ft] and vim.bo[buf].buftype ~= "acwrite" then
      return win
    end
  end
end

--- Diff of one file as changed by a commit (parent version | commit version), shown in the
--- editor area; the same two windows are reused when another file is selected.
function M.show_file_diff(entry, file)
  local key = entry.hash .. ":" .. file.path
  local d = S.diff
  if d and d.key == key and valid_win(d.left) and valid_win(d.right) then
    return
  end
  local parent = entry.parents[1]
  local old_path = file.old or file.path
  local old_lines = (parent and file.status ~= "A") and file_at(parent, old_path) or {}
  local new_lines = file.status ~= "D" and file_at(entry.hash, file.path) or {}
  local ft = vim.filetype.match({ filename = file.path })
  local short_parent = parent and parent:sub(1, 7) or "(none)"
  local left_buf = scratch(old_lines, ("%s @ %s"):format(old_path, short_parent), ft)
  local right_buf = scratch(new_lines, ("%s @ %s"):format(file.path, entry.short), ft)

  if not (d and valid_win(d.left) and valid_win(d.right)) then
    local origin = editor_window()
    d = {}
    if origin then
      d.origin_win, d.origin_buf = origin, vim.api.nvim_win_get_buf(origin)
      d.left = origin
    else
      d.left = vim.api.nvim_open_win(left_buf, false, { split = "above", win = S.list_win })
    end
    vim.api.nvim_win_set_buf(d.left, left_buf)
    d.right = vim.api.nvim_open_win(right_buf, false, { split = "right", win = d.left })
    S.diff = d
  else
    for _, win in ipairs({ d.left, d.right }) do
      vim.api.nvim_win_call(win, function()
        vim.cmd("diffoff")
      end)
    end
    vim.api.nvim_win_set_buf(d.left, left_buf)
    vim.api.nvim_win_set_buf(d.right, right_buf)
  end
  d.key = key

  vim.wo[d.left].winbar = ("%%#IdeGitLogDim# BEFORE  %s  %%*%s"):format(short_parent, old_path)
  vim.wo[d.right].winbar = ("%%#IdeGitLogTag# AFTER  %s  %%*%s  %%#IdeGitLogDim#%s%%*  %%=%%#IdeGitLogDim#q close %%*")
    :format(entry.short, file.path, (entry.subject:gsub("%%", "%%%%")))
  for _, win in ipairs({ d.left, d.right }) do
    vim.api.nvim_win_call(win, function()
      vim.cmd("diffthis")
    end)
    vim.wo[win].foldlevel = 99
  end
end

--- Close the diff and put back what was in the editor window before.
function M.close_diff()
  local d = S.diff
  S.diff = nil
  if not d then
    return
  end
  if valid_win(d.right) then
    pcall(vim.api.nvim_win_close, d.right, true)
  end
  if valid_win(d.left) then
    vim.api.nvim_win_call(d.left, function()
      vim.cmd("diffoff")
    end)
    vim.wo[d.left].winbar = ""
    if d.origin_win == d.left and d.origin_buf and vim.api.nvim_buf_is_valid(d.origin_buf) then
      vim.api.nvim_win_set_buf(d.left, d.origin_buf)
    elseif d.origin_win ~= d.left then
      pcall(vim.api.nvim_win_close, d.left, true)
    else
      vim.api.nvim_win_set_buf(d.left, vim.api.nvim_create_buf(true, false))
    end
  end
end

--------------------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------------------

local function log_item()
  return valid_win(S.list_win) and S.items[vim.api.nvim_win_get_cursor(S.list_win)[1]] or nil
end

local function tree_item()
  return valid_win(S.files_win) and S.tree_items[vim.api.nvim_win_get_cursor(S.files_win)[1]] or nil
end

--- Changed Files: folders expand/collapse, files show their diff.
function M.files_activate(focus_diff)
  local item = tree_item()
  if not item then
    return
  end
  if item.kind == "dir" then
    S.collapsed[item.path] = not S.collapsed[item.path] or nil
    render_files()
  elseif item.kind == "file" and S.selected then
    M.show_file_diff(S.selected, item.file)
    if focus_diff and S.diff and valid_win(S.diff.right) then
      vim.api.nvim_set_current_win(S.diff.right)
    end
  end
end

--- Click hook (see lua/ide/click.lua): a click on a folder's ▸ / ▾ expands or collapses it.
function M.arrow_click(pos)
  if not M.is_open() or pos.winid ~= S.files_win or pos.line == 0 then
    return false
  end
  local item = S.tree_items[pos.line]
  if not (item and item.kind == "dir") then
    return false
  end
  local line = vim.api.nvim_buf_get_lines(S.files_buf, pos.line - 1, pos.line, false)[1] or ""
  local idx = line:find("▸", 1, true) or line:find("▾", 1, true)
  local col = pos.wincol - vim.fn.getwininfo(S.files_win)[1].textoff
  local start = idx and vim.fn.strdisplaywidth(line:sub(1, idx - 1)) + 1
  if not start or col < start or col > start + 1 then
    return false
  end
  local lnum = pos.line
  vim.schedule(function()
    vim.api.nvim_set_current_win(S.files_win)
    vim.api.nvim_win_set_cursor(S.files_win, { lnum, 0 })
    S.collapsed[item.path] = not S.collapsed[item.path] or nil
    render_files()
  end)
  return true
end

--------------------------------------------------------------------------------
-- Checkout (right-click menu on a commit)
--------------------------------------------------------------------------------

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Git Checkout" })
end

local function after_checkout()
  vim.cmd("silent! checktime") -- reload open files that changed on disk
  pcall(function()
    local events = require("neo-tree.events")
    events.fire_event(events.GIT_EVENT)
  end)
  M.refresh()
end

--- Check out `target` (a commit hash or a local branch), keeping uncommitted changes.
--- Warns first when there are uncommitted or unsaved changes.
function M.checkout(target, label)
  local changes = vim.split(git({ "status", "--porcelain", "--untracked-files=no" }) or "", "\n", { trimempty = true })
  local unsaved = vim.tbl_filter(function(buf)
    return vim.bo[buf].modified and vim.bo[buf].buftype == "" and vim.api.nvim_buf_get_name(buf):sub(1, #S.root + 1) == S.root .. "/"
  end, vim.api.nvim_list_bufs())

  if #changes > 0 or #unsaved > 0 then
    local parts = {}
    if #changes > 0 then
      table.insert(parts, ("%d file(s) with uncommitted changes"):format(#changes))
    end
    if #unsaved > 0 then
      table.insert(parts, ("%d unsaved file(s), which will be saved first"):format(#unsaved))
    end
    local msg = ("You have %s.\n\nCheck out %s anyway? Your changes will be kept and carried over."):format(table.concat(parts, " and "), label)
    if vim.fn.confirm(msg, "Check&out\n&Cancel", 2, "Warning") ~= 1 then
      return
    end
    if #unsaved > 0 then
      for _, buf in ipairs(unsaved) do
        vim.api.nvim_buf_call(buf, function()
          vim.cmd("silent write")
        end)
      end
      changes = vim.split(git({ "status", "--porcelain", "--untracked-files=no" }) or "", "\n", { trimempty = true })
    end
  end

  -- 1) plain checkout: Git carries the changes over when they don't clash with the target
  local _, res = git({ "checkout", target })
  if res.code == 0 then
    after_checkout()
    return notify(("Checked out %s"):format(label) .. (#changes > 0 and "\nYour changes were kept." or ""))
  end
  local err = vim.trim(res.stderr or "")
  if not err:find("would be overwritten", 1, true) or #changes == 0 then
    return notify("Checkout failed:\n" .. err, vim.log.levels.ERROR)
  end

  -- 2) smart checkout: stash the changes, check out, and put the changes back
  local stash_msg = "ide: changes before checking out " .. label
  local _, st = git({ "stash", "push", "--message", stash_msg })
  if st.code ~= 0 then
    return notify("Could not set your changes aside:\n" .. vim.trim(st.stderr), vim.log.levels.ERROR)
  end
  local _, co = git({ "checkout", target })
  if co.code ~= 0 then
    git({ "stash", "pop" }) -- go back to how things were
    return notify("Checkout failed:\n" .. vim.trim(co.stderr), vim.log.levels.ERROR)
  end
  local _, pop = git({ "stash", "pop" })
  after_checkout()
  if pop.code ~= 0 then
    return notify(
      ("Checked out %s, but your changes conflict with it.\nResolve the conflicts in the files marked as conflicted (Commit tab).\n"
        .. "A copy of your changes is kept in the stash: \"%s\"."):format(label, stash_msg),
      vim.log.levels.WARN
    )
  end
  notify(("Checked out %s\nYour changes were kept."):format(label))
end

--- Commits that "remove from here" would drop: `entry` and every newer commit on the
--- current branch. nil when not possible (detached HEAD, not on this branch, root commit,
--- or some of those commits were already pushed).
local function removable_commits(entry, current)
  if current == "" or #entry.parents == 0 then
    return nil
  end
  local _, anc = git({ "merge-base", "--is-ancestor", entry.hash, "HEAD" })
  if anc.code ~= 0 then
    return nil
  end
  local range = entry.parents[1] .. "..HEAD"
  local all = vim.split(git({ "rev-list", range }) or "", "\n", { trimempty = true })
  local unpushed = vim.split(git({ "rev-list", range, "--not", "--remotes" }) or "", "\n", { trimempty = true })
  if #all == 0 or #unpushed ~= #all then
    return nil
  end
  return all
end

--- Remove `entry` and the newer commits after it from the current branch (they must be
--- unpushed). Their changes are either kept as uncommitted changes or discarded; uncommitted
--- work you already had is kept either way.
function M.remove_commits(entry)
  local current = vim.trim(git({ "branch", "--show-current" }) or "")
  local commits = removable_commits(entry, current)
  if not commits then
    return notify("These commits can't be removed (already pushed, or not on the current branch)", vim.log.levels.WARN)
  end
  local list = vim.split(git({ "log", "--format=  %h  %s", "-n", "10", entry.parents[1] .. "..HEAD" }) or "", "\n", { trimempty = true })
  if #commits > #list then
    table.insert(list, ("  … and %d more"):format(#commits - #list))
  end
  local msg = ("Remove %d unpushed commit%s from branch '%s'?\n\n%s\n\nWhat should happen to the changes %s?")
    :format(#commits, #commits == 1 and "" or "s", current, table.concat(list, "\n"), #commits == 1 and "it made" or "they made")
  local choice = vim.fn.confirm(msg, "&Keep them as uncommitted changes\n&Discard them\n&Cancel", 3, "Question")
  if choice ~= 1 and choice ~= 2 then
    return
  end
  local old_head = vim.trim(git({ "rev-parse", "--short", "HEAD" }) or "")
  -- --soft keeps the commits' changes (staged); --keep drops them but refuses to touch
  -- uncommitted work that would be affected
  local _, res = git({ "reset", choice == 1 and "--soft" or "--keep", entry.parents[1] })
  if res.code ~= 0 then
    local blocked = {}
    for f in (res.stderr or ""):gmatch("Entry '([^']+)' not uptodate") do
      table.insert(blocked, f)
    end
    if #blocked > 0 then
      return notify(("Nothing was removed: you have uncommitted changes in %s, which %s also changed.\n"
        .. "Commit or roll back those changes first, or choose \"Keep them as uncommitted changes\".")
        :format(table.concat(blocked, ", "), #commits == 1 and "that commit" or "those commits"), vim.log.levels.WARN)
    end
    return notify("Could not remove the commits:\n" .. vim.trim(res.stderr), vim.log.levels.ERROR)
  end
  after_checkout()
  notify(("Removed %d commit%s from '%s'%s.\n(To undo this: git reset --keep %s)"):format(
    #commits, #commits == 1 and "" or "s", current,
    choice == 1 and "; their changes are now uncommitted (see the Commit tab)" or "", old_head))
end

local function is_ancestor(a, b)
  local _, res = git({ "merge-base", "--is-ancestor", a, b })
  return res.code == 0
end

--- With a detached HEAD (e.g. after "Checkout Revision"): local branches that continue past
--- HEAD with only unpushed commits, when `entry` is HEAD or one of those commits.
---@return { branch: string, commits: string[] }[]
local function branches_ahead(entry, current, head)
  local result = {}
  if current ~= "" or head == "" then
    return result
  end
  if entry.hash ~= head and not is_ancestor(head, entry.hash) then
    return result -- the clicked commit isn't after HEAD
  end
  for _, branch in ipairs(vim.split(git({ "for-each-ref", "refs/heads", "--format=%(refname:short)" }) or "", "\n", { trimempty = true })) do
    local tip = vim.trim(git({ "rev-parse", branch }) or "")
    if tip ~= head and is_ancestor(head, branch) and (entry.hash == head or is_ancestor(entry.hash, branch)) then
      local range = head .. ".." .. branch
      local all = vim.split(git({ "rev-list", range }) or "", "\n", { trimempty = true })
      local unpushed = vim.split(git({ "rev-list", range, "--not", "--remotes" }) or "", "\n", { trimempty = true })
      if #all > 0 and #unpushed == #all then
        table.insert(result, { branch = branch, commits = all })
      end
    end
  end
  return result
end

--- Remove the commits of `branch` that come after the (detached) HEAD, then switch back to
--- `branch`, which now ends at HEAD. Their changes are kept as uncommitted changes or discarded.
function M.remove_after_head(branch)
  local head = vim.trim(git({ "rev-parse", "HEAD" }) or "")
  local short = head:sub(1, 7)
  local tip = vim.trim(git({ "rev-parse", "--short", branch }) or "")
  local count = #vim.split(git({ "rev-list", head .. ".." .. branch }) or "", "\n", { trimempty = true })
  local list = vim.split(git({ "log", "--format=  %h  %s", "-n", "10", head .. ".." .. branch }) or "", "\n", { trimempty = true })
  if count > #list then
    table.insert(list, ("  … and %d more"):format(count - #list))
  end
  local msg = ("Remove the %d unpushed commit%s after HEAD (%s) from branch '%s'?\n\n%s\n\n"
    .. "'%s' will then end at %s and you'll be back on it.\nWhat should happen to the changes %s?")
    :format(count, count == 1 and "" or "s", short, branch, table.concat(list, "\n"), branch, short, count == 1 and "it made" or "they made")
  local choice = vim.fn.confirm(msg, "&Keep them as uncommitted changes\n&Discard them\n&Cancel", 3, "Question")
  if choice ~= 1 and choice ~= 2 then
    return
  end

  if choice == 1 then
    -- go to the branch tip (carrying any uncommitted work), then drop the commits but keep their changes
    local _, co = git({ "checkout", branch })
    if co.code ~= 0 then
      return notify(("Nothing was removed: your uncommitted changes clash with '%s'.\n"
        .. "Commit or roll back your changes first, or choose \"Discard them\".\n\n%s"):format(branch, vim.trim(co.stderr)), vim.log.levels.WARN)
    end
    git({ "reset", "--soft", head })
  else
    -- move the branch back to HEAD and switch to it (files stay as they are)
    local _, mv = git({ "branch", "--force", branch, head })
    if mv.code ~= 0 then
      return notify("Could not remove the commits:\n" .. vim.trim(mv.stderr), vim.log.levels.ERROR)
    end
    git({ "checkout", branch })
  end
  after_checkout()
  notify(("Removed %d commit%s from '%s'; you're on '%s' at %s%s.\n(To undo this: git branch --force %s %s)"):format(
    count, count == 1 and "" or "s", branch, branch, short,
    choice == 1 and ", with their changes uncommitted (see the Commit tab)" or "", branch, tip))
end

--- Create a branch at `entry` (asks for the name), then offer to check it out.
function M.new_branch(entry)
  vim.ui.input({ prompt = ("New branch from %s: "):format(entry.short) }, function(name)
    name = name and vim.trim(name) or ""
    if name == "" then
      return
    end
    local _, valid = git({ "check-ref-format", "--branch", name })
    if valid.code ~= 0 then
      return notify(("'%s' isn't a valid branch name (no spaces, '..', '~', '^', ':' or '\\')"):format(name), vim.log.levels.WARN)
    end
    local _, exists = git({ "show-ref", "--verify", "--quiet", "refs/heads/" .. name })
    if exists.code == 0 then
      return notify(("A branch named '%s' already exists"):format(name), vim.log.levels.WARN)
    end
    local _, res = git({ "branch", name, entry.hash })
    if res.code ~= 0 then
      return notify("Could not create the branch:\n" .. vim.trim(res.stderr), vim.log.levels.ERROR)
    end
    M.refresh()
    local choice = vim.fn.confirm(("Created branch '%s' at %s.\nCheck it out now?"):format(name, entry.short), "&Checkout\n&Not now", 1, "Question")
    if choice == 1 then
      M.checkout(name, ("branch '%s'"):format(name))
    else
      notify(("Created branch '%s' at %s"):format(name, entry.short))
    end
  end)
end

--- Revert `entry`: a new commit (or staged changes) that undoes what it changed.
function M.revert_commit(entry)
  local msg = ("Revert commit %s?\n\n  %s\n\nThis adds changes that undo it; the commit itself stays in the history.")
    :format(entry.short, entry.subject)
  local choice = vim.fn.confirm(msg, "&Revert and commit\nRevert &without committing\n&Cancel", 3, "Question")
  if choice ~= 1 and choice ~= 2 then
    return
  end
  local args = { "revert", "--no-edit" }
  if #entry.parents > 1 then
    vim.list_extend(args, { "-m", "1" }) -- merge: undo what it brought in from the other branch
  end
  if choice == 2 then
    table.insert(args, "--no-commit")
  end
  table.insert(args, entry.hash)
  local _, res = git(args)
  local message = { ('Revert "%s"'):format(entry.subject), "", ("This reverts commit %s."):format(entry.hash) }

  local function to_commit_tab()
    pcall(function()
      require("ide.commit").set_message(message)
      require("neo-tree.command").execute({ action = "focus", source = "git_status", dir = S.root })
    end)
  end

  if res.code ~= 0 then
    local conflicts = vim.split(git({ "diff", "--name-only", "--diff-filter=U" }) or "", "\n", { trimempty = true })
    after_checkout()
    if #conflicts > 0 then
      to_commit_tab()
      return notify(("Reverting %s conflicts with later changes in:\n  %s\n\nFix the conflicts (<<<<<<< markers), then commit from the Commit tab.\n"
        .. "To give up instead: git revert --abort"):format(entry.short, table.concat(conflicts, "\n  ")), vim.log.levels.WARN)
    end
    local err = vim.trim(res.stderr ~= "" and res.stderr or res.stdout)
    if err:find("would be overwritten", 1, true) or err:find("local changes", 1, true) then
      return notify("Nothing was reverted: you have uncommitted changes in files this commit touched.\n"
        .. "Commit or roll back those changes first.\n\n" .. err, vim.log.levels.WARN)
    end
    return notify("Revert failed:\n" .. err, vim.log.levels.ERROR)
  end

  after_checkout()
  if choice == 2 then
    to_commit_tab()
    notify(("The changes undoing %s are staged.\nReview them and commit from the Commit tab (message pre-filled)."):format(entry.short))
  else
    notify(("Reverted %s: created %s"):format(entry.short, vim.trim(git({ "log", "-1", "--format=%h %s" }) or "")))
  end
end

--- Merge `target` (a branch name or commit hash) into the current branch, staying on it.
function M.merge(target, label)
  local current = vim.trim(git({ "branch", "--show-current" }) or "")
  if current == "" then
    return notify("Check out a branch first (HEAD is detached)", vim.log.levels.WARN)
  end
  local incoming = vim.split(git({ "log", "--format=  %h  %s", "HEAD.." .. target }) or "", "\n", { trimempty = true })
  if #incoming == 0 then
    return notify(("'%s' already contains %s"):format(current, label))
  end
  local shown = vim.list_slice(incoming, 1, 10)
  if #incoming > 10 then
    table.insert(shown, ("  … and %d more"):format(#incoming - 10))
  end
  local ff = is_ancestor("HEAD", target)
  local changes = vim.split(git({ "status", "--porcelain", "--untracked-files=no" }) or "", "\n", { trimempty = true })
  local msg = ("Merge %s into '%s'?\n\n%d commit%s will come in:\n%s"):format(label, current, #incoming, #incoming == 1 and "" or "s", table.concat(shown, "\n"))
  if ff then
    msg = msg .. ("\n\n('%s' has no commits of its own since then, so it simply moves forward.)"):format(current)
  end
  if #changes > 0 then
    msg = msg .. ("\n\nWarning: you have %d file(s) with uncommitted changes. They are kept, but the merge\n"
      .. "is refused if it needs to change those same files."):format(#changes)
  end
  if vim.fn.confirm(msg, "&Merge\n&Cancel", 2, #changes > 0 and "Warning" or "Question") ~= 1 then
    return
  end

  local _, res = git({ "merge", "--no-edit", target })
  after_checkout()
  if res.code == 0 then
    return notify(("Merged %s into '%s'%s"):format(label, current, ff and " (fast-forward)" or ""))
  end
  local conflicts = vim.split(git({ "diff", "--name-only", "--diff-filter=U" }) or "", "\n", { trimempty = true })
  if #conflicts > 0 then
    pcall(function()
      local merge_msg = vim.fn.readfile(vim.trim(git({ "rev-parse", "--git-path", "MERGE_MSG" }) or ""))
      require("ide.commit").set_message(vim.tbl_filter(function(l)
        return not l:match("^#")
      end, merge_msg))
      require("neo-tree.command").execute({ action = "focus", source = "git_status", dir = S.root })
    end)
    return notify(("Merging %s has conflicts in:\n  %s\n\nFix the conflicts (<<<<<<< markers), tick the files, then commit from the Commit tab.\n"
      .. "To give up instead: git merge --abort"):format(label, table.concat(conflicts, "\n  ")), vim.log.levels.WARN)
  end
  local err = vim.trim(res.stderr ~= "" and res.stderr or res.stdout)
  if err:find("would be overwritten", 1, true) then
    return notify("Nothing was merged: the merge needs to change files you have uncommitted changes in.\n"
      .. "Commit or roll back those changes first.\n\n" .. err, vim.log.levels.WARN)
  end
  notify("Merge failed:\n" .. err, vim.log.levels.ERROR)
end

--------------------------------------------------------------------------------
-- Rebase
--------------------------------------------------------------------------------

--- Runs git with no editor popping up (rebase would otherwise open one for messages).
local function git_noedit(args)
  local res = vim.system(vim.list_extend({ "git" }, args), { cwd = S.root, text = true, env = { GIT_EDITOR = "true" } }):wait()
  return res
end

--- Progress of a rebase in progress: { done, total } or nil.
function M.rebase_state()
  if not S.git_dir then
    return nil
  end
  for _, dir in ipairs({ "rebase-merge", "rebase-apply" }) do
    local path = S.git_dir .. "/" .. dir
    if vim.uv.fs_stat(path) then
      local function num(file)
        local f = io.open(path .. "/" .. file)
        local n = f and tonumber(f:read("*l"))
        if f then
          f:close()
        end
        return n
      end
      return { done = num("msgnum") or num("next") or 0, total = num("end") or num("last") or 0 }
    end
  end
end

local function unmerged_files()
  return vim.split(git({ "diff", "--name-only", "--diff-filter=U" }) or "", "\n", { trimempty = true })
end

--- After a rebase step: report success, or the next conflict.
local function report_rebase(res, label)
  after_checkout()
  if not M.rebase_state() then
    if res.code == 0 then
      return notify(label and ("Rebased onto %s"):format(label) or "Rebase finished")
    end
    return notify("Rebase failed:\n" .. vim.trim(res.stderr ~= "" and res.stderr or res.stdout), vim.log.levels.ERROR)
  end
  local st = M.rebase_state()
  local conflicts = unmerged_files()
  local stopped_at = vim.trim(git({ "log", "-1", "--format=%h %s", "REBASE_HEAD" }) or "")
  if #conflicts > 0 then
    return notify(("Rebase paused at commit %d of %d (%s): conflicts in\n  %s\n\n"
      .. "Fix the <<<<<<< markers, then click ⏵ Continue in the Git Log header\n(⏭ Skip drops this commit, ✕ Abort goes back to before the rebase).")
      :format(st.done, st.total, stopped_at, table.concat(conflicts, "\n  ")), vim.log.levels.WARN)
  end
  local err = vim.trim(res.stderr ~= "" and res.stderr or res.stdout)
  notify(("Rebase paused at commit %d of %d (%s):\n%s\n\nUse ⏵ Continue, ⏭ Skip or ✕ Abort in the Git Log header.")
    :format(st.done, st.total, stopped_at, err), vim.log.levels.WARN)
end

--- Replay the current branch's own commits on top of `target`, staying on the branch.
function M.rebase(target, label)
  local current = vim.trim(git({ "branch", "--show-current" }) or "")
  if current == "" then
    return notify("Check out a branch first (HEAD is detached)", vim.log.levels.WARN)
  end
  if M.rebase_state() then
    return notify("A rebase is already in progress: finish it with ⏵ Continue / ⏭ Skip / ✕ Abort in the Git Log header", vim.log.levels.WARN)
  end
  local ours = vim.split(git({ "log", "--format=  %h  %s", target .. "..HEAD" }) or "", "\n", { trimempty = true })
  local incoming = vim.split(git({ "rev-list", "HEAD.." .. target }) or "", "\n", { trimempty = true })
  if #incoming == 0 then
    return notify(("'%s' is already based on %s"):format(current, label))
  end
  local unpushed = vim.split(git({ "rev-list", target .. "..HEAD", "--not", "--remotes" }) or "", "\n", { trimempty = true })
  local pushed = #ours - #unpushed
  local changes = vim.split(git({ "status", "--porcelain", "--untracked-files=no" }) or "", "\n", { trimempty = true })

  local msg
  if #ours == 0 then
    msg = ("Rebase '%s' onto %s?\n\n'%s' has no commits of its own, so it simply moves forward (%d new commit%s).")
      :format(current, label, current, #incoming, #incoming == 1 and "" or "s")
  else
    local shown = vim.list_slice(ours, 1, 10)
    if #ours > 10 then
      table.insert(shown, ("  … and %d more"):format(#ours - 10))
    end
    msg = ("Rebase '%s' onto %s?\n\nYour %d commit%s will be replayed on top of it (%d new commit%s first):\n%s")
      :format(current, label, #ours, #ours == 1 and "" or "s", #incoming, #incoming == 1 and " comes in" or "s come in", table.concat(shown, "\n"))
  end
  if pushed > 0 then
    msg = msg .. ("\n\nWarning: %d of these commits %s already pushed. Rebasing rewrites them, so you'll have to\n"
      .. "force-push afterwards, which affects anyone who already pulled them."):format(pushed, pushed == 1 and "is" or "are")
  end
  if #changes > 0 then
    msg = msg .. ("\n\nYour uncommitted changes (%d file%s) will be set aside and put back afterwards."):format(#changes, #changes == 1 and "" or "s")
  end
  if vim.fn.confirm(msg, "&Rebase\n&Cancel", 2, pushed > 0 and "Warning" or "Question") ~= 1 then
    return
  end
  report_rebase(git_noedit({ "rebase", "--autostash", target }), label)
end

function M.rebase_continue()
  local remaining = {}
  for _, file in ipairs(unmerged_files()) do
    -- stage files whose conflicts were fixed (no markers left); report the others
    local ok, lines = pcall(vim.fn.readfile, S.root .. "/" .. file)
    local has_markers = ok and vim.iter(lines):any(function(l)
      return l:match("^<<<<<<< ") or l:match("^>>>>>>> ")
    end)
    if has_markers then
      table.insert(remaining, file)
    else
      git({ "add", "--", file })
    end
  end
  if #remaining > 0 then
    return notify(("These files still have conflict markers (<<<<<<< … >>>>>>>):\n  %s\n\nFix them, then Continue."):format(table.concat(remaining, "\n  ")), vim.log.levels.WARN)
  end
  vim.cmd("silent! wall") -- make sure fixed files are saved
  local res = git_noedit({ "rebase", "--continue" })
  local err = (res.stderr or "") .. (res.stdout or "")
  if res.code ~= 0 and err:find("nothing to commit", 1, true) then
    return notify("This commit has nothing left to apply after your fixes. Use ⏭ Skip to drop it.", vim.log.levels.WARN)
  end
  report_rebase(res)
end

function M.rebase_skip()
  report_rebase(git_noedit({ "rebase", "--skip" }))
end

function M.rebase_abort()
  if vim.fn.confirm("Abort the rebase?\nYour branch goes back to exactly how it was before the rebase started.", "&Abort rebase\n&Keep going", 2) ~= 1 then
    return
  end
  local res = git_noedit({ "rebase", "--abort" })
  after_checkout()
  if res.code == 0 then
    notify("Rebase aborted: back to how it was before")
  else
    notify("Could not abort:\n" .. vim.trim(res.stderr), vim.log.levels.ERROR)
  end
end

_G.IdeGitLogRebase = function(minwid)
  local action = ({ M.rebase_continue, M.rebase_skip, M.rebase_abort })[minwid]
  if action then
    vim.schedule(action)
  end
end

--- Header of the log: repository and branch, or the rebase controls while one is in progress.
_G.IdeGitLogWinbar = function()
  local left = ("%%#Title# GIT LOG %%*%%#IdeGitLogDim#%s  %s%%*"):format(
    vim.fn.fnamemodify(S.root or "", ":t"), S.branch and S.branch ~= "" and ("on " .. S.branch) or "")
  local st = M.rebase_state()
  if st then
    left = left .. ("   %%#IdeGitLogHead# REBASING %d/%d %%* "):format(st.done, st.total)
      .. "%#IdeGitLogBranch#%1@v:lua.IdeGitLogRebase@ ⏵ Continue %X%*"
      .. "%#Special#%2@v:lua.IdeGitLogRebase@ ⏭ Skip %X%*"
      .. "%#IdeGitLogHead#%3@v:lua.IdeGitLogRebase@ ✕ Abort %X%*"
  end
  -- ⇡ Push (N commits waiting; just "Push" when the branch hasn't been pushed before)
  local push = ""
  if S.branch and S.branch ~= "" and not st then
    local label = S.ahead == nil and " ⇡ Push " or S.ahead > 0 and (" ⇡ Push (%d) "):format(S.ahead) or nil
    if label then
      push = "%#IdeGitLogBranch#%@v:lua.IdeGitLogPush@" .. label .. "%X%*"
    end
  end
  local refresh = S.fetching and "%#IdeGitLogDim# ⟳ Fetching… %*"
    or "%#Special#%@v:lua.IdeGitLogRefresh@ ⟳ Refresh %X%*"
  return left .. "%=" .. push .. refresh
end

_G.IdeGitLogPush = function()
  vim.schedule(function()
    require("ide.git_repo").push(S.root)
  end)
end

local menu_actions = {}

_G.IdeGitLogMenu = function(i)
  local action = menu_actions[i]
  if action then
    vim.schedule(action)
  end
end

local function menu_escape(text)
  return (text:gsub("[%s%.\\|<]", "\\%0"):gsub("&", "&&"))
end

--- Right-click on a commit in the log: Checkout Revision / Checkout '<branch>' / Copy hash.
--- Returns false when the click isn't on a commit in this panel.
function M.right_click(pos)
  if not M.is_open() or pos.winid ~= S.list_win or pos.line == 0 then
    return false
  end
  local item = S.items[pos.line]
  if not (item and item.kind == "commit") then
    return false
  end
  vim.api.nvim_set_current_win(S.list_win)
  vim.api.nvim_win_set_cursor(S.list_win, { pos.line, 0 })
  select_commit(item.entry)

  local entry = item.entry
  local current = vim.trim(git({ "branch", "--show-current" }) or "")
  local head = vim.trim(git({ "rev-parse", "HEAD" }) or "")
  local branches = vim.tbl_filter(function(b)
    return not b:match("^%(") -- "(HEAD detached at …)" isn't a branch
  end, vim.split(git({ "branch", "--points-at", entry.hash, "--format=%(refname:short)" }) or "", "\n", { trimempty = true }))

  menu_actions = {}
  local entries = {}
  local function add(name, action)
    table.insert(menu_actions, action)
    table.insert(entries, { name, #menu_actions })
  end
  local function separator() -- between groups; never first or doubled
    if #entries > 0 and entries[#entries] ~= "sep" then
      table.insert(entries, "sep")
    end
  end
  for _, branch in ipairs(branches) do
    if branch ~= current then
      add(("Checkout '%s'"):format(branch), function()
        M.checkout(branch, ("branch '%s'"):format(branch))
      end)
    end
  end
  if entry.hash ~= head or current ~= "" then
    add(("Checkout Revision %s"):format(entry.short), function()
      M.checkout(entry.hash, ("revision %s (detached HEAD)"):format(entry.short))
    end)
  end
  add("New Branch…", function()
    M.new_branch(entry)
  end)
  separator()
  if current ~= "" and head ~= "" and not is_ancestor(entry.hash, head) then -- not merged yet
    local remote = vim.split(git({ "branch", "--remotes", "--points-at", entry.hash, "--format=%(refname:short)" }) or "", "\n", { trimempty = true })
    local names = vim.list_extend(vim.deepcopy(branches), vim.tbl_filter(function(r)
      return not r:match("/HEAD$")
    end, remote))
    for _, b in ipairs(names) do
      add(("Merge '%s' into '%s'…"):format(b, current), function()
        M.merge(b, ("'%s'"):format(b))
      end)
    end
    if #names == 0 then
      add(("Merge Commit %s into '%s'…"):format(entry.short, current), function()
        M.merge(entry.hash, ("commit %s"):format(entry.short))
      end)
    end
    for _, b in ipairs(names) do
      add(("Rebase '%s' onto '%s'…"):format(current, b), function()
        M.rebase(b, ("'%s'"):format(b))
      end)
    end
    if #names == 0 then
      add(("Rebase '%s' onto Commit %s…"):format(current, entry.short), function()
        M.rebase(entry.hash, ("commit %s"):format(entry.short))
      end)
    end
  end
  if head ~= "" and is_ancestor(entry.hash, head) then -- only commits in the current history
    add("Revert Commit…", function()
      M.revert_commit(entry)
    end)
  end
  local ahead = branches_ahead(entry, current, head)
  for _, a in ipairs(ahead) do
    local n = #a.commits
    add(("Remove %d Commit%s After HEAD from '%s'…"):format(n, n == 1 and "" or "s", a.branch), function()
      M.remove_after_head(a.branch)
    end)
  end
  local removable = removable_commits(entry, current)
  if removable then
    separator()
    add(#removable == 1 and "Remove This Commit…" or ("Remove This and %d Newer Commits…"):format(#removable - 1), function()
      M.remove_commits(entry)
    end)
  end
  separator()
  add("Copy Revision Number", M.copy_hash)

  pcall(vim.cmd.aunmenu, "]GitLogCommit")
  for i, e in ipairs(entries) do
    if e == "sep" then
      vim.cmd(("anoremenu ]GitLogCommit.-sep%d- <Nop>"):format(i))
    else
      vim.cmd(("anoremenu ]GitLogCommit.%s <Cmd>lua IdeGitLogMenu(%d)<CR>"):format(menu_escape(e[1]), e[2]))
    end
  end
  vim.cmd("popup ]GitLogCommit")
  return true
end

function M.copy_hash()
  local entry = S.selected
  if entry and entry.hash then
    vim.fn.setreg("+", entry.hash)
    vim.notify("Copied " .. entry.hash, vim.log.levels.INFO, { title = "Git Log" })
  end
end

function M.refresh()
  if not M.is_open() then
    return
  end
  local hash = S.selected and S.selected.hash
  S.files, S.details, S.selected = {}, {}, nil
  S.branch = vim.trim(git({ "branch", "--show-current" }) or "") -- may have changed (checkout, rebase…)
  S.ahead = require("ide.git_repo").ahead(S.root)
  load_entries()
  -- keep the same commit selected; if it's gone (amend, rebase, removed…), the newest one
  local newest
  for _, e in ipairs(S.entries) do
    if e.hash then
      newest = newest or e
      if e.hash == hash then
        S.selected = e
        break
      end
    end
  end
  S.selected = S.selected or newest
  render_list()
  render_files()
  render_details()
end

--- Refresh button / R: show the local state right away, then fetch from the remotes in the
--- background (so new remote commits and the ⇡ Push count show up) and refresh again.
function M.refresh_remote()
  M.refresh()
  if not M.is_open() or S.fetching then
    return
  end
  S.fetching = true
  vim.cmd.redrawstatus({ bang = true })
  local root = S.root
  vim.system({ "git", "fetch", "--all", "--prune", "--quiet" }, {
    cwd = root,
    text = true,
    env = { GIT_TERMINAL_PROMPT = "0" }, -- never hang waiting for credentials
  }, function(res)
    vim.schedule(function()
      S.fetching = false
      if S.root ~= root then
        return
      end
      if res.code ~= 0 then
        vim.notify("Could not fetch from the remote (showing local data):\n" .. vim.trim(res.stderr or ""),
          vim.log.levels.WARN, { title = "Git Log" })
      end
      M.refresh()
      vim.cmd.redrawstatus({ bang = true })
    end)
  end)
end

--------------------------------------------------------------------------------
-- Panel
--------------------------------------------------------------------------------

function M.is_open()
  return valid_win(S.list_win)
end

function M.close()
  M.close_diff()
  for _, win in ipairs({ S.list_win, S.files_win, S.det_win }) do
    if valid_win(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  S.list_win, S.files_win, S.det_win = nil, nil, nil
  vim.cmd.redrawtabline()
end

_G.IdeGitLogRefresh = function()
  vim.schedule(M.refresh_remote)
end
_G.IdeGitLogClose = function()
  vim.schedule(M.close)
end

local function panel_window_options(win)
  local wo = vim.wo[win]
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.foldcolumn = "0"
  wo.statuscolumn = ""
  wo.spell = false
  wo.list = false
  wo.wrap = false
  wo.winfixheight = true
  wo.winfixbuf = true
end

local function new_buf(name, ft)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = ft
  vim.b[buf].snacks_indent = false
  pcall(vim.api.nvim_buf_set_name, buf, name)
  return buf
end

function M.open(dir)
  if M.is_open() then
    vim.api.nvim_set_current_win(S.list_win)
    return
  end
  dir = dir or vim.fn.getcwd()
  local top = vim.system({ "git", "-C", dir, "rev-parse", "--show-toplevel" }, { text = true }):wait()
  if top.code ~= 0 then
    vim.notify("Not inside a Git repository", vim.log.levels.WARN, { title = "Git Log" })
    return
  end
  S.root = vim.trim(top.stdout)
  S.files, S.details, S.selected, S.collapsed = {}, {}, nil, {}
  load_entries()

  S.list_buf = new_buf("Git Log", "ide-gitlog")
  S.files_buf = new_buf("Changed Files", "ide-gitlog-files")
  S.det_buf = new_buf("Commit Details", "ide-gitlog-details")

  -- GIT LOG | CHANGED FILES | COMMIT DETAILS
  vim.cmd("botright 15split")
  S.list_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(S.list_win, S.list_buf)
  -- (the details pane takes its width from the files pane, so that one starts wider)
  S.files_win = vim.api.nvim_open_win(S.files_buf, false, { split = "right", win = S.list_win, width = math.floor(vim.o.columns * 0.53) })
  S.det_win = vim.api.nvim_open_win(S.det_buf, false, { split = "right", win = S.files_win, width = math.floor(vim.o.columns * 0.25) })
  for _, win in ipairs({ S.list_win, S.files_win, S.det_win }) do
    panel_window_options(win)
  end
  vim.wo[S.list_win].cursorline = true
  vim.wo[S.files_win].cursorline = true
  vim.wo[S.det_win].wrap = true
  vim.wo[S.det_win].linebreak = true
  S.git_dir = vim.trim(git({ "rev-parse", "--absolute-git-dir" }) or "")
  S.branch = vim.trim(git({ "branch", "--show-current" }) or "")
  S.ahead = require("ide.git_repo").ahead(S.root)
  vim.wo[S.list_win].winbar = "%{%v:lua.IdeGitLogWinbar()%}"
  vim.wo[S.det_win].winbar = "%#Title# COMMIT DETAILS %*%=%#Special#%@v:lua.IdeGitLogClose@ ✕ Close %X%*"

  -- start with the newest commit selected
  for _, e in ipairs(S.entries) do
    if e.hash then
      S.selected = e
      break
    end
  end
  render_list()
  render_files()
  render_details()

  -- keys
  for _, buf in ipairs({ S.list_buf, S.files_buf, S.det_buf }) do
    vim.keymap.set("n", "q", M.close, { buffer = buf, nowait = true, desc = "Close Git Log" })
    vim.keymap.set("n", "y", M.copy_hash, { buffer = buf, nowait = true, desc = "Copy commit hash" })
    vim.keymap.set("n", "R", M.refresh_remote, { buffer = buf, nowait = true, desc = "Refresh (fetch + reload)" })
  end
  local fopts = { buffer = S.files_buf, nowait = true }
  for _, key in ipairs({ "<CR>", "l", "o", "<2-LeftMouse>" }) do
    vim.keymap.set("n", key, function()
      M.files_activate(key ~= "<2-LeftMouse>")
    end, vim.tbl_extend("force", fopts, { desc = "Open diff / toggle folder" }))
  end
  vim.keymap.set("n", "<Tab>", function() -- jump to the changed files of the selected commit
    vim.api.nvim_set_current_win(S.files_win)
  end, { buffer = S.list_buf, desc = "Go to Changed Files" })
  vim.keymap.set("n", "<CR>", function()
    vim.api.nvim_set_current_win(S.files_win)
  end, { buffer = S.list_buf, desc = "Go to Changed Files" })

  -- selection follows the cursor: commit -> files & details, file -> diff
  local group = vim.api.nvim_create_augroup("ide_gitlog_panel", { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    buffer = S.list_buf,
    callback = function()
      local item = log_item()
      if item and item.kind == "commit" then
        select_commit(item.entry)
      end
    end,
  })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    buffer = S.files_buf,
    callback = function()
      local item = tree_item()
      if item and item.kind == "file" then
        M.files_activate(false)
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinResized", {
    group = group,
    callback = function()
      if M.is_open() and vim.tbl_contains(vim.v.event.windows or {}, S.list_win) then
        render_list()
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", { -- closing any part closes the whole panel
    group = group,
    callback = function(args)
      local closed = tonumber(args.match)
      if closed == S.list_win or closed == S.files_win or closed == S.det_win then
        vim.api.nvim_del_augroup_by_id(group)
        vim.schedule(M.close)
      end
    end,
  })
  vim.api.nvim_set_current_win(S.list_win)
  vim.cmd.redrawtabline()
end

function M.toggle(dir)
  if M.is_open() then
    M.close()
  else
    M.open(dir)
  end
end

return M
