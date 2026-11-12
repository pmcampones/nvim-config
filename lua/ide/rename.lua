-- IntelliJ-style "Rename…": rename the variable / field / method / class under the cursor and
-- every reference to it, in all files, through the language server (jdtls for Java).
-- Renaming a Java class also renames its file. Files changed by the rename are saved.

local M = {}

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Rename" })
end

--- The language server that can rename in this buffer, or nil.
function M.client(bufnr)
  for _, c in ipairs(vim.lsp.get_clients({ bufnr = bufnr or 0 })) do
    if c:supports_method("textDocument/rename") then
      return c
    end
  end
end

--- Files touched by a workspace edit: list of file paths (new path for renamed files).
local function touched_files(edit)
  local files, seen = {}, {}
  local function add(uri)
    local path = vim.uri_to_fname(uri)
    if not seen[path] then
      seen[path] = true
      table.insert(files, path)
    end
  end
  for uri in pairs(edit.changes or {}) do
    add(uri)
  end
  for _, change in ipairs(edit.documentChanges or {}) do
    if change.textDocument then
      add(change.textDocument.uri)
    elseif change.kind == "rename" then
      add(change.newUri)
    end
  end
  return files
end

function M.rename()
  local bufnr = vim.api.nvim_get_current_buf()
  local client = M.client(bufnr)
  if not client then
    return notify("No language server here that can rename", vim.log.levels.WARN)
  end
  local win = vim.api.nvim_get_current_win()
  local params = vim.lsp.util.make_position_params(win, client.offset_encoding)
  local word = vim.fn.expand("<cword>")

  local function ask(current)
    vim.ui.input({ prompt = ("Rename '%s' to: "):format(current), default = current }, function(new_name)
      new_name = new_name and vim.trim(new_name) or ""
      if new_name == "" or new_name == current then
        return
      end
      -- buffers that already had unsaved changes are left unsaved (they're yours)
      local modified_before = {}
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.bo[b].modified then
          modified_before[vim.api.nvim_buf_get_name(b)] = true
        end
      end
      local rename_params = vim.tbl_extend("force", params, { newName = new_name })
      client:request("textDocument/rename", rename_params, function(err, edit)
        vim.schedule(function()
          if err then
            return notify("Can't rename: " .. err.message, vim.log.levels.ERROR)
          end
          if not edit or (vim.tbl_isempty(edit.changes or {}) and vim.tbl_isempty(edit.documentChanges or {})) then
            return notify("Nothing to rename here", vim.log.levels.WARN)
          end
          vim.lsp.util.apply_workspace_edit(edit, client.offset_encoding)
          local files = touched_files(edit)
          local saved = 0
          for _, path in ipairs(files) do
            local b = vim.fn.bufnr(path)
            if b ~= -1 and vim.api.nvim_buf_is_loaded(b) and vim.bo[b].modified and not modified_before[path] then
              -- a normal save (so the language server hears about it), but without
              -- LazyVim's format-on-save: a rename shouldn't reformat files
              local before = vim.b[b].autoformat
              vim.b[b].autoformat = false
              vim.api.nvim_buf_call(b, function()
                vim.cmd("silent update")
              end)
              vim.b[b].autoformat = before
              saved = saved + 1
            end
          end
          notify(("Renamed '%s' to '%s' in %d file%s"):format(current, new_name, #files, #files == 1 and "" or "s"))
        end)
      end, bufnr)
    end)
  end

  -- ask the server first whether this can be renamed (and what the exact name is)
  if client:supports_method("textDocument/prepareRename") then
    client:request("textDocument/prepareRename", params, function(err, result)
      vim.schedule(function()
        if err or result == nil then
          return notify(("'%s' can't be renamed here (put the cursor on a variable, field, method or class name)"):format(word), vim.log.levels.WARN)
        end
        local current = word
        if result.placeholder then
          current = result.placeholder
        elseif result.start or result.range then
          local range = result.range or result
          local line = vim.api.nvim_buf_get_lines(bufnr, range.start.line, range.start.line + 1, false)[1] or ""
          if range.start.line == range["end"].line then
            local s = vim.str_byteindex(line, client.offset_encoding, range.start.character, false)
            local e = vim.str_byteindex(line, client.offset_encoding, range["end"].character, false)
            current = line:sub(s + 1, e)
          end
        end
        ask(current)
      end)
    end, bufnr)
  else
    ask(word)
  end
end

return M
