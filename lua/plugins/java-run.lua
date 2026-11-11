-- "▶ Run 'Main.main()'" in the editor's right-click menu for Java files with a main method.
-- (The explorer's right-click menu gets the same item, see neo-tree-context-menu.lua.)
-- Logic lives in lua/ide/java_run.lua.

local ITEM = "PopUp.▶\\ Run\\ main()"
local SEP = "PopUp.-run-sep-"
local TEST_ITEMS = {} -- test items currently in the menu

--- Menu names need spaces, dots and backslashes escaped.
local function menu_name(text)
  return (text:gsub("[%s%.\\]", "\\%0"))
end

_G.IdeRunJavaTests = function(method, profile)
  require("ide.java_run").run_tests(vim.api.nvim_buf_get_name(0), method ~= "" and method or nil, profile and { profile = true } or nil)
end

_G.IdeRunCurrentJava = function(profile)
  require("ide.java_run").run(vim.api.nvim_buf_get_name(0), profile and { profile = true } or nil)
end

vim.api.nvim_create_autocmd("MenuPopup", {
  group = vim.api.nvim_create_augroup("ide_java_run_popup", { clear = true }),
  callback = function()
    pcall(vim.cmd.aunmenu, ITEM)
    pcall(vim.cmd.aunmenu, SEP)
    for _, item in ipairs(TEST_ITEMS) do
      pcall(vim.cmd.aunmenu, item)
    end
    TEST_ITEMS = {}
    local name = vim.bo.filetype == "java" and require("ide.java_run").runnable(vim.api.nvim_buf_get_name(0))
    if name then
      -- priority 1 puts it at the top of the menu, like IntelliJ ("\\." keeps the dot in
      -- "Main.main()" from starting a submenu)
      ITEM = ("PopUp.▶\\ Run\\ '%s\\.main()'"):format(name)
      vim.cmd(("anoremenu 1 %s <Cmd>lua IdeRunCurrentJava()<CR>"):format(ITEM))
      local profile_item = "PopUp." .. menu_name(("◉ Profile '%s.main()'"):format(name))
      vim.cmd(("anoremenu 1.01 %s <Cmd>lua IdeRunCurrentJava(true)<CR>"):format(profile_item))
      table.insert(TEST_ITEMS, profile_item)
      vim.cmd("anoremenu 1.1 " .. SEP .. " <Nop>")
    end
    -- JUnit: the test method under the cursor, and the whole class
    local tests = vim.bo.filetype == "java"
      and require("ide.java_run").test_info(vim.api.nvim_buf_get_name(0), vim.api.nvim_buf_get_lines(0, 0, -1, false), vim.fn.line("."))
    if tests then
      if tests.method then
        local item = "PopUp." .. menu_name(("▶ Run Test '%s()'"):format(tests.method))
        vim.cmd(("anoremenu 1.02 %s <Cmd>lua IdeRunJavaTests(%q)<CR>"):format(item, tests.method))
        table.insert(TEST_ITEMS, item)
        local pitem = "PopUp." .. menu_name(("◉ Profile Test '%s()'"):format(tests.method))
        vim.cmd(("anoremenu 1.025 %s <Cmd>lua IdeRunJavaTests(%q, true)<CR>"):format(pitem, tests.method))
        table.insert(TEST_ITEMS, pitem)
      end
      local suffix = tests.abstract and (" (%d implementations)"):format(#tests.implementations) or ""
      local item = "PopUp." .. menu_name(("▶ Run Tests in '%s'%s"):format(tests.class, suffix))
      vim.cmd(("anoremenu 1.03 %s <Cmd>lua IdeRunJavaTests('')<CR>"):format(item))
      table.insert(TEST_ITEMS, item)
      local pitem = "PopUp." .. menu_name(("◉ Profile Tests in '%s'%s"):format(tests.class, suffix))
      vim.cmd(("anoremenu 1.035 %s <Cmd>lua IdeRunJavaTests('', true)<CR>"):format(pitem))
      table.insert(TEST_ITEMS, pitem)
      vim.cmd("anoremenu 1.1 " .. SEP .. " <Nop>")
    end
  end,
})

-- Fix jdtls's source-folder guess for projects without Maven/Gradle as soon as a Java file
-- is opened, so no false "declared package does not match" errors show up.
vim.api.nvim_create_autocmd("LspAttach", {
  group = vim.api.nvim_create_augroup("ide_java_source_root", { clear = true }),
  callback = function(args)
    local client = vim.lsp.get_client_by_id(args.data.client_id)
    if client and client.name == "jdtls" then
      require("ide.java_run").track_ready(client) -- know when the project is loaded (Run / tests)
      local path = vim.api.nvim_buf_get_name(args.buf)
      require("ide.java_run").ensure_source_root(client, args.buf, path, vim.api.nvim_buf_get_lines(args.buf, 0, -1, false))
    end
  end,
})

return {}
