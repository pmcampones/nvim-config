-- Mason's default package marker "◍" (U+25CD) isn't in the Nerd Font,
-- so use Nerd Font package icons instead.
return {
  {
    "mason-org/mason.nvim",
    opts = {
      ui = {
        icons = {
          package_installed = "󰏗", -- closed package
          package_pending = "󰔟", -- hourglass
          package_uninstalled = "󰏖", -- open package
        },
      },
    },
  },
}
