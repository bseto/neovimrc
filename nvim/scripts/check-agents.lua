vim.opt.rtp:prepend(vim.fn.getcwd())
vim.opt.rtp:append(vim.fn.stdpath("data") .. "/lazy/snacks.nvim")
vim.o.columns = 140
vim.o.lines = 45
Snacks = require("snacks")
Snacks.setup({})

local Status = require("util.claude_status")
-- Status follows the record's current session ID, not the launch ID, so it survives /clear.
local status_home = vim.fn.tempname()
vim.env.NVIM_TEAM_HOME = status_home
vim.fn.mkdir(status_home .. "/launch-id", "p")
vim.fn.writefile(
  { vim.json.encode({ id = "launch-id", backend = "claude", session_id = "after-clear" }) },
  status_home .. "/launch-id/agent.json"
)
local session_file = vim.fn.tempname()
vim.fn.writefile({ vim.json.encode({ sessionId = "after-clear", kind = "interactive", status = "waiting" }) }, session_file)
local glob = vim.fn.glob
vim.fn.glob = function()
  return { session_file }
end
local test_buffer = vim.api.nvim_create_buf(false, true)
vim.b[test_buffer].snacks_terminal = { env = { NVIM_TEAM_SESSION = "launch-id" } }
local detected
Status.poll({ { buf = test_buffer, cmd = "claude" } }, function(_, state)
  detected = state
end, function() end)
assert(detected == "waiting")
vim.fn.glob = glob
vim.api.nvim_buf_delete(test_buffer, { force = true })
vim.fn.delete(session_file)
vim.fn.delete(status_home, "rf")
vim.env.NVIM_TEAM_HOME = nil

local termopen = vim.fn.termopen
vim.fn.termopen = function(_, opts)
  return termopen({ "cat" }, opts)
end
local status_callback
package.loaded["util.claude_status"] = {
  home = function()
    return vim.env.NVIM_TEAM_HOME
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

local team_home = vim.fn.tempname()
vim.env.NVIM_TEAM_HOME = team_home
agent.new()
local first = agent.open(1)
assert(first and first:win_valid())
local first_job = vim.b[first.buf].terminal_job_id
local first_session = vim.b[first.buf].snacks_terminal.env.NVIM_TEAM_SESSION
vim.fn.mkdir(team_home .. "/" .. first_session, "p")
agent.sidebar()
local rail = vim.api.nvim_get_current_win()
local rail_buf = vim.api.nvim_get_current_buf()
assert(vim.bo[rail_buf].filetype == "agent_sidebar")
assert(vim.api.nvim_win_get_width(rail) == 24)
agent.rename()
assert(vim.fn.readfile(team_home .. "/" .. first_session .. "/name")[1] == "Fix auth")
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
assert(vim.b[first.buf].terminal_job_id == first_job)
assert(vim.wait(1500, function()
  return status_callback ~= nil
end))
status_callback({ buf = first.buf }, "busy")
status_callback({ buf = first.buf }, "idle")
assert(vim.b[first.buf].claude_chat_unread)
status_callback({ buf = second.buf }, "waiting")
local waiting, unread = agent.attention()
assert(#waiting == 1 and waiting[1].buf == second.buf and #unread == 1 and unread[1].buf == first.buf)
local lualine = { sections = { lualine_x = {} } }
require("plugins.chat-attention").opts(nil, lualine)
assert(lualine.sections.lualine_x[1][1]() == "!1 *1")
agent.next_attention() -- in chat 2 (waiting), so it skips to chat 1 (unread)
assert(first:win_valid() and not vim.b[first.buf].claude_chat_unread)
agent.next_attention()
assert(second:win_valid())
status_callback({ buf = second.buf }, "idle")
assert(lualine.sections.lualine_x[1][1]() == "")
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
local fake_id = "11111111-2222-3333-4444-555555555555"
vim.fn.mkdir(team_home .. "/" .. fake_id, "p")
vim.fn.writefile({ "Reattached" }, team_home .. "/" .. fake_id .. "/name")
local picked_items
local pick_system, pick_select = vim.system, vim.ui.select
vim.system = function(cmd, _, callback)
  assert(cmd[3] == "running")
  callback({
    code = 0,
    stdout = vim.json.encode({
      { id = first_session, backend = "claude", name = "x", attached = 1 },
      { id = fake_id, backend = "claude", name = "claude chat", role = "chat", cwd = "/work/app", created = os.time(), attached = 0 },
      { id = "unnamed-id", backend = "claude", name = "claude chat", role = "chat", cwd = "/work/infra", created = os.time() - 3 * 3600, attached = 0 },
    }),
  })
end
vim.ui.select = function(items, _, callback)
  picked_items = items
  callback(vim.iter(items):find(function(item)
    return item.id == fake_id
  end))
end
agent.pick()
local reopened
assert(vim.wait(1000, function()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local meta = vim.b[buf].snacks_terminal
    if type(meta) == "table" and meta.env and meta.env.NVIM_TEAM_SESSION == fake_id then
      reopened = buf
      return true
    end
  end
end))
vim.system, vim.ui.select = pick_system, pick_select
assert(not vim.iter(picked_items):any(function(item)
  return item.id == first_session
end))
assert(vim.iter(picked_items):any(function(item)
  return item.label == "↺ claude · Reattached · app"
end))
assert(vim.iter(picked_items):any(function(item)
  return item.label == "↺ claude · infra · 3h ago"
end))
assert(vim.b[reopened].snacks_terminal.cmd:find("launch --backend claude", 1, true))
assert(vim.b[reopened].claude_chat_name == "Reattached")
agent.hide()
agent.open(1)
agent.sidebar()
local first_meta = vim.b[first.buf].snacks_terminal
local saved_chat = vim.json.encode({
  id = first_meta.env.NVIM_TEAM_SESSION,
  role = "chat",
  name = "Fix auth",
  backend = "claude",
})
vim.fn.writefile({ saved_chat }, team_home .. "/" .. first_meta.env.NVIM_TEAM_SESSION .. "/agent.json")
local ran
local system, ui_select = vim.system, vim.ui.select
vim.ui.select = function(_, _, choose)
  choose("Delete chat")
end
vim.system = function(cmd)
  ran = cmd
end
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.fn.maparg("d", "n", false, true).callback()
assert(ran[4] == "delete" and ran[6] == first_meta.env.NVIM_TEAM_SESSION)
vim.system, vim.ui.select = system, ui_select
assert(vim.fn.maparg("a", "n", false, true).callback == nil)
vim.fn.delete(team_home, "rf")
local sidebar_escape = vim.fn.maparg("<Esc>", "n", false, true)
sidebar_escape.callback()
assert(first:win_valid())
agent.hide()
for _, n in ipairs({ 1, 2, 3 }) do
  status_callback({ buf = n == 3 and reopened or n == 1 and first.buf or second.buf }, "waiting")
end
for _, expected in ipairs({ 1, 2, 3, 1 }) do
  agent.next_attention()
  assert(vim.b[vim.api.nvim_get_current_buf()].snacks_terminal.id == expected)
end
for _, buf in ipairs({ first.buf, second.buf, reopened }) do
  status_callback({ buf = buf }, "idle")
end
agent.open(1)
agent.toggle_layout()
assert(first:win_valid() and vim.api.nvim_win_get_config(first.win).relative == "")
assert(vim.api.nvim_win_get_width(first.win) == math.floor(vim.o.columns * 0.4))
assert(vim.wo[first.win].winbar:find("Fix auth", 1, true))
assert(vim.b[first.buf].terminal_job_id == first_job)
local function rail_visible()
  return vim.iter(vim.api.nvim_list_wins()):any(function(win)
    return vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "agent_sidebar"
  end)
end
assert(not rail_visible())
agent.toggle_sidebar()
assert(rail_visible() and vim.bo.filetype == "agent_sidebar")
agent.toggle_sidebar()
assert(not rail_visible())
agent.open(2)
assert(second:win_valid() and not first:win_valid())
assert(vim.api.nvim_win_get_width(second.win) == math.floor(vim.o.columns * 0.4))
vim.o.columns = 100
vim.api.nvim_exec_autocmds("VimResized", {})
assert(vim.api.nvim_win_get_width(second.win) == 40)
vim.cmd.stopinsert()
vim.fn.maparg("<C-h>", "n", false, true).callback()
assert(vim.api.nvim_get_current_win() ~= second.win)
agent.toggle_layout()
assert(second:win_valid() and vim.api.nvim_win_get_config(second.win).relative == "editor")
assert(vim.wo[second.win].winbar == "" and rail_visible())
-- Open chats are saved per repo; restore reopens only the ones not already open.
local repo = vim.fn.tempname()
vim.fn.mkdir(repo, "p")
repo = vim.uv.fs_realpath(repo)
vim.fn.mkdir(team_home .. "/" .. first_session, "p")
vim.fn.writefile({ vim.json.encode({ id = first_session, backend = "claude", cwd = repo }) },
  team_home .. "/" .. first_session .. "/agent.json")
agent.refresh_all()
local saved = vim.json.decode(vim.fn.readfile(team_home .. "/open-chats.json")[1])
assert(vim.deep_equal(saved[repo], { first_session }))
local resumed_id = "11111111-1111-1111-1111-111111111111"
vim.fn.mkdir(team_home .. "/" .. resumed_id, "p")
vim.fn.writefile({ vim.json.encode({ id = resumed_id, backend = "claude", cwd = repo }) },
  team_home .. "/" .. resumed_id .. "/agent.json")
saved[repo] = { first_session, resumed_id }
vim.fn.writefile({ vim.json.encode(saved) }, team_home .. "/open-chats.json")
vim.cmd.stopinsert()
vim.cmd.enew()
vim.cmd.cd(repo)
local before = #Snacks.terminal.list()
agent.restore()
local resumed = vim.iter(Snacks.terminal.list()):find(function(t)
  return vim.b[t.buf].snacks_terminal.env.NVIM_TEAM_SESSION == resumed_id
end)
assert(resumed and #Snacks.terminal.list() == before + 1)
vim.fn.jobstop(vim.b[resumed.buf].terminal_job_id)
vim.fn.jobstop(first_job)
vim.fn.jobstop(vim.b[reopened].terminal_job_id)
vim.fn.jobstop(vim.b[second.buf].terminal_job_id)
print("Agent sidebar checks passed")
vim.cmd("qa!")
