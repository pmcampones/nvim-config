-- Commands for repository setup (logic in lua/ide/git_repo.lua). The same actions are in the
-- explorer's right-click menu, and Push is also a button in the Git Log header.
--   :GitInit [dir]   create a Git repository (default: the project folder)
--   :GitRemote       set or change the remote ("origin")
--   :GitPush         push the current branch (asks for a remote / sets the upstream if needed)

local function project_dir()
  local ok, root = pcall(function()
    return LazyVim.root()
  end)
  return ok and root or vim.fn.getcwd()
end

vim.api.nvim_create_user_command("GitInit", function(opts)
  require("ide.git_repo").init(opts.args ~= "" and vim.fn.expand(opts.args) or project_dir())
end, { nargs = "?", complete = "dir", desc = "Create a Git repository" })

vim.api.nvim_create_user_command("GitRemote", function()
  require("ide.git_repo").set_remote(project_dir())
end, { desc = "Set the Git remote (origin)" })

vim.api.nvim_create_user_command("GitPush", function()
  require("ide.git_repo").push(project_dir())
end, { desc = "Push the current branch" })

return {}
