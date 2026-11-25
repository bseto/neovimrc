-- Rendering only reads memory; refreshes happen in a background process.
local M = {}
local value = "Bifrost budget …"
local spend
local checked = 0
local busy = false

function M.refresh()
  if busy or os.time() - checked < 60 then
    return
  end
  busy = true
  checked = os.time()
  vim.system(
    { "python3", vim.fn.stdpath("config") .. "/scripts/bifrost-budget.py", "--json" },
    { text = true },
    function(result)
      vim.schedule(function()
        busy = false
        local ok, data = pcall(vim.json.decode, result.stdout or "")
        if result.code == 0 and ok and type(data) == "table" and type(data.text) == "string" then
          value = data.text:gsub("[%c]", " ")
          local parts = {}
          for _, b in ipairs(type(data.budgets) == "table" and data.budgets or {}) do
            table.insert(parts, ("$%.0f spent / $%.0f left (%s)"):format(b.used, b.remaining, b.period))
          end
          spend = #parts > 0 and "bifrost " .. table.concat(parts, " | ") or nil
        else
          value = "Bifrost budget unavailable"
          spend = nil
        end
        vim.cmd.redrawstatus()
      end)
    end
  )
end

function M.text()
  return value
end

--- Compact spend text for the grid usage bar, or nil without data.
function M.spend()
  return spend
end

--- True for chats launched as claude-bf or codex-bf.
function M.is_bifrost(meta)
  meta = meta or vim.b.snacks_terminal
  if type(meta) ~= "table" or type(meta.cmd) ~= "string" then
    return false
  end
  return meta.cmd:find("codex-bf", 1, true) ~= nil or meta.cmd:find("claude-bf", 1, true) ~= nil
end

return M
