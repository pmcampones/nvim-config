-- Run Go programs: right-click a file with `package main` + `func main()` → ▶ Run.
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

return M
