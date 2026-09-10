-- Multiple AI-agent chats (Claude Code, Codex CLI) via snacks.nvim floating
-- terminals.
--
local M = {}
local Status = require("util.claude_status")
local sidebar
local active
local terminals = {}
local namespace = vim.api.nvim_create_namespace("agent_sidebar")
local states = {
  busy = { "●", "Working", "DiagnosticInfo" },
  waiting = { "!", "Needs approval", "DiagnosticWarn" },
  idle = { "○", "Ready for input", "DiagnosticOk" },
  exited = { "×", "Exited", "DiagnosticError" },
  unknown = { "?", "Status unknown", "Comment" },
}

-- Launch command variants. `claude`, `claude-bf` and `codex-bf` are zsh
-- functions in ~/.zshenv (the `-bf` ones route through StackAdapt's Bifrost
-- gateway using the keychain virtual key), and snacks runs the command through
-- a non-interactive zsh which sources ~/.zshenv, so all of them resolve fine.
-- The claude flags mirror the old greggh/claude-code.nvim setup. Codex's
-- `--approve-for-me` is its equivalent of Claude's auto mode (approvals go through
-- automatic review inside a workspace-write sandbox); its Bifrost provider and
-- model live in ~/.codex/config.toml, so no other flags are needed.
--
local VARIANTS = {
  { label = "claude", tag = "claude", cmd = "claude --enable-auto-mode" },
  { label = "claude-bf (Bifrost)", tag = "claude-bf", cmd = "claude-bf --enable-auto-mode" },
  { label = "codex-bf (Bifrost)", tag = "codex", backend = "codex-bf", cmd = "codex-bf --approve-for-me" },
}
for _, variant in ipairs(VARIANTS) do
  variant.backend = variant.backend or variant.tag
  variant.launch = "python3 "
    .. vim.fn.shellescape(vim.fn.stdpath("config") .. "/scripts/agent-team.py")
    .. " launch --backend "
    .. variant.backend
end

--- The variant whose launch command is `cmd`, or nil if it isn't one of ours.
--- @param cmd any
--- @return { label: string, tag: string, cmd: string }?
local function variant_for(cmd)
  for _, v in ipairs(VARIANTS) do
    if cmd == v.cmd or cmd == v.launch then
      return v
    end
  end
end

--- True if `cmd` is one of our chat launch commands (any variant).
--- @param cmd any
--- @return boolean
local function is_chat_cmd(cmd)
  return variant_for(cmd) ~= nil
end

-- Number of the chat most recently opened/focused, used by toggle_last().
M.last = nil

--- Resolve the git root (falls back to cwd) so chats open at the project root,
--- matching the old `git.use_git_root = true` behaviour.
--- @return string
local function root()
  return vim.fs.root(0, ".git") or vim.uv.cwd()
end

--- @param buf integer
--- @param count integer?
--- @return string
local function display(buf, count)
  local name = vim.b[buf] and vim.b[buf].claude_chat_name
  if type(name) == "string" and name ~= "" then
    return name
  end
  return "Chat " .. tostring(count or "?")
end

--- List currently-open chats, sorted by chat number.
--- Scans every buffer for the `b:snacks_terminal` marker snacks sets on
--- terminal buffers, then keeps the ones running any of our launch commands.
--- @return { count: integer, buf: integer, cmd: string }[]
local function team_record(meta)
  local id = meta.env and meta.env.NVIM_TEAM_SESSION
  if not id then
    return
  end
  local directory = vim.env.NVIM_TEAM_HOME or (vim.fn.expand("~") .. "/.local/state/nvim/agent-teams")
  local file = io.open(directory .. "/" .. id .. "/agent.json", "r")
  if not file then
    return
  end
  local ok, record = pcall(vim.json.decode, file:read("*a"))
  file:close()
  if ok and record.team_id then
    return team_record({ env = { NVIM_TEAM_SESSION = record.team_id } })
  end
  return ok and record or nil
end

local function chats(include_archived)
  local out = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      local ok, meta = pcall(function()
        return vim.b[buf].snacks_terminal
      end)
      if ok and type(meta) == "table" and is_chat_cmd(meta.cmd) then
        local record = team_record(meta)
        if include_archived or not (record and record.archived) then
          out[#out + 1] = { count = meta.id, buf = buf, cmd = meta.cmd }
        end
      end
    end
  end
  table.sort(out, function(a, b)
    return (a.count or 0) < (b.count or 0)
  end)
  return out
end

local function dimensions()
  local width = math.floor(vim.o.columns * 0.9)
  local rail = math.min(26, math.max(16, math.floor(width * 0.25)))
  return width, rail, math.floor((vim.o.columns - width) / 2)
end

local function selected()
  if sidebar and sidebar:win_valid() and vim.api.nvim_get_current_win() == sidebar.win then
    return chats()[math.floor((vim.api.nvim_win_get_cursor(sidebar.win)[1] - 1) / 3) + 1]
  end
end

local function render()
  if not (sidebar and sidebar:win_valid()) then
    return
  end
  local lines, highlights = {}, {}
  for _, chat in ipairs(chats()) do
    local state = states[vim.b[chat.buf].claude_chat_status] or states.unknown
    local unread = vim.b[chat.buf].claude_chat_unread and " *" or ""
    local marker = active and active.buf == chat.buf and ">" or " "
    lines[#lines + 1] = ("%s %d %s %s%s"):format(marker, chat.count, variant_for(chat.cmd).tag, state[1], unread)
    highlights[#highlights + 1] = { #lines - 1, marker == ">" and "PmenuSel" or state[3] }
    lines[#lines + 1] = "  " .. display(chat.buf, chat.count):gsub("[\r\n]", " ")
    lines[#lines + 1] = ""
  end
  vim.bo[sidebar.buf].modifiable = true
  vim.api.nvim_buf_set_lines(sidebar.buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(sidebar.buf, namespace, 0, -1)
  for _, highlight in ipairs(highlights) do
    vim.api.nvim_buf_set_extmark(sidebar.buf, namespace, highlight[1], 0, {
      line_hl_group = highlight[2],
    })
  end
  vim.bo[sidebar.buf].modifiable = false
end

function M.hide()
  if active and active:win_valid() then
    active:hide()
  end
  if sidebar then
    sidebar:hide()
  end
end

function M.sidebar()
  if sidebar and sidebar:win_valid() then
    vim.cmd.stopinsert()
    sidebar:focus()
  end
end

local function show_sidebar(term)
  if active and active ~= term and active:win_valid() then
    active:hide()
  end
  active = term
  M.last = vim.b[term.buf].snacks_terminal.id
  vim.b[term.buf].claude_chat_unread = false
  if not sidebar then
    sidebar = Snacks.win({
      show = false,
      enter = false,
      position = "float",
      width = function()
        local _, rail = dimensions()
        return rail - 2
      end,
      col = function()
        local _, _, left = dimensions()
        return left
      end,
      height = 0.9,
      border = "rounded",
      title = " Agents ",
      footer = " a:arc d:del A:list ",
      backdrop = false,
      wo = { wrap = false, cursorline = true, scrolloff = 0 },
      bo = { filetype = "agent_sidebar" },
      keys = {
        q = M.hide,
        ["<Esc>"] = function() end,
        ["<CR>"] = function()
          local chat = selected()
          if chat then
            M.open(chat.count)
          end
        end,
        j = function(self)
          local row = vim.api.nvim_win_get_cursor(self.win)[1]
          vim.api.nvim_win_set_cursor(self.win, { math.min(row + 3, math.max(1, #chats() * 3 - 2)), 0 })
        end,
        k = function(self)
          local row = vim.api.nvim_win_get_cursor(self.win)[1]
          vim.api.nvim_win_set_cursor(self.win, { math.max(1, row - 3), 0 })
        end,
        r = function()
          M.rename()
        end,
        n = function()
          M.new()
        end,
        a = function()
          M.manage_selected("archive")
        end,
        d = function()
          M.manage_selected("delete")
        end,
        A = function()
          require("util.agent_team").toggle(true)
        end,
        ["?"] = function()
          vim.notify(
            "Enter: open · r: rename · n: new\na: archive · d: delete · A: archived chats/teams\nArchive hides without stopping work. In archives, a restores and i opens the chat."
          )
        end,
        ["<C-l>"] = function()
          if active and active:win_valid() then
            active:focus()
          end
        end,
      },
    })
  end
  sidebar.opts.zindex = term.opts.zindex
  sidebar:show()
  render()
end

--- @param win snacks.win
local function refresh(win)
  if not (win and win.win_valid and win:win_valid()) then
    return
  end
  local state = states[vim.b[win.buf].claude_chat_status] or states.unknown
  win.opts.title = " " .. state[2] .. " "
  win.opts.footer = ""
  local meta = vim.b[win.buf].snacks_terminal
  if meta and type(meta.cmd) == "string" and meta.cmd:find("codex-bf", 1, true) then
    local budget = require("util.bifrost_budget")
    budget.refresh()
    win.opts.footer = " " .. budget.text() .. " "
  end
  win:update()
end

function M.refresh_all()
  for _, t in ipairs(Snacks.terminal.list()) do
    local meta = vim.b[t.buf] and vim.b[t.buf].snacks_terminal
    if type(meta) == "table" and is_chat_cmd(meta.cmd) then
      refresh(t)
    end
  end
  render()
end

--- @param count integer
--- @return snacks.terminal.Opts
local function term_opts(count, session)
  return {
    count = count,
    cwd = root(),
    env = { NVIM_TEAM_SESSION = session },
    win = {
      position = "float",
      width = function()
        local width, rail = dimensions()
        return width - rail - 2
      end,
      col = function()
        local _, rail, left = dimensions()
        return left + rail
      end,
      height = 0.9,
      border = "rounded",
      keys = {
        term_normal = {
          "<Esc>",
          function()
            vim.cmd.stopinsert()
          end,
          mode = "t",
          expr = false,
          desc = "Terminal Normal mode",
        },
        ["<Esc>"] = { "<Esc>", function() end, mode = "n" },
        send_escape = {
          "<C-g>",
          function(self)
            vim.api.nvim_chan_send(vim.b[self.buf].terminal_job_id, "\27")
          end,
          mode = { "n", "t" },
          desc = "Send Escape to agent",
        },
        ["<C-h>"] = { "<C-h>", M.sidebar, mode = "n", desc = "Focus agents" },
        ["<leader>ct"] = {
          "<leader>ct",
          function()
            require("util.agent_team").toggle()
          end,
          mode = "n",
          desc = "Team view",
        },
        q = M.hide,
      },
      on_win = function(self)
        show_sidebar(self)
        refresh(self)
      end,
      on_close = function(self)
        if active == self and sidebar then
          sidebar:hide()
        end
      end,
    },
  }
end

--- Lowest chat number not already in use.
--- @param list { count: integer }[]
--- @return integer
local function next_count(list)
  local used = {}
  for _, c in ipairs(list) do
    used[c.count] = true
  end
  local n = 1
  while used[n] do
    n = n + 1
  end
  return n
end

--- Spawn a new chat in the next free slot running `cmd`. Internal; callers go
--- through M.new() (which picks the variant first).
--- @param cmd string
local function spawn(cmd, session)
  local n = next_count(chats(true))
  M.last = n
  session = session or vim.trim(vim.fn.system("uuidgen")):lower()
  local term = Snacks.terminal.open(variant_for(cmd).launch, term_opts(n, session))
  if term then
    terminals[n] = term
    term:on("BufWipeout", function()
      terminals[n] = nil
      vim.schedule(M.refresh_all)
    end, { buf = true })
    term:on("TermClose", function()
      if term.buf and vim.api.nvim_buf_is_valid(term.buf) then
        vim.b[term.buf].claude_chat_exited = true
      end
      vim.schedule(M.refresh_all)
    end, { buf = true })
  end
  vim.schedule(M.refresh_all)
  return term
end

function M.manage_selected(action)
  local chat = selected()
  if not chat then
    return
  end
  local record = team_record(vim.b[chat.buf].snacks_terminal)
  if not record then
    vim.notify("This chat has no saved session record. Reopen it with the current launcher first.", vim.log.levels.WARN)
    return
  end
  record.name = display(chat.buf, chat.count)
  require("util.agent_team").manage(action, record)
end

function M.after_manage(id, action, chat_ids)
  for _, term in ipairs(Snacks.terminal.list()) do
    local meta = vim.b[term.buf].snacks_terminal
    local record = meta and team_record(meta)
    local session = meta and meta.env and meta.env.NVIM_TEAM_SESSION
    if session and (session == id or (record and record.id == id) or vim.tbl_contains(chat_ids or {}, session)) then
      if action == "archive" or action == "delete" then
        if active == term then
          M.hide()
        else
          term:hide()
        end
      end
      if action == "delete" and vim.api.nvim_buf_is_valid(term.buf) then
        vim.api.nvim_buf_delete(term.buf, { force = true })
      end
    end
  end
  M.refresh_all()
end

-- Reattach the durable supervisor after restarting Neovim.
function M.open_session(record)
  for _, term in ipairs(Snacks.terminal.list()) do
    local meta = vim.b[term.buf].snacks_terminal
    if meta and meta.env and meta.env.NVIM_TEAM_SESSION == record.id then
      if not vim.b[term.buf].claude_chat_exited then
        return M.open(meta.id)
      end
    end
  end
  for _, variant in ipairs(VARIANTS) do
    if variant.backend == record.backend then
      return spawn(variant.cmd, record.id)
    end
  end
end

--- Open a brand-new chat, prompting for the launch variant (claude,
--- claude-bf, codex-bf) first.
function M.new()
  -- Single variant collapses to no prompt; otherwise ask which to launch.
  if #VARIANTS == 1 then
    return spawn(VARIANTS[1].cmd)
  end
  vim.ui.select(VARIANTS, {
    prompt = "New chat",
    format_item = function(v)
      return v.label
    end,
  }, function(choice)
    if choice then
      spawn(choice.cmd)
    end
  end)
end

--- The launch command for the open chat numbered `count`, or nil if no such
--- chat is open. Used to reattach to the right variant instead of guessing.
--- @param count integer
--- @return string?
local function cmd_for(count)
  for _, c in ipairs(chats()) do
    if c.count == count then
      return c.cmd
    end
  end
end

--- Show and focus an existing chat by number.
--- @param count integer
function M.open(count)
  M.last = count
  for _, term in ipairs(Snacks.terminal.list()) do
    local meta = vim.b[term.buf].snacks_terminal
    if meta and is_chat_cmd(meta.cmd) and meta.id == count then
      term:show():focus()
      vim.b[term.buf].claude_chat_unread = false
      render()
      return term
    end
  end
end

--- Jump to chat number `n` if it's open; otherwise do nothing (with a hint).
--- Backs the `<leader>c<N>` keymaps.
--- @param n integer
function M.select(n)
  for _, c in ipairs(chats()) do
    if c.count == n then
      return M.open(n)
    end
  end
  vim.notify("No chat " .. n, vim.log.levels.WARN)
end

--- Toggle the most-recently-used chat, creating a new one if none exist.
function M.toggle_last()
  local list = chats()
  if #list == 0 then
    return M.new()
  end
  if active and active:win_valid() then
    return M.hide()
  end
  local count = cmd_for(M.last) and M.last or list[1].count
  return M.open(count)
end

--- Pick an open chat (by name) or create a new one via vim.ui.select.
function M.pick()
  local list = chats()
  local items = {}
  for _, c in ipairs(list) do
    items[#items + 1] = {
      count = c.count,
      label = ("%d. %s · %s"):format(c.count, variant_for(c.cmd).tag, display(c.buf, c.count)),
    }
  end
  items[#items + 1] = { count = nil, label = "＋ New chat" }

  vim.ui.select(items, {
    prompt = "Chats",
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if not choice then
      return
    end
    if choice.count then
      M.open(choice.count)
    else
      M.new()
    end
  end)
end

--- Rename the current chat (or the last-used one if not focused in a chat).
function M.rename()
  local chat = selected()
  local buf = chat and chat.buf or vim.api.nvim_get_current_buf()
  local meta = vim.b[buf] and vim.b[buf].snacks_terminal
  if not (type(meta) == "table" and is_chat_cmd(meta.cmd)) then
    -- Not focused in a chat: fall back to the last-used / first open chat.
    local list = chats()
    buf = nil
    for _, c in ipairs(list) do
      if c.count == M.last then
        buf = c.buf
      end
    end
    buf = buf or (list[1] and list[1].buf)
    if not buf then
      vim.notify("No chat to rename", vim.log.levels.WARN)
      return
    end
  end

  vim.ui.input({
    prompt = "Chat name (empty to reset): ",
    default = vim.b[buf].claude_chat_name or "",
  }, function(input)
    if input == nil or not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    vim.b[buf].claude_chat_name = (input ~= "" and input) or nil
    M.refresh_all()
  end)
end

local timer = vim.uv.new_timer()
timer:start(
  0,
  1000,
  vim.schedule_wrap(function()
    local list = chats()
    if #list == 0 then
      return
    end
    Status.poll(list, function(chat, state)
      local previous = vim.b[chat.buf].claude_chat_status
      local focused = vim.api.nvim_get_current_buf() == chat.buf
      if previous == "busy" and state == "idle" and not focused then
        vim.b[chat.buf].claude_chat_unread = true
      elseif focused then
        vim.b[chat.buf].claude_chat_unread = false
      end
      vim.b[chat.buf].claude_chat_status = state
    end, M.refresh_all)
  end)
)
vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    timer:stop()
    timer:close()
  end,
})

return M
