-- One global <LeftMouse> mapping shared by the explorer features (drag & drop, commit checkboxes).
-- A mapping has to be global: when another window has focus, buffer-local mappings of the
-- clicked window don't apply to the click.
--
-- Hooks run inside an expression mapping (text is locked), so they must only inspect state
-- and vim.schedule() any real work. A hook returns true to consume the click.

local M = { hooks = {} }

---@param fn fun(pos: table): boolean? receives vim.fn.getmousepos()
function M.on_left_press(fn)
  table.insert(M.hooks, fn)
end

vim.keymap.set("n", "<LeftMouse>", function()
  local pos = vim.fn.getmousepos()
  for _, hook in ipairs(M.hooks) do
    local ok, consumed = pcall(hook, pos)
    if ok and consumed then
      return ""
    end
  end
  return "<LeftMouse>"
end, { expr = true, desc = "Left click (explorer-aware)" })

return M
