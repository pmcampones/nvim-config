-- "Find Usages" in the editor's right-click menu: lists where the function / variable / field /
-- type under the cursor is used in the project (lua/ide/usages.lua). Shown only when the file's
-- language server can find references (gopls for Go, jdtls for Java, lua_ls…).

local ITEM = "PopUp.Find\\ Usages"

_G.IdeFindUsages = function()
  require("ide.usages").find()
end

-- 1.2: next to "Rename Symbol…" (plugins/lsp-rename.lua), above Neovim's own items
vim.cmd(("anoremenu 1.2 %s <Cmd>lua IdeFindUsages()<CR>"):format(ITEM))

vim.api.nvim_create_autocmd("MenuPopup", {
  group = vim.api.nvim_create_augroup("ide_usages_popup", { clear = true }),
  callback = function()
    -- (the right-click already moved the cursor onto the clicked word)
    local can = require("ide.usages").client(0) ~= nil and vim.fn.expand("<cword>"):match("^[%a_$][%w_$]*$") ~= nil
    vim.cmd("amenu " .. (can and "enable" or "disable") .. " " .. ITEM)
  end,
})

return {}
