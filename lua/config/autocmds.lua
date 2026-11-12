-- Autocmds are automatically loaded on the VeryLazy event
-- Default autocmds that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/autocmds.lua
--
-- Add any additional autocmds here
-- with `vim.api.nvim_create_autocmd`
--
-- Or remove existing autocmds by their group name (which is prefixed with `lazyvim_` for the defaults)
-- e.g. vim.api.nvim_del_augroup_by_name("lazyvim_wrap_spell")

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
