-- Right-click context menu for the Neo-tree file explorer (IntelliJ-style):
--   right-click a folder -> "New File" / "New Folder" creates it inside that folder
--   right-click a file   -> creates it next to that file (in the same folder)
--   Rename / Delete / Copy Path act on the clicked file or folder
--   Stage / Unstage (shown only when the file or folder has changes to stage/unstage)
--   Show Diff: current file vs. last commit, side by side (only for changed, committed files)
--   Rollback…: discard changes since the last commit (asks first; only when there are changes)
--   Create Git Repository… (folders outside a repository), Set Git Remote…, Push,
--   Add to .gitignore
-- In the editor: "Show Git Diff" / "Rollback to Last Commit…" in Neovim's right-click menu.
-- In the Commit tab: Stage / Unstage / Show Diff / Rollback / Copy Path.
--   ▶ Run / ◉ Profile 'Main.main()' for Java files with a main method, and ▶ Run / ◉ Profile
--   Tests for JUnit test files and folders (lua/ide/java_run.lua, lua/ide/profiler.lua)
-- In the Git Log panel: right-click a commit to check it out (see lua/ide/gitlog.lua).
-- Right-clicking anywhere else keeps Neovim's normal right-click menu.

local target_state -- neo-tree state of the explorer that was right-clicked

local function run(command)
  if not target_state then
    return
  end
  require("neo-tree.sources.filesystem.commands")[command](target_state)
end

_G.NeotreeContextNewFile = function()
  run("add")
end
_G.NeotreeContextNewFolder = function()
  run("add_directory")
end
_G.NeotreeContextRename = function()
  run("rename")
end
_G.NeotreeContextDelete = function()
  run("delete") -- neo-tree asks for confirmation first
end
_G.NeotreeContextCopyPath = function()
  local node = target_state and target_state.tree:get_node()
  if not node then
    return
  end
  local path = node:get_id()
  vim.fn.setreg("+", path, "c")
  vim.notify("Copied: " .. path, vim.log.levels.INFO, { title = "Explorer" })
end

-- Remove a menu before (re)defining it, e.g. when the config is reloaded.
local function clear_menu(name)
  local errmsg = vim.v.errmsg
  pcall(vim.cmd.aunmenu, name) -- fails harmlessly on first load (menu doesn't exist yet)
  vim.v.errmsg = errmsg
end

-- A hidden menu (names starting with "]" never appear in a menu bar) shown with :popup.
clear_menu("]NeoTree")
vim.cmd([[
  anoremenu ]NeoTree.New\ File   <Cmd>lua NeotreeContextNewFile()<CR>
  anoremenu ]NeoTree.New\ Folder <Cmd>lua NeotreeContextNewFolder()<CR>
  anoremenu ]NeoTree.-sep1-      <Nop>
  anoremenu ]NeoTree.Rename      <Cmd>lua NeotreeContextRename()<CR>
  anoremenu ]NeoTree.Delete      <Cmd>lua NeotreeContextDelete()<CR>
  anoremenu ]NeoTree.-sep2-      <Nop>
  anoremenu ]NeoTree.Stage       <Cmd>lua NeotreeContextGit("stage")<CR>
  anoremenu ]NeoTree.Unstage     <Cmd>lua NeotreeContextGit("unstage")<CR>
  anoremenu ]NeoTree.Show\ Diff  <Cmd>lua NeotreeContextGit("show_diff")<CR>
  anoremenu ]NeoTree.Rollback…   <Cmd>lua NeotreeContextGit("rollback")<CR>
  anoremenu ]NeoTree.Create\ Git\ Repository…  <Cmd>lua NeotreeContextRepo("init")<CR>
  anoremenu ]NeoTree.Set\ Git\ Remote…  <Cmd>lua NeotreeContextRepo("set_remote")<CR>
  anoremenu ]NeoTree.Push        <Cmd>lua NeotreeContextRepo("push")<CR>
  anoremenu ]NeoTree.Add\ to\ \.gitignore  <Cmd>lua NeotreeContextIgnore()<CR>
  anoremenu ]NeoTree.-sep3-      <Nop>
  anoremenu ]NeoTree.Copy\ Path  <Cmd>lua NeotreeContextCopyPath()<CR>
]])

-- "▶ Run 'Main.main()'" at the top of the menu for Java files with a main method
-- (lua/ide/java_run.lua).
local run_items = {} -- Run / Profile items currently in the menu

--- opts: nil (run) or { profile = true }
_G.NeotreeContextTests = function(profile)
  local node = target_state and target_state.tree:get_node()
  local opts = profile and { profile = true } or nil
  if node and node.path then
    if node.type == "directory" then
      require("ide.java_run").run_dir_tests(node.path, opts)
    else
      require("ide.java_run").run_tests(node.path, nil, opts)
    end
  end
end
_G.NeotreeContextRun = function(profile)
  local node = target_state and target_state.tree:get_node()
  if node and node.path then
    require("ide.java_run").run(node.path, profile and { profile = true } or nil)
  end
end

_G.NeotreeContextGoTests = function()
  local node = target_state and target_state.tree:get_node()
  if node and node.path then
    if node.type == "directory" then
      require("ide.go_run").run_dir_tests(node.path)
    else
      require("ide.go_run").run_tests(node.path)
    end
  end
end

_G.NeotreeContextGoRun = function()
  local node = target_state and target_state.tree:get_node()
  if node and node.path then
    require("ide.go_run").run(node.path)
  end
end

local function menu_text(text)
  return (text:gsub("[%s%.\\]", "\\%0"))
end

local function update_run_item(node)
  for _, item in ipairs(run_items) do
    pcall(vim.cmd.aunmenu, item)
  end
  run_items = {}
  pcall(vim.cmd.aunmenu, "]NeoTree.-run-sep-")
  -- "1.1": the item's priority is the 2nd number (the 1st is the menu's); same-priority items
  -- keep the order they're added in, and the separator is added last (below them)
  local function add(_, text, rhs)
    local item = "]NeoTree." .. menu_text(text)
    vim.cmd(("anoremenu 1.1 %s <Cmd>lua %s<CR>"):format(item, rhs))
    table.insert(run_items, item)
  end
  local jr = require("ide.java_run")
  local name = node and node.type == "file" and jr.runnable(node.path)
  if name then
    add("1", ("▶ Run '%s.main()'"):format(name), "NeotreeContextRun()")
    add("1.01", ("◉ Profile '%s.main()'"):format(name), "NeotreeContextRun(true)")
  end
  local go_name = node and node.type == "file" and require("ide.go_run").runnable(node.path)
  if go_name then
    add("1", ("▶ Run '%s'"):format(go_name), "NeotreeContextGoRun()")
  end
  local tests = node and node.type == "file" and jr.test_info(node.path)
  local dir_has_tests = node and node.type == "directory" and node.path and #jr.tests_in_dir(node.path, true) > 0
  if dir_has_tests then
    tests = { class = vim.fn.fnamemodify(node.path, ":t") }
  end
  if tests then
    local what = dir_has_tests and ("All Tests in '%s'"):format(tests.class)
      or tests.abstract and ("Tests in '%s' (%d implementations)"):format(tests.class, #tests.implementations)
      or ("Tests in '%s'"):format(tests.class)
    add("1.02", "▶ Run " .. what, "NeotreeContextTests()")
    add("1.03", "◉ Profile " .. what, "NeotreeContextTests(true)")
  end
  -- Go tests: a _test.go file, or every test in a folder (sub-folders included)
  local gr = require("ide.go_run")
  local go_tests = node and node.type == "file" and gr.test_info(node.path)
  if go_tests then
    add("1.04", ("▶ Run Tests in '%s'"):format(go_tests.file), "NeotreeContextGoTests()")
  elseif node and node.type == "directory" and node.path and gr.dir_has_tests(node.path) then
    -- (a different name when the folder also has Java tests: menu items need unique names)
    add("1.04", ("▶ Run All %sTests in '%s'"):format(dir_has_tests and "Go " or "", vim.fn.fnamemodify(node.path, ":t")),
      "NeotreeContextGoTests()")
  end
  if #run_items > 0 then
    vim.cmd("anoremenu 1.1 ]NeoTree.-run-sep- <Nop>")
  end
end

-- Show Stage / Unstage only when they apply to the clicked file or folder
-- (disabled items are hidden in the popup).
local function update_git_items(menu)
  local node = target_state and target_state.tree:get_node()
  local s = node and node.type ~= "message" and require("ide.commit").stage_state(node)
  local function set(item, enabled)
    vim.cmd(("amenu %s %s.%s"):format(enabled and "enable" or "disable", menu, item))
  end
  local can_stage, can_unstage = s == "off" or s == "partial", s == "on" or s == "partial"
  local commit = require("ide.commit")
  local can_diff = node and node.type == "file" and commit.can_diff(node.path)
  local can_rollback = node and node.type ~= "message" and node.path and commit.can_rollback(node.path)
  set("Stage", can_stage)
  set("Unstage", can_unstage)
  set("Show\\ Diff", can_diff)
  set("Rollback…", can_rollback)
  -- repository setup: create one outside a repository; remote / push inside one
  local path = node and node.type ~= "message" and node.path
  local repo = path and require("ide.git_repo").root(path)
  if menu == "]NeoTree" then
    set("Create\\ Git\\ Repository…", path and not repo and node.type == "directory")
    set("Set\\ Git\\ Remote…", repo ~= nil)
  else
    set("Set\\ Remote…", repo ~= nil)
  end
  set("Push", repo ~= nil)
  if menu == "]NeoTree" then -- not on the project folder itself, .git or .gitignore
    local rel = repo and path and path:sub(#repo + 2) or ""
    set("Add\\ to\\ \\.gitignore", repo ~= nil and path ~= repo and rel ~= ".gitignore" and rel ~= ".git" and not rel:match("^%.git/"))
  end
  if menu == "]NeoTree" then
    -- no double separator when there is no Git item
    set("-sep3-", can_stage or can_unstage or can_diff or can_rollback or path ~= nil)
    update_run_item(node)
  end
end

-- Editor right-click menu: "Show Git Diff" / "Rollback to Last Commit…" for the current file,
-- shown only when it has changes since the last commit.
local function current_file()
  return { type = "file", path = vim.api.nvim_buf_get_name(0) }
end
_G.IdeEditorGit = function(action)
  require("ide.commit")[action](current_file())
end
pcall(vim.cmd.aunmenu, "PopUp.Show\\ Git\\ Diff")
pcall(vim.cmd.aunmenu, "PopUp.Rollback\\ to\\ Last\\ Commit…")
vim.cmd([[
  anoremenu PopUp.Show\ Git\ Diff                <Cmd>lua IdeEditorGit("show_diff")<CR>
  anoremenu PopUp.Rollback\ to\ Last\ Commit…    <Cmd>lua IdeEditorGit("rollback")<CR>
]])
vim.api.nvim_create_autocmd("MenuPopup", {
  group = vim.api.nvim_create_augroup("ide_popup_git_diff", { clear = true }),
  callback = function()
    local commit = require("ide.commit")
    local path = current_file().path
    local ok_diff, diff = pcall(commit.can_diff, path)
    local ok_rb, rb = pcall(commit.can_rollback, path)
    vim.cmd("amenu " .. ((ok_diff and diff) and "enable" or "disable") .. " PopUp.Show\\ Git\\ Diff")
    vim.cmd("amenu " .. ((ok_rb and rb) and "enable" or "disable") .. " PopUp.Rollback\\ to\\ Last\\ Commit…")
  end,
})

-- Create Git Repository… / Set Remote… / Push (lua/ide/git_repo.lua). On a file, they act on
-- its folder.
_G.NeotreeContextIgnore = function()
  local node = target_state and target_state.tree:get_node()
  if node and node.path then
    require("ide.git_repo").add_to_gitignore(node.path)
  end
end

_G.NeotreeContextRepo = function(action)
  local node = target_state and target_state.tree:get_node()
  if node and node.path then
    local dir = node.type == "directory" and node.path or vim.fn.fnamemodify(node.path, ":h")
    require("ide.git_repo")[action](dir)
  end
end

-- Menu for the Commit tab (git changes); actions live in lua/ide/commit.lua.
_G.NeotreeContextGit = function(action)
  local node = target_state and target_state.tree:get_node()
  if node and node.type ~= "message" then
    require("ide.commit")[action](node)
  end
end

clear_menu("]NeoTreeGit")
vim.cmd([[
  anoremenu ]NeoTreeGit.Stage        <Cmd>lua NeotreeContextGit("stage")<CR>
  anoremenu ]NeoTreeGit.Unstage      <Cmd>lua NeotreeContextGit("unstage")<CR>
  anoremenu ]NeoTreeGit.-sep1-       <Nop>
  anoremenu ]NeoTreeGit.Show\ Diff   <Cmd>lua NeotreeContextGit("show_diff")<CR>
  anoremenu ]NeoTreeGit.Rollback…    <Cmd>lua NeotreeContextGit("rollback")<CR>
  anoremenu ]NeoTreeGit.-sep3-       <Nop>
  anoremenu ]NeoTreeGit.Set\ Remote…  <Cmd>lua NeotreeContextRepo("set_remote")<CR>
  anoremenu ]NeoTreeGit.Push         <Cmd>lua NeotreeContextRepo("push")<CR>
  anoremenu ]NeoTreeGit.-sep2-       <Nop>
  anoremenu ]NeoTreeGit.Copy\ Path   <Cmd>lua NeotreeContextCopyPath()<CR>
]])

local function on_right_click()
  local pos = vim.fn.getmousepos()
  -- a commit in the Git Log panel (lua/ide/gitlog.lua) has its own menu
  if package.loaded["ide.gitlog"] and require("ide.gitlog").right_click(pos) then
    return
  end
  local win = pos.winid
  local is_explorer = win ~= 0
    and vim.api.nvim_win_is_valid(win)
    and vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "neo-tree"
  local state = is_explorer and require("neo-tree.sources.manager").get_state_for_window(win)

  local menu = state and ({ filesystem = "]NeoTree", git_status = "]NeoTreeGit" })[state.name]
  if not menu then
    -- Not the file explorer: fall back to the default right-click behaviour.
    vim.api.nvim_feedkeys(vim.keycode("<RightMouse>"), "n", false)
    return
  end

  -- Focus the explorer and put the cursor on the clicked entry so neo-tree acts on it.
  vim.api.nvim_set_current_win(win)
  if pos.line > 0 then
    vim.api.nvim_win_set_cursor(win, { math.min(pos.line, vim.api.nvim_buf_line_count(0)), 0 })
  end
  target_state = state
  update_git_items(menu)
  vim.cmd("popup " .. menu)
end

vim.keymap.set("n", "<RightMouse>", on_right_click, { desc = "Context menu (explorer-aware)" })

return {}
