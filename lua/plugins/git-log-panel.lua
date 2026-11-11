-- IntelliJ-style Git Log panel (bottom of the screen). Logic lives in lua/ide/gitlog.lua.
-- Open/close it with <leader>gv, or the "Log" button in the explorer's title bar.

-- clicking a folder's ▸ / ▾ in Changed Files expands/collapses it
require("ide.click").on_left_press(function(pos)
  return require("ide.gitlog").arrow_click(pos)
end)

return {
  {
    "nvim-neo-tree/neo-tree.nvim",
    keys = {
      {
        "<leader>gv",
        function()
          require("ide.gitlog").toggle(LazyVim.root())
        end,
        desc = "Git Log (commit tree)",
      },
    },
    opts = function(_, opts)
      -- never open files from the explorer inside the log panel
      opts.open_files_do_not_replace_types = opts.open_files_do_not_replace_types or {}
      vim.list_extend(opts.open_files_do_not_replace_types, { "ide-gitlog", "ide-gitlog-files", "ide-gitlog-details" })
    end,
  },
}
