-- Chats that need you: !N waiting, *N unread.
local function text()
  -- Don't load util.claude (and start its timer) before the first chat exists.
  local chat = package.loaded["util.claude"]
  if not chat then
    return ""
  end
  local waiting, unread = chat.attention()
  local parts = {}
  if #waiting > 0 then
    parts[#parts + 1] = "!" .. #waiting
  end
  if #unread > 0 then
    parts[#parts + 1] = "*" .. #unread
  end
  return table.concat(parts, " ")
end

return {
  "nvim-lualine/lualine.nvim",
  opts = function(_, opts)
    table.insert(opts.sections.lualine_x, 1, {
      text,
      cond = function()
        return text() ~= ""
      end,
      color = function()
        return { fg = Snacks.util.color("DiagnosticWarn") }
      end,
    })
  end,
}
