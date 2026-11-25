-- Multiple AI-agent chats (Claude Code, Codex CLI) via snacks.nvim floating
-- terminals.
--
local M = {}
local Status = require("util.claude_status")
local sidebar
local active
local grid
local close_grid, render_grid
local terminals = {}
local namespace = vim.api.nvim_create_namespace("agent_sidebar")
-- One glyph, colour and sort tier per state, shared by the sidebar, the grid and window titles.
local states = {
  waiting = { "!", "Needs you", "AgentNeedsYou", tier = 1 },
  exited = { "✗", "Exited", "AgentNeedsYou", tier = 1 },
  ready = { "●", "Ready", "AgentReady", tier = 2 },
  busy = { "", "Working", "AgentWorking", tier = 3 },
  idle = { "○", "Idle", "AgentIdle", tier = 4 },
  unknown = { "◌", "Status unknown", "AgentIdle", tier = 5 },
}
local SPIN = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

-- Grid neon look: one accent per chat name, and a synthwave palette for the cards' text colours.
local ACCENTS = { "#ff7edb", "#36f9f6", "#c792ea", "#fede5d", "#72f1b8", "#ff8b39", "#6e8bff" }
local NEON16 = {
  [0] = "#2a2139",
  "#fe4450",
  "#72f1b8",
  "#fede5d",
  "#6e8bff",
  "#ff7edb",
  "#36f9f6",
  "#e0def4",
  "#848bbd",
  "#ff6e83",
  "#9cffd3",
  "#fff27a",
  "#9aaaff",
  "#ffa8ec",
  "#8cfbff",
  "#ffffff",
}
local TOKENS = {
  AgentUrl = { "#36f9f6", underline = true },
  AgentPath = { "#72f1b8" },
  AgentRef = { "#ff7edb", bold = true },
  AgentJira = { "#fede5d", bold = true },
  AgentNumber = { "#ff8b39" },
  AgentLabel = { "#c792ea", bold = true },
  AgentGood = { "#72f1b8", bold = true },
  AgentBad = { "#fe4450", bold = true },
}
-- Window-local matches that colour tokens in the cards; higher priority wins where they overlap.
local PATTERNS = {
  { "AgentUrl", [[\vhttps?://\S+]], 15 },
  { "AgentPath", [[\v(^|\s|\()\zs[~.]{0,2}/[[:alnum:]_.@-]+(/[[:alnum:]_.@-]*)+]], 12 },
  { "AgentRef", [[\v#\d+>]], 11 },
  { "AgentJira", [[\v<[A-Z][A-Z0-9]+-\d+>]], 11 },
  { "AgentLabel", [[\v^\s*(- )?\zs[A-Z][[:alnum:] ]{1,24}:\ze(\s|$)]], 11 },
  { "AgentGood", [[\v<(done|passed|merged|fixed|ok|OK)>]], 11 },
  { "AgentBad", [[\v<(error|failed|denied|refused|blocked)>]], 11 },
  { "AgentNumber", [[\v<\d+(\.\d+)?(ms|s|m|h|d|k|Gi|Mi|GB|MB)?>]], 10 },
}

--- Colour the PATTERNS tokens in a window, once per window.
local function add_patterns(win)
  if vim.w[win].agent_patterns then
    return
  end
  vim.w[win].agent_patterns = true
  for _, pattern in ipairs(PATTERNS) do
    vim.fn.matchadd(pattern[1], pattern[2], pattern[3], -1, { window = win })
  end
end

--- Mix two "#rrggbb" colours; `a` is the weight of `fg`.
local function blend(fg, bg, a)
  local out = "#"
  for i = 2, 6, 2 do
    local f, b = tonumber(fg:sub(i, i + 1), 16), tonumber(bg:sub(i, i + 1), 16)
    out = out .. ("%02x"):format(math.floor(f * a + b * (1 - a) + 0.5))
  end
  return out
end

local function highlights()
  for name, link in pairs({
    AgentNeedsYou = "DiagnosticError",
    AgentReady = "DiagnosticOk",
    AgentWorking = "DiagnosticInfo",
    AgentIdle = "Comment",
  }) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
  local function hex(name, key)
    local value = vim.api.nvim_get_hl(0, { name = name, link = false })[key]
    return value and ("#%06x"):format(value)
  end
  local bg = hex("NormalFloat", "bg") or hex("Normal", "bg") or "#1e2030"
  -- Fake glow: a dim tint of the text colour behind it.
  local function glow(name, fg, alpha, extra)
    vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", { fg = fg, bg = blend(fg, bg, alpha) }, extra or {}))
  end
  vim.api.nvim_set_hl(0, "AgentBorder", { fg = "#7a6ff0" })
  for i, accent in ipairs(ACCENTS) do
    glow("AgentAccent" .. i, accent, 0.2, { bold = true })
    vim.api.nvim_set_hl(0, "AgentBorder" .. i, { fg = accent })
  end
  for _, state in ipairs({ "AgentNeedsYou", "AgentReady", "AgentWorking", "AgentIdle" }) do
    glow(state .. "Glow", hex(state, "fg") or "#c8d3f5", 0.2, { bold = true })
  end
  for name, spec in pairs(TOKENS) do
    glow(name, spec[1], 0.12, { bold = spec.bold, underline = spec.underline })
  end
end
highlights()
vim.api.nvim_create_autocmd("ColorScheme", { callback = highlights })

--- A finished turn you haven't looked at yet counts as "ready", not "idle".
local function state_of(buf)
  local status = vim.b[buf].claude_chat_status
  return states[status == "idle" and vim.b[buf].claude_chat_unread and "ready" or status] or states.unknown
end

local function glyph(state)
  return state == states.busy and SPIN[os.time() % #SPIN + 1] or state[1]
end

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
local TMUX_SOCKET = vim.env.NVIM_TEAM_TMUX or "nvim-agents"
for _, variant in ipairs(VARIANTS) do
  variant.backend = variant.backend or variant.tag
  variant.launch = "python3 " .. vim.fn.shellescape(SCRIPT) .. " launch --backend " .. variant.backend
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
local layout = "float" -- fullscreen, or "right"; lasts for this Neovim session

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

local function record(session)
  local ok, value = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(Status.home() .. "/" .. session .. "/agent.json"), "\n"))
  end)
  return ok and type(value) == "table" and value or nil
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
  return vim.o.columns, math.min(26, math.max(16, math.floor(vim.o.columns * 0.25))), 0
end

local function selected()
  if grid then
    for _, slot in ipairs(grid.slots) do
      if slot.win == vim.api.nvim_get_current_win() then
        return slot.chat
      end
    end
  end
  if sidebar and sidebar:win_valid() and vim.api.nvim_get_current_win() == sidebar.win then
    return chats()[math.floor((vim.api.nvim_win_get_cursor(sidebar.win)[1] - 1) / 3) + 1]
  end
end

local function render()
  if not (sidebar and sidebar:win_valid()) then
    return
  end
  -- Each chat is 3 lines (j/k and selected() rely on it): mark + number + agent, name, blank.
  local lines, marks = {}, {}
  local function line(segments)
    local text = ""
    for _, segment in ipairs(segments) do
      if segment[2] then
        marks[#marks + 1] = { #lines, #text, #text + #segment[1], segment[2] }
      end
      text = text .. segment[1]
    end
    lines[#lines + 1] = text
  end
  for _, chat in ipairs(chats()) do
    local state, accent = state_of(chat.buf), (chat.count - 1) % #ACCENTS + 1
    local bar = active and active.buf == chat.buf and { "▎", "AgentBorder" .. accent } or { " " }
    line({
      bar,
      { " " .. glyph(state) .. " ", state[3] .. "Glow" },
      { " " .. chat.count .. " ", "Comment" },
      {
        variant_for(chat.cmd).tag,
        "AgentBorder",
      },
    })
    local name = display(chat.buf, chat.count):gsub("[\r\n]", " ")
    line({ bar, { " " .. name .. " ", "AgentAccent" .. accent } })
    line({ { "" } })
  end
  vim.bo[sidebar.buf].modifiable = true
  vim.api.nvim_buf_set_lines(sidebar.buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(sidebar.buf, namespace, 0, -1)
  for _, mark in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(sidebar.buf, namespace, mark[1], mark[2], { end_col = mark[3], hl_group = mark[4] })
  end
  vim.bo[sidebar.buf].modifiable = false
end

-- Grid: one card per chat showing the bottom of its screen in colour, sorted by state tier.
-- Cards are fixed slots; a re-render swaps their contents and only rebuilds when the chat count changes.
local DASHED = { "┌", "╌", "┐", "╎", "┘", "╌", "└", "╎" }
local CSI, OSC = "\27%[[0-?]*[ -/]*[@-~]", "\27%].-\27\\"
local HELP = {
  "hjkl     move (h from column 1: commander)",
  "c        talk to the commander",
  "Tab      next card that wants you",
  "Enter    open the chat",
  "1-9      answer a waiting prompt",
  "] [      next / previous page (j k at the edge too)",
  "o        sort: attention, recent, manual",
  "m        move a chat: m, pick its place, m",
  "s        swap two chats: s, pick the other, s",
  "/        filter by name (Esc clears)",
  "a i      reply (Enter sends, Esc keeps a draft)",
  "n r d    new · rename · delete",
  "< >      fewer / more columns",
  "( ) - +  fewer / more rows",
  "=        fit the grid to the chats",
  "q Esc    close the grid",
}
local open_grid

function close_grid()
  if not grid then
    return
  end
  pcall(vim.api.nvim_win_close, grid.bg, true)
  for _, slot in ipairs(grid.slots) do
    pcall(vim.api.nvim_win_close, slot.win, true)
  end
  grid = nil
end

-- Grid sort: "attention" (state tier), "recent" (latest state change first) or "manual" (`order`, a list of chat keys).
local MODES = { "attention", "recent", "manual" }
local sort
local function sort_file()
  return Status.home() .. "/grid-sort.json"
end
local function sort_state()
  if not sort then
    local ok, value = pcall(function()
      return vim.json.decode(table.concat(vim.fn.readfile(sort_file()), "\n"))
    end)
    sort = ok and type(value) == "table" and vim.tbl_contains(MODES, value.mode) and value or { mode = "attention" }
    sort.order = type(sort.order) == "table" and sort.order or {}
  end
  return sort
end
local function save_sort()
  pcall(vim.fn.writefile, { vim.json.encode(sort) }, sort_file())
end
--- A chat's key in the manual order: its team session, which survives restarts.
local function chat_key(chat)
  return vim.b[chat.buf].snacks_terminal.env.NVIM_TEAM_SESSION or ("chat " .. chat.count)
end

--- Chats whose name contains `filter`, in the grid's sort mode, then by number.
local function sorted(filter)
  local list = vim.tbl_filter(function(chat)
    return not filter or display(chat.buf, chat.count):lower():find(filter, 1, true) ~= nil
  end, chats())
  for _, chat in ipairs(list) do
    chat.state = state_of(chat.buf)
    local session = vim.b[chat.buf].snacks_terminal.env.NVIM_TEAM_SESSION
    chat.record = session and record(session) or {}
  end
  local mode, rank = sort_state().mode, {}
  for i, key in ipairs(sort.order) do
    rank[key] = i
  end
  table.sort(list, function(a, b)
    if mode == "recent" then
      local x, y = vim.b[a.buf].claude_chat_active or 0, vim.b[b.buf].claude_chat_active or 0
      if x ~= y then
        return x > y
      end
    elseif mode == "manual" then
      local x, y = rank[chat_key(a)] or math.huge, rank[chat_key(b)] or math.huge
      if x ~= y then
        return x < y
      end
    elseif a.state.tier ~= b.state.tier then
      return a.state.tier < b.state.tier
    end
    return a.count < b.count
  end)
  return list
end

local function plain(line)
  return (line:gsub(CSI, ""):gsub(OSC, ""))
end

local function is_rule(line)
  local text = vim.trim(plain(line or ""))
  return text ~= "" and (text:gsub("─", "")) == ""
end

--- Drop Claude's input box and footer (kept while a prompt waits, so the question shows) and trailing blanks.
local function trim(lines, state)
  if state ~= states.waiting then
    local rules = {}
    for i = #lines, 1, -1 do
      if is_rule(lines[i]) then
        rules[#rules + 1] = i
        if #rules == 2 then
          break
        end
      end
    end
    if rules[2] and vim.startswith(plain(lines[rules[2] + 1] or ""), "❯") then
      lines = vim.list_slice(lines, 1, rules[2] - 1)
    end
  end
  while #lines > 0 and vim.trim(plain(lines[#lines])) == "" do
    table.remove(lines)
  end
  return lines
end

--- Cut a line to `width` cells, keeping its colour codes and links.
local function xterm(n)
  if n >= 232 then
    local v = 8 + (n - 232) * 10
    return v, v, v
  end
  n = n - 16
  local function level(i)
    return i == 0 and 0 or 55 + i * 40
  end
  return level(math.floor(n / 36)), level(math.floor(n / 6) % 6), level(n % 6)
end

--- Push a colour to neon: stretch its channels to full saturation; greys turn synthwave lavender.
local function neonize(r, g, b)
  local high, low = math.max(r, g, b), math.min(r, g, b)
  if high - low < 24 then
    return blend(("#%02x%02x%02x"):format(r, g, b), "#a8a0ff", 0.6)
  end
  local floor = math.floor(low * 0.6)
  local function stretch(c)
    return math.floor(floor + (c - low) * (255 - floor) / (high - low) + 0.5)
  end
  return ("#%02x%02x%02x"):format(stretch(r), stretch(g), stretch(b))
end

--- Rewrite the foreground colours in one SGR sequence (its params, without ESC [ and m) to the neon palette.
local function neon(params)
  local p, out, i = vim.split(params, ";", { plain = true }), {}, 1
  while i <= #p do
    local n, colour = tonumber(p[i]), nil
    if n == 38 and p[i + 1] == "5" and tonumber(p[i + 2]) then
      local index = tonumber(p[i + 2])
      colour = index < 16 and NEON16[index] or neonize(xterm(index))
      i = i + 3
    elseif n == 38 and p[i + 1] == "2" and tonumber(p[i + 4]) then
      colour = neonize(tonumber(p[i + 2]), tonumber(p[i + 3]), tonumber(p[i + 4]))
      i = i + 5
    elseif n and (n >= 30 and n <= 37 or n >= 90 and n <= 97) then
      colour = NEON16[n >= 90 and n - 82 or n - 30]
      i = i + 1
    else
      -- Copy anything else; a background colour keeps all its params.
      local take = n == 48 and (p[i + 1] == "5" and 3 or p[i + 1] == "2" and 5) or 1
      vim.list_extend(out, p, i, math.min(#p, i + take - 1))
      i = i + take
    end
    if colour then
      out[#out + 1] = ("38;2;%d;%d;%d"):format(
        tonumber(colour:sub(2, 3), 16),
        tonumber(colour:sub(4, 5), 16),
        tonumber(colour:sub(6, 7), 16)
      )
    end
  end
  return "\27[" .. table.concat(out, ";") .. "m"
end

--- Cut a line to `width` cells, keeping its links and turning its colour codes neon.
local function crop(line, width)
  local out, used, i = {}, 0, 1
  while i <= #line do
    local piece = line:match("^" .. CSI, i) or line:match("^" .. OSC, i)
    if piece and piece:sub(2, 2) == "[" and piece:sub(-1) == "m" then
      i = i + #piece
      piece = neon(piece:sub(3, -2))
    elseif piece then
      i = i + #piece
    else
      piece = line:match("^[\1-\127\194-\244][\128-\191]*", i) or line:sub(i, i)
      local cells = #piece == 1 and 1 or vim.fn.strdisplaywidth(piece)
      if used + cells > width then
        break
      end
      used = used + cells
      i = i + #piece
    end
    out[#out + 1] = piece
  end
  return table.concat(out) .. "\27[0m\27]8;;\27\\"
end

--- Paint the chat's tmux pane into its card; falls back to the plain terminal text when tmux has no pane.
local function fill(slot, chat)
  local function paint(lines)
    if not (grid and slot.chat == chat and vim.api.nvim_win_is_valid(slot.win)) then
      return
    end
    local width, height = vim.api.nvim_win_get_width(slot.win), vim.api.nvim_win_get_height(slot.win)
    lines = trim(lines, chat.state)
    lines = vim.list_slice(lines, math.max(1, #lines - height + 1))
    for i, line in ipairs(lines) do
      lines[i] = crop(line, width)
    end
    vim.api.nvim_chan_send(slot.chan, "\27[H\27[2J\27[3J" .. table.concat(lines, "\r\n"))
  end
  local session = vim.b[chat.buf].snacks_terminal.env.NVIM_TEAM_SESSION
  if not session then
    return paint(vim.api.nvim_buf_get_lines(chat.buf, 0, -1, false))
  end
  vim.system(
    { "tmux", "-L", TMUX_SOCKET, "capture-pane", "-e", "-p", "-t", "team-" .. session },
    { text = true },
    vim.schedule_wrap(function(result)
      paint(
        result.code == 0 and vim.split(result.stdout, "\n")
          or vim.api.nvim_buf_is_valid(chat.buf) and vim.api.nvim_buf_get_lines(chat.buf, 0, -1, false)
          or {}
      )
    end)
  )
end

--- Context used, as the statusline shows it; Claude's statusline hook writes it per session.
--- A per-session JSON file in $TMPDIR, written by Claude's status line: claude-ctx-<session>.json (GSD hook)
--- or claude-model-<session>.json (scripts/statusline-usage.sh).
local function session_file(chat, prefix)
  local session = chat.record.session_id or vim.b[chat.buf].snacks_terminal.env.NVIM_TEAM_SESSION
  if not session then
    return {}
  end
  local ok, value = pcall(function()
    local path = vim.fs.joinpath(vim.uv.os_tmpdir(), prefix .. session .. ".json")
    return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
  end)
  return ok and type(value) == "table" and value or {}
end

--- Bottom bar of a card: state, context used (as the status line shows it), then model and effort.
local function footer(chat)
  local state = chat.state
  local chunks = { { " " .. state[2] .. " ", state[3] .. "Glow" } }
  local pct = tonumber(session_file(chat, "claude-ctx-").used_pct)
  if pct then
    local hl = pct >= 80 and "DiagnosticError" or pct >= 50 and "DiagnosticWarn" or "Comment"
    table.insert(chunks, { pct .. "% ", hl })
  end
  local info = session_file(chat, "claude-model-")
  if type(info.model) == "string" then
    local label = info.model:gsub("^Claude ", "") .. (type(info.effort) == "string" and " " .. info.effort or "")
    table.insert(chunks, { label .. " ", "AgentAccent3" })
  end
  return chunks
end

-- Grid size picked with < > - +, as { cols, rows }; false fits the grid to the chat count.
local shape
local function shape_file()
  return Status.home() .. "/grid-shape.json"
end

--- What the grid shows: the commander in its own column, then one page of chats by attention, as many as the size fits.
local function arrange(filter, page)
  local view = { cards = {} }
  for _, chat in ipairs(sorted(filter)) do
    if chat.record.role == "commander" and not view.commander then
      view.commander = chat
    else
      table.insert(view.cards, chat)
    end
  end
  if shape == nil then
    local ok, value = pcall(function()
      return vim.json.decode(table.concat(vim.fn.readfile(shape_file()), "\n"))
    end)
    shape = ok and type(value) == "table" and value.cols and value or false
  end
  local n = math.max(1, #view.cards)
  view.cols = shape and shape.cols or math.min(n, math.ceil(math.sqrt((view.commander and 1 or 2) * n)))
  view.rows = shape and shape.rows or math.ceil(n / view.cols)
  local cells = view.cols * view.rows
  view.pages = math.max(1, math.ceil(#view.cards / cells))
  view.page = math.max(1, math.min(view.pages, page or 1))
  view.slots = vim.list_slice(view.cards, (view.page - 1) * cells + 1, view.page * cells)
  if view.commander then
    table.insert(view.slots, 1, view.commander)
  end
  return view
end

local plan
--- Plan name from Claude's account record, e.g. "Team · Max 5x"; read once.
local function plan_name()
  if plan == nil then
    local ok, account = pcall(function()
      return vim.json.decode(table.concat(vim.fn.readfile(vim.fn.expand("~/.claude.json")), "\n")).oauthAccount
    end)
    account = ok and type(account) == "table" and account or {}
    local parts = {}
    local org = ({ claude_team = "Team", claude_enterprise = "Enterprise", claude_max = "Max", claude_pro = "Pro" })[account.organizationType]
    local tier = type(account.userRateLimitTier) == "string" and account.userRateLimitTier:match("max_(%d+x)$")
    if org then
      table.insert(parts, org)
    end
    if tier then
      table.insert(parts, "Max " .. tier)
    end
    plan = table.concat(parts, " · ")
  end
  return plan
end

--- One usage window as a bar: label, ▰▱ meter, percent and reset time. Empty once the window has reset.
local function meter(label, limit, format)
  if type(limit) ~= "table" or not tonumber(limit.used_percentage) or (tonumber(limit.resets_at) or 0) < os.time() then
    return {}
  end
  local pct = math.floor(limit.used_percentage + 0.5)
  local filled = math.max(0, math.min(8, math.floor(pct * 8 / 100 + 0.5)))
  local hl = pct >= 80 and "DiagnosticError" or pct >= 50 and "DiagnosticWarn" or "DiagnosticOk"
  return {
    { label .. " ", "Comment" },
    { ("▰"):rep(filled) .. ("▱"):rep(8 - filled), hl },
    { (" %d%%"):format(pct), hl },
    { " ↻ " .. os.date(format, limit.resets_at) .. "   ", "Comment" },
  }
end

local COUNTED = { "waiting", "exited", "ready", "busy", "idle", "unknown" }

--- Header (state counts, page, filter) and the bottom bar (plan and usage windows) on the grid background.
local function bars(view)
  local buf = vim.api.nvim_win_get_buf(grid.bg)
  local last = vim.api.nvim_buf_line_count(buf) - 1
  local function put(line, chunks, pos)
    vim.api.nvim_buf_set_extmark(buf, namespace, line, 0, {
      virt_text = chunks,
      virt_text_pos = pos == "right" and "right_align" or nil,
      virt_text_win_col = pos ~= "right" and 0 or nil,
    })
  end
  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
  local header = { { " AGENTS ", "PmenuSel" }, { ("  grid %d×%d"):format(grid.cols, grid.rows), "Comment" } }
  if grid.filter then
    table.insert(header, { "   / " .. grid.filter .. "  (Esc clears)", "AgentAccent4" })
  end
  if grid.mark then
    local verb = grid.mark.kind == "swap" and "pick a chat to swap with" or "pick its new place"
    table.insert(
      header,
      { ("   %s: %s, then %s or Enter (Esc cancels)"):format(grid.mark.name, verb, grid.mark.lhs), "AgentAccent2" }
    )
  end
  put(0, header)
  local counts, right = {}, {}
  for _, chat in ipairs(view.cards) do
    counts[chat.state] = (counts[chat.state] or 0) + 1
  end
  for _, key in ipairs(COUNTED) do
    local state = states[key]
    if counts[state] then
      table.insert(right, { glyph(state) .. " " .. counts[state] .. "  ", state[3] .. "Glow" })
    end
  end
  if view.pages > 1 then
    table.insert(right, { ("page %d/%d  "):format(view.page, view.pages), "AgentAccent4" })
  end
  table.insert(right, { "sort: " .. sort_state().mode .. "  ", "Comment" })
  if #right > 0 then
    put(0, right, "right")
  end
  local usage = plan_name() ~= "" and { { " " .. plan_name() .. "   ", "AgentAccent3" } } or { { " ", "Comment" } }
  -- Saved by scripts/statusline-usage.sh, the Claude status line wrapper.
  local ok, limits = pcall(function()
    local path = vim.fs.joinpath(vim.uv.os_tmpdir(), "claude-usage.json")
    return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
  end)
  if ok and type(limits) == "table" then
    vim.list_extend(usage, meter("5h", limits.five_hour, "%H:%M"))
    vim.list_extend(usage, meter("week", limits.seven_day, "%a %H:%M"))
  end
  local budget = require("util.bifrost_budget")
  budget.refresh()
  if budget.spend() then
    table.insert(usage, { "  " .. budget.spend(), "AgentAccent3" })
  end
  put(last, usage)
  put(last, { { "c commander · a reply · o sort · ] [ page · < > ( ) = size · ? keys ", "Comment" } }, "right")
end

--- Card layout: the commander column width, and each card's inner width and height (before the 1-cell floor).
--- Row 0 is the header and the last row the usage bar; each card has a 2-cell border and a 2-column / 1-row gap.
local function geometry(commander, cols, rows)
  local width, height = vim.o.columns, vim.o.lines - vim.o.cmdheight - 1
  local left = commander and math.max(40, math.floor(width / 3)) or 0
  return left, math.floor((width - left - 2) / cols) - 4, math.floor((height - 2) / rows) - 3, width, height
end

local function reopen(filter, page)
  local pick, current, mark = grid.pick, grid.page, grid.mark
  close_grid()
  open_grid(pick, filter, page or current)
  if grid and mark then
    grid.mark = mark
    render_grid()
  end
end

function render_grid()
  if not grid then
    return
  end
  for _, slot in ipairs(grid.slots) do
    if not vim.api.nvim_win_is_valid(slot.win) then
      return close_grid()
    end
  end
  local view = arrange(grid.filter, grid.page)
  local list = view.slots
  grid.pages = view.pages
  if
    #list ~= #grid.slots
    or (view.commander ~= nil) ~= grid.commander
    or view.cols ~= grid.cols
    or view.rows ~= grid.rows
    or view.page ~= grid.page
  then
    return reopen(grid.filter)
  end
  if grid.hold then
    -- The reply bar is anchored to its card's window, so cards keep their places while it is open.
    local by_count = {}
    for _, chat in ipairs(view.cards) do
      by_count[chat.count] = chat
    end
    for _, chat in ipairs(list) do
      by_count[chat.count] = chat
    end
    local kept = vim
      .iter(grid.slots)
      :map(function(slot)
        return by_count[slot.chat.count]
      end)
      :totable()
    if #kept == #list then
      list = kept
    end
  end
  if not vim.iter(list):any(function(c)
    return c.count == grid.pick
  end) then
    grid.pick = (list[grid.commander and 2 or 1] or list[1]).count
  end
  local current = vim.api.nvim_get_current_win()
  local focused = vim.iter(grid.slots):any(function(slot)
    return slot.win == current
  end)
  for i, chat in ipairs(list) do
    local slot, state, picked = grid.slots[i], chat.state, chat.count == grid.pick
    slot.chat = chat
    fill(slot, chat)
    local name = display(chat.buf, chat.count):gsub("[\r\n]", " ")
    local title = {
      { " " .. glyph(state) .. " ", state[3] .. "Glow" },
      { chat.count .. " ", "Comment" },
      { name .. " ", "AgentAccent" .. (chat.count - 1) % #ACCENTS + 1 },
    }
    if grid.mark and grid.mark.key == chat_key(chat) then
      table.insert(title, 1, { " " .. grid.mark.kind .. " ", "PmenuSel" })
    end
    if chat == view.commander then
      table.insert(title, { "chief of staff ", "Comment" })
    end
    vim.api.nvim_win_set_config(slot.win, {
      border = picked and "double" or state.tier == 1 and "bold" or state == states.unknown and DASHED or "rounded",
      title = title,
      footer = footer(chat),
      footer_pos = "right",
    })
    vim.wo[slot.win].winhighlight = "FloatBorder:"
      .. (state.tier <= 2 and state[3] or picked and "Normal" or "FloatBorder")
    if picked and focused and current ~= slot.win then
      vim.api.nvim_set_current_win(slot.win)
    end
  end
  bars(view)
end

local function picked_index()
  for i, slot in ipairs(grid.slots) do
    if slot.chat.count == grid.pick then
      return i
    end
  end
  return 1
end

local function pick_slot(index)
  grid.pick = grid.slots[math.max(1, math.min(#grid.slots, index))].chat.count
  render_grid()
end

--- hjkl: h from the first column goes to the commander, l from the commander to the first card.
--- ] [ (and j / k past the last / first row): the next or previous page of chats.
local function turn(delta)
  local page = grid.page + delta
  if page >= 1 and page <= grid.pages then
    reopen(grid.filter, page)
  end
end

local function move(dcol, drow)
  local i, first = picked_index(), grid.commander and 2 or 1
  if i < first then
    return dcol > 0 and #grid.slots >= first and pick_slot(first)
  end
  if dcol < 0 and (i - first) % grid.cols == 0 then
    return first > 1 and pick_slot(1)
  end
  local row, last_row = math.floor((i - first) / grid.cols), math.floor((#grid.slots - first) / grid.cols)
  if drow > 0 and row == last_row or drow < 0 and row == 0 then
    return turn(drow)
  end
  local target = i + dcol + drow * grid.cols
  if target >= first and target <= #grid.slots then
    pick_slot(target)
  end
end

--- Set the grid to `cols` x `rows` cards, or fit it to the chats when nil. Kept across restarts.
local function resize(cols, rows)
  shape = cols and { cols = cols, rows = rows } or false
  pcall(vim.fn.writefile, { vim.json.encode(shape or vim.empty_dict()) }, shape_file())
  reopen(grid.filter)
end

--- < > - +: one column or row more or fewer. Sizes that round to the same card size are skipped, so each press
--- shows a change; it stops where cards would get too small to read.
local function step(dcols, drows)
  local _, w0, h0 = geometry(grid.commander, grid.cols, grid.rows)
  local cols, rows = grid.cols, grid.rows
  repeat
    cols, rows = cols + dcols, rows + drows
    local _, w, h = geometry(grid.commander, cols, rows)
    if cols < 1 or rows < 1 or w < 12 or h < 2 then
      return
    end
  until w ~= w0 or h ~= h0
  resize(cols, rows)
end

--- Move to the next card that wants you (needs you, exited, or ready).
local function next_wanting()
  local from = picked_index()
  for step = 1, #grid.slots do
    local i = (from + step - 1) % #grid.slots + 1
    if grid.slots[i].chat.state.tier <= 2 then
      return pick_slot(i)
    end
  end
end

--- Pick option `n` of the picked card's waiting prompt without opening it.
local function answer(n)
  local chat = grid.slots[picked_index()].chat
  if chat.state ~= states.waiting then
    return vim.notify("Nothing to answer", vim.log.levels.WARN)
  end
  vim.api.nvim_chan_send(vim.b[chat.buf].terminal_job_id, tostring(n))
end

--- Type `text` into the chat's live session, then press Enter there.
local function send(chat, text)
  local session = vim.b[chat.buf].snacks_terminal.env.NVIM_TEAM_SESSION
  if not session then
    return vim.api.nvim_chan_send(vim.b[chat.buf].terminal_job_id, text .. "\r")
  end
  local target = "team-" .. session
  vim.system({ "tmux", "-L", TMUX_SOCKET, "send-keys", "-t", target, "-l", "--", text }, {}, function(result)
    if result.code ~= 0 then
      return vim.schedule(function()
        vim.notify("Send failed: " .. (result.stderr or ""), vim.log.levels.ERROR)
      end)
    end
    -- A separate Enter, so the agent sees typed text and not a paste ending in a newline.
    vim.defer_fn(function()
      vim.system({ "tmux", "-L", TMUX_SOCKET, "send-keys", "-t", target, "Enter" })
    end, 100)
  end)
end

-- Unsent reply text per chat number, kept when Esc closes the reply bar.
local drafts = {}

--- A reply bar on the picked card, like insert mode: Enter sends, Esc closes it and keeps the text as a draft.
local function reply()
  local slot = grid.slots[picked_index()]
  local chat = slot.chat
  if chat.state == states.waiting then
    return vim.notify("This chat waits on a prompt. Answer it with 1-9 first.", vim.log.levels.WARN)
  end
  local width, height = vim.api.nvim_win_get_width(slot.win), vim.api.nvim_win_get_height(slot.win)
  local function close(self)
    drafts[chat.count] = self:text()
    self:execute("cancel")
  end
  grid.hold = true
  Snacks.input({
    prompt = "Reply to " .. display(chat.buf, chat.count),
    default = drafts[chat.count],
    win = {
      relative = "win",
      win = slot.win,
      row = math.max(0, height - 3),
      col = 0,
      width = math.max(10, width - 2),
      zindex = 60,
      title_pos = "left",
      keys = {
        i_esc = { "<esc>", close, mode = "i" },
        n_esc = { "<esc>", close, mode = "n" },
      },
    },
  }, function(text)
    if grid then
      grid.hold = nil
      render_grid()
    end
    if text and vim.trim(text) ~= "" then
      drafts[chat.count] = nil
      send(chat, text)
    end
  end)
end

local function help()
  local from = vim.api.nvim_get_current_win()
  Snacks.win({
    text = HELP,
    width = 54,
    height = #HELP,
    border = "rounded",
    title = " Grid keys ",
    backdrop = false,
    zindex = 60,
    keys = { q = "close", ["<Esc>"] = "close", ["?"] = "close" },
    on_close = function()
      vim.schedule(function()
        if vim.api.nvim_win_is_valid(from) then
          vim.api.nvim_set_current_win(from)
        end
      end)
    end,
  })
end

local function search()
  vim.ui.input({ prompt = "Filter chats by name: ", default = grid.filter or "" }, function(input)
    if input == nil or not grid then
      return
    end
    local filter = input ~= "" and input:lower() or nil
    if #sorted(filter) == 0 then
      return vim.notify("No chat names match " .. input, vim.log.levels.WARN)
    end
    reopen(filter, 1)
  end)
end

--- Chat keys in the current order of all chats, without the commander (it has its own column).
local function current_order()
  return vim
    .iter(sorted())
    :filter(function(chat)
      return chat.record.role ~= "commander"
    end)
    :map(chat_key)
    :totable()
end

--- o: attention, then recent, then manual. Manual starts from the order on screen.
local function cycle_sort()
  local state = sort_state()
  local next_mode = MODES[vim.fn.index(MODES, state.mode) + 2] or MODES[1]
  if next_mode == "manual" then
    state.order = current_order()
  end
  state.mode = next_mode
  save_sort()
  render_grid()
end

--- m / s: mark the picked chat to move or swap; the next m / s / Enter on another chat drops it there.
local function mark(kind, lhs)
  local chat = grid.slots[picked_index()].chat
  if chat.record.role == "commander" then
    return vim.notify("The commander keeps its own column", vim.log.levels.WARN)
  end
  if sort_state().mode ~= "manual" then
    sort.order, sort.mode = current_order(), "manual"
    save_sort()
  end
  grid.mark = { kind = kind, lhs = lhs, key = chat_key(chat), count = chat.count, name = display(chat.buf, chat.count) }
  render_grid()
end

local function drop()
  local marked, target = grid.mark, grid.slots[picked_index()].chat
  grid.mark = nil
  local order = current_order()
  local from, to = vim.fn.index(order, marked.key) + 1, vim.fn.index(order, chat_key(target)) + 1
  if from > 0 and to > 0 and from ~= to then
    if marked.kind == "swap" then
      order[from], order[to] = order[to], order[from]
    else
      -- The moved chat takes the target's place; the chats between shift by one.
      table.insert(order, to, table.remove(order, from))
    end
    sort.order = order
    save_sort()
  end
  grid.pick = marked.count
  render_grid()
end

local function grid_keys(buf)
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true })
  end
  map("h", function()
    move(-1, 0)
  end)
  map("l", function()
    move(1, 0)
  end)
  map("k", function()
    move(0, -1)
  end)
  map("j", function()
    move(0, 1)
  end)
  map("c", function()
    if not grid.commander then
      close_grid()
      return M.commander()
    end
    pick_slot(1)
    reply()
  end)
  for lhs, delta in pairs({
    ["<"] = { -1, 0 },
    [">"] = { 1, 0 },
    ["-"] = { 0, -1 },
    ["+"] = { 0, 1 },
    ["("] = { 0, -1 },
    [")"] = { 0, 1 },
  }) do
    map(lhs, function()
      step(delta[1], delta[2])
    end)
  end
  map("=", function()
    resize()
  end)
  map("<Tab>", next_wanting)
  map("<CR>", function()
    if grid.mark then
      return drop()
    end
    M.open(grid.pick)
  end)
  map("o", cycle_sort)
  for lhs, kind in pairs({ m = "move", s = "swap" }) do
    map(lhs, function()
      if grid.mark then
        return drop()
      end
      mark(kind, lhs)
    end)
  end
  map("n", function()
    close_grid()
    M.new()
  end)
  map("a", reply)
  map("i", reply)
  map("r", function()
    M.rename()
  end)
  map("d", function()
    M.delete_selected()
  end)
  map("/", search)
  map("?", help)
  map("]", function()
    turn(1)
  end)
  map("[", function()
    turn(-1)
  end)
  map("q", close_grid)
  map("<Esc>", function()
    if grid.mark then
      grid.mark = nil
      return render_grid()
    end
    if grid.filter then
      return reopen(nil, 1)
    end
    close_grid()
  end)
  for n = 1, 9 do
    map(tostring(n), function()
      answer(n)
    end)
  end
end

open_grid = function(pick, filter, page)
  local view = arrange(filter, page)
  local list = view.slots
  if #list == 0 then
    if filter then
      return open_grid(pick)
    end
    return vim.notify("No chats")
  end
  M.hide()
  vim.cmd.stopinsert()
  local cols, rows = view.cols, view.rows
  local left, card_w, card_h, width, height = geometry(view.commander, cols, rows)
  card_w, card_h = math.max(1, card_w), math.max(1, card_h)
  local function scratch()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    return buf
  end
  grid = {
    slots = {},
    cols = cols,
    rows = rows,
    commander = view.commander ~= nil,
    filter = filter,
    page = view.page,
    pages = view.pages,
    pick = pick or M.last or list[1].count,
  }
  local bg = scratch()
  vim.api.nvim_buf_set_lines(bg, 0, -1, false, vim.fn["repeat"]({ "" }, height))
  grid.bg = vim.api.nvim_open_win(bg, false, {
    relative = "editor",
    row = 0,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    focusable = false,
    zindex = 40,
  })
  for i = 1, #list do
    local buf = scratch()
    local p = i - 1 - (view.commander and 1 or 0)
    local win = vim.api.nvim_open_win(buf, i == 1, {
      relative = "editor",
      row = p < 0 and 1 or 1 + math.floor(p / cols) * (card_h + 3),
      col = p < 0 and 2 or left + 2 + p % cols * (card_w + 4),
      width = p < 0 and left - 4 or card_w,
      height = p < 0 and height - 5 or card_h,
      style = "minimal",
      border = "rounded",
      zindex = 50,
    })
    grid_keys(buf)
    add_patterns(win)
    -- A process-less terminal renders the pane's colour codes; open it after the window so it takes the card's size.
    grid.slots[i] = { buf = buf, win = win, chan = vim.api.nvim_open_term(buf, {}) }
  end
  render_grid()
end

--- Show or hide the grid of all chats.
function M.grid()
  if grid then
    return close_grid()
  end
  open_grid()
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
      height = 0,
      border = "rounded",
      title = " Agents ",
      footer = " n:new r:name d:del ",
      backdrop = false,
      wo = {
        wrap = false,
        cursorline = true,
        scrolloff = 0,
        winhighlight = "FloatBorder:AgentBorder,FloatTitle:AgentAccent3,FloatFooter:Comment",
      },
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
  local state = state_of(win.buf)
  local id = vim.b[win.buf].snacks_terminal.id
  local accent = (id - 1) % #ACCENTS + 1
  win.opts.title = {
    { " " .. glyph(state) .. " " .. state[2] .. " ", state[3] .. "Glow" },
    { " " .. display(win.buf, id):gsub("[\r\n]", " ") .. " ", "AgentAccent" .. accent },
  }
  win.opts.footer = ""
  local highlight = vim.wo[win.win].winhighlight:gsub(",?FloatBorder:[^,]*", ""):gsub("^,", "")
  win.opts.wo.winhighlight = (highlight ~= "" and highlight .. "," or "") .. "FloatBorder:AgentBorder" .. accent
  win.opts.wo.winbar = win.opts.position == "right"
      and (" %d %s · %s %s"):format(id, display(win.buf, id), glyph(state), state[2]):gsub("%%", "%%%%")
    or ""
  local meta = vim.b[win.buf].snacks_terminal
  local budget = require("util.bifrost_budget")
  if budget.is_bifrost(meta) then
    budget.refresh()
    win.opts.footer = " " .. budget.text() .. " "
  end
  win:update()
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

-- On quit, snacks closes the chat terminals one by one; saving then would shrink the list M.restore reads.
-- Registered before any terminal opens, so it runs before snacks' own ExitPre handlers.
local exiting = false
vim.api.nvim_create_autocmd("ExitPre", {
  callback = function()
    exiting = true
  end,
})

--- Remember which chats are open per repo (keyed by each chat's cwd) for M.restore after a reboot.
local function save_open()
  if exiting then
    return
  end
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
  render_grid()
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
local function term_opts(count, session, role)
  return {
    count = count,
    cwd = root(),
    env = { NVIM_TEAM_SESSION = session, NVIM_TEAM_ROLE = role },
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
      height = 0,
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
        add_patterns(self.win)
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
local function spawn(cmd, session, role)
  local n = next_count(chats())
  M.last = n
  session = session or vim.trim(vim.fn.system("uuidgen")):lower()
  local term = Snacks.terminal.open(variant_for(cmd).launch, term_opts(n, session, role))
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
    prompt = "Delete "
      .. display(chat.buf, chat.count)
      .. "? Stops its agents and removes their transcripts; project files stay.",
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
  close_grid()
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
  vim.notify(layout == "right" and "Chats open in a right-hand panel" or "Chats open fullscreen")
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

--- Open the commander chat, reattach one still running in tmux, or start one.
function M.commander()
  for _, c in ipairs(chats()) do
    local rec = record(vim.b[c.buf].snacks_terminal.env.NVIM_TEAM_SESSION)
    if rec and rec.role == "commander" then
      return M.open(c.count)
    end
  end
  local claude = vim.iter(VARIANTS):find(function(v)
    return v.backend == "claude"
  end)
  vim.system({ "python3", SCRIPT, "running" }, { text = true }, function(result)
    vim.schedule(function()
      local ok, running = pcall(vim.json.decode, result.stdout or "")
      local live = ok
        and type(running) == "table"
        and vim.iter(running):find(function(r)
          return r.role == "commander"
        end)
      local term = spawn(claude.cmd, live and live.id or nil, not live and "commander" or nil)
      if term then
        vim.b[term.buf].claude_chat_name = "Commander"
      end
    end)
  end)
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
    if grid then
      local pick = grid.pick
      close_grid()
      open_grid(pick)
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
    Status.poll(list, function(chat, state, active)
      vim.b[chat.buf].claude_chat_active = active
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
