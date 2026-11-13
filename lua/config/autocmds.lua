-- Autocmds are automatically loaded on the VeryLazy event
-- Default autocmds that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/autocmds.lua
--
-- Add any additional autocmds here
-- with `vim.api.nvim_create_autocmd`
--
-- Or remove existing autocmds by their group name (which is prefixed with `lazyvim_` for the defaults)
-- e.g. vim.api.nvim_del_augroup_by_name("lazyvim_wrap_spell")
-- Terminals: keys only reach the program (e.g. Claude Code's 1/2/3 menus, Enter, Esc) in
-- Terminal mode, but a mouse click or switching windows drops you into Normal mode. Go back
-- into Terminal mode automatically when entering a terminal window or clicking inside it.
-- (A mouse drag still selects text: that ends in Visual mode, which is left alone.)
local function term_insert()
  if vim.bo.buftype == "terminal" and vim.fn.mode() == "n" and vim.fn.jobwait({ vim.bo.channel }, 0)[1] == -1 then
    vim.cmd.startinsert()
  end
end
vim.api.nvim_create_autocmd({ "WinEnter", "BufEnter" }, {
  group = vim.api.nvim_create_augroup("ide_term_autoinsert", { clear = true }),
  callback = function()
    vim.schedule(term_insert)
  end,
})
vim.keymap.set("n", "<LeftRelease>", function()
  if vim.bo.buftype == "terminal" then
    vim.schedule(term_insert)
  end
  return "<LeftRelease>"
end, { expr = true, desc = "Click in a terminal: back to Terminal mode" })

-- closing a buffer never leaves two windows showing the same file (lua/ide/bufclose.lua)
require("ide.bufclose").setup()
-- `nvim .` (or plain `nvim`) starts with an empty, unnamed buffer that stays as a tab.
-- As soon as a real file is opened, close such empty tabs (only if nothing was typed in them
-- and they're no longer shown in any window).
vim.api.nvim_create_autocmd("BufEnter", {
  group = vim.api.nvim_create_augroup("close_empty_start_buffer", { clear = true }),
  callback = function(ev)
    if vim.bo[ev.buf].buftype ~= "" or vim.api.nvim_buf_get_name(ev.buf) == "" then
      return
    end
    vim.schedule(function()
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if b ~= ev.buf
          and vim.api.nvim_buf_is_valid(b)
          and vim.bo[b].buflisted
          and vim.bo[b].buftype == ""
          and vim.api.nvim_buf_get_name(b) == ""
          and not vim.bo[b].modified
          and vim.api.nvim_buf_line_count(b) == 1
          and vim.api.nvim_buf_get_lines(b, 0, 1, false)[1] == ""
          and #vim.fn.win_findbuf(b) == 0
        then
          pcall(vim.api.nvim_buf_delete, b, {})
        end
      end
    end)
  end,
})
