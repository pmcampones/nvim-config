-- Flame graph viewer for "collapsed stacks" files ("root;caller;...;leaf <samples>" per line),
-- plus an SVG writer for opening the same graph in a browser.
--
-- In the viewer (a new tab): each bar is a method, its width is its share of the samples, the
-- callers are below the callees (root at the bottom). Move onto a bar to see its name and
-- percentage in the header.
--   <CR> / double-click  zoom into the bar under the cursor
--   <BS> / u             zoom out          /  highlight frames matching a text
--   o                    open the SVG in the browser          q  close

local M = {}

local ns = vim.api.nvim_create_namespace("ide_flamegraph")

--------------------------------------------------------------------------------
-- Data
--------------------------------------------------------------------------------

---@class FlameNode
---@field name string
---@field value integer
---@field children table<string, FlameNode>
---@field order string[]
---@field parent FlameNode?

local function new_node(name, parent)
  return { name = name, value = 0, children = {}, order = {}, parent = parent }
end

--- Reads a collapsed-stacks file into a tree.
function M.parse(path)
  local root = new_node("all", nil)
  for _, line in ipairs(vim.fn.readfile(path)) do
    local stack, count = line:match("^(.*) (%d+)$")
    if stack then
      count = tonumber(count)
      root.value = root.value + count
      local node = root
      for frame in stack:gmatch("[^;]+") do
        local child = node.children[frame]
        if not child then
          child = new_node(frame, node)
          node.children[frame] = child
          table.insert(node.order, frame)
        end
        child.value = child.value + count
        node = child
      end
    end
  end
  -- widest first, like most flame graph tools
  local function sort(node)
    table.sort(node.order, function(a, b)
      return node.children[a].value > node.children[b].value
    end)
    for _, name in ipairs(node.order) do
      sort(node.children[name])
    end
  end
  sort(root)
  return root
end

local function depth_of(node)
  local max = 0
  for _, name in ipairs(node.order) do
    max = math.max(max, 1 + depth_of(node.children[name]))
  end
  return max
end

--- Short display name: "com.app.Foo.bar" -> "Foo.bar" (the full name shows in the header).
local function short(name)
  if name:match("^%[") then
    return name -- thread
  end
  local cls, method = name:match("([%w_$]+)%.([%w_$<>:]+)$")
  return cls and (cls .. "." .. method) or name
end

--------------------------------------------------------------------------------
-- Colors
--------------------------------------------------------------------------------

local WARM = { "#E8743B", "#E2903B", "#D9A441", "#E05D44", "#F2A65A", "#D97B48", "#C9663F", "#EDB458" }

local function hash(s)
  local h = 0
  for i = 1, #s do
    h = (h * 31 + s:byte(i)) % 2147483647
  end
  return h
end

--- Highlight group and SVG color for a frame: JDK / libraries are muted, your code is warm.
local function frame_color(name)
  if name:match("^%[") then
    return "IdeFlameThread", "#8A8F98"
  end
  if name:match("^java%.") or name:match("^javax%.") or name:match("^jdk%.") or name:match("^sun%.") or name:match("^com%.sun%.") then
    return "IdeFlameJdk", "#C7B37A"
  end
  if name:match("^org%.junit%.") or name:match("^org%.apache%.maven%.") or name:match("^org%.hibernate%.")
    or name:match("^org%.springframework%.") or name:match("^com%.google%.") or name:match("^io%.grpc%.") then
    return "IdeFlameLib", "#9CB5A3"
  end
  local i = hash(name) % #WARM + 1
  return "IdeFlameUser" .. i, WARM[i]
end

local function set_highlights()
  vim.api.nvim_set_hl(0, "IdeFlameThread", { bg = "#8A8F98", fg = "#111111" })
  vim.api.nvim_set_hl(0, "IdeFlameJdk", { bg = "#C7B37A", fg = "#111111" })
  vim.api.nvim_set_hl(0, "IdeFlameLib", { bg = "#9CB5A3", fg = "#111111" })
  for i, c in ipairs(WARM) do
    vim.api.nvim_set_hl(0, "IdeFlameUser" .. i, { bg = c, fg = "#111111" })
  end
  vim.api.nvim_set_hl(0, "IdeFlameMatch", { bg = "#B04CD9", fg = "#FFFFFF", bold = true })
  vim.api.nvim_set_hl(0, "IdeFlameCurrent", { bg = "#FFFFFF", fg = "#000000", bold = true })
end

--------------------------------------------------------------------------------
-- Viewer
--------------------------------------------------------------------------------

local function render(view)
  local buf, win = view.buf, view.win
  if not (vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_win_is_valid(win)) then
    return
  end
  local width = vim.api.nvim_win_get_width(win) - 1
  local root = view.focus
  local levels = depth_of(root) + 1
  local rows = {} -- rows[depth] = { chars = {...}, segments = { {s, e, node} } }
  for d = 0, levels - 1 do
    rows[d] = { line = string.rep(" ", width), segments = {} }
  end

  local function place(node, depth, x, w)
    local s, e = math.floor(x + 0.5), math.floor(x + w + 0.5)
    if e - s < 1 then
      return -- too narrow to show
    end
    local label = short(node.name)
    local room = e - s - 1
    local text = room >= 3 and (vim.fn.strcharpart(label, 0, room) .. string.rep(" ", math.max(0, room - vim.fn.strchars(label)))) or string.rep(" ", room)
    if vim.fn.strchars(label) > room and room >= 3 then
      text = vim.fn.strcharpart(label, 0, room - 1) .. "…"
    end
    text = text .. " "
    local row = rows[depth]
    -- the line is ASCII spaces where nothing is drawn; frames may contain multibyte chars,
    -- so rebuild the line from character cells
    row.cells = row.cells or vim.split(row.line, "")
    local chars = vim.fn.split(text, "\\zs")
    for i = 1, e - s do
      row.cells[s + i] = chars[i] or " "
    end
    table.insert(row.segments, { s = s, e = e, node = node })
    local child_x = x
    for _, name in ipairs(node.order) do
      local child = node.children[name]
      local cw = w * child.value / node.value
      place(child, depth + 1, child_x, cw)
      child_x = child_x + cw
    end
  end
  place(root, 0, 0, width)

  -- root at the bottom: depth 0 is the last line
  local lines, line_rows = {}, {}
  for d = levels - 1, 0, -1 do
    local row = rows[d]
    table.insert(lines, row.cells and table.concat(row.cells) or row.line)
    line_rows[#lines] = row
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  view.line_rows = line_rows
  for lnum, row in pairs(line_rows) do
    local text = lines[lnum]
    for _, seg in ipairs(row.segments) do
      -- convert cell columns to byte columns
      local bs = vim.str_byteindex(text, "utf-32", seg.s, false)
      local be = vim.str_byteindex(text, "utf-32", math.max(seg.s, seg.e - 1), false)
      local group = frame_color(seg.node.name)
      if view.search and view.search ~= "" and seg.node.name:lower():find(view.search:lower(), 1, true) then
        group = "IdeFlameMatch"
      end
      if seg.node == view.current then
        group = "IdeFlameCurrent"
      end
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, lnum - 1, bs, { end_col = be, hl_group = group })
    end
  end
end

local function node_at_cursor(view)
  local cur = vim.api.nvim_win_get_cursor(view.win)
  local row = view.line_rows and view.line_rows[cur[1]]
  if not row then
    return nil
  end
  local line = vim.api.nvim_buf_get_lines(view.buf, cur[1] - 1, cur[1], false)[1] or ""
  local cell = vim.fn.strchars(line:sub(1, cur[2]))
  for _, seg in ipairs(row.segments) do
    if cell >= seg.s and cell < seg.e then
      return seg.node
    end
  end
end

local views = {}

_G.IdeFlameOpenSvg = function()
  local view = views[vim.api.nvim_get_current_buf()] or select(2, next(views))
  if view and view.svg then
    vim.ui.open(view.svg)
  end
end

local function update_header(view)
  local node = node_at_cursor(view)
  view.current = node
  local info
  if node then
    local pct_total = 100 * node.value / view.root.value
    info = ("%s  —  %d samples, %.1f%%"):format(node.name, node.value, pct_total)
  else
    info = "move onto a bar to see the method"
  end
  local zoom = view.focus ~= view.root and ("%#WarningMsg# zoomed: " .. short(view.focus.name) .. " (BS = out) %*") or ""
  vim.wo[view.win].winbar = ("%%#Title# 🔥 %s %%*%s %%#Normal#%s%%*%%=%%#Special#%%@v:lua.IdeFlameOpenSvg@ ⇱ SVG %%X%%*")
    :format(view.title:gsub("%%", "%%%%"), zoom, info:gsub("%%", "%%%%"))
end

--- Open the flame graph of a collapsed-stacks file in a new tab.
function M.open(collapsed, title, svg)
  set_highlights()
  local root = M.parse(collapsed)
  if root.value == 0 then
    vim.notify("The profile has no CPU samples (the program may have run too briefly).", vim.log.levels.WARN, { title = "Profiler" })
    return
  end
  vim.cmd("tabnew")
  local buf = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "ide-flamegraph"
  pcall(vim.api.nvim_buf_set_name, buf, "Flame graph: " .. title)
  local wo = vim.wo[win]
  wo.number, wo.relativenumber, wo.signcolumn, wo.statuscolumn = false, false, "no", ""
  wo.wrap, wo.cursorline, wo.list, wo.spell = false, false, false, false
  local view = { buf = buf, win = win, root = root, focus = root, title = title, svg = svg }
  views[buf] = view
  render(view)
  vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
  update_header(view)

  local function zoom_in()
    local node = node_at_cursor(view)
    if node and node ~= view.focus then
      view.focus = node
      render(view)
      vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
      update_header(view)
    end
  end
  local function zoom_out()
    if view.focus.parent then
      view.focus = view.focus.parent
      render(view)
      vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
      update_header(view)
    end
  end
  local opts = { buffer = buf, nowait = true }
  vim.keymap.set("n", "<CR>", zoom_in, opts)
  vim.keymap.set("n", "<2-LeftMouse>", zoom_in, opts)
  vim.keymap.set("n", "<BS>", zoom_out, opts)
  vim.keymap.set("n", "u", zoom_out, opts)
  vim.keymap.set("n", "o", _G.IdeFlameOpenSvg, opts)
  vim.keymap.set("n", "q", "<Cmd>tabclose<CR>", opts)
  vim.keymap.set("n", "/", function()
    vim.ui.input({ prompt = "Highlight frames containing: ", default = view.search or "" }, function(text)
      if text then
        view.search = text
        render(view)
        update_header(view)
      end
    end)
  end, opts)
  local group = vim.api.nvim_create_augroup("ide_flamegraph_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    buffer = buf,
    callback = function()
      local before = view.current
      update_header(view)
      if view.current ~= before then
        render(view) -- move the white "current" highlight
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinResized", {
    group = group,
    callback = function()
      if vim.api.nvim_win_is_valid(win) and vim.tbl_contains(vim.v.event.windows or {}, win) then
        render(view)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    callback = function()
      views[buf] = nil
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })
end

--------------------------------------------------------------------------------
-- SVG
--------------------------------------------------------------------------------

local function xml_escape(s)
  return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

--- Write a static flame graph SVG (root at the bottom; hover a bar for its full name).
function M.write_svg(collapsed, svg_path, title)
  local root = M.parse(collapsed)
  local W, H = 1600, 18
  local levels = depth_of(root) + 1
  local height = levels * H + 50
  local out = {
    ('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" font-family="monospace" font-size="12">'):format(W, height),
    ('<rect width="100%%" height="100%%" fill="#1e1e1e"/>'),
    ('<text x="10" y="22" fill="#eeeeee" font-size="16">%s — %d samples (hover a bar for details)</text>'):format(xml_escape(title), root.value),
  }
  local function place(node, depth, x, w)
    if w < 0.5 then
      return
    end
    local y = height - (depth + 1) * H
    local _, color = frame_color(node.name)
    local pct = 100 * node.value / root.value
    table.insert(out, ('<g><title>%s (%d samples, %.2f%%)</title><rect x="%.2f" y="%d" width="%.2f" height="%d" fill="%s" rx="2"/>')
      :format(xml_escape(node.name), node.value, pct, x, y, math.max(w - 1, 0.5), H - 1, color))
    local chars = math.floor((w - 6) / 7.2)
    if chars >= 3 then
      local label = short(node.name)
      if #label > chars then
        label = label:sub(1, chars - 1) .. "…"
      end
      table.insert(out, ('<text x="%.2f" y="%d" fill="#111111">%s</text>'):format(x + 3, y + H - 5, xml_escape(label)))
    end
    table.insert(out, "</g>")
    local cx = x
    for _, name in ipairs(node.order) do
      local child = node.children[name]
      local cw = w * child.value / node.value
      place(child, depth + 1, cx, cw)
      cx = cx + cw
    end
  end
  place(root, 0, 0, W)
  table.insert(out, "</svg>")
  vim.fn.writefile(out, svg_path)
end

return M
