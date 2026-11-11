-- Keep Rust formatting (rustfmt, run on save through rust-analyzer) at 2-space indents
-- instead of rustfmt's default of 4. The editor-side indent options are in lua/config/options.lua.
return {
  {
    "mrcjkb/rustaceanvim",
    optional = true,
    opts = {
      server = {
        default_settings = {
          ["rust-analyzer"] = {
            rustfmt = { extraArgs = { "--config", "tab_spaces=2" } },
          },
        },
      },
    },
  },
}
