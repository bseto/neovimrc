return {
  "nvim-lualine/lualine.nvim",
  opts = function(_, opts)
    table.insert(opts.sections.lualine_x, 1, {
      function()
        return require("util.bifrost_budget").text()
      end,
      cond = function()
        return require("util.bifrost_budget").is_bifrost()
      end,
    })
  end,
}
