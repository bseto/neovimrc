-- Git diff/merge tool: side-by-side diffs of any revision range, plus file history.
-- `<leader>gd` is taken by LazyVim (snacks git-diff picker), so these live under `<leader>gv`.
return {
  "sindrets/diffview.nvim",
  cmd = { "DiffviewOpen", "DiffviewFileHistory", "DiffviewClose", "DiffviewToggleFiles", "DiffviewRefresh" },
  keys = {
    { "<leader>gv", "", desc = "+diffview" },
    { "<leader>gvo", "<cmd>DiffviewOpen<cr>", desc = "Open Diffview" },
    { "<leader>gvc", "<cmd>DiffviewClose<cr>", desc = "Close Diffview" },
    { "<leader>gvh", "<cmd>DiffviewFileHistory %<cr>", desc = "File History (current file)" },
    { "<leader>gvH", "<cmd>DiffviewFileHistory<cr>", desc = "File History (repo)" },
  },
  opts = {
    enhanced_diff_hl = true,
    view = {
      merge_tool = { layout = "diff3_mixed" },
    },
  },
}
