-- Rendering only reads memory; refreshes happen in a background process.
local M = {}
local value = "Bifrost budget …"
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
        else
          value = "Bifrost budget unavailable"
        end
        vim.cmd.redrawstatus()
      end)
    end
  )
end

function M.text()
  return value
end

function M.is_codex_bifrost()
  local meta = vim.b.snacks_terminal
  return type(meta) == "table" and type(meta.cmd) == "string" and meta.cmd:find("codex-bf", 1, true) ~= nil
end

return M
