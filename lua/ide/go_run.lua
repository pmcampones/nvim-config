-- Run Go programs and tests.
--   * a file with `package main` + `func main()` → ▶ Run
--   * a _test.go file → ▶ Run Tests in the file, or ▶ Run Test 'TestX' for the test under the
--     cursor (editor menu)
--   * a folder → ▶ Run All Tests in it, sub-folders included (`go test ./...`)
-- The program runs in the same Run panel as Java (lua/ide/java_run.lua): its output shows
-- there and what you type goes to the program's stdin; ⟳ Rerun, ■ Stop, ✕ Close.
--
-- What is run:
--   * in a Go module (go.mod above the file): `go run .` in the file's folder, i.e. the whole
--     main package (all its .go files), like `go run` from a terminal
--   * if that folder holds several separate programs (more than one file with func main, e.g.
--     scripts with //go:build ignore), or there's no go.mod: just this file, `go run file.go`

local M = {}

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Run" })
end

local function file_lines(path)
  local buf = vim.fn.bufnr(path)
  if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  return ok and lines or {}
end

--- Lines without comments (so a commented-out main doesn't count).
local function code_lines(lines)
  local out, in_block = {}, false
  for _, l in ipairs(lines) do
    if in_block then
      local e = l:find("*/", 1, true)
      l = e and l:sub(e + 2) or ""
      in_block = not e
    end
    l = l:gsub("/%*.-%*/", "")
    local b = l:find("/*", 1, true)
    if b then
      l, in_block = l:sub(1, b - 1), true
    end
    l = l:gsub("//.*", "")
    table.insert(out, l)
  end
  return out
end

local function has_main(lines)
  local pkg, main = false, false
  for _, l in ipairs(code_lines(lines)) do
    pkg = pkg or l:match("^%s*package%s+main%s*$") ~= nil
    main = main or l:match("^%s*func%s+main%s*%(%s*%)") ~= nil
  end
  return pkg and main
end

--- For menus: "main.go" when `path` is a Go file with package main and func main(), else nil.
function M.runnable(path)
  if not path or not path:match("%.go$") or path:match("_test%.go$") then
    return nil
  end
  if not has_main(file_lines(path)) then
    return nil
  end
  return vim.fn.fnamemodify(path, ":t")
end

--- Other files in the same folder that also have a main() (separate programs).
local function other_mains(path)
  local dir = vim.fn.fnamemodify(path, ":h")
  for name, kind in vim.fs.dir(dir) do
    local p = dir .. "/" .. name
    if kind == "file" and name:match("%.go$") and not name:match("_test%.go$") and p ~= path and has_main(file_lines(p)) then
      return true
    end
  end
  return false
end

function M.run(path)
  path = vim.fn.fnamemodify(path, ":p")
  local name = M.runnable(path)
  if not name then
    return notify(("%s has no func main() in package main"):format(vim.fn.fnamemodify(path, ":t")), vim.log.levels.WARN)
  end
  if vim.fn.executable("go") == 0 then
    return notify("Go isn't installed (no `go` command found)", vim.log.levels.ERROR)
  end
  vim.cmd("silent! wall") -- run what's on screen
  local dir = vim.fn.fnamemodify(path, ":h")
  local module = vim.fs.root(path, "go.mod")
  local cmd, title
  if module and not other_mains(path) then
    cmd = { "go", "run", "." }
    local rel = dir == module and "." or ("./" .. dir:sub(#module + 2))
    title = ("go run %s"):format(rel)
  else
    cmd = { "go", "run", name }
    title = "go run " .. name
  end
  require("ide.java_run").run_in_panel(title, cmd, dir, function()
    M.run(path)
  end)
end

--------------------------------------------------------------------------------
-- Tests (go test)
--------------------------------------------------------------------------------

--- Test functions in the file: { { name, line, last } } (line/last: first and closing line).
local function test_funcs(lines)
  local code, out = code_lines(lines), {}
  for i, l in ipairs(code) do
    -- TestXxx(t *testing.T), where Xxx doesn't start with a lowercase letter (Go's rule)
    local name = l:match("^func%s+(Test[%w_]*)%s*%(%s*[%w_]+%s+%*testing%.T%s*%)")
    if name and not name:match("^Test%l") then
      local last = #code
      for j = i + 1, #code do
        if code[j]:match("^}") then
          last = j
          break
        end
      end
      table.insert(out, { name = name, line = i, last = last })
    end
  end
  return out
end

--- For menus: { file = "foo_test.go", tests = {names}, method = "TestX" (under the cursor) }
--- for a _test.go file with tests, else nil.
function M.test_info(path, lines, cursor)
  if not path or not path:match("_test%.go$") then
    return nil
  end
  local funcs = test_funcs(lines or file_lines(path))
  if #funcs == 0 then
    return nil
  end
  local info = { file = vim.fn.fnamemodify(path, ":t"), tests = {} }
  for _, f in ipairs(funcs) do
    table.insert(info.tests, f.name)
    if cursor and cursor >= f.line and cursor <= f.last then
      info.method = f.name
    end
  end
  return info
end

-- folders `go test ./...` skips
local function skipped_dir(name)
  return name:match("^[%._]") or name == "testdata" or name == "vendor" or name == "node_modules"
end

--- Whether `dir` or a sub-folder has a _test.go file with tests.
function M.dir_has_tests(dir)
  for name, kind in vim.fs.dir(dir, { depth = 30, skip = function(d)
    return not skipped_dir(vim.fs.basename(d))
  end }) do
    if kind == "file" and name:match("_test%.go$") and #test_funcs(file_lines(dir .. "/" .. name)) > 0 then
      return true
    end
  end
  return false
end

local function check_go()
  if vim.fn.executable("go") == 0 then
    notify("Go isn't installed (no `go` command found)", vim.log.levels.ERROR)
    return false
  end
  return true
end

--- Run the tests of a _test.go file, or only `method` (a TestXxx name).
function M.run_tests(path, method)
  path = vim.fn.fnamemodify(path, ":p")
  local info = M.test_info(path)
  if not info then
    return notify(("%s has no tests"):format(vim.fn.fnamemodify(path, ":t")), vim.log.levels.WARN)
  end
  if not check_go() then
    return
  end
  vim.cmd("silent! wall")
  local names = method and { method } or info.tests
  -- go test runs a package; -run picks this file's tests (-count=1: always really run them)
  local cmd = { "go", "test", "-v", "-count=1", "-run", "^(" .. table.concat(names, "|") .. ")$", "." }
  local title = method and ("go test %s"):format(method) or ("go test %s"):format(info.file)
  require("ide.java_run").run_in_panel(title, cmd, vim.fn.fnamemodify(path, ":h"), function()
    M.run_tests(path, method)
  end, "test")
end

--- Run all tests in `dir` and its sub-folders. Go modules nested below it (their own go.mod)
--- are tested too, each in its own folder (`go test ./...` stops at module boundaries).
function M.run_dir_tests(dir)
  dir = vim.fn.fnamemodify(dir, ":p"):gsub("/$", "")
  if not check_go() then
    return
  end
  vim.cmd("silent! wall")
  local roots = {}
  if vim.fs.root(dir, "go.mod") then
    table.insert(roots, dir)
  end
  for name, kind in vim.fs.dir(dir, { depth = 30, skip = function(d)
    return not skipped_dir(vim.fs.basename(d))
  end }) do
    if kind == "file" and vim.fs.basename(name) == "go.mod" then
      local root = dir .. "/" .. vim.fs.dirname(name)
      root = root:gsub("/%.$", "")
      if not vim.tbl_contains(roots, root) then
        table.insert(roots, root)
      end
    end
  end
  if #roots == 0 then
    return notify("No Go module (go.mod) here or below: go test needs one", vim.log.levels.WARN)
  end
  local title = ("go test ./%s/..."):format(vim.fn.fnamemodify(dir, ":t"))
  local rerun = function()
    M.run_dir_tests(dir)
  end
  if #roots == 1 then
    return require("ide.java_run").run_in_panel(title, { "go", "test", "-v", "-count=1", "./..." }, roots[1], rerun, "test")
  end
  -- several modules: test each one, report failure if any failed
  local script = { "status=0" }
  for _, root in ipairs(roots) do
    local rel = root == dir and "." or root:sub(#dir + 2)
    table.insert(script, ("echo '=== module %s'; (cd %s && go test -v -count=1 ./...) || status=1")
      :format(rel, vim.fn.shellescape(root)))
  end
  table.insert(script, "exit $status")
  require("ide.java_run").run_in_panel(title, { "sh", "-c", table.concat(script, "\n") }, dir, rerun, "test")
end

return M
