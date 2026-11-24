-- Chat status for the sidebar. Agents run under a detached tmux server, so
-- they are never descendants of the Neovim terminal; status is looked up by
-- the session ID saved in the chat's team record instead.
local M = {}

local function read(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end
  local content = file:read("*a")
  file:close()
  return content
end

function M.home()
  return vim.env.NVIM_TEAM_HOME or (vim.fn.expand("~") .. "/.local/state/nvim/agent-teams")
end

function M.poll(chats, callback, done)
  local by_id = {}
  for _, directory in ipairs({ vim.env.CLAUDE_CONFIG_DIR or vim.fn.expand("~/.claude"), vim.fn.expand("~/.claude-personal") }) do
    for _, path in ipairs(vim.fn.glob(directory .. "/sessions/*.json", false, true)) do
      local ok, session = pcall(vim.json.decode, read(path) or "")
      if ok and type(session) == "table" and session.kind == "interactive" then
        by_id[session.sessionId or vim.fn.fnamemodify(path, ":t:r")] = session
      end
    end
  end
  local home = M.home()
  for _, chat in ipairs(chats) do
    if vim.api.nvim_buf_is_valid(chat.buf) then
      local state, active = "unknown", nil
      local meta = vim.b[chat.buf].snacks_terminal
      local id = meta and meta.env and meta.env.NVIM_TEAM_SESSION
      if id then
        local ok, record = pcall(vim.json.decode, read(home .. "/" .. id .. "/agent.json") or "")
        record = ok and type(record) == "table" and record or {}
        if (record.backend or ""):match("^codex") then
          state = record.chat_status or "unknown"
          active = tonumber(record.chat_status_at)
        else
          local session = by_id[record.session_id or id]
          state = session and session.status or "unknown"
          active = session and tonumber(session.statusUpdatedAt) and session.statusUpdatedAt / 1000
        end
      end
      if vim.b[chat.buf].claude_chat_exited then
        state = "exited"
      end
      -- `active`: when the chat's state last changed, in epoch seconds.
      callback(chat, state, active)
    end
  end
  done()
end

return M
