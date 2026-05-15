return {
  "yetone/avante.nvim",
  event = "VeryLazy",
  version = false,
  build = "make",
  opts = {
    provider = "lmstudio",
    providers = {
      claude = {
        auth_type = "api",
        endpoint = "https://api.anthropic.com",
        model = "claude-sonnet-4-6",
        timeout = 30000,
        extra_request_body = {
          temperature = 0.75,
          max_tokens = 20480,
        },
      },
      lmstudio = {
        __inherited_from = "openai",
        endpoint = "http://127.0.0.1:1234/v1",
        api_key = "lm-studio",
        model = "local-model", -- replace with the model name shown in LM Studio
        timeout = 60000,
        extra_request_body = {
          temperature = 0.75,
          max_tokens = 262144,
        },
      },
    },
  },
  dependencies = {
    "nvim-lua/plenary.nvim",
    "MunifTanjim/nui.nvim",
    "nvim-tree/nvim-web-devicons",
    {
      "HakonHarnes/img-clip.nvim",
      event = "VeryLazy",
      opts = {
        default = {
          embed_image_as_base64 = false,
          prompt_for_file_name = false,
          drag_and_drop = {
            insert_mode = true,
          },
        },
      },
    },
    {
      "MeanderingProgrammer/render-markdown.nvim",
      opts = {
        file_types = { "markdown", "Avante" },
      },
      ft = { "markdown", "Avante" },
    },
  },
}
