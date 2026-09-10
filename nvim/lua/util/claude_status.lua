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

function M.command(cmd)
  if not cmd:match("^codex") then
    return cmd
  end
  local script = vim.fn.stdpath("config") .. "/scripts/agent-status.sh"
  local events = {
    SessionStart = "idle",
    UserPromptSubmit = "busy",
    PermissionRequest = "waiting",
    PostToolUse = "busy",
    Stop = "idle",
    Interrupt = "idle",
    SessionEnd = "exited",
  }
  local names = vim.tbl_keys(events)
  table.sort(names)
  for _, event in ipairs(names) do
    local command = "sh " .. vim.fn.shellescape(script) .. " " .. events[event]
    local config = ('hooks.%s=[{hooks=[{type="command",command=%s}]}]'):format(event, vim.json.encode(command))
    cmd = cmd .. " -c " .. vim.fn.shellescape(config)
  end
  return cmd
end

function M.poll(chats, callback, done)
  local sessions = {}
  local by_id = {}
  local directories = {
    vim.env.CLAUDE_CONFIG_DIR or vim.fn.expand("~/.claude"),
    vim.fn.expand("~/.claude-personal"),
  }
  for _, directory in ipairs(directories) do
    for _, path in ipairs(vim.fn.glob(directory .. "/sessions/*.json", false, true)) do
      local ok, session = pcall(vim.json.decode, read(path) or "")
      if ok and type(session) == "table" and session.kind == "interactive" and type(session.pid) == "number" then
        sessions[session.pid] = session
        by_id[session.sessionId or session.session_id or vim.fn.fnamemodify(path, ":t:r")] = session
      end
    end
  end
  vim.system({ "ps", "-axo", "pid=,ppid=" }, { text = true }, function(result)
    vim.schedule(function()
      local parents = {}
      for pid, parent in (result.stdout or ""):gmatch("(%d+)%s+(%d+)") do
        parents[tonumber(pid)] = tonumber(parent)
      end
      for _, chat in ipairs(chats) do
        if vim.api.nvim_buf_is_valid(chat.buf) then
          local state = "unknown"
          local job = vim.b[chat.buf].terminal_job_id
          local ok, terminal_pid = pcall(vim.fn.jobpid, job or -1)
          if ok and result.code == 0 then
            for pid, session in pairs(sessions) do
              local ancestor = pid
              local visited = {}
              while parents[ancestor] and not visited[ancestor] do
                if ancestor == terminal_pid then
                  state = session.status or "unknown"
                  break
                end
                visited[ancestor] = true
                ancestor = parents[ancestor]
              end
              if state ~= "unknown" then
                break
              end
            end
          end
          local meta = vim.b[chat.buf].snacks_terminal
          local team_session = meta and meta.env and meta.env.NVIM_TEAM_SESSION
          if team_session and by_id[team_session] then
            state = by_id[team_session].status or "unknown"
          end
          if team_session then
            local directory = vim.env.NVIM_TEAM_HOME or (vim.fn.expand("~") .. "/.local/state/nvim/agent-teams")
            local ok_record, record =
              pcall(vim.json.decode, read(directory .. "/" .. team_session .. "/agent.json") or "")
            if ok_record and type(record) == "table" and record.backend:match("^codex") then
              state = record.chat_status or "unknown"
            end
          end
          local path = meta and meta.env and meta.env.NVIM_AGENT_STATUS_FILE
          if chat.cmd:match("^codex") and path then
            state = vim.trim(read(path) or "unknown")
          end
          if vim.b[chat.buf].claude_chat_exited then
            state = "exited"
          end
          callback(chat, state)
        end
      end
      done()
    end)
  end)
end

return M
