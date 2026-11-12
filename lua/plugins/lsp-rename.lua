-- "Rename Symbol…" in the editor's right-click menu: renames the variable / field / method /
-- class under the cursor and all its references (lua/ide/rename.lua). Shown only when the
-- file's language server can rename (jdtls for Java, also Lua, Go, Rust…).

local ITEM = "PopUp.Rename\\ Symbol…"
local SEP = "PopUp.-rename-sep-"

_G.IdeRenameSymbol = function()
  require("ide.rename").rename()
end

vim.cmd(([[
  anoremenu 1.2 %s <Cmd>lua IdeRenameSymbol()<CR>
  anoremenu 1.3 %s <Nop>
]]):format(ITEM, SEP))

vim.api.nvim_create_autocmd("MenuPopup", {
  group = vim.api.nvim_create_augroup("ide_rename_popup", { clear = true }),
  callback = function()
    -- (the right-click already moved the cursor onto the clicked word)
    local can = require("ide.rename").client(0) ~= nil and vim.fn.expand("<cword>"):match("^[%a_$][%w_$]*$") ~= nil
    vim.cmd("amenu " .. (can and "enable" or "disable") .. " " .. ITEM)
    vim.cmd("amenu " .. (can and "enable" or "disable") .. " " .. SEP)
  end,
})

return {}
