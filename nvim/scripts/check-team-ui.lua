vim.opt.rtp:prepend(vim.fn.getcwd())
vim.opt.rtp:append(vim.fn.stdpath("data") .. "/lazy/snacks.nvim")
vim.o.columns = 160
vim.o.lines = 45
Snacks = require("snacks")
Snacks.setup({})

local state = vim.fn.tempname()
vim.fn.mkdir(state .. "/worker", "p")
vim.fn.writefile({ "## Worker", "", "Which color?" }, state .. "/worker/chat.md")
vim.env.NVIM_TEAM_HOME = state
local system = vim.system
local is_archived, deleted, mutation
local owner_backend = "codex"
vim.system = function(args, _, callback)
  if args[3] == "manage" then
    mutation = args[4]
    assert(args[6] == "supervisor")
    if mutation == "delete" then
      deleted = true
    else
      is_archived = mutation == "archive"
    end
    callback({ code = 0, stdout = "{}" })
    return
  end
  callback({
    code = 0,
    stdout = vim.json.encode(deleted and {} or {
      {
        id = "supervisor",
        role = "supervisor",
        name = "Color",
        backend = "claude",
        status = "supervising",
        brief = "Use blue",
        handoff = "Worker needs a color decision.",
        execution = "planning",
        checkpoint_at = os.time() - 120,
        owner = "successor",
        archived = is_archived,
      },
      {
        id = "successor",
        role = "chat",
        team_id = "supervisor",
        backend = owner_backend,
      },
      {
        id = "worker",
        parent = "supervisor",
        role = "worker",
        name = "Implement",
        backend = "codex",
        status = "needs supervisor",
        message = "Which color?",
      },
    }),
  })
end
local opened, hidden
package.loaded["util.claude"] = {
  hide = function()
    hidden = true
  end,
  open_session = function(record)
    opened = record.id
  end,
}
local team = require("util.agent_team")
team.toggle()
assert(hidden)
assert(vim.wait(2000, function()
  return vim.api.nvim_buf_line_count(0) == 6
end))
local function key(lhs)
  local mapping = vim.fn.maparg(lhs, "n", false, true)
  assert(mapping.callback, lhs)
  mapping.callback()
end
local setreg, copied = vim.fn.setreg, {}
vim.fn.setreg = function(register, value)
  copied[register] = value
end
key("j")
assert(vim.api.nvim_win_get_cursor(0)[1] == 5)
key("y")
assert(copied['"'] == "$supervise-takeover supervisor")
key("j")
assert(vim.api.nvim_win_get_cursor(0)[1] == 6)
key("y")
assert(copied['"'] == "$supervise-takeover supervisor")
key("l")
key("y")
assert(copied['"'] == "$supervise-takeover supervisor")
local lines = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
assert(lines:find("Which color?", 1, true))
key("h")
lines = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
assert(lines:find("Use blue", 1, true))
assert(lines:find("Worker needs a color decision.", 1, true))
assert(lines:find("$supervise-takeover supervisor", 1, true))
assert(lines:find("Last checkpoint: 2m ago", 1, true))
owner_backend = "claude"
assert(vim.wait(2000, function()
  key("y")
  return copied['"'] == "/supervise-takeover supervisor"
end, 100))
vim.fn.setreg = setreg
key("i")
assert(opened == "successor")
team.toggle()
key("h")
key("j")
key("a")
assert(vim.wait(1000, function()
  return mutation == "archive" and vim.api.nvim_buf_line_count(0) == 5
end))
key("A")
assert(vim.api.nvim_buf_line_count(0) == 6)
key("j")
key("a")
assert(vim.wait(1000, function()
  return mutation == "restore" and vim.api.nvim_buf_line_count(0) == 5
end))
key("A")
key("j")
local select = vim.ui.select
vim.ui.select = function(_, _, callback)
  callback("Cancel")
end
key("d")
assert(not deleted)
vim.ui.select = function(_, _, callback)
  callback("Delete team")
end
key("d")
assert(vim.wait(1000, function()
  return deleted and vim.api.nvim_buf_line_count(0) == 5
end))
vim.ui.select = select
key("q")
vim.system = system
vim.fn.delete(state, "rf")
print("Team hierarchy, transcript, parent navigation, supervisor attachment, and close checks passed")
vim.cmd("qa!")
