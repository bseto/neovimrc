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
local SCRIPT = vim.fn.stdpath("config") .. "/scripts/agent-team.py"
for _, variant in ipairs(VARIANTS) do
  variant.backend = variant.backend or variant.tag
  variant.launch = "python3 "
    .. vim.fn.shellescape(SCRIPT)
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
local layout = "float" -- or "right"; lasts for this Neovim session

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

local function name_file(session)
  return Status.home() .. "/" .. session .. "/name"
end

--- The name saved by M.rename for this agent session, if any.
local function saved_name(session)
  local ok, lines = pcall(vim.fn.readfile, name_file(session), "", 1)
  return ok and lines[1] ~= "" and lines[1] or nil
end

--- List currently-open chats, sorted by chat number.
--- Scans every buffer for the `b:snacks_terminal` marker snacks sets on
--- terminal buffers, then keeps the ones running any of our launch commands.
--- @return { count: integer, buf: integer, cmd: string }[]
local function chats()
  local out = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      local ok, meta = pcall(function()
        return vim.b[buf].snacks_terminal
      end)
      if ok and type(meta) == "table" and is_chat_cmd(meta.cmd) then
        out[#out + 1] = { count = meta.id, buf = buf, cmd = meta.cmd }
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
  if layout == "right" then
    return vim.cmd.wincmd("h")
  end
  if sidebar and sidebar:win_valid() then
    vim.cmd.stopinsert()
    sidebar:focus()
  end
end

local function ensure_sidebar()
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
        local _, rail, left = dimensions()
        return layout == "right" and vim.o.columns - math.floor(vim.o.columns * 0.4) - rail or left
      end,
      height = 0.9,
      border = "rounded",
      title = " Agents ",
      footer = " n:new r:name d:del ",
      backdrop = false,
      wo = { wrap = false, cursorline = true, scrolloff = 0 },
      bo = { filetype = "agent_sidebar" },
      keys = {
        q = M.hide,
        ["<Esc>"] = function() end,
        ["<CR>"] = function()
          local chat = selected()
          if chat then
            if layout == "right" then
              sidebar:hide()
            end
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
        d = function()
          M.delete_selected()
        end,
        ["?"] = function()
          vim.notify("Enter: open · r: rename · n: new · d: delete (stops the agent)")
        end,
        ["<C-l>"] = function()
          if active and active:win_valid() then
            active:focus()
          end
        end,
      },
    })
  end
end

local function show_sidebar(term)
  if active and active ~= term and active:win_valid() then
    active:hide()
  end
  active = term
  M.last = vim.b[term.buf].snacks_terminal.id
  vim.b[term.buf].claude_chat_unread = false
  if layout == "right" then
    if sidebar then
      sidebar:hide()
    end
    return
  end
  ensure_sidebar()
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
  local id = vim.b[win.buf].snacks_terminal.id
  win.opts.wo.winbar = win.opts.position == "right"
      and (" %d %s · %s %s"):format(id, display(win.buf, id), state[1], state[2]):gsub("%%", "%%%%")
    or ""
  local meta = vim.b[win.buf].snacks_terminal
  if meta and type(meta.cmd) == "string" and meta.cmd:find("codex-bf", 1, true) then
    local budget = require("util.bifrost_budget")
    budget.refresh()
    win.opts.footer = " " .. budget.text() .. " "
  end
  win:update()
end

local function record(session)
  local ok, value = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(Status.home() .. "/" .. session .. "/agent.json"), "\n"))
  end)
  return ok and type(value) == "table" and value or nil
end

local function open_file()
  return Status.home() .. "/open-chats.json"
end

local function read_open()
  local ok, value = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(open_file()), "\n"))
  end)
  return ok and type(value) == "table" and value or {}
end

-- Repos this Neovim has had chats in, so closing a repo's last chat clears its entry.
local touched, last_saved = {}, nil

--- Remember which chats are open per repo (keyed by each chat's cwd) for M.restore after a reboot.
local function save_open()
  local by_cwd = {}
  for _, chat in ipairs(chats()) do
    local session = vim.b[chat.buf].snacks_terminal.env.NVIM_TEAM_SESSION
    local rec = session and record(session)
    if rec and rec.cwd then
      touched[rec.cwd] = true
      by_cwd[rec.cwd] = by_cwd[rec.cwd] or {}
      table.insert(by_cwd[rec.cwd], session)
    end
  end
  local encoded = vim.json.encode(by_cwd)
  if encoded == last_saved then
    return
  end
  last_saved = encoded
  local all = read_open()
  for cwd in pairs(touched) do
    all[cwd] = by_cwd[cwd]
  end
  pcall(vim.fn.writefile, { vim.json.encode(all) }, open_file())
end

function M.refresh_all()
  save_open()
  for _, t in ipairs(Snacks.terminal.list()) do
    local meta = vim.b[t.buf] and vim.b[t.buf].snacks_terminal
    if type(meta) == "table" and is_chat_cmd(meta.cmd) then
      refresh(t)
    end
  end
  render()
end

local function age(created)
  local seconds = os.time() - created
  if seconds < 3600 then
    return math.max(1, math.floor(seconds / 60)) .. "m ago"
  end
  return seconds < 86400 and math.floor(seconds / 3600) .. "h ago" or math.floor(seconds / 86400) .. "d ago"
end

--- Chats that need you: waiting on approval, then finished turns not yet seen.
function M.attention()
  local waiting, unread = {}, {}
  for _, chat in ipairs(chats()) do
    if vim.b[chat.buf].claude_chat_status == "waiting" then
      waiting[#waiting + 1] = chat
    elseif vim.b[chat.buf].claude_chat_unread then
      unread[#unread + 1] = chat
    end
  end
  return waiting, unread
end

--- Open the next chat that needs you, skipping the one already in front of you.
function M.next_attention()
  local waiting, unread = M.attention()
  local list = vim.list_extend(waiting, unread)
  local current = vim.api.nvim_get_current_buf()
  local from = 0
  for i, chat in ipairs(list) do
    if chat.buf == current then
      from = i
    end
  end
  for step = 1, #list do
    local chat = list[(from + step - 1) % #list + 1]
    if chat.buf ~= current then
      return M.open(chat.count)
    end
  end
  vim.notify("No chats need you")
end

--- @param count integer
--- @return snacks.terminal.Opts
local function term_opts(count, session)
  return {
    count = count,
    cwd = root(),
    env = { NVIM_TEAM_SESSION = session },
    win = {
      position = layout,
      stack = false,
      wo = { winfixwidth = true },
      width = function()
        if layout == "right" then
          return math.floor(vim.o.columns * 0.4)
        end
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
  local n = next_count(chats())
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

--- Stop the selected chat's agent (and any workers it started) and remove its
--- saved records, after confirmation.
function M.delete_selected()
  local chat = selected()
  local meta = chat and vim.b[chat.buf].snacks_terminal
  local session = meta and meta.env and meta.env.NVIM_TEAM_SESSION
  if not session then
    return
  end
  vim.ui.select({ "Cancel", "Delete chat" }, {
    prompt = "Delete " .. display(chat.buf, chat.count) .. "? Stops its agents and removes their transcripts; project files stay.",
  }, function(choice)
    if choice ~= "Delete chat" then
      return
    end
    vim.system({ "python3", SCRIPT, "manage", "delete", "--agent", session }, { text = true }, function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          vim.notify("Delete failed: " .. (result.stderr or ""), vim.log.levels.ERROR)
          return
        end
        local ok, value = pcall(vim.json.decode, result.stdout or "")
        local ids = ok and value.chat_ids or { session }
        for _, term in ipairs(Snacks.terminal.list()) do
          local m = vim.b[term.buf].snacks_terminal
          if m and m.env and vim.tbl_contains(ids, m.env.NVIM_TEAM_SESSION) then
            if active == term then
              M.hide()
            end
            vim.api.nvim_buf_delete(term.buf, { force = true })
          end
        end
        M.refresh_all()
      end)
    end)
  end)
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
      term.opts.position = layout
      term:show():focus()
      vim.b[term.buf].claude_chat_unread = false
      render()
      if layout == "right" then
        -- shortcut: the pty sometimes ends up narrower than the panel (cause not found); a 1-column
        -- nudge makes the agent redraw. Remove once the root cause is fixed.
        local width = vim.api.nvim_win_get_width(term.win)
        vim.defer_fn(function()
          if term:win_valid() then
            vim.api.nvim_win_set_width(term.win, width - 1)
            vim.defer_fn(function()
              if term:win_valid() then
                vim.api.nvim_win_set_width(term.win, width)
              end
            end, 50)
          end
        end, 50)
      end
      return term
    end
  end
end

--- Show or hide the agent list. In the right-hand layout it floats beside the panel and takes focus.
function M.toggle_sidebar()
  if sidebar and sidebar:win_valid() then
    return sidebar:hide()
  end
  ensure_sidebar()
  sidebar:show()
  render()
  vim.cmd.stopinsert()
  sidebar:focus()
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

--- Switch chats between the centred popup and a right-hand panel, for this Neovim session.
function M.toggle_layout()
  layout = layout == "float" and "right" or "float"
  local term = active and active:win_valid() and active
  if term then
    M.hide()
    return M.open(vim.b[term.buf].snacks_terminal.id)
  end
  vim.notify(layout == "right" and "Chats open in a right-hand panel" or "Chats open as a popup")
end

--- Reopen the chats that were open in this repo last time (resuming saved sessions after a
--- reboot), then show the last one. Falls back to the picker when there is nothing to restore.
function M.restore()
  local open = {}
  for _, c in ipairs(chats()) do
    open[vim.b[c.buf].snacks_terminal.env.NVIM_TEAM_SESSION] = c.count
  end
  local restored
  for _, session in ipairs(read_open()[root()] or {}) do
    local rec = record(session)
    local variant = rec and vim.iter(VARIANTS):find(function(v)
      return v.backend == rec.backend
    end)
    -- Codex can only resume once its session ID was recorded.
    if variant and not open[session] and (rec.backend:match("^claude") or rec.session_id) then
      if restored then
        restored:hide()
      end
      restored = spawn(variant.cmd, session)
      if restored then
        vim.b[restored.buf].claude_chat_name = saved_name(session)
      end
    end
  end
  if restored then
    return
  end
  if next(open) then
    return M.toggle_last()
  end
  M.pick()
end

--- Pick an open chat, reopen a chat still running in tmux, or create a new one.
function M.pick()
  vim.system({ "python3", SCRIPT, "running" }, { text = true }, function(result)
    vim.schedule(function()
      local ok, running = pcall(vim.json.decode, result.stdout or "")
      if result.code ~= 0 or not ok or type(running) ~= "table" then
        vim.notify("Could not list running chats", vim.log.levels.WARN)
        running = {}
      end
      local items, open = {}, {}
      for _, c in ipairs(chats()) do
        open[vim.b[c.buf].snacks_terminal.env.NVIM_TEAM_SESSION] = true
        items[#items + 1] = {
          count = c.count,
          label = ("%d. %s · %s"):format(c.count, variant_for(c.cmd).tag, display(c.buf, c.count)),
        }
      end
      for _, record in ipairs(running) do
        local variant = vim.iter(VARIANTS):find(function(v)
          return v.backend == record.backend
        end)
        if variant and not open[record.id] then
          local name = saved_name(record.id) or (record.role == "supervisor" and record.name) or nil
          local where = vim.fs.basename(record.cwd or "")
          items[#items + 1] = {
            variant = variant,
            id = record.id,
            name = name,
            label = ("↺ %s · %s%s"):format(
              variant.tag,
              name and (name .. " · " .. where) or (where .. " · " .. age(record.created or os.time())),
              record.attached > 0 and " (open elsewhere)" or ""
            ),
          }
        end
      end
      items[#items + 1] = { label = "＋ New chat" }
      vim.ui.select(items, {
        prompt = "Chats",
        format_item = function(item)
          return item.label
        end,
      }, function(choice)
        if not choice then
          return
        elseif choice.count then
          M.open(choice.count)
        elseif choice.id then
          local term = spawn(choice.variant.cmd, choice.id)
          if term then
            vim.b[term.buf].claude_chat_name = choice.name
          end
        else
          M.new()
        end
      end)
    end)
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
    local session = vim.b[buf].snacks_terminal.env.NVIM_TEAM_SESSION
    if input == "" then
      vim.fn.delete(name_file(session))
    elseif not pcall(vim.fn.writefile, { input }, name_file(session)) then
      vim.notify("Chat name not saved", vim.log.levels.WARN)
    end
    M.refresh_all()
  end)
end

vim.api.nvim_create_autocmd("VimResized", {
  callback = function()
    if layout == "right" and active and active:win_valid() then
      vim.api.nvim_win_set_width(active.win, math.floor(vim.o.columns * 0.4))
    end
  end,
})

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
      local visible = vim.fn.bufwinid(chat.buf) ~= -1
      if previous == "busy" and state == "idle" and not visible then
        vim.b[chat.buf].claude_chat_unread = true
      elseif visible then
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
