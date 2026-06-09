-- Keep terraform-ls's very chatty indexing logs out of Neovim's lsp.log.
--
-- By default terraform-ls writes its module-discovery walk to stderr, and
-- Neovim records every LSP server stderr line into ~/.local/state/nvim/lsp.log
-- at [ERROR] level. In a large repo (lots of vendored .terraform/modules) this
-- balloons lsp.log to multiple GB. The `-log-file` flag redirects terraform-ls's
-- own logging to a per-process file in /tmp (cleared on reboot) instead.
return {
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        terraformls = {
          cmd = { "terraform-ls", "serve", "-log-file", "/tmp/terraform-ls-{{.Pid}}.log" },
        },
      },
    },
  },
}
