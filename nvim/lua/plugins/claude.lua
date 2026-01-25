return {
  "greggh/claude-code.nvim",
  dependencies = {
    "nvim-lua/plenary.nvim", -- Required for git operations
  },
  keys = {
    {
      "<leader>cc",
      function()
        require("claude-code").toggle({ window = { position = "botright" } })
      end,
      desc = "Claude Code (bottom)",
      mode = { "n", "t" },
    },
    {
      "<leader>cp",
      function()
        require("claude-code").toggle({
          window = {
            position = "float",
            float = {
              width = "90%",
              height = "90%",
              row = "center",
              col = "center",
              relative = "editor",
              border = "double",
            },
          },
        })
      end,
      desc = "Claude Code (popup)",
      mode = { "n", "t" },
    },
  },
  config = function()
    require("claude-code").setup({
      window = {
        position = "float",
        float = {
          width = "90%",
          height = "90%",
          row = "center",
          col = "center",
          relative = "editor",
          border = "double",
        },
      },
    })
  end,
}
