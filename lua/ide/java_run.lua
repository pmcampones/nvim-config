-- Run a Java class's main() method (IntelliJ-style "Run 'Main.main()'"):
--   1. save open files and let the Java language server (jdtls) compile the project
--   2. ask jdtls for the project's runtime classpath (output folders + dependencies)
--   3. run `java -cp <classpath> <package.Class>` in a "Run" panel at the bottom
-- Without jdtls it falls back to Java's source launcher (`java path/Main.java`).
-- The Run panel takes keyboard input for the program; its header has Rerun / Stop / Close.

local M = {}

local run = { buf = nil, win = nil, job = nil, last = nil }

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Run" })
end

--------------------------------------------------------------------------------
-- Finding main()
--------------------------------------------------------------------------------

local function strip_comments(lines)
  local text = table.concat(lines, "\n")
  text = text:gsub("/%*.-%*/", function(c) -- keep line count for block comments
    return (c:gsub("[^\n]", " "))
  end)
  text = text:gsub("//[^\n]*", "")
  return text
end

--- Whether Java source has a runnable main method:
---   static void main(String[] args) / (String args[]) / (String... args)
---   and Java 25's instance main: void main()
function M.has_main(lines)
  local text = strip_comments(lines)
  for line in (text .. "\n"):gmatch("(.-)\n") do
    -- static void main(<a String array/varargs parameter>), in any modifier order / spelling
    local params = line:match("%f[%w]static%f[%W].-%f[%w]void%s+main%s*%(([^%)]*)%)?")
    if params and params:match("%f[%w]String%f[%W]") and (params:match("%[") or params:match("%.%.%.")) then
      return true
    end
    if line:match("^%s*[%w%s]*%f[%w]void%s+main%s*%(%s*%)") then -- Java 25 instance main
      return true
    end
  end
  return false
end

--- Fully-qualified class name: package + file name (the class main lives in).
function M.class_name(path, lines)
  local pkg = strip_comments(lines):match("%f[%w]package%s+([%w_%.]+)%s*;")
  local cls = vim.fn.fnamemodify(path, ":t:r")
  return pkg and (pkg .. "." .. cls) or cls
end

local function file_lines(path)
  local buf = vim.fn.bufnr(path)
  if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  return ok and lines or {}
end

--- For menus: "Main" when `path` is a Java file with a main method, else nil.
function M.runnable(path)
  if not path or not path:match("%.java$") then
    return nil
  end
  local lines = file_lines(path)
  if not M.has_main(lines) then
    return nil
  end
  return vim.fn.fnamemodify(path, ":t:r"), lines
end

--------------------------------------------------------------------------------
-- Run panel
--------------------------------------------------------------------------------

_G.IdeRunRerun = function()
  vim.schedule(function()
    if run.last then
      M.run(run.last)
    end
  end)
end
_G.IdeRunStop = function()
  vim.schedule(M.stop)
end
_G.IdeRunClose = function()
  vim.schedule(M.close)
end

_G.IdeRunWinbar = function()
  local title = run.title or ""
  if run.preparing then
    return ("%%#Title# RUN %%*%%#Special#%s%%* %%#DiagnosticWarn# ⏳ preparing… %ds %%*%%=%%#Special#%%@v:lua.IdeRunClose@ ✕ Cancel %%X%%*")
      :format(title, math.floor((vim.uv.now() - run.t0) / 1000))
  end
  local running = run.job and vim.fn.jobwait({ run.job }, 0)[1] == -1
  local status = "%#DiagnosticOk# ● running %*"
  if not running then
    local code = run.exit_code
    status = code == nil and "%#Comment# finished %*"
      or code == 0 and "%#Comment# finished (exit code 0) %*"
      or ("%%#DiagnosticError# finished (exit code %d) %%*"):format(code)
  end
  return ("%%#Title# RUN %%*%%#Special#%s%%* %s%%=%%#DiagnosticOk#%%@v:lua.IdeRunRerun@ ⟳ Rerun %%X%%*"):format(title, status)
    .. (running and "%#DiagnosticError#%@v:lua.IdeRunStop@ ■ Stop %X%*" or "")
    .. "%#Special#%@v:lua.IdeRunClose@ ✕ Close %X%*"
end

function M.stop()
  if run.job then
    pcall(vim.fn.jobstop, run.job)
  end
end

function M.close()
  M.stop()
  run.token = (run.token or 0) + 1 -- cancels a run that is still being prepared
  run.preparing = false
  if run.win and vim.api.nvim_win_is_valid(run.win) then
    pcall(vim.api.nvim_win_close, run.win, true)
  end
  run.win = nil
end

--- Show `buf` in the Run panel (opening the panel if needed) and drop the previous buffer.
local function show_in_panel(buf)
  local old = run.buf
  if run.win and vim.api.nvim_win_is_valid(run.win) then
    vim.api.nvim_win_set_buf(run.win, buf)
  else
    local prev = vim.api.nvim_get_current_win()
    vim.cmd("botright 12split")
    run.win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(run.win, buf)
    vim.api.nvim_set_current_win(prev)
  end
  -- (set every time: some window options reset when the window gets a new buffer)
  local wo = vim.wo[run.win]
  wo.number, wo.relativenumber, wo.signcolumn, wo.statuscolumn = false, false, "no", ""
  wo.winfixheight = true
  wo.wrap = true
  wo.winbar = "%{%v:lua.IdeRunWinbar()%}"
  if old and old ~= buf and vim.api.nvim_buf_is_valid(old) then
    pcall(vim.api.nvim_buf_delete, old, { force = true })
  end
  run.buf = buf
  vim.keymap.set("n", "q", M.close, { buffer = buf, nowait = true, desc = "Close Run panel" })
end

local progress_ns = vim.api.nvim_create_namespace("ide_java_run_progress")

--- Open the Run panel right away with a log of what's happening while the program is being
--- prepared (language server start, Maven/Gradle import, build, classpath).
local function prepare(title)
  M.stop()
  run.token = (run.token or 0) + 1
  run.preparing, run.title, run.exit_code, run.t0, run.job = true, title, nil, vim.uv.now(), nil
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  show_in_panel(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { ("Preparing to run %s…"):format(title) })
  local timer = vim.uv.new_timer()
  timer:start(1000, 1000, vim.schedule_wrap(function() -- keep the elapsed time in the header ticking
    if not run.preparing then
      timer:stop()
      timer:close()
      return
    end
    vim.cmd.redrawstatus({ bang = true })
  end))
  return run.token
end

--- Add a line to the preparation log (only while that run is still current).
local function status(token, msg, hl)
  if token ~= run.token or not (run.buf and vim.api.nvim_buf_is_valid(run.buf)) or not run.preparing then
    return
  end
  local line = ("%5.1fs  %s"):format((vim.uv.now() - run.t0) / 1000, msg)
  local lines = vim.split(line, "\n")
  local n = vim.api.nvim_buf_line_count(run.buf)
  vim.api.nvim_buf_set_lines(run.buf, n, n, false, lines)
  if hl then
    for i = n, n + #lines - 1 do
      vim.api.nvim_buf_set_extmark(run.buf, progress_ns, i, 0, { line_hl_group = hl })
    end
  end
  if run.win and vim.api.nvim_win_is_valid(run.win) then
    pcall(vim.api.nvim_win_set_cursor, run.win, { vim.api.nvim_buf_line_count(run.buf), 0 })
  end
end

--- Preparation failed: say why in the panel and stop "preparing".
local function fail(token, msg)
  status(token, msg, "DiagnosticError")
  if token == run.token then
    run.preparing = false
    vim.cmd.redrawstatus({ bang = true })
  end
end

--- Start `cmd` in the Run panel (reusing it), with keyboard input going to the program.
local function start(token, cmd, cwd, title)
  if token ~= run.token then
    return -- cancelled (✕) or replaced by another run while preparing
  end
  M.stop()
  run.preparing = false
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  show_in_panel(buf)
  run.title, run.exit_code = title, nil
  vim.api.nvim_set_current_win(run.win)
  vim.api.nvim_buf_call(buf, function()
    run.job = vim.fn.jobstart(cmd, {
      term = true,
      cwd = cwd,
      on_exit = function(_, code)
        run.exit_code = code
        vim.schedule(function()
          -- leave typing mode so the next key doesn't close the output (Neovim prints
          -- "[Process exited N]" itself)
          if vim.api.nvim_get_current_buf() == buf and vim.fn.mode() == "t" then
            vim.cmd.stopinsert()
          end
          vim.cmd.redrawstatus({ bang = true })
        end)
      end,
    })
  end)
  vim.keymap.set("n", "q", M.close, { buffer = buf, nowait = true, desc = "Close Run panel" })
  vim.cmd.startinsert() -- typing goes to the program (Scanner, System.in…)
end

--- jdtls work in progress (import, build…): token -> true. The project is only ready to
--- build once this is empty; building earlier reports false "compile errors".
local busy = {}

--- Show jdtls progress (e.g. "Importing Maven project(s) 40%") as one updating line.
local function progress_line(text)
  if not (run.preparing and run.buf and vim.api.nvim_buf_is_valid(run.buf)) then
    return
  end
  local line = ("%5.1fs  jdtls: %s"):format((vim.uv.now() - run.t0) / 1000, text)
  local n = vim.api.nvim_buf_line_count(run.buf)
  local last = vim.api.nvim_buf_get_lines(run.buf, n - 1, n, false)[1] or ""
  local row = last:find("jdtls: ", 1, true) and n - 1 or n -- replace the previous progress line
  vim.api.nvim_buf_set_lines(run.buf, row, row + 1, false, { line })
  vim.api.nvim_buf_set_extmark(run.buf, progress_ns, row, 0, { line_hl_group = "Comment" })
  if run.win and vim.api.nvim_win_is_valid(run.win) then
    pcall(vim.api.nvim_win_set_cursor, run.win, { vim.api.nvim_buf_line_count(run.buf), 0 })
  end
end

vim.api.nvim_create_autocmd("LspProgress", {
  group = vim.api.nvim_create_augroup("ide_java_run_progress", { clear = true }),
  callback = function(args)
    local client = vim.lsp.get_client_by_id(args.data.client_id)
    if not (client and client.name == "jdtls") then
      return
    end
    local params = args.data.params or {}
    local v = params.value or {}
    local token = tostring(params.token)
    if v.kind == "end" then
      busy[token] = nil
      return
    end
    busy[token] = true
    local text = v.title or ""
    if v.message and v.message ~= "" and v.message ~= v.title and not v.message:find(v.title or "\0", 1, true) then
      text = text .. ": " .. v.message:gsub("%s*%-?%s*%d+%%$", "")
    end
    if v.percentage then
      text = text .. (" (%d%%)"):format(v.percentage)
    end
    progress_line(vim.trim(text))
  end,
})

--------------------------------------------------------------------------------
-- Running
--------------------------------------------------------------------------------

local function jdtls_client(bufnr)
  return vim.lsp.get_clients({ name = "jdtls", bufnr = bufnr })[1]
end

--------------------------------------------------------------------------------
-- Source folder of projects without Maven/Gradle
--------------------------------------------------------------------------------

local BUILD_FILES = { "pom.xml", "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts", "build.xml" }

--- Folder that contains the package folders of `path` (e.g. …/src for src/com/app/Main.java
--- with "package com.app;"), or nil when the folders don't match the package.
function M.source_root(path, lines)
  local dir = vim.fn.fnamemodify(path, ":h")
  local pkg = strip_comments(lines):match("%f[%w]package%s+([%w_%.]+)%s*;")
  if not pkg then
    return dir
  end
  local suffix = "/" .. pkg:gsub("%.", "/")
  if dir:sub(-#suffix) == suffix then
    return dir:sub(1, #dir - #suffix)
  end
end

--- jdtls guesses the source folder of a project without Maven/Gradle from the first file it
--- sees, and sometimes guesses a package folder (src/com/app instead of src). Then every file
--- shows "declared package does not match" and nothing compiles. Fix the guess from the
--- file's package declaration. Calls `done()` when finished (also when nothing was needed).
local fixing = {} -- source folder -> callbacks waiting for the fix in progress

function M.ensure_source_root(client, bufnr, path, lines, done)
  done = done or function() end
  local root_dir = client.root_dir or (client.config and client.config.root_dir)
  local src = M.source_root(path, lines or file_lines(path))
  if not root_dir or not src then
    return done()
  end
  for _, f in ipairs(BUILD_FILES) do
    if vim.uv.fs_stat(root_dir .. "/" .. f) then
      return done() -- Maven/Gradle/Ant: jdtls reads the source folders from the build file
    end
  end
  if fixing[src] then -- already being checked: just wait for that
    table.insert(fixing[src], done)
    return
  end
  fixing[src] = { done }
  local function finish()
    local waiting = fixing[src] or {}
    fixing[src] = nil
    for _, cb in ipairs(waiting) do
      cb()
    end
  end
  local key = "org.eclipse.jdt.ls.core.sourcePaths"
  local function exec(command, args, cb)
    client:request("workspace/executeCommand", { command = command, arguments = args }, function(err, res)
      vim.schedule(function()
        cb(err, res)
      end)
    end, bufnr)
  end
  exec("java.project.getSettings", { vim.uri_from_fname(path), { key } }, function(err, res)
    local paths = (not err and res and res[key]) or {}
    if vim.tbl_contains(paths, src) then
      return finish()
    end
    -- drop guesses inside the real source folder (nested source folders aren't allowed), add it
    local wrong = vim.tbl_filter(function(p)
      return p:sub(1, #src + 1) == src .. "/"
    end, paths)
    local function add()
      exec("java.project.addToSourcePath", { vim.uri_from_fname(src) }, function()
        finish()
      end)
    end
    local function remove_next(i)
      if i > #wrong then
        return add()
      end
      exec("java.project.removeFromSourcePath", { vim.uri_from_fname(wrong[i]) }, function()
        remove_next(i + 1)
      end)
    end
    remove_next(1)
  end)
end

local function sep()
  return package.config:sub(1, 1) == "\\" and ";" or ":"
end

local function run_with_source_launcher(token, path, cls, why)
  status(token, why, "DiagnosticWarn")
  status(token, "Running with Java's source launcher instead (only the JDK, no project dependencies).", "DiagnosticWarn")
  start(token, { "java", path }, vim.fn.fnamemodify(path, ":h"), cls)
end

--- Errors jdtls reported, as "File.java:12: message" lines (at most `max`).
local function error_lines(root, max)
  local lines, total = {}, 0
  for _, d in ipairs(vim.diagnostic.get(nil, { severity = vim.diagnostic.severity.ERROR })) do
    local name = vim.api.nvim_buf_get_name(d.bufnr)
    if name:match("%.java$") then
      total = total + 1
      if #lines < max then
        local rel = root and name:sub(1, #root + 1) == root .. "/" and name:sub(#root + 2) or vim.fn.fnamemodify(name, ":t")
        table.insert(lines, ("  %s:%d: %s"):format(rel, d.lnum + 1, (d.message:gsub("\n.*", ""))))
      end
    end
  end
  if total > #lines then
    table.insert(lines, ("  … and %d more"):format(total - #lines))
  end
  return lines, total
end

--- Build with jdtls, fetch the classpath, run.
local function run_with_jdtls(token, client, bufnr, path, cls)
  status(token, "Checking the project's source folders…")
  M.ensure_source_root(client, bufnr, path, nil, function()
    if token ~= run.token then
      return
    end
    -- wait until jdtls has finished importing/building (idle for a moment), at most 3 minutes
    local idle_since, waited, announced = nil, 0, false
    local function when_idle(cb)
      if token ~= run.token then
        return
      end
      if next(busy) == nil then
        idle_since = idle_since or vim.uv.now()
        if vim.uv.now() - idle_since >= 1500 then
          return cb()
        end
      else
        idle_since = nil
        if not announced then
          announced = true
          status(token, "Waiting for the Java language server to finish importing the project…")
        end
      end
      waited = waited + 250
      if waited > 180000 then
        return cb()
      end
      vim.defer_fn(function()
        when_idle(cb)
      end, 250)
    end
    when_idle(function()
    status(token, "Building the project…")
    client:request("java/buildWorkspace", false, function(err, result)
      vim.schedule(function()
        if token ~= run.token then
          return
        end
        -- result: 0 failed, 1 ok, 2 compile errors, 3 cancelled
        if err or result == 0 or result == 3 then
          return fail(token, "Build failed: " .. (err and err.message or "see :LspLog"))
        end
        local function go()
          status(token, "Loading the project classpath…")
          client:request("workspace/executeCommand", {
            command = "java.project.getClasspaths",
            arguments = { vim.uri_from_fname(path), vim.json.encode({ scope = "runtime" }) },
          }, function(err2, resp)
            vim.schedule(function()
              if err2 or not resp then
                return run_with_source_launcher(token, path, cls, "Couldn't get the project classpath from jdtls.")
              end
              local cmd = { "java" }
              if resp.modulepaths and #resp.modulepaths > 0 then
                vim.list_extend(cmd, { "--module-path", table.concat(resp.modulepaths, sep()) })
              end
              vim.list_extend(cmd, { "-cp", table.concat(resp.classpaths or {}, sep()), cls })
              -- run from the project folder, like IntelliJ (relative file paths in the program)
              start(token, cmd, client.root_dir or vim.fn.getcwd(), cls)
            end)
          end, bufnr)
        end
        if result == 2 then
          local errs, total = error_lines(client.root_dir, 8)
          status(token, ("The project has %s:"):format(total > 0 and (total .. " compile error(s)") or "compile errors"), "DiagnosticWarn")
          for _, l in ipairs(errs) do
            status(token, l, "DiagnosticWarn")
          end
          local msg = ("The project has compile errors%s\n%s\n\nErrors in other classes (tests, for example) usually don't stop this program.\nRun anyway?")
            :format(total > 0 and (" (" .. total .. "):") or ".", table.concat(errs, "\n"))
          if vim.fn.confirm(msg, "&Run anyway\n&Cancel", 1, "Warning") ~= 1 then
            return fail(token, "Cancelled.")
          end
        end
        go()
      end)
    end, bufnr)
    end)
  end)
end

--- Run the main() of the Java file at `path`.
function M.run(path)
  path = vim.fn.fnamemodify(path, ":p")
  local name, lines = M.runnable(path)
  if not name then
    return notify(("%s has no main method"):format(vim.fn.fnamemodify(path, ":t")), vim.log.levels.WARN)
  end
  run.last = path
  local cls = M.class_name(path, lines)
  vim.cmd("silent! wall") -- run what's on screen
  local token = prepare(cls)

  local bufnr = vim.fn.bufadd(path)
  local client = jdtls_client(bufnr) or vim.lsp.get_clients({ name = "jdtls" })[1]
  if client and client.initialized then
    return run_with_jdtls(token, client, bufnr, path, cls)
  end
  if not client and not package.loaded["jdtls"] and vim.fn.executable("jdtls") == 0
    and not vim.uv.fs_stat(vim.fn.stdpath("data") .. "/mason/bin/jdtls") then
    return run_with_source_launcher(token, path, cls, "The Java language server (jdtls) isn't available.")
  end

  -- jdtls not started yet: open the file (that starts it) and wait for it to attach
  if vim.fn.bufwinid(bufnr) == -1 then
    local win
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local b = vim.api.nvim_win_get_buf(w)
      if w ~= run.win and vim.bo[b].buftype == "" and vim.bo[b].filetype ~= "neo-tree" and vim.api.nvim_win_get_config(w).relative == "" then
        win = w
        break
      end
    end
    if win then
      vim.api.nvim_win_call(win, function()
        vim.cmd.edit(vim.fn.fnameescape(path))
      end)
    else
      vim.cmd("aboveleft vsplit " .. vim.fn.fnameescape(path))
    end
    bufnr = vim.fn.bufnr(path)
  end
  status(token, "Starting the Java language server (the first time in a project, this and the\n       Maven/Gradle import can take a minute; later runs are much faster)…")
  local waited = 0
  local function wait()
    if token ~= run.token then
      return
    end
    local c = jdtls_client(bufnr)
    if c and c.initialized then
      status(token, "Java language server ready.")
      return run_with_jdtls(token, c, bufnr, path, cls)
    end
    waited = waited + 250
    if waited > 180000 then
      return run_with_source_launcher(token, path, cls, "The Java language server didn't start within 3 minutes.")
    end
    vim.defer_fn(wait, 250)
  end
  wait()
end

return M
