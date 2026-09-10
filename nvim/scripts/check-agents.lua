vim.opt.rtp:prepend(vim.fn.getcwd())
vim.opt.rtp:append(vim.fn.stdpath("data") .. "/lazy/snacks.nvim")
vim.o.columns = 140
vim.o.lines = 45
Snacks = require("snacks")
Snacks.setup({})

local Status = require("util.claude_status")
local command = Status.command("codex")
assert(command == Status.command("codex"))
local config = vim.system({ "zsh", "-c", command .. " features list" }, { text = true }):wait()
assert(config.code == 0, config.stderr)
local file = vim.fn.tempname()
local hook = vim
  .system({ "sh", "scripts/agent-status.sh", "busy" }, {
    env = { NVIM_AGENT_STATUS_FILE = file },
  })
  :wait()
assert(hook.code == 0 and vim.fn.readfile(file)[1] == "busy")
vim.fn.delete(file)

local session_file = vim.fn.tempname()
vim.fn.writefile({ vim.json.encode({ pid = 103, kind = "interactive", status = "waiting" }) }, session_file)
local system, glob, jobpid = vim.system, vim.fn.glob, vim.fn.jobpid
vim.system = function(_, _, callback)
  callback({ code = 0, stdout = "101 1\n102 101\n103 102\n" })
end
vim.fn.glob = function()
  return { session_file }
end
vim.fn.jobpid = function()
  return 101
end
local test_buffer = vim.api.nvim_create_buf(false, true)
local detected, complete
Status.poll({ { buf = test_buffer, cmd = "claude" } }, function(_, state)
  detected = state
end, function()
  complete = true
end)
assert(vim.wait(1000, function()
  return complete
end))
assert(detected == "waiting")
vim.system, vim.fn.glob, vim.fn.jobpid = system, glob, jobpid
vim.api.nvim_buf_delete(test_buffer, { force = true })
vim.fn.delete(session_file)

local termopen = vim.fn.termopen
vim.fn.termopen = function(_, opts)
  return termopen({ "cat" }, opts)
end
local status_callback
package.loaded["util.claude_status"] = {
  command = function(cmd)
    return cmd
  end,
  poll = function(_, callback, done)
    status_callback = callback
    done()
  end,
}
package.loaded["util.bifrost_budget"] = {
  refresh = function() end,
  text = function()
    return "Bifrost $865.97/$900 left (1M)"
  end,
}
local agent = require("util.claude")
local choice = 1
vim.ui.select = function(items, _, callback)
  callback(items[choice])
end
vim.ui.input = function(_, callback)
  callback("Fix auth")
end

agent.new()
local first = agent.open(1)
assert(first and first:win_valid())
local first_job = vim.b[first.buf].terminal_job_id
agent.sidebar()
local rail = vim.api.nvim_get_current_win()
local rail_buf = vim.api.nvim_get_current_buf()
assert(vim.bo[rail_buf].filetype == "agent_sidebar")
assert(vim.api.nvim_win_get_width(rail) == 24)
agent.rename()
local rows = vim.api.nvim_buf_get_lines(rail_buf, 0, -1, false)
assert(rows[1]:find("1 claude", 1, true) and rows[2]:find("Fix auth", 1, true))
choice = 3
agent.new()
local second = agent.open(2)
assert(second.opts.footer:find("Bifrost $865.97/$900", 1, true))
assert(not first:win_valid() and second:win_valid())
local second_meta = vim.b[second.buf].snacks_terminal
assert(second_meta.cmd:find("launch --backend codex-bf", 1, true))
assert(second_meta.env.NVIM_TEAM_SESSION)
assert(agent.open_session({ id = second_meta.env.NVIM_TEAM_SESSION, backend = "codex-bf" }) == second)
assert(vim.b[first.buf].terminal_job_id == first_job)
assert(vim.wait(1500, function()
  return status_callback ~= nil
end))
status_callback({ buf = first.buf }, "busy")
status_callback({ buf = first.buf }, "idle")
assert(vim.b[first.buf].claude_chat_unread)
agent.open(1)
assert(not vim.b[first.buf].claude_chat_unread)
assert(first:win_valid() and not second:win_valid())
agent.hide()
assert(not first:win_valid())
agent.toggle_last()
assert(first:win_valid() and vim.b[first.buf].terminal_job_id == first_job)
local escape
for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(first.buf, "t")) do
  if mapping.lhs == "<Esc>" then
    escape = mapping
  end
end
assert(escape and escape.expr == 0)
escape.callback()
assert(first:win_valid())
local chan_send = vim.api.nvim_chan_send
for _, mode in ipairs({ "n", "t" }) do
  local sent
  vim.api.nvim_chan_send = function(channel, data)
    assert(channel == first_job and data == string.char(27))
    sent = true
  end
  local send_escape = vim.fn.maparg("<C-g>", mode, false, true)
  assert(send_escape.buffer == 1 and send_escape.callback)
  send_escape.callback()
  assert(sent and first:win_valid())
end
vim.api.nvim_chan_send = chan_send
agent.sidebar()
local team_home = vim.fn.tempname()
local first_meta = vim.b[first.buf].snacks_terminal
vim.env.NVIM_TEAM_HOME = team_home
vim.fn.mkdir(team_home .. "/" .. first_meta.env.NVIM_TEAM_SESSION, "p")
local saved_chat = vim.json.encode({
  id = first_meta.env.NVIM_TEAM_SESSION,
  role = "chat",
  name = "Fix auth",
  backend = "claude",
})
vim.fn.writefile({ saved_chat }, team_home .. "/" .. first_meta.env.NVIM_TEAM_SESSION .. "/agent.json")
local action, archived_list
package.loaded["util.agent_team"] = {
  manage = function(value, record)
    action = value
    assert(record.id == first_meta.env.NVIM_TEAM_SESSION)
  end,
  toggle = function(show_archived)
    archived_list = show_archived
  end,
}
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.fn.maparg("a", "n", false, true).callback()
assert(action == "archive")
vim.fn.maparg("d", "n", false, true).callback()
assert(action == "delete")
vim.fn.maparg("A", "n", false, true).callback()
assert(archived_list == true)
vim.fn.delete(team_home, "rf")
local sidebar_escape = vim.fn.maparg("<Esc>", "n", false, true)
sidebar_escape.callback()
assert(first:win_valid())
vim.fn.jobstop(first_job)
vim.fn.jobstop(vim.b[second.buf].terminal_job_id)
print("Agent sidebar checks passed")
vim.cmd("qa!")
