-- IntelliJ-style "Commit" tool window built on Neo-tree's git_status source:
--   * a checkbox per changed file/folder: ticked = staged (included in the next commit)
--   * a commit message box under the tree with "Commit" and "Commit and Push" buttons
--   * Stage / Unstage / Show Diff / Rollback actions (used by the right-click menu)

local M = {}

M.BOX = { on = "󰄲", off = "󰄱", partial = "󰡖" }

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Commit" })
end

local function neo_git()
  return require("neo-tree.git")
end

local function refresh()
  require("neo-tree.events").fire_event(require("neo-tree.events").GIT_EVENT)
end

---@return string? root, table? status_map  (status_map: path -> code, only changed paths)
local function worktree(path)
  local g = neo_git()
  if g.worktrees and g.worktrees[path] then -- the repository root itself (not found by the lookup below)
    return path, g.worktrees[path].status
  end
  local root, wt = g.find_existing_worktree(path)
  return root, wt and wt.status
end

---@param root string
---@param args string[]
local function git(root, args, opts)
  local res = vim.system(vim.list_extend({ "git" }, args), vim.tbl_extend("force", { cwd = root, text = true }, opts or {})):wait()
  if res.code ~= 0 then
    notify(("git %s failed:\n%s"):format(args[1], vim.trim(res.stderr ~= "" and res.stderr or res.stdout)), vim.log.levels.ERROR)
  end
  return res
end

local function has_head(root)
  return vim.system({ "git", "rev-parse", "--verify", "--quiet", "HEAD" }, { cwd = root }):wait().code == 0
end

--------------------------------------------------------------------------------
-- Staging state
--------------------------------------------------------------------------------

---@param code string
---@return "on"|"off"|"partial"|nil
local function code_state(code)
  if code == "?" then
    return "off"
  end
  if code == "!" or #code < 2 then
    return nil
  end
  local x, y = code:sub(1, 1), code:sub(2, 2) -- x = staging area, y = working tree
  if y == "." then
    return "on"
  elseif x == "." then
    return "off"
  end
  return "partial" -- staged, then changed again
end

--- Files below `dir` (or `dir` itself), with their status codes.
local function changed_under(dir, status_map)
  local prefix = dir .. "/"
  local result = {}
  for path, code in pairs(status_map) do
    if type(code) == "string" and code ~= "!" and (path == dir or path:sub(1, #prefix) == prefix) then
      result[path] = code
    end
  end
  return result
end

---@return "on"|"off"|"partial"|nil
function M.stage_state(node)
  if not node or node.type == "message" or not node.path then
    return nil
  end
  local root, status_map = worktree(node.path)
  if not root or not status_map then
    return nil
  end
  if node.type ~= "directory" then
    local code = neo_git().find_existing_status_code(node.path)
    return type(code) == "string" and code_state(code) or nil
  end
  local on, off = false, false
  for _, code in pairs(changed_under(node.path, status_map)) do
    local s = code_state(code)
    on = on or s == "on" or s == "partial"
    off = off or s == "off" or s == "partial"
  end
  if on and off then
    return "partial"
  end
  return (on and "on") or (off and "off") or nil
end

function M.stage(node)
  local root = worktree(node.path)
  if not root then
    return
  end
  if node.path == root then
    git(root, { "add", "-A" })
  else
    git(root, { "add", "--", node.path })
  end
  refresh()
end

function M.unstage(node)
  local root = worktree(node.path)
  if not root then
    return
  end
  if has_head(root) then
    git(root, { "reset", "--quiet", "--", node.path })
  else -- brand-new repository: nothing to reset to
    git(root, { "rm", "-r", "--cached", "--quiet", "--", node.path })
  end
  refresh()
end

--- Tick / untick the checkbox: unstage if fully staged, otherwise stage everything.
function M.toggle(node)
  local s = M.stage_state(node)
  if s == "on" then
    M.unstage(node)
  elseif s then
    M.stage(node)
  end
end

--- Discard local changes (like IntelliJ "Rollback"). Newly added files are un-added but kept
--- on disk; untracked files are left alone (delete them instead).
--- What a rollback of `path` (file or folder) would do, asking Git directly.
---@return { root: string?, restore: string[], unadd: string[], unsaved: integer[] }
local function rollback_plan(path)
  local plan = { restore = {}, unadd = {}, unsaved = {} }
  local dir = vim.fn.isdirectory(path) == 1 and path or vim.fn.fnamemodify(path, ":h")
  local top = vim.system({ "git", "-C", dir, "rev-parse", "--show-toplevel" }, { text = true }):wait()
  if top.code ~= 0 then
    return plan
  end
  plan.root = vim.trim(top.stdout)
  -- tracked changes only (untracked files are never touched)
  local res = vim.system({ "git", "status", "--porcelain=v1", "-z", "--untracked-files=no", "--", path }, { cwd = plan.root, text = true }):wait()
  local entries = vim.split(res.stdout or "", "\0", { trimempty = true })
  local i = 1
  while i <= #entries do
    local xy, file = entries[i]:sub(1, 2), plan.root .. "/" .. entries[i]:sub(4)
    local x = xy:sub(1, 1)
    if x == "R" or x == "C" then -- renamed/copied: the next entry is the original path
      table.insert(plan.unadd, file)
      if x == "R" then
        table.insert(plan.restore, plan.root .. "/" .. entries[i + 1])
      end
      i = i + 1
    elseif x == "A" then -- new file added to Git: un-add it, keep it on disk
      table.insert(plan.unadd, file)
    else
      table.insert(plan.restore, file)
    end
    i = i + 1
  end
  -- open buffers with unsaved edits are rolled back too
  local prefix = path .. "/"
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if vim.bo[buf].modified and vim.bo[buf].buftype == "" and (name == path or name:sub(1, #prefix) == prefix) then
      local in_head = vim.system({ "git", "cat-file", "-e", "HEAD:" .. name:sub(#plan.root + 2) }, { cwd = plan.root }):wait().code == 0
      if in_head then
        table.insert(plan.unsaved, buf)
      end
    end
  end
  return plan
end

--- Whether "Rollback" has anything to do for this file/folder.
function M.can_rollback(path)
  local plan = rollback_plan(path)
  return #plan.restore + #plan.unadd + #plan.unsaved > 0
end

--- Discard local changes (like IntelliJ "Rollback"): files go back to their last committed
--- version, including unsaved edits in open buffers. Newly added files are un-added but kept
--- on disk; untracked files are left alone (delete them instead).
function M.rollback(node)
  local plan = rollback_plan(node.path)
  local files = {}
  for _, p in ipairs(vim.list_extend(vim.list_extend({}, plan.restore), plan.unadd)) do
    files[p] = true
  end
  for _, buf in ipairs(plan.unsaved) do
    files[vim.api.nvim_buf_get_name(buf)] = true
  end
  local count = vim.tbl_count(files)
  if count == 0 then
    notify("Nothing to roll back: no changes since the last commit (untracked files can only be deleted)", vim.log.levels.WARN)
    return
  end
  local rel = vim.fn.fnamemodify(node.path, ":~:.")
  local msg = count == 1 and next(files) == node.path
      and ("Rollback %s to the last commit?\nYour changes to it will be discarded."):format(rel)
    or ("Rollback %s to the last commit?\nYour changes to %d file(s) will be discarded."):format(rel, count)
  if vim.fn.confirm(msg, "&Rollback\n&Cancel", 2) ~= 1 then
    return
  end
  if #plan.unadd > 0 then
    git(plan.root, vim.list_extend({ "rm", "--cached", "--quiet", "--" }, plan.unadd))
  end
  if #plan.restore > 0 then
    git(plan.root, vim.list_extend({ "checkout", "HEAD", "--" }, plan.restore))
  end
  -- reload open buffers of the rolled-back files from disk (dropping unsaved edits)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and files[vim.api.nvim_buf_get_name(buf)] then
      vim.api.nvim_buf_call(buf, function()
        vim.cmd("silent! edit!")
      end)
    end
  end
  notify(("Rolled back %s"):format(rel))
  refresh()
end

--------------------------------------------------------------------------------
-- Diff
--------------------------------------------------------------------------------

local function editor_window()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_win_get_config(win).relative == "" and vim.bo[buf].buftype == "" and vim.bo[buf].filetype ~= "neo-tree" then
      return win
    end
  end
end

--- Whether the file has a committed version that differs from the current one.
--- (Asks Git directly, so it also works before the explorer has loaded Git status.)
function M.can_diff(path)
  if not path or path == "" or vim.fn.filereadable(path) == 0 then
    return false
  end
  local dir, name = vim.fn.fnamemodify(path, ":h"), vim.fn.fnamemodify(path, ":t")
  local function ok(args)
    return vim.system(vim.list_extend({ "git", "-C", dir }, args)):wait().code == 0
  end
  if not ok({ "cat-file", "-e", "HEAD:./" .. name }) then
    return false -- not in the last commit (new/untracked file, or not a Git repository)
  end
  local buf = vim.fn.bufnr(path)
  if buf ~= -1 and vim.bo[buf].modified then
    return true -- unsaved edits
  end
  return not ok({ "diff", "--quiet", "HEAD", "--", name })
end

--- Open the file and show its changes against the last commit side by side.
function M.show_diff(node)
  if not node or node.type == "directory" then
    return
  end
  local dir, name = vim.fn.fnamemodify(node.path, ":h"), vim.fn.fnamemodify(node.path, ":t")
  local in_last_commit = vim.system({ "git", "-C", dir, "cat-file", "-e", "HEAD:./" .. name }):wait().code == 0
  if vim.api.nvim_buf_get_name(0) ~= node.path then -- right-clicked in the editor: stay in that window
    local win = editor_window()
    if win then
      vim.api.nvim_set_current_win(win)
    else
      vim.cmd("botright vsplit")
    end
  end
  vim.cmd.edit(vim.fn.fnameescape(node.path))
  if not in_last_commit then
    return -- new file: nothing to compare with
  end
  local ok, gs = pcall(require, "gitsigns")
  if not ok then
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  local tries = 0
  local function try() -- gitsigns needs a moment to attach to a freshly opened buffer
    tries = tries + 1
    if vim.b[buf].gitsigns_status_dict or tries > 20 then
      vim.api.nvim_buf_call(buf, function()
        gs.diffthis("HEAD")
      end)
    else
      vim.defer_fn(try, 50)
    end
  end
  try()
end

--------------------------------------------------------------------------------
-- Neo-tree components (git_status source)
--------------------------------------------------------------------------------

function M.checkbox_component(_, node, _)
  local s = M.stage_state(node)
  if not s then
    return {}
  end
  return { text = M.BOX[s] .. " ", highlight = s == "off" and "NeoTreeDimText" or "NeoTreeIdeaStaged" }
end

function M.name_component(config, node, state)
  local result = state.components.name(config, node, state)
  if node:get_depth() == 1 then
    local _, status_map = worktree(node.path)
    local n = 0
    for _, code in pairs(status_map or {}) do
      if type(code) == "string" and code ~= "!" then
        n = n + 1
      end
    end
    result.text = n == 0 and "No changes" or ("Changes  %d file%s"):format(n, n == 1 and "" or "s")
  end
  return result
end

--- Click hook: a left click on a checkbox toggles it.
function M.checkbox_click(pos)
  local win = pos.winid
  if pos.line == 0 or win == 0 or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(win)
  if vim.bo[buf].filetype ~= "neo-tree" then
    return false
  end
  local state = require("neo-tree.sources.manager").get_state_for_window(win)
  if not state or state.name ~= "git_status" then
    return false
  end
  local line = vim.api.nvim_buf_get_lines(buf, pos.line - 1, pos.line, false)[1] or ""
  local col = pos.wincol - vim.fn.getwininfo(win)[1].textoff
  for _, glyph in pairs(M.BOX) do
    local idx = line:find(glyph, 1, true)
    if idx then
      local start = vim.fn.strdisplaywidth(line:sub(1, idx - 1)) + 1
      if col >= start and col <= start + vim.fn.strdisplaywidth(glyph) then
        local lnum = pos.line
        vim.schedule(function()
          local ok, node = pcall(state.tree.get_node, state.tree, lnum)
          if ok and node then
            M.toggle(node)
          end
        end)
        return true
      end
    end
  end
  return false
end

--------------------------------------------------------------------------------
-- Commit message box
--------------------------------------------------------------------------------

local box = { buf = nil, win = nil, root = nil }
local placeholder_ns = vim.api.nvim_create_namespace("ide_commit_placeholder")

local function update_placeholder()
  if not (box.buf and vim.api.nvim_buf_is_valid(box.buf)) then
    return
  end
  vim.api.nvim_buf_clear_namespace(box.buf, placeholder_ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(box.buf, 0, -1, false)
  if #lines == 1 and lines[1] == "" then
    vim.api.nvim_buf_set_extmark(box.buf, placeholder_ns, 0, 0, {
      virt_text = { { "Commit message", "Comment" } },
      virt_text_pos = "overlay",
    })
  end
end

local function get_buf()
  if box.buf and vim.api.nvim_buf_is_valid(box.buf) then
    return box.buf
  end
  local buf = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_name(buf, "Commit Message")
  vim.bo[buf].buftype = "acwrite" -- :w commits
  vim.bo[buf].bufhidden = "hide" -- keep the message while the panel is closed
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "gitcommit"
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      M.commit(false)
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufEnter" }, {
    buffer = buf,
    callback = update_placeholder,
  })
  box.buf = buf
  update_placeholder()
  return buf
end

_G.IdeCommit = function()
  vim.schedule(function()
    M.commit(false)
  end)
end
_G.IdeCommitPush = function()
  vim.schedule(function()
    M.commit(true)
  end)
end

function M.open_box(tree_win, path)
  box.root = worktree(path) or vim.fn.systemlist({ "git", "-C", path, "rev-parse", "--show-toplevel" })[1]
  if box.win and vim.api.nvim_win_is_valid(box.win) then
    return
  end
  local win = vim.api.nvim_open_win(get_buf(), false, { split = "below", win = tree_win, height = 6 })
  box.win = win
  local wo = vim.wo[win]
  wo.winfixheight = true
  wo.winfixbuf = true
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.foldcolumn = "0"
  wo.statuscolumn = ""
  wo.cursorline = false
  wo.wrap = true
  wo.linebreak = true
  wo.winbar = ("%%{%%v:lua.IdeCommitWinbar(%d)%%}"):format(win)
end

-- Buttons above the message box; shorter labels when the sidebar is narrow.
_G.IdeCommitWinbar = function(win)
  local width = vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_width(win) or 80
  local commit = " ✓ Commit "
  local push
  for _, label in ipairs({ " ⇡ Commit and Push ", " ⇡ Commit+Push ", " ⇡ Push " }) do
    push = label
    if vim.fn.strdisplaywidth(commit .. " " .. label) <= width then
      break
    end
  end
  return "%#NeoTreeIdeaStaged#%@v:lua.IdeCommit@" .. commit .. "%X%* %#Special#%@v:lua.IdeCommitPush@" .. push .. "%X%*"
end

--- Pre-fill the commit message box (e.g. after "Revert without committing").
function M.set_message(lines)
  local buf = get_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  update_placeholder()
end

function M.close_box()
  if box.win and vim.api.nvim_win_is_valid(box.win) then
    pcall(vim.api.nvim_win_close, box.win, true)
  end
  box.win = nil
end

---@param push boolean also push after committing
function M.commit(push)
  local root = box.root
  if not root or root == "" then
    notify("Not in a Git repository", vim.log.levels.ERROR)
    return
  end
  local lines = box.buf and vim.api.nvim_buf_get_lines(box.buf, 0, -1, false) or {}
  -- drop gitcommit-style comment lines and surrounding blank lines
  lines = vim.tbl_filter(function(l)
    return not l:match("^#")
  end, lines)
  local msg = vim.trim(table.concat(lines, "\n"))
  if msg == "" then
    notify("Enter a commit message first", vim.log.levels.WARN)
    if box.win and vim.api.nvim_win_is_valid(box.win) then
      vim.api.nvim_set_current_win(box.win)
    end
    return
  end
  local git_dir = vim.trim(vim.system({ "git", "rev-parse", "--absolute-git-dir" }, { cwd = root, text = true }):wait().stdout or "")
  if vim.uv.fs_stat(git_dir .. "/rebase-merge") or vim.uv.fs_stat(git_dir .. "/rebase-apply") then
    notify("A rebase is in progress: a commit now would get mixed into it.\n"
      .. "Use ⏵ Continue / ⏭ Skip / ✕ Abort in the Git Log header (<leader>gv) instead.", vim.log.levels.WARN)
    return
  end
  local function in_progress(ref) -- finishing a merge/revert may legitimately stage nothing
    return vim.system({ "git", "rev-parse", "-q", "--verify", ref }, { cwd = root }):wait().code == 0
  end
  local finishing = in_progress("MERGE_HEAD") or in_progress("REVERT_HEAD")
  if not finishing and vim.system({ "git", "diff", "--cached", "--quiet" }, { cwd = root }):wait().code == 0 then
    notify("Nothing to commit: tick the files you want to include", vim.log.levels.WARN)
    return
  end
  vim.system({ "git", "commit", "-F", "-" }, { cwd = root, stdin = msg .. "\n", text = true }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then
        notify("Commit failed:\n" .. vim.trim(res.stderr ~= "" and res.stderr or res.stdout), vim.log.levels.ERROR)
        return
      end
      notify(vim.split(vim.trim(res.stdout), "\n")[1] or "Committed")
      if box.buf and vim.api.nvim_buf_is_valid(box.buf) then
        vim.api.nvim_buf_set_lines(box.buf, 0, -1, false, {})
        vim.bo[box.buf].modified = false
        update_placeholder()
      end
      refresh()
      pcall(function() -- show the new commit in the Git Log panel, if it's open
        require("ide.gitlog").refresh()
      end)
      if push then -- (asks for a remote / sets the upstream when needed, see ide/git_repo.lua)
        require("ide.git_repo").push(root)
      end
    end)
  end)
  if box.buf and vim.api.nvim_buf_is_valid(box.buf) then
    vim.bo[box.buf].modified = false -- :w succeeded from Vim's point of view
  end
end

return M
