-- "▶ Run 'main.go'" in the editor's right-click menu for Go files with package main and
-- func main(). (The explorer's right-click menu gets the same item, see
-- neo-tree-context-menu.lua.) Logic lives in lua/ide/go_run.lua.

local ITEM

_G.IdeRunCurrentGo = function()
  require("ide.go_run").run(vim.api.nvim_buf_get_name(0))
end

vim.api.nvim_create_autocmd("MenuPopup", {
  group = vim.api.nvim_create_augroup("ide_go_run_popup", { clear = true }),
  callback = function()
    if ITEM then
      pcall(vim.cmd.aunmenu, ITEM)
      pcall(vim.cmd.aunmenu, "PopUp.-go-run-sep-")
      ITEM = nil
    end
    local name = vim.bo.filetype == "go" and require("ide.go_run").runnable(vim.api.nvim_buf_get_name(0))
    if name then
      ITEM = "PopUp." .. (("▶ Run '%s'"):format(name):gsub("[%s%.\\]", "\\%0"))
      vim.cmd(("anoremenu 1.1 %s <Cmd>lua IdeRunCurrentGo()<CR>"):format(ITEM))
      vim.cmd("anoremenu 1.1 PopUp.-go-run-sep- <Nop>")
    end
  end,
})

return {}
