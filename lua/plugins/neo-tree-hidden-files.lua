-- Show hidden files (dotfiles like .gitignore, .idea, .env) in the explorer.
-- The .git folder stays hidden (Git's internal data, like in IntelliJ).
-- Files ignored by .gitignore (target/, *.db…) are still hidden: press H in the explorer to
-- show/hide them, or set hide_gitignored = false below to always show them.
return {
  {
    "nvim-neo-tree/neo-tree.nvim",
    opts = {
      filesystem = {
        filtered_items = {
          hide_dotfiles = false,
          never_show = { ".git" },
        },
      },
    },
  },
}
