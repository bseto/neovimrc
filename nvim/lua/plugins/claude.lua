-- AI-agent chats (Claude Code, Codex CLI) run as snacks.nvim floating
-- terminals with support for multiple independent chats. Logic lives in
-- lua/util/claude.lua; <leader>cn asks which agent variant to launch.
--
-- Keymaps (chosen to preserve muscle memory from the old greggh setup):
--   <leader>cp   pick/open a chat (lists open chats by name + "New chat")
--   <leader>cn   open a new chat immediately
--   <leader>cR   rename the current (or last-used) chat
--   <leader>ct   inspect persistent supervisor teams
--   <leader>c1-9 jump straight to chat 1..9
--   <C-,>        toggle the last-used chat (creates Chat 1 if none exist)
local keys = {
  {
    "<leader>ct",
    function()
      require("util.agent_team").toggle()
    end,
    desc = "Chat: team view",
  },
  {
    "<leader>cp",
    function()
      require("util.claude").pick()
    end,
    desc = "Chat: pick/open chat",
  },
  {
    "<leader>cn",
    function()
      require("util.claude").new()
    end,
    desc = "Chat: new chat",
  },
  {
    "<leader>cR",
    function()
      require("util.claude").rename()
    end,
    desc = "Chat: rename chat",
  },
  {
    "<C-,>",
    function()
      require("util.claude").toggle_last()
    end,
    desc = "Chat: toggle last chat",
    mode = { "n", "t" },
  },
}

-- <leader>c1 .. <leader>c9 jump to the chat with that number.
for i = 1, 9 do
  keys[#keys + 1] = {
    "<leader>c" .. i,
    function()
      require("util.claude").select(i)
    end,
    desc = "Chat: go to chat " .. i,
  }
end

return {
  "folke/snacks.nvim",
  keys = keys,
}
