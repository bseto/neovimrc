-- CodeCompanion, wired to StackAdapt's Bifrost gateway. Replaces Avante
-- (removed; its spec is in git history).
--
-- Bifrost fronts Claude on its Anthropic-native route (/anthropic), so we extend
-- the stock `anthropic` adapter and only swap the URL, the key and the model
-- list. Endpoint, key lookup and default model match the old Avante config.
--
-- Keymaps (<leader> is ","):
--   <leader>aa   toggle the chat buffer
--   <leader>an   new chat
--   <leader>ac   actions palette
--   <leader>ae   inline assistant (operates on the visual selection if any)
--   <leader>ad   add the visual selection to the current chat
--   :cc          abbreviation for :CodeCompanion
--
-- Inside the chat buffer: `ga` switches adapter/model, `gd` opens the debug
-- window showing the exact request settings, `?` lists all keymaps.

-- Bifrost's Anthropic-native route. The stock adapter posts to
-- https://api.anthropic.com/v1/messages, so the path must include /v1/messages.
local BIFROST_URL = "https://bifrost.stackadapt.dev/anthropic/v1/messages"

-- Key lives in the macOS Keychain, never in this repo. Set it once with:
--   security add-generic-password -U -a "$USER" -s bifrost_api_key -w
-- CodeCompanion runs `cmd:` values through the shell on each request.
local BIFROST_KEY = "cmd:security find-generic-password -s bifrost_api_key -w"

-- Models reachable through Bifrost, which exposes Anthropic models under a
-- bedrock/ prefix. The list is static because the stock adapter discovers
-- models (and their capabilities) from api.anthropic.com/v1/models, which the
-- Bifrost key can't reach, and Bifrost's own /v1/models carries none of the
-- capability metadata the adapter keys off.
--
-- `can_reason = true` makes the adapter send `thinking = { type = "adaptive" }`,
-- which is what Opus 4.8 / Sonnet 5 expect (verified against Bifrost). No
-- temperature is ever sent. Compaction and structured outputs are Anthropic
-- beta features that haven't been verified through Bifrost, so they stay off.
local function bifrost_model(display_name)
  return {
    formatted_name = display_name,
    meta = { context_window = 200000, max_tokens = 32768 },
    opts = {
      can_reason = true,
      has_vision = true,
      can_manage_context = false,
      can_form_structured_outputs = false,
    },
  }
end

local MODELS = {
  ["bedrock/claude-opus-4-8"] = bifrost_model("Claude Opus 4.8 (Bifrost)"),
  ["bedrock/claude-sonnet-5"] = bifrost_model("Claude Sonnet 5 (Bifrost)"),
}

-- Chat, inline and :CodeCompanionCmd use Opus (same as Avante did).
local DEFAULT_MODEL = "bedrock/claude-opus-4-8"
-- Background work (chat titles, tool judging, compaction) uses Sonnet.
local BACKGROUND_MODEL = "bedrock/claude-sonnet-5"

return {
  {
    "olimorris/codecompanion.nvim",
    -- Upstream recommends pinning to a major to avoid breaking changes.
    version = "^19.0.0",
    cmd = { "CodeCompanion", "CodeCompanionChat", "CodeCompanionActions", "CodeCompanionCmd" },
    keys = {
      { "<leader>a", "", desc = "+ai", mode = { "n", "v" } },
      { "<leader>aa", "<cmd>CodeCompanionChat Toggle<cr>", desc = "CodeCompanion: toggle chat", mode = { "n", "v" } },
      { "<leader>an", "<cmd>CodeCompanionChat<cr>", desc = "CodeCompanion: new chat", mode = { "n", "v" } },
      { "<leader>ac", "<cmd>CodeCompanionActions<cr>", desc = "CodeCompanion: actions", mode = { "n", "v" } },
      -- Leaves you in the cmdline to type the prompt; in visual mode the
      -- '<,'> range is inserted automatically so the selection is the target.
      { "<leader>ae", ":CodeCompanion ", desc = "CodeCompanion: inline prompt", mode = { "n", "v" } },
      { "<leader>ad", "<cmd>CodeCompanionChat Add<cr>", desc = "CodeCompanion: add selection to chat", mode = "v" },
    },
    init = function()
      -- `:cc <prompt>` as shorthand for `:CodeCompanion <prompt>`.
      vim.cmd([[cabbrev cc CodeCompanion]])
    end,
    dependencies = {
      "nvim-lua/plenary.nvim",
      "nvim-treesitter/nvim-treesitter",
      -- Paste clipboard images into the chat buffer with :PasteImage.
      {
        "HakonHarnes/img-clip.nvim",
        opts = {
          default = {
            embed_image_as_base64 = false,
            prompt_for_file_name = false,
            drag_and_drop = {
              insert_mode = true,
            },
          },
          filetypes = {
            codecompanion = {
              prompt_for_file_name = false,
              template = "[Image]($FILE_PATH)",
              use_absolute_path = true,
            },
          },
        },
      },
    },
    opts = {
      adapters = {
        http = {
          bifrost = function()
            return require("codecompanion.adapters").extend("anthropic", {
              formatted_name = "Bifrost",
              url = BIFROST_URL,
              env = { api_key = BIFROST_KEY },
              opts = { compaction = false },
              schema = {
                model = {
                  default = DEFAULT_MODEL,
                  choices = MODELS,
                },
              },
            })
          end,
          opts = {
            -- Hide the built-in adapters (copilot, openai, ...) from `ga`;
            -- only Bifrost is usable here.
            show_presets = false,
          },
        },
      },
      interactions = {
        chat = { adapter = "bifrost" },
        inline = { adapter = "bifrost" },
        cmd = { adapter = "bifrost" },
        background = { adapter = { name = "bifrost", model = BACKGROUND_MODEL } },
      },
    },
  },

  -- Render the chat buffer's markdown like a normal markdown file. LazyVim's
  -- markdown extra already lazy-loads render-markdown on the `codecompanion`
  -- filetype but doesn't enable rendering for it.
  {
    "MeanderingProgrammer/render-markdown.nvim",
    opts = { file_types = { "markdown", "codecompanion" } },
  },
}
