-- Show hidden files (dotfiles like .gitignore, .idea, .env) and files ignored by .gitignore
-- (target/, *.db…) in the explorer. Ignored files are shown dimmed, like in IntelliJ.
-- The .git folder stays hidden (Git's internal data). Press H in the explorer to hide/show
-- the ignored and hidden files for a while.
return {
  {
    "nvim-neo-tree/neo-tree.nvim",
    opts = {
      filesystem = {
        filtered_items = {
          hide_dotfiles = false,
          hide_gitignored = false,
          never_show = { ".git" },
        },
      },
    },
  },
}
