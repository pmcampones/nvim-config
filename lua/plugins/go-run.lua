-- Editor right-click menu for Go: "▶ Run 'main.go'" for files with package main and
-- func main(); "▶ Run Test 'TestX'" (test under the cursor) and "▶ Run Tests in 'x_test.go'"
-- for test files. (The explorer's right-click menu gets the same item, see
-- neo-tree-context-menu.lua.) Logic lives in lua/ide/go_run.lua.

local TEST_ITEMS = {}

_G.IdeRunGoTests = function(method)
  require("ide.go_run").run_tests(vim.api.nvim_buf_get_name(0), method ~= "" and method or nil)
end

_G.IdeRunCurrentGo = function()
  require("ide.go_run").run(vim.api.nvim_buf_get_name(0))
end

vim.api.nvim_create_autocmd("MenuPopup", {
  group = vim.api.nvim_create_augroup("ide_go_run_popup", { clear = true }),
  callback = function()
    for _, item in ipairs(TEST_ITEMS) do
      pcall(vim.cmd.aunmenu, item)
    end
    TEST_ITEMS = {}
    pcall(vim.cmd.aunmenu, "PopUp.-go-run-sep-")
    if vim.bo.filetype ~= "go" then
      return
    end
    local gr = require("ide.go_run")
    local path = vim.api.nvim_buf_get_name(0)
    local function add(text, rhs)
      local item = "PopUp." .. (text:gsub("[%s%.\\]", "\\%0"))
      vim.cmd(("anoremenu 1.1 %s <Cmd>lua %s<CR>"):format(item, rhs))
      table.insert(TEST_ITEMS, item)
    end
    local name = gr.runnable(path)
    if name then
      add(("▶ Run '%s'"):format(name), "IdeRunCurrentGo()")
    end
    local tests = gr.test_info(path, vim.api.nvim_buf_get_lines(0, 0, -1, false), vim.fn.line("."))
    if tests then
      if tests.method then
        add(("▶ Run Test '%s'"):format(tests.method), ("IdeRunGoTests(%q)"):format(tests.method))
      end
      add(("▶ Run Tests in '%s'"):format(tests.file), "IdeRunGoTests('')")
    end
    if #TEST_ITEMS > 0 then
      vim.cmd("anoremenu 1.1 PopUp.-go-run-sep- <Nop>") -- added last so it ends up below the items
    end
  end,
})

return {}
