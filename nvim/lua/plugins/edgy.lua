-- Configure edgy.nvim to allow resizable sidebars
return {
  "folke/edgy.nvim",
  opts = {
    -- Enable animated resizing
    animate = {
      enabled = false, -- Set to true if you want smooth animation
    },
    -- Configure the right sidebar (outline, etc.)
    right = {
      {
        title = "Outline",
        ft = "Outline",
        pinned = true,
        size = { width = 0.2 }, -- 20% of screen width, adjustable
        open = "Outline",
      },
      {
        title = "Database",
        ft = "dbui",
        pinned = true,
        size = { width = 0.2 },
        open = "DBUI",
      },
      {
        title = "DB Query",
        ft = "dbout",
        size = { height = 0.4 },
      },
    },
    -- Keys for resizing edgy windows (when focused on edgy sidebar)
    keys = {
      -- Use H/L for resizing when in edgy window
      ["H"] = function(win)
        win:resize("width", -2)
      end,
      ["L"] = function(win)
        win:resize("width", 2)
      end,
      ["K"] = function(win)
        win:resize("height", 2)
      end,
      ["J"] = function(win)
        win:resize("height", -2)
      end,
    },
    options = {
      right = {
        size = 40, -- Default width in columns
      },
    },
  },
}
