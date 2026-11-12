-- Repository setup: create a Git repository in a folder, set its remote, push.
--   M.init(dir)        "Create Git Repository…" (git init)
--   M.set_remote(dir)  "Set Remote…" (add or change origin)
--   M.push(dir)        push the current branch; asks for a remote when there is none and sets
--                      the upstream on the first push (git push -u origin <branch>)
-- Pushing runs in a small terminal panel so Git can ask for a username/password or token.

local M = {}

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Git" })
end

local function git(dir, args)
  local res = vim.system(vim.list_extend({ "git" }, args), { cwd = dir, text = true }):wait()
  return res.code == 0 and vim.trim(res.stdout or "") or nil, res
end

--- After repository changes: refresh the explorer colors / Commit tab and the Git Log.
local function refresh()
  pcall(function()
    local events = require("neo-tree.events")
    events.fire_event(events.GIT_EVENT)
  end)
  pcall(function()
    require("ide.gitlog").refresh()
  end)
end

--- Top folder of the Git repository containing `path` (file or folder), or nil.
function M.root(path)
  if not path or path == "" then
    return nil
  end
  local dir = vim.fn.isdirectory(path) == 1 and path or vim.fn.fnamemodify(path, ":h")
  if vim.fn.isdirectory(dir) == 0 then
    return nil
  end
  return git(dir, { "rev-parse", "--show-toplevel" })
end

--------------------------------------------------------------------------------
-- Create a repository
--------------------------------------------------------------------------------

function M.init(dir)
  dir = vim.fn.fnamemodify(dir, ":p"):gsub("/$", "")
  local existing = M.root(dir)
  if existing then
    return notify(("'%s' is already inside a Git repository (%s)"):format(vim.fn.fnamemodify(dir, ":~"), vim.fn.fnamemodify(existing, ":~")), vim.log.levels.WARN)
  end
  local msg = ("Create a Git repository in\n  %s ?\n\nNothing is committed yet: afterwards, tick the files in the Commit tab and commit them.")
    :format(vim.fn.fnamemodify(dir, ":~"))
  if vim.fn.confirm(msg, "&Create\n&Cancel", 1, "Question") ~= 1 then
    return
  end
  local branch = git(dir, { "config", "--get", "init.defaultBranch" })
  local _, res = git(dir, { "init", "--initial-branch", (branch and branch ~= "") and branch or "main" })
  if res.code ~= 0 then
    return notify("Could not create the repository:\n" .. vim.trim(res.stderr), vim.log.levels.ERROR)
  end
  refresh()
  notify(("Created a Git repository in %s\nOpen the Commit tab to make the first commit; use Set Remote… to connect it to GitHub/GitLab.")
    :format(vim.fn.fnamemodify(dir, ":~")))
end

--------------------------------------------------------------------------------
-- Remote
--------------------------------------------------------------------------------

local function remote_url(root)
  return git(root, { "remote", "get-url", "origin" })
end

--- Ask for the URL of "origin" (pre-filled with the current one) and save it.
--- `then_cb(root)` runs after a URL was saved.
function M.set_remote(dir, then_cb)
  local root = M.root(dir)
  if not root then
    return notify("Not inside a Git repository: use Create Git Repository… first", vim.log.levels.WARN)
  end
  local current = remote_url(root)
  vim.ui.input({
    prompt = current and "Remote URL (origin): " or "Remote URL for 'origin' (e.g. https://github.com/you/repo.git or git@github.com:you/repo.git): ",
    default = current or "",
  }, function(url)
    url = url and vim.trim(url) or ""
    if url == "" or url == current then
      return
    end
    if not (url:match("^%a[%w+.-]*://") or url:match("^[%w._-]+@[%w._-]+:") or vim.fn.isdirectory(vim.fn.expand(url)) == 1) then
      return notify(("'%s' doesn't look like a Git URL"):format(url), vim.log.levels.WARN)
    end
    local _, res = git(root, current and { "remote", "set-url", "origin", url } or { "remote", "add", "origin", url })
    if res.code ~= 0 then
      return notify("Could not set the remote:\n" .. vim.trim(res.stderr), vim.log.levels.ERROR)
    end
    refresh()
    notify(("Remote 'origin' %s:\n  %s"):format(current and "changed" or "set", url))
    if then_cb then
      then_cb(root)
    elseif git(root, { "rev-parse", "--verify", "--quiet", "HEAD" }) then
      if vim.fn.confirm("Push the current branch to the remote now?", "&Push\n&Later", 1) == 1 then
        M.push(root)
      end
    end
  end)
end

--------------------------------------------------------------------------------
-- Push (in a terminal panel, so credentials can be typed)
--------------------------------------------------------------------------------

local push_win

local function push_terminal(root, args, title, on_done)
  if push_win and vim.api.nvim_win_is_valid(push_win) then
    pcall(vim.api.nvim_win_close, push_win, true)
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local prev = vim.api.nvim_get_current_win()
  vim.cmd("botright 8split")
  push_win = vim.api.nvim_get_current_win()
  local win = push_win
  vim.api.nvim_win_set_buf(win, buf)
  local wo = vim.wo[win]
  wo.number, wo.relativenumber, wo.signcolumn, wo.statuscolumn, wo.winfixheight = false, false, "no", "", true
  wo.winbar = ("%%#Title# %s %%*%%#Comment# type your username / token here if Git asks · q closes %%*"):format(title)
  vim.keymap.set("n", "q", function()
    pcall(vim.api.nvim_win_close, win, true)
  end, { buffer = buf, nowait = true })
  vim.fn.jobstart(vim.list_extend({ "git" }, args), {
    term = true,
    cwd = root,
    on_exit = function(_, code)
      vim.schedule(function()
        on_done(code)
        if code == 0 then
          -- success: close the panel after a moment (the notification says what happened)
          vim.defer_fn(function()
            if vim.api.nvim_win_is_valid(win) then
              pcall(vim.api.nvim_win_close, win, true)
              if vim.api.nvim_win_is_valid(prev) then
                vim.api.nvim_set_current_win(prev)
              end
            end
          end, 1500)
        else
          if vim.api.nvim_get_current_buf() == buf and vim.fn.mode() == "t" then
            vim.cmd.stopinsert() -- keep the error visible
          end
          vim.wo[win].winbar = ("%%#DiagnosticError# %s failed %%*%%#Comment# read the message above · q closes %%*"):format(title)
        end
      end)
    end,
  })
  vim.cmd.startinsert()
end

--- Push the current branch. No remote yet: asks for one first. No upstream yet: sets it.
function M.push(dir, on_done)
  local root = M.root(dir)
  if not root then
    return notify("Not inside a Git repository", vim.log.levels.WARN)
  end
  local branch = git(root, { "branch", "--show-current" })
  if not branch or branch == "" then
    return notify("Check out a branch before pushing (HEAD is detached)", vim.log.levels.WARN)
  end
  if not git(root, { "rev-parse", "--verify", "--quiet", "HEAD" }) then
    return notify("Nothing to push yet: make a first commit in the Commit tab", vim.log.levels.WARN)
  end
  if not remote_url(root) then
    notify("This repository has no remote yet: enter its URL to push")
    return M.set_remote(root, function()
      M.push(root, on_done)
    end)
  end
  local upstream = git(root, { "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}" })
  local args = upstream and { "push" } or { "push", "--set-upstream", "origin", branch }
  push_terminal(root, args, ("PUSH %s → %s"):format(branch, upstream or ("origin/" .. branch)), function(code)
    if code == 0 then
      notify(("Pushed '%s' to %s"):format(branch, upstream or ("origin/" .. branch)))
    else
      notify("Push failed (see the panel). Common causes: wrong URL, no access, or the remote has commits you don't have yet (pull first).", vim.log.levels.ERROR)
    end
    refresh()
    if on_done then
      on_done(code)
    end
  end)
end

--- Commits on the current branch not pushed yet: number, or nil when there's no upstream.
function M.ahead(root)
  local n = git(root, { "rev-list", "--count", "@{u}..HEAD" })
  return n and tonumber(n) or nil
end

--------------------------------------------------------------------------------
-- .gitignore
--------------------------------------------------------------------------------

--- A .gitignore line matching exactly this path (relative to the repository root):
--- "/src/secret.txt" or "/build/" for a folder. Special characters are escaped.
local function ignore_pattern(rel, is_dir)
  local p = rel:gsub("([%*%?%[%]\\])", "\\%1") -- glob characters are literal
  p = p:gsub(" +$", function(sp) -- trailing spaces would be dropped by Git
    return (sp:gsub(" ", "\\ "))
  end)
  return "/" .. p .. (is_dir and "/" or "")
end

--- Add a file or folder to the repository's .gitignore (root of the repository). If Git already
--- tracks it, offer to stop tracking it too (the files stay on disk).
function M.add_to_gitignore(path)
  path = vim.fn.fnamemodify(path, ":p"):gsub("/$", "")
  local root = M.root(path)
  if not root then
    return notify("Not inside a Git repository", vim.log.levels.WARN)
  end
  if path == root then
    return notify("The project folder itself can't be ignored", vim.log.levels.WARN)
  end
  local rel = path:sub(#root + 2)
  if rel == ".git" or rel:match("^%.git/") or rel == ".gitignore" then
    return notify(("'%s' can't be added to .gitignore"):format(rel), vim.log.levels.WARN)
  end
  local is_dir = vim.fn.isdirectory(path) == 1
  local pattern = ignore_pattern(rel, is_dir)
  local file = root .. "/.gitignore"
  local lines = vim.uv.fs_stat(file) and vim.fn.readfile(file) or {}
  if vim.tbl_contains(lines, pattern) then
    notify(("'%s' is already in .gitignore"):format(pattern))
  else
    -- keep the file ending with a newline; don't glue onto a last line without one
    if #lines > 0 and lines[#lines] == "" then
      table.remove(lines)
    end
    table.insert(lines, pattern)
    vim.fn.writefile(lines, file)
    local buf = vim.fn.bufnr(file)
    if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) and not vim.bo[buf].modified then
      vim.api.nvim_buf_call(buf, function()
        vim.cmd("silent! edit")
      end)
    end
    notify(("Added '%s' to .gitignore"):format(pattern))
  end

  -- .gitignore only affects untracked files: offer to stop tracking it
  local tracked = git(root, { "ls-files", "--", rel })
  if tracked and tracked ~= "" then
    local count = #vim.split(tracked, "\n", { trimempty = true })
    local msg = ("Git already tracks %s, so .gitignore has no effect on %s yet.\n\n"
      .. "Stop tracking %s? The file%s stay%s on disk; %s removed from the repository in your next commit.")
      :format(is_dir and ("%d file(s) in '%s'"):format(count, rel) or ("'" .. rel .. "'"), count == 1 and "it" or "them",
        count == 1 and "it" or "them", count == 1 and "" or "s", count == 1 and "s" or "", count == 1 and "it's" or "they're")
    if vim.fn.confirm(msg, "&Stop tracking\n&Keep tracking", 1, "Question") == 1 then
      local _, res = git(root, { "rm", "-r", "--cached", "--quiet", "--", rel })
      if res.code == 0 then
        notify(("Git stopped tracking '%s' (still on disk). Commit to make it final."):format(rel))
      else
        notify("Couldn't stop tracking it:\n" .. vim.trim(res.stderr), vim.log.levels.ERROR)
      end
    end
  end
  refresh()
end

return M
