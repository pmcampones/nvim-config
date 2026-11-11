-- Drag & drop to move files/folders in the Neo-tree file explorer (IntelliJ-style):
--   press on a file or folder, drag it, release on a folder -> moves it into that folder
--   releasing on a file moves it into that file's folder; releasing on empty space below
--   the tree moves it to the project root. A confirmation is asked before moving.
-- Open buffers of moved files follow the new path. Dragging the window separator still resizes.

local press -- { win, line } where the left button went down inside the explorer
local dragging = false

local function explorer_state(win)
  if win == 0 or not vim.api.nvim_win_is_valid(win) then
    return nil
  end
  if vim.bo[vim.api.nvim_win_get_buf(win)].filetype ~= "neo-tree" then
    return nil
  end
  local state = require("neo-tree.sources.manager").get_state_for_window(win)
  return state and state.name == "filesystem" and state or nil
end

local function node_at(state, line)
  local ok, node = pcall(state.tree.get_node, state.tree, line)
  if ok and node and node.type ~= "message" then
    return node
  end
end

local function rel(state, path)
  local root = state.path
  if path == root then
    return vim.fn.fnamemodify(root, ":t") .. "/"
  end
  return path:sub(1, #root + 1) == root .. "/" and path:sub(#root + 2) or path
end

local function do_move(state, from_line, to_line)
  local src = node_at(state, from_line)
  if not src or src:get_id() == state.path then
    return -- nothing (or the root itself) was dragged
  end
  local source = src:get_id()

  local target = to_line and node_at(state, to_line)
  local dest_dir
  if not target then
    dest_dir = state.path -- dropped below the tree: project root
  elseif target.type == "directory" then
    dest_dir = target:get_id()
  else
    dest_dir = vim.fn.fnamemodify(target:get_id(), ":h")
  end

  local parent = vim.fn.fnamemodify(source, ":h")
  if dest_dir == parent or dest_dir == source then
    return -- dropped where it already is
  end
  if src.type == "directory" and dest_dir:sub(1, #source + 1) == source .. "/" then
    vim.notify("Cannot move a folder into itself", vim.log.levels.WARN, { title = "Explorer" })
    return
  end

  local name = vim.fn.fnamemodify(source, ":t")
  local choice =
    vim.fn.confirm(('Move "%s" to "%s"?'):format(rel(state, source), rel(state, dest_dir)), "&Move\n&Cancel", 1)
  if choice ~= 1 then
    return
  end

  local fs = require("neo-tree.sources.filesystem")
  require("neo-tree.sources.filesystem.lib.fs_actions").move_node(source, dest_dir .. "/" .. name, function(s, d)
    fs.focus_destination_children(state, s, d)
  end, "")
end

-- Remember where a left click started (pass-through: the click itself behaves as usual).
require("ide.click").on_left_press(function(pos)
  press, dragging = nil, false
  -- line == 0 means the separator/status line, so separator drags (resizing) are untouched
  if pos.line > 0 and explorer_state(pos.winid) then
    press = { win = pos.winid, line = pos.line }
  end
  return false
end)

local function on_drag()
  if not press then
    return "<LeftDrag>"
  end
  dragging = true
  -- highlight the entry under the mouse as the drop target
  local pos = vim.fn.getmousepos()
  vim.schedule(function()
    if pos.winid == press.win and pos.line > 0 and vim.api.nvim_win_is_valid(press.win) then
      local last = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(press.win))
      pcall(vim.api.nvim_win_set_cursor, press.win, { math.min(pos.line, last), 0 })
    end
  end)
  return ""
end

local function on_release()
  local p, was_dragging = press, dragging
  press, dragging = nil, false
  if not (p and was_dragging) then
    return "<LeftRelease>"
  end
  local pos = vim.fn.getmousepos()
  if pos.winid ~= p.win then
    return "" -- dropped outside the explorer: cancel
  end
  vim.schedule(function()
    local state = explorer_state(p.win)
    if not state then
      return
    end
    -- getmousepos() clamps "line" to the last line, so use the screen row to detect
    -- a drop on the empty space below the tree (= move to the project root)
    local last = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(p.win))
    local row_line = vim.fn.line("w0", p.win) + pos.winrow - 1
    local to_line = (pos.line > 0 and row_line <= last) and pos.line or nil
    if to_line == p.line then
      return
    end
    do_move(state, p.line, to_line)
  end)
  return ""
end

vim.api.nvim_create_autocmd("FileType", {
  group = vim.api.nvim_create_augroup("neotree_drag_move", { clear = true }),
  pattern = "neo-tree",
  callback = function(args)
    vim.keymap.set("n", "<LeftDrag>", on_drag, { buffer = args.buf, expr = true, desc = "Drag to move" })
    vim.keymap.set("n", "<LeftRelease>", on_release, { buffer = args.buf, expr = true, desc = "Drop to move" })
  end,
})

return {}
