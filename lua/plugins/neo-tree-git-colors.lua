-- IntelliJ-style Git colors for file/folder names in the Neo-tree explorer:
--   default (white) : committed and unchanged
--   blue            : modified, with changes not yet staged
--   green           : staged and not yet committed (new files that were `git add`-ed
--                     stay green until committed, like IntelliJ's "added" files)
--   red             : untracked (never added to Git, not ignored)
-- Ignored files and merge conflicts keep Neo-tree's own colors.
-- A folder takes the color of its changes: green/red when they are all of that kind,
-- blue when they are mixed.

local COLORS = {
  dark = { modified = "#6897BB", staged = "#629755", untracked = "#D1675A" },
  light = { modified = "#0032A0", staged = "#067D17", untracked = "#993300" },
}

local HL = {
  modified = "NeoTreeIdeaModified",
  staged = "NeoTreeIdeaStaged",
  untracked = "NeoTreeIdeaUntracked",
}

local function set_highlights()
  local palette = COLORS[vim.o.background] or COLORS.dark
  for kind, group in pairs(HL) do
    vim.api.nvim_set_hl(0, group, { fg = palette[kind] })
  end
end

---@param code string a status code from neo-tree, e.g. "?", ".M", "M.", "AM"
---@return "modified"|"staged"|"untracked"|nil
local function classify(code)
  if code == "?" then
    return "untracked"
  end
  if code == "!" or #code < 2 then
    return nil -- ignored: keep Neo-tree's dimmed color
  end
  local x, y = code:sub(1, 1), code:sub(2, 2) -- x = staging area, y = working tree
  if require("neo-tree.git.parser").status_code_is_conflict(x, y) then
    return nil
  end
  if x == "A" then
    return "staged" -- new file added to Git
  end
  if y ~= "." then
    return "modified" -- has changes that aren't staged
  end
  return "staged" -- all changes staged
end

-- Neo-tree summarizes a folder's status as a single letter (losing staged vs. unstaged),
-- so a folder's color is computed from the statuses of the files inside it.
-- (Only changed files are in the status map, so this scan is small.)
local function folder_kind(dir, status_map)
  local prefix = dir .. "/"
  local kind
  for path, code in pairs(status_map) do
    if type(code) == "string" and path:sub(1, #prefix) == prefix then
      local k = classify(code)
      if k then
        if kind and kind ~= k then
          return "modified"
        end
        kind = k
      end
    end
  end
  return kind
end

local function kind_for(node)
  local git = require("neo-tree.git")
  local status = git.find_existing_status_code(node.path)
  if type(status) == "string" then
    return classify(status) -- a file, or a folder that is entirely untracked/ignored
  end
  if node.type == "directory" and status then
    local _, worktree = git.find_existing_worktree(node.path)
    if worktree and worktree.status then
      return folder_kind(node.path, worktree.status)
    end
  end
end

--- Wraps a source's own "name" component so names get the Git colors.
local function colored(base_module)
  return function(config, node, state)
    local result = require(base_module).name(config, node, state)
    if node.type ~= "message" and node:get_depth() > 1 and node.path then
      local kind = kind_for(node)
      if kind then
        result.highlight = HL[kind]
      end
    end
    return result
  end
end

return {
  {
    "nvim-neo-tree/neo-tree.nvim",
    opts = function(_, opts)
      set_highlights()
      vim.api.nvim_create_autocmd("ColorScheme", {
        group = vim.api.nvim_create_augroup("neotree_idea_git_colors", { clear = true }),
        callback = set_highlights,
      })
      -- No "?" marker for untracked files: the red name already says it.
      opts.default_component_configs = opts.default_component_configs or {}
      opts.default_component_configs.git_status = opts.default_component_configs.git_status or {}
      opts.default_component_configs.git_status.symbols = opts.default_component_configs.git_status.symbols or {}
      opts.default_component_configs.git_status.symbols.untracked = ""

      opts.filesystem = opts.filesystem or {}
      opts.filesystem.components = opts.filesystem.components or {}
      opts.filesystem.components.name = colored("neo-tree.sources.common.components")
      -- same colors in the Commit tab (see neo-tree-commit-panel.lua)
      opts.git_status = opts.git_status or {}
      opts.git_status.components = opts.git_status.components or {}
      opts.git_status.components.name = colored("neo-tree.sources.git_status.components")
    end,
  },
}
