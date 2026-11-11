-- "▶ Run 'Main.main()'" in the editor's right-click menu for Java files with a main method.
-- (The explorer's right-click menu gets the same item, see neo-tree-context-menu.lua.)
-- Logic lives in lua/ide/java_run.lua.

local ITEM = "PopUp.▶\\ Run\\ main()"
local SEP = "PopUp.-run-sep-"

_G.IdeRunCurrentJava = function()
  require("ide.java_run").run(vim.api.nvim_buf_get_name(0))
end

vim.api.nvim_create_autocmd("MenuPopup", {
  group = vim.api.nvim_create_augroup("ide_java_run_popup", { clear = true }),
  callback = function()
    pcall(vim.cmd.aunmenu, ITEM)
    pcall(vim.cmd.aunmenu, SEP)
    local name = vim.bo.filetype == "java" and require("ide.java_run").runnable(vim.api.nvim_buf_get_name(0))
    if name then
      -- priority 1 puts it at the top of the menu, like IntelliJ ("\\." keeps the dot in
      -- "Main.main()" from starting a submenu)
      ITEM = ("PopUp.▶\\ Run\\ '%s\\.main()'"):format(name)
      vim.cmd(("anoremenu 1 %s <Cmd>lua IdeRunCurrentJava()<CR>"):format(ITEM))
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
      local path = vim.api.nvim_buf_get_name(args.buf)
      require("ide.java_run").ensure_source_root(client, args.buf, path, vim.api.nvim_buf_get_lines(args.buf, 0, -1, false))
    end
  end,
})

return {}
