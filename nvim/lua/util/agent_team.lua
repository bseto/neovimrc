-- Durable team records live outside Neovim; this buffer only displays them.
local M = {}
local view, timer, page, rows
local records = {}
local busy = false
local managing = false
local archived = false
local directory = vim.env.NVIM_TEAM_HOME or (vim.fn.expand("~") .. "/.local/state/nvim/agent-teams")
local script = vim.fn.stdpath("config") .. "/scripts/agent-team.py"

local function clean(value)
  return tostring(value or ""):gsub("[%c]", " ")
end

local function find(id)
  for _, record in ipairs(records) do
    if record.id == id then
      return record
    end
  end
end

local function read(path)
  local file = io.open(path, "r")
  if not file then
    return {}
  end
  local content = file:read("*a")
  file:close()
  return vim.split(content, "\n", { plain = true })
end

local function render()
  if not (view and view:win_valid()) then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(view.win)
  local selected = rows and rows[cursor[1]]
  local lines = {}
  rows = {}
  local function add(record, prefix)
    lines[#lines + 1] = string.format(
      "%-38s %-10s %-18s %s",
      prefix .. clean(record.name),
      clean(record.kind or record.backend),
      clean(record.status),
      clean(record.message ~= "" and record.message or record.task)
    )
    rows[#lines] = record.id
  end
  local current = page and find(page)
  if current then
    lines = {
      clean(current.name) .. " · " .. clean(current.backend) .. " · " .. clean(current.status),
      "h parent · i supervisor · y copy takeover · a archive/restore · d delete · A active/archived · q close",
      "",
    }
    for _, record in ipairs(records) do
      if record.role == "worker" and record.parent == current.id then
        add(record, "  ↳ ")
      end
    end
    lines[#lines + 1] = ""
    if current.role == "supervisor" then
      lines[#lines + 1] = "Project brief (i opens the live supervisor conversation)"
      vim.list_extend(lines, vim.split(current.brief or "", "\n", { plain = true }))
      lines[#lines + 1] = ""
      lines[#lines + 1] = "Handoff · " .. clean(current.execution or "planning")
      lines[#lines + 1] = "Phase: " .. clean(current.phase or "planning")
      if current.plan_path then
        lines[#lines + 1] = "Plan: " .. clean(current.plan_path)
      end
      local age = current.checkpoint_at and math.max(0, os.time() - math.floor(current.checkpoint_at))
      lines[#lines + 1] = age and ("Last checkpoint: " .. math.floor(age / 60) .. "m ago")
        or "Last checkpoint: never"
      vim.list_extend(lines, vim.split(current.handoff or "No handoff saved yet.", "\n", { plain = true }))
      lines[#lines + 1] = ""
      lines[#lines + 1] = "$supervise-takeover " .. current.id .. " (Codex)"
      lines[#lines + 1] = "/supervise-takeover " .. current.id .. " (Claude)"
    else
      lines[#lines + 1] = "Conversation"
      vim.list_extend(lines, read(directory .. "/" .. current.id .. "/chat.md"))
      if current.status == "error" or current.status == "interrupted" or current.status == "blocked" then
        lines[#lines + 1] = "Backend log"
        vim.list_extend(lines, read(directory .. "/" .. current.id .. "/backend.log"))
      end
    end
  else
    page = nil
    lines = {
      archived and "Teams (archived)" or "Teams",
      "j/k select · l inspect · i chat · y copy takeover · a archive/restore · d delete · A active/archived · q close",
      "",
      string.format("%-38s %-10s %-18s %s", "Agent", "Backend", "State", "Task / update"),
    }
    for _, record in ipairs(records) do
      if
        (record.role == "supervisor" or (archived and record.role == "chat"))
        and (record.archived == true) == archived
      then
        add(record, "▾ ")
        for _, child in ipairs(records) do
          if child.role == "worker" and child.parent == record.id then
            add(child, "  ↳ ")
          end
        end
      end
    end
    if #lines == 4 then
      lines[#lines + 1] = archived and "No archived teams. A returns to active teams."
        or "No active teams. A shows archives; /supervise in Claude or $supervise in Codex starts a team."
    end
  end
  vim.bo[view.buf].modifiable = true
  vim.api.nvim_buf_set_lines(view.buf, 0, -1, false, lines)
  vim.bo[view.buf].modifiable = false
  local row = math.min(cursor[1], #lines)
  if selected then
    for index, id in pairs(rows) do
      if id == selected then
        row = index
      end
    end
  end
  vim.api.nvim_win_set_cursor(view.win, { math.max(1, row), 0 })
end

local function refresh()
  if busy or managing or not (view and view:win_valid()) then
    return
  end
  busy = true
  vim.system({ "python3", script, "snapshot" }, { text = true }, function(result)
    vim.schedule(function()
      busy = false
      if result.code == 0 then
        local ok, value = pcall(vim.json.decode, result.stdout)
        if ok then
          records = value
          render()
        end
      else
        vim.notify("Team view: " .. result.stderr, vim.log.levels.ERROR)
      end
    end)
  end)
end

function M.hide()
  if view then
    view:hide()
  end
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
end

local function selected()
  return rows and rows[vim.api.nvim_win_get_cursor(view.win)[1]]
end

local function copy_takeover()
  local record = find(selected() or page)
  record = record and (record.parent and find(record.parent) or record)
  if not record or record.role ~= "supervisor" then
    vim.notify("Select a team first", vim.log.levels.INFO)
    return
  end
  local owner = find(record.owner) or record
  local prefix = (owner.backend or ""):match("^claude") and "/" or "$"
  local command = prefix .. "supervise-takeover " .. record.id
  vim.fn.setreg('"', command)
  if vim.fn.has("clipboard") == 1 then
    vim.fn.setreg("+", command)
  end
  vim.notify("Copied: " .. command)
end

local function move(direction)
  local row = vim.api.nvim_win_get_cursor(view.win)[1]
  if page then
    vim.api.nvim_win_set_cursor(
      view.win,
      { math.max(1, math.min(vim.api.nvim_buf_line_count(view.buf), row + direction)), 0 }
    )
    return
  end
  repeat
    row = row + direction
  until rows[row] or row < 1 or row > vim.api.nvim_buf_line_count(view.buf)
  if rows[row] then
    vim.api.nvim_win_set_cursor(view.win, { row, 0 })
  end
end

local function enter()
  local id = selected()
  if id then
    page = id
    rows = {}
    vim.api.nvim_win_set_cursor(view.win, { 1, 0 })
    render()
  elseif page and find(page).role == "supervisor" then
    local record = find(page)
    M.hide()
    require("util.claude").open_session(find(record.owner) or record)
  end
end

local function chat()
  local record = find(selected() or page)
  if not record then
    return
  end
  -- Keep one sender: user instructions go through the supervisor, which owns
  -- the worker's context and sees every revision.
  record = record.parent and find(record.parent) or record
  M.hide()
  require("util.claude").open_session(find(record.owner) or record)
end

function M.manage(action, target)
  if managing then
    return
  end
  local record = target or find(selected() or page)
  record = record and (record.team_id and find(record.team_id) or record)
  record = record and (record.parent and find(record.parent) or record)
  if not record then
    vim.notify("Select a team first", vim.log.levels.INFO)
    return
  end
  if action == "archive" and record.archived then
    action = "restore"
  end
  local function run()
    managing = true
    vim.system({ "python3", script, "manage", action, "--agent", record.id }, { text = true }, function(result)
      vim.schedule(function()
        managing = false
        if result.code ~= 0 then
          vim.notify("Team " .. action .. " failed: " .. (result.stderr or ""), vim.log.levels.ERROR)
          return
        end
        page = nil
        rows = {}
        local chats = require("util.claude")
        if chats.after_manage then
          local ok, value = pcall(vim.json.decode, result.stdout or "")
          chats.after_manage(record.id, action, ok and value.chat_ids or nil)
        end
        refresh()
      end)
    end)
  end
  if action == "delete" then
    vim.ui.select({ "Cancel", "Delete team" }, {
      prompt = "Delete "
        .. clean(record.name)
        .. "? Stops its agents and removes team transcripts; project files stay.",
    }, function(choice)
      if choice == "Delete team" then
        run()
      end
    end)
  else
    run()
  end
end

function M.toggle(show_archived)
  if show_archived ~= nil then
    archived = show_archived
    page = nil
    rows = {}
    if view and view:win_valid() then
      render()
      return
    end
  end
  if view and view:win_valid() then
    return M.hide()
  end
  require("util.claude").hide()
  view = Snacks.win({
    position = "float",
    width = 0.9,
    height = 0.9,
    border = "rounded",
    title = " Teams ",
    bo = { filetype = "agent_team", buftype = "nofile", modifiable = false },
    wo = { wrap = false, cursorline = true },
    keys = {
      q = M.hide,
      ["<Esc>"] = M.hide,
      ["<leader>ct"] = M.hide,
      j = function()
        move(1)
      end,
      k = function()
        move(-1)
      end,
      l = enter,
      ["<CR>"] = enter,
      h = function()
        local current = page and find(page)
        page = current and current.parent or nil
        rows = {}
        render()
      end,
      i = chat,
      y = copy_takeover,
      a = function()
        M.manage("archive")
      end,
      d = function()
        M.manage("delete")
      end,
      A = function()
        archived = not archived
        page = nil
        rows = {}
        render()
      end,
    },
    on_close = function()
      if timer then
        timer:stop()
        timer:close()
        timer = nil
      end
    end,
  })
  render()
  timer = vim.uv.new_timer()
  timer:start(0, 1000, vim.schedule_wrap(refresh))
end

return M
