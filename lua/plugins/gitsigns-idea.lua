-- IntelliJ-style change markers in the editor gutter (next to the line numbers):
--   green bar  : added lines
--   blue bar   : modified lines
--   grey arrow : lines were deleted here
-- Everything since the last commit is shown, staged or not: gitsigns draws staged changes
-- separately (normally dimmed), so they get the same look here. Colors match the explorer
-- (lua/plugins/neo-tree-git-colors.lua).
-- LazyVim keys still work: ]h / [h next/prev change, <leader>ghp preview, <leader>ghr reset.

local COLORS = {
  dark = { add = "#629755", change = "#6897BB", delete = "#808080" },
  light = { add = "#067D17", change = "#0032A0", delete = "#9A9A9A" },
}

local function set_highlights()
  local c = COLORS[vim.o.background] or COLORS.dark
  for _, prefix in ipairs({ "GitSigns", "GitSignsStaged" }) do
    vim.api.nvim_set_hl(0, prefix .. "Add", { fg = c.add })
    vim.api.nvim_set_hl(0, prefix .. "Change", { fg = c.change })
    vim.api.nvim_set_hl(0, prefix .. "Changedelete", { fg = c.change })
    vim.api.nvim_set_hl(0, prefix .. "Delete", { fg = c.delete })
    vim.api.nvim_set_hl(0, prefix .. "Topdelete", { fg = c.delete })
  end
  vim.api.nvim_set_hl(0, "GitSignsUntracked", { fg = c.add }) -- a new file: every line is added
end

return {
  {
    "lewis6991/gitsigns.nvim",
    opts = function(_, opts)
      set_highlights()
      vim.api.nvim_create_autocmd("ColorScheme", {
        group = vim.api.nvim_create_augroup("gitsigns_idea_colors", { clear = true }),
        callback = set_highlights,
      })
      opts.signs_staged_enable = true -- keep showing staged changes until they're committed
      opts.signs_staged = vim.deepcopy(opts.signs or {})
      opts.signs_staged.untracked = nil
    end,
  },
}
