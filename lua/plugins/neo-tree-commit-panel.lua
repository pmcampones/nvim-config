-- IntelliJ-style "Commit" tab in the explorer sidebar (Neo-tree's git_status source).
-- Click "Commit" at the top of the explorer (or <leader>ge) to open it:
--   * changed files, colored like the Project tab
--   * a checkbox per file/folder: click it to stage/unstage (ticked = goes into the commit);
--     the root "Changes" checkbox stages/unstages everything
--   * double-click a file to see its diff against the last commit
--   * type a message in the box below and click "✓ Commit" (or :w in the box),
--     or "⇡ Commit and Push"
-- Logic lives in lua/ide/commit.lua.

local commit = require("ide.commit")

require("ide.click").on_left_press(commit.checkbox_click)

return {
  {
    "nvim-neo-tree/neo-tree.nvim",
    opts = function(_, opts)
      local defaults = require("neo-tree.defaults")
      -- the checkbox already shows staged/unstaged, so drop those markers in this panel
      local symbols = vim.tbl_extend("force", vim.deepcopy(defaults.default_component_configs.git_status.symbols), {
        staged = "",
        unstaged = "",
        untracked = "",
      })

      opts.git_status = opts.git_status or {}
      opts.git_status.components = vim.tbl_extend("force", opts.git_status.components or {}, {
        commit_checkbox = commit.checkbox_component,
        commit_name = commit.name_component,
      })
      opts.git_status.renderers = {
        directory = {
          { "indent" },
          { "commit_checkbox" },
          { "icon" },
          {
            "container",
            content = {
              { "commit_name", zindex = 10 },
              { "git_status", zindex = 10, align = "right", hide_when_expanded = true, symbols = symbols },
            },
          },
        },
        file = {
          { "indent" },
          { "commit_checkbox" },
          { "icon" },
          {
            "container",
            content = {
              { "commit_name", zindex = 10 },
              { "git_status", zindex = 10, align = "right", symbols = symbols },
            },
          },
        },
      }

      opts.git_status.window = opts.git_status.window or {}
      opts.git_status.window.mappings = vim.tbl_extend("force", opts.git_status.window.mappings or {}, {
        ["<2-LeftMouse>"] = {
          function(state)
            local node = state.tree:get_node()
            if node and node.type == "directory" then
              require("neo-tree.sources.common.commands").toggle_node(state)
            else
              commit.show_diff(node)
            end
          end,
          desc = "Show diff",
        },
        ["gt"] = {
          function(state)
            commit.toggle(state.tree:get_node())
          end,
          desc = "Toggle staged (checkbox)",
        },
      })

      -- never open files in the commit message box
      opts.open_files_do_not_replace_types = opts.open_files_do_not_replace_types or {}
      table.insert(opts.open_files_do_not_replace_types, "gitcommit")

      -- show the message box under the tree while the Commit tab is shown
      opts.event_handlers = opts.event_handlers or {}
      table.insert(opts.event_handlers, {
        event = "neo_tree_window_after_open",
        handler = function(args)
          if args.position ~= "left" and args.position ~= "right" then
            return
          end
          if args.source == "git_status" then
            local state = require("neo-tree.sources.manager").get_state("git_status")
            vim.schedule(function()
              if vim.api.nvim_win_is_valid(args.winid) then
                commit.open_box(args.winid, state and state.path or vim.fn.getcwd())
              end
            end)
          else
            commit.close_box()
          end
        end,
      })
      table.insert(opts.event_handlers, {
        event = "neo_tree_window_after_close",
        handler = function()
          commit.close_box()
        end,
      })
    end,
  },
}
