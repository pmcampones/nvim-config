-- IDE-like mouse controls for the Neo-tree file explorer:
--   * drag the vertical separator to resize; the width is remembered (also across restarts)
--   * click "« Hide" in the explorer's title bar to minimize it
--   * drag the separator almost all the way left to snap it closed
--   * click "Explorer" at the top-left (or the folder icon in the statusline) to open it again

local MIN_WIDTH = 10 -- dragging narrower than this minimizes the explorer
local DEFAULT_WIDTH = 35
local width_file = vim.fn.stdpath("state") .. "/neotree_width"

local M = {}

local function load_width()
  local f = io.open(width_file, "r")
  if not f then
    return DEFAULT_WIDTH
  end
  local w = tonumber(f:read("*l"))
  f:close()
  return w or DEFAULT_WIDTH
end

M.width = load_width()

local function save_width(w)
  if w == M.width then
    return
  end
  M.width = w
  local f = io.open(width_file, "w")
  if f then
    f:write(tostring(w))
    f:close()
  end
end

local function is_open()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "neo-tree" then
      return true
    end
  end
  return false
end
M.is_open = is_open

function M.minimize()
  require("neo-tree.command").execute({ action = "close" })
end

function M.restore()
  require("neo-tree.command").execute({ action = "show", dir = LazyVim.root() })
end

function M.toggle()
  if is_open() then
    M.minimize()
  else
    M.restore()
  end
end

-- Click handlers for %@...@ in winbar/statusline must be reachable from v:lua.
_G.NeotreeMouseMinimize = function()
  vim.schedule(M.minimize)
end

-- Sidebar tabs (IntelliJ tool windows): minwid 1 = Project (files), 2 = Commit (git changes),
-- 3 = Log (bottom panel)
local TABS = { { label = "Project", source = "filesystem" }, { label = "Commit", source = "git_status" } }

_G.NeotreeTab = function(minwid)
  if minwid == 3 then -- "Log": toggles the Git Log panel at the bottom (lua/ide/gitlog.lua)
    vim.schedule(function()
      require("ide.gitlog").toggle(LazyVim.root())
    end)
    return
  end
  local tab = TABS[minwid]
  if tab then
    vim.schedule(function()
      require("neo-tree.command").execute({ action = "focus", source = tab.source, dir = LazyVim.root() })
    end)
  end
end

-- Evaluated per window, so the active tab follows the source shown in that window.
_G.NeotreeWinbar = function(win)
  local ok, state = pcall(require("neo-tree.sources.manager").get_state_for_window, win)
  local current = ok and state and state.name or "filesystem"
  local parts = {}
  for i, tab in ipairs(TABS) do
    local hl = tab.source == current and "%#Title#" or "%#Comment#"
    table.insert(parts, ("%s%%%d@v:lua.NeotreeTab@ %s %%X%%*"):format(hl, i, tab.label))
  end
  local log_hl = package.loaded["ide.gitlog"] and require("ide.gitlog").is_open() and "%#Title#" or "%#Comment#"
  table.insert(parts, log_hl .. "%3@v:lua.NeotreeTab@ Log %X%*")  return table.concat(parts, "%#Comment#│%*") .. "%=%#Special#%@v:lua.NeotreeMouseMinimize@ « Hide %X%*"
end
_G.NeotreeMouseToggle = function()
  vim.schedule(M.toggle)
end

return {
  {
    "nvim-neo-tree/neo-tree.nvim",
    opts = function(_, opts)
      opts.window = opts.window or {}
      opts.window.width = function()
        return M.width
      end

      opts.event_handlers = opts.event_handlers or {}
      table.insert(opts.event_handlers, {
        event = "neo_tree_window_after_open",
        handler = function(args)
          if args.position ~= "left" and args.position ~= "right" then
            return
          end
          if args.winid and vim.api.nvim_win_is_valid(args.winid) then
            vim.wo[args.winid].winbar = ("%%{%%v:lua.NeotreeWinbar(%d)%%}"):format(args.winid)
          end
        end,
      })

      -- Track mouse drags of the separator: remember the width, or snap closed when tiny.
      vim.api.nvim_create_autocmd("WinResized", {
        group = vim.api.nvim_create_augroup("neotree_mouse_resize", { clear = true }),
        callback = function()
          for _, win in ipairs(vim.v.event.windows or {}) do
            if vim.api.nvim_win_is_valid(win) and vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "neo-tree" then
              local w = vim.api.nvim_win_get_width(win)
              if w < MIN_WIDTH then
                vim.schedule(M.minimize)
              elseif w <= math.floor(vim.o.columns * 0.6) then
                -- ignore cases where it became the only/huge window
                save_width(w)
              end
            end
          end
        end,
      })
    end,
  },

  -- Clickable explorer toggle at the far left of the statusline (restores a minimized explorer).
  {
    "nvim-lualine/lualine.nvim",
    opts = function(_, opts)
      -- LazyVim hides the statusline on the start screen (dashboard); keep it, so the explorer
      -- and Terminal buttons are there from the moment Neovim opens
      local disabled = vim.tbl_get(opts, "options", "disabled_filetypes", "statusline")
      if type(disabled) == "table" then
        opts.options.disabled_filetypes.statusline = vim.tbl_filter(function(ft)
          return not vim.tbl_contains({ "dashboard", "alpha", "ministarter", "snacks_dashboard" }, ft)
        end, disabled)
      end
      local explorer_button = {
        function()
          return is_open() and "󰉖" or "󰉋"
        end,
        on_click = function()
          M.toggle()
        end,
        color = "Directory",
        padding = { left = 1, right = 1 },
      }
      -- "Terminal" button next to it: shows / hides the terminal panel, whose terminals are
      -- tabs (lua/ide/terminals.lua)
      local terminal_button = {
        function()
          return " Terminal"
        end,
        on_click = function()
          vim.schedule(require("ide.terminals").toggle)
        end,
        color = function()
          local open = package.loaded["ide.terminals"] and require("ide.terminals").is_open()
          return open and "Title" or "Comment"
        end,
        padding = { left = 0, right = 1 },
      }
      opts.sections = opts.sections or {}
      opts.sections.lualine_c = opts.sections.lualine_c or {}
      table.insert(opts.sections.lualine_c, 1, explorer_button)
      table.insert(opts.sections.lualine_c, 2, terminal_button)

      -- While the explorer is focused (as it is right after startup), lualine's "neo-tree"
      -- extension replaces the whole statusline with just the folder name: use one that also
      -- keeps the buttons.
      opts.extensions = vim.tbl_filter(function(ext)
        return ext ~= "neo-tree"
      end, opts.extensions or {})
      table.insert(opts.extensions, {
        filetypes = { "neo-tree" },
        sections = {
          lualine_a = {
            function()
              return vim.fn.fnamemodify(vim.fn.getcwd(), ":~")
            end,
          },
          lualine_c = { explorer_button, terminal_button },
        },
      })
    end,
  },

  -- Always-visible "Explorer" button at the top-left of the tab bar.
  {
    "akinsho/bufferline.nvim",
    opts = function(_, opts)
      opts.options = opts.options or {}
      opts.options.always_show_bufferline = true -- keep the bar (and the button) visible
      opts.options.custom_areas = opts.options.custom_areas or {}
      opts.options.custom_areas.left = function()
        if is_open() then
          return {}
        end
        return {
          { text = "%@v:lua.NeotreeMouseToggle@ 󰉋 Explorer %X", link = "Directory" },
        }
      end
      -- keep the bar updated when the explorer opens/closes
      vim.api.nvim_create_autocmd({ "WinNew", "WinClosed", "BufWinEnter" }, {
        group = vim.api.nvim_create_augroup("neotree_mouse_tabline", { clear = true }),
        callback = function()
          vim.schedule(function()
            vim.cmd.redrawtabline()
          end)
        end,
      })
    end,
  },
}
