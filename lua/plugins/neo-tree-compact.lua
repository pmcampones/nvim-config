-- IntelliJ-style "compact middle packages" for the Neo-tree file explorer:
-- a directory whose only child is another directory is shown as one node, e.g. "A/B",
-- and expanding it shows B's contents directly.
return {
  {
    "nvim-neo-tree/neo-tree.nvim",
    opts = {
      filesystem = {
        group_empty_dirs = true,
        -- "deep" looks inside directories ahead of time so chains are collapsed before
        -- you expand them ("shallow" would only group them after you open them).
        scan_mode = "deep",
      },
    },
  },
}
