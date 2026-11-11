-- CPU profiling of Java runs with Java Flight Recorder (built into the JDK).
--   M.new(root, title)  -> profile { jfr, collapsed, svg, jvm_flags } for one run
--   M.finish(profile)   -> after the JVM exits: JFR -> collapsed stacks -> SVG, then opens the
--                          flame graph in Neovim (lua/ide/flamegraph.lua)
-- Files go to ~/.local/share/nvim/profiles/<project>/<time>-<name>.{jfr,collapsed.txt,svg}:
--   .jfr            open with IntelliJ's profiler or JDK Mission Control
--   .collapsed.txt  folded stacks for speedscope / flamegraph.pl / inferno
--   .svg            the flame graph, for a browser

local M = {}

local CONVERTER = vim.fn.stdpath("config") .. "/lua/ide/jfr/JfrCollapse.java"

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Profiler" })
end

function M.dir()
  return vim.fn.stdpath("data") .. "/profiles"
end

--- JFR settings with CPU sampling every 1 ms (the built-in "profile" settings sample every
--- 10–20 ms, too coarse for short runs). Generated once with `jfr configure`; falls back to
--- "profile" on JDKs without it.
local function settings()
  local path = M.dir() .. "/sampling-1ms.jfc"
  if not vim.uv.fs_stat(path) then
    vim.fn.mkdir(M.dir(), "p")
    vim.system({ "jfr", "configure", "method-profiling=max", "--output", path }):wait()
  end
  return vim.uv.fs_stat(path) and path or "profile"
end

function M.new(root, title)
  local project = vim.fn.fnamemodify(root, ":t")
  local dir = ("%s/%s"):format(M.dir(), project)
  vim.fn.mkdir(dir, "p")
  local name = title:gsub("[^%w%._-]+", "_"):gsub("_+$", "")
  local base = ("%s/%s-%s"):format(dir, os.date("%Y%m%d-%H%M%S"), name)
  local jfr = base .. ".jfr"
  return {
    title = title,
    jfr = jfr,
    collapsed = base .. ".collapsed.txt",
    svg = base .. ".svg",
    -- sample CPU every 1 ms, keep deep stacks, write the file when the JVM exits
    jvm_flags = {
      "-XX:FlightRecorderOptions:stackdepth=1024",
      ("-XX:StartFlightRecording=filename=%s,settings=%s,dumponexit=true"):format(jfr, settings()),
    },
  }
end

--- Called when the profiled run ended: convert and show the flame graph.
function M.finish(profile, on_ready)
  if not vim.uv.fs_stat(profile.jfr) then
    return notify("No profile was written: the JVM didn't start, or was killed before it could save the recording.", vim.log.levels.WARN)
  end
  notify("Building the flame graph…")
  vim.system({ "java", CONVERTER, profile.jfr, profile.collapsed }, { text = true }, function(res)
    vim.schedule(function()
      if res.code ~= 0 or not vim.uv.fs_stat(profile.collapsed) then
        return notify("Couldn't read the recording:\n" .. vim.trim(res.stderr or ""), vim.log.levels.ERROR)
      end
      local fg = require("ide.flamegraph")
      pcall(fg.write_svg, profile.collapsed, profile.svg, profile.title)
      profile.ready = true
      fg.open(profile.collapsed, profile.title, profile.svg)
      notify(("Profile of %s (%s)\nSaved in %s:\n  %s\n  %s\n  %s"):format(
        profile.title, vim.trim(res.stdout or ""), vim.fn.fnamemodify(vim.fn.fnamemodify(profile.jfr, ":h"), ":~"),
        vim.fn.fnamemodify(profile.jfr, ":t"), vim.fn.fnamemodify(profile.collapsed, ":t"), vim.fn.fnamemodify(profile.svg, ":t")))
      if on_ready then
        on_ready()
      end
    end)
  end)
end

--- Reopen the flame graph of a finished profile.
function M.show(profile)
  if profile and profile.ready then
    require("ide.flamegraph").open(profile.collapsed, profile.title, profile.svg)
  end
end

return M
