-- AI-agent chats (Claude Code, Codex CLI) run as snacks.nvim floating
-- terminals with support for multiple independent chats. Logic lives in
-- lua/util/claude.lua; <leader>cn asks which agent variant to launch.
--
-- Keymaps (chosen to preserve muscle memory from the old greggh setup):
--   <leader>cO   recover the chats this repo had open last time (resumes after a reboot)
--   <leader>cp   pick/open a chat (lists open chats by name + "New chat")
--   <leader>cn   open a new chat immediately
--   <leader>cR   rename the current (or last-used) chat
--   <leader>c1-9 jump straight to chat 1..9
--   <leader>c0   open the next chat needing you (waiting, then unread)
--   <leader>cL   switch chats between fullscreen and a right-hand panel
--   <leader>cb   show/hide the agent list
--   <leader>ck   open the commander chat (reads and replies to your other chats)
--   <leader>cg   show/hide the grid of all chats (also <C-.>, works inside a chat)
--   <C-,>        toggle the last-used chat (creates Chat 1 if none exist)
local keys = {
  {
    "<leader>cO",
    function()
      require("util.claude").restore()
    end,
    desc = "Chat: recover this repo's chats",
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
    "<leader>ck",
    function()
      require("util.claude").commander()
    end,
    desc = "Chat: commander",
  },
  {
    "<leader>cR",
    function()
      require("util.claude").rename()
    end,
    desc = "Chat: rename chat",
  },
  {
    "<leader>c0",
    function()
      require("util.claude").next_attention()
    end,
    desc = "Chat: next chat needing you",
  },
  {
    "<leader>cL",
    function()
      require("util.claude").toggle_layout()
    end,
    desc = "Chat: fullscreen / right panel",
  },
  {
    "<leader>cb",
    function()
      require("util.claude").toggle_sidebar()
    end,
    desc = "Chat: show/hide agent list",
  },
  {
    "<leader>cg",
    function()
      require("util.claude").grid()
    end,
    desc = "Chat: grid of all chats",
  },
  {
    "<C-.>",
    function()
      require("util.claude").grid()
    end,
    desc = "Chat: grid of all chats",
    mode = { "n", "t" },
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
