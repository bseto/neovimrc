-- Multiple Claude Code chats via snacks.nvim floating terminals.
--
-- Each chat is a `claude` terminal distinguished by snacks' `count` field
-- (1, 2, 3...). snacks tracks terminals by {cmd, cwd, count}, so reusing the
-- same cmd + cwd and only varying `count` gives us stable, addressable chats.
-- Open chats are discovered by scanning buffers for the `b:snacks_terminal`
-- marker, which keeps the picker/footers accurate regardless of window state.
--
-- Each chat carries an optional custom name in `b:claude_chat_name` (the
-- variable lives and dies with the chat's buffer). Every float lists all open
-- chats along the bottom border (footer) as "N. name", with the chat you're
-- currently in highlighted. `<leader>c<N>` jumps straight to chat N.

local M = {}

-- Launch command. Mirrors the flags the old greggh/claude-code.nvim setup used.
local CMD = "claude --enable-auto-mode"

-- Number of the chat most recently opened/focused, used by toggle_last().
M.last = nil

--- Resolve the git root (falls back to cwd) so chats open at the project root,
--- matching the old `git.use_git_root = true` behaviour.
--- @return string
local function root()
  return vim.fs.root(0, ".git") or vim.uv.cwd()
end

--- Human-facing name for a chat buffer: the custom name if set, else "Chat N".
--- @param buf integer
--- @param count integer?
--- @return string
local function display(buf, count)
  local name = vim.b[buf] and vim.b[buf].claude_chat_name
  if type(name) == "string" and name ~= "" then
    return name
  end
  local meta = vim.b[buf] and vim.b[buf].snacks_terminal
  return "Chat " .. tostring(count or (meta and meta.id) or "?")
end

--- List currently-open Claude chats, sorted by chat number.
--- Scans every buffer for the `b:snacks_terminal` marker snacks sets on
--- terminal buffers, then keeps the ones running our `claude` command.
--- @return { count: integer, buf: integer }[]
local function chats()
  local out = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      local ok, meta = pcall(function()
        return vim.b[buf].snacks_terminal
      end)
      if ok and type(meta) == "table" and meta.cmd == CMD then
        out[#out + 1] = { count = meta.id, buf = buf }
      end
    end
  end
  table.sort(out, function(a, b)
    return (a.count or 0) < (b.count or 0)
  end)
  return out
end

--- Footer content for a chat: every open chat as "N. name", with the chat
--- this footer belongs to (`buf`) highlighted. Returns "" when there are no
--- chats (shouldn't happen for an open window).
--- @param buf integer
--- @return string|table
local function footer_for(buf)
  local chunks = {}
  for _, c in ipairs(chats()) do
    local label = ("%d. %s"):format(c.count, display(c.buf, c.count))
    local hl = (c.buf == buf) and "PmenuSel" or "Comment"
    chunks[#chunks + 1] = { "  " .. label .. "  ", hl }
  end
  return #chunks > 0 and chunks or ""
end

--- Apply the footer (all chats, current highlighted) to a chat window, and
--- clear the title. Safe to call on any snacks.win; no-ops if the window is
--- gone.
--- @param win snacks.win
local function refresh(win)
  if not (win and win.win_valid and win:win_valid()) then
    return
  end
  win.opts.title = ""
  win.opts.footer = footer_for(win.buf)
  win.opts.footer_pos = "center"
  win:update()
end

--- Refresh title + footer on every open chat window. Called after the set of
--- chats changes (new, rename, close) so footers stay accurate even for
--- already-visible floats (which don't re-run on_win).
function M.refresh_all()
  for _, t in ipairs(Snacks.terminal.list()) do
    local meta = vim.b[t.buf] and vim.b[t.buf].snacks_terminal
    if type(meta) == "table" and meta.cmd == CMD then
      refresh(t)
    end
  end
end

--- snacks terminal opts for a given chat number. Must stay deterministic on
--- {cmd, cwd, count}: snacks derives a terminal's identity from those, so the
--- same `count` always maps to the same chat. `win.on_win` (not part of the
--- identity) renders the title/footer on open and on every reopen-from-hidden.
--- @param count integer
--- @return snacks.terminal.Opts
local function term_opts(count)
  return {
    count = count,
    cwd = root(),
    win = {
      position = "float",
      width = 0.9,
      height = 0.9,
      border = "rounded",
      footer_pos = "center",
      on_win = function(self)
        refresh(self)
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

--- Open a brand-new (unnamed) chat in the next free slot.
function M.new()
  local n = next_count(chats())
  M.last = n
  local term = Snacks.terminal.toggle(CMD, term_opts(n))
  -- Keep other chats' footers in sync when this one opens or later closes.
  if term then
    term:on("TermClose", function()
      vim.schedule(M.refresh_all)
    end, { buf = true })
  end
  vim.schedule(M.refresh_all)
end

--- Show and focus an existing chat by number.
--- @param count integer
function M.open(count)
  M.last = count
  -- NOTE: snacks keeps terminal handles in a weak table. In the rare case a
  -- hidden chat's handle was garbage-collected while its buffer survives,
  -- focus() may spawn a fresh process instead of reattaching. Unlikely in
  -- practice (the live buffer keeps the handle referenced).
  return Snacks.terminal.focus(CMD, term_opts(count))
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
  vim.notify("No Claude chat " .. n, vim.log.levels.WARN)
end

--- Toggle the most-recently-used chat, creating Chat 1 if none exist.
function M.toggle_last()
  local list = chats()
  if #list == 0 then
    return M.new()
  end
  local count = M.last or list[1].count
  M.last = count
  return Snacks.terminal.toggle(CMD, term_opts(count))
end

--- Pick an open chat (by name) or create a new one via vim.ui.select.
function M.pick()
  local list = chats()
  local items = {}
  for _, c in ipairs(list) do
    items[#items + 1] = { count = c.count, label = display(c.buf, c.count) }
  end
  items[#items + 1] = { count = nil, label = "＋ New chat" }

  vim.ui.select(items, {
    prompt = "Claude chats",
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
  local buf = vim.api.nvim_get_current_buf()
  local meta = vim.b[buf] and vim.b[buf].snacks_terminal
  if not (type(meta) == "table" and meta.cmd == CMD) then
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
      vim.notify("No Claude chat to rename", vim.log.levels.WARN)
      return
    end
  end

  vim.ui.input({
    prompt = "Chat name (empty to reset): ",
    default = vim.b[buf].claude_chat_name or "",
  }, function(input)
    if input == nil then
      return
    end
    vim.b[buf].claude_chat_name = (input ~= "" and input) or nil
    M.refresh_all()
  end)
end

return M
