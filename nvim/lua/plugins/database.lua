-- Database client. Two are wired up; lua/config/db.lua picks which one is live.
-- Change that value, restart Neovim, then run :Lazy sync.
local client = require("config.db")

return {
  -- sqmeow.nvim -- database UI backed by a Rust engine.
  {
    "2giosangmitom/sqmeow.nvim",
    enabled = client == "sqmeow",
    dependencies = { "MunifTanjim/nui.nvim" },
    version = "*",
    build = function()
      -- Downloads the release binary matching this version and checks its SHA-256.
      -- Pass "cargo" instead to build from source.
      require("sqmeow").install()
    end,
    opts = {},
    cmd = "Sqmeow",
    keys = {
      { "<leader>Dd", "<cmd>Sqmeow toggle<cr>", desc = "Toggle Database UI" },
      { "<leader>Da", "<cmd>Sqmeow add<cr>", desc = "Add Connection" },
      { "<leader>Ds", "<cmd>Sqmeow scratch<cr>", desc = "New Scratchpad" },
      { "<leader>Dc", "<cmd>Sqmeow cancel<cr>", desc = "Cancel Query" },
    },
  },

  -- vim-dadbod-ui arrives with the lazyvim.plugins.extras.lang.sql import in
  -- lua/config/lazy.lua. Switching it off here leaves the rest of that extra --
  -- sqlfluff, treesitter sql, and dadbod completion -- in place.
  {
    "kristijanhusak/vim-dadbod-ui",
    enabled = client == "dadbod",
  },

  -- That same extra pins a dbui sidebar and a dbout result pane into edgy.
  -- With dadbod off the :DBUI those panes call no longer exists, so drop them.
  {
    "folke/edgy.nvim",
    optional = true,
    opts = function(_, opts)
      if client == "dadbod" then
        return
      end
      for _, side in ipairs({ "left", "right", "top", "bottom" }) do
        if opts[side] then
          opts[side] = vim.tbl_filter(function(view)
            return view.ft ~= "dbui" and view.ft ~= "dbout"
          end, opts[side])
        end
      end
    end,
  },
}
