vim.opt.nu = true
vim.opt.relativenumber = true
vim.opt.tabstop = 2
vim.opt.softtabstop = 2
vim.opt.shiftwidth = 2
vim.opt.expandtab = true
vim.opt.smartindent = true
vim.opt.swapfile = false
vim.opt.backup = false
vim.opt.hlsearch = true
vim.opt.incsearch = true
vim.opt.termguicolors = true
vim.opt.signcolumn = "yes"
vim.opt.isfname:append("@-@")
vim.opt.autoread = true;

vim.cmd('colorscheme nord')
vim.api.nvim_create_autocmd({ "FocusGained" }, {
  pattern = { "*" },
  command = ":checktime",
})

vim.g.mapleader = " "

local builtin = require('telescope.builtin')
vim.keymap.set('n', '<leader>pf', builtin.find_files, {})
vim.keymap.set('n', '<leader>s', function() builtin.lsp_document_symbols { symbol_width = 60 } end, {})
vim.keymap.set('n', '<leader>c', builtin.commands, {})
vim.keymap.set('n', '<leader>t', builtin.treesitter, {})
vim.keymap.set('n', '<leader>e', function() builtin.diagnostics({ bufnr = 0 }) end, {})
vim.keymap.set('n', 'gd', builtin.lsp_definitions, {})
vim.keymap.set('n', 'gr', builtin.lsp_references, {})
vim.keymap.set('n', 'gi', builtin.lsp_implementations, {})
vim.keymap.set('n', 'gn', vim.diagnostic.goto_next, {})
vim.keymap.set('n', '<C-p>', builtin.git_files, {})
vim.keymap.set('n', '<C-b>', builtin.buffers, {})
vim.keymap.set('n', '<C-g>', builtin.grep_string, {})
vim.keymap.set('n', 'L', builtin.live_grep, {})
vim.keymap.set('n', 'z=', builtin.spell_suggest, {})

local nvim_lsp = require('lspconfig')

local on_attach = function(client, bufnr)
  vim.api.nvim_create_autocmd("BufWritePre", {
    buffer = bufnr,
    callback = function() vim.lsp.buf.format() end,
  })
  local opts = { buffer = bufnr, remap = false }
  vim.keymap.set("n", "K", vim.lsp.buf.hover, opts)
  vim.keymap.set("n", "[d", vim.diagnostic.goto_next, opts)
  vim.keymap.set("n", "]d", vim.diagnostic.goto_prev, opts)
  vim.keymap.set("n", "<leader>ca", vim.lsp.buf.code_action, opts)
  vim.keymap.set("n", "<leader>rn", vim.lsp.buf.rename, opts)
  vim.keymap.set("n", "<leader>f", vim.lsp.buf.format, opts)
  vim.keymap.set("i", "<C-h>", vim.lsp.buf.signature_help, opts)
end

local cmp = require('cmp')
cmp.setup({
  sources = { { name = 'nvim_lsp', keyword_length = 2 }, { name = 'path' }, { name = 'buffer', keyword_length = 2 }},
  mapping = cmp.mapping.preset.insert({
    ['<CR>'] = cmp.mapping.confirm({ select = true }),
    ['<Up>'] = cmp.mapping.select_prev_item(),
    ['<Down>'] = cmp.mapping.select_next_item(),
  }),
  window = {
    documentation = cmp.config.window.bordered()
  },
})

local servers = { "zls", "clangd", "pyright", "rubocop", "templ", "rust_analyzer", "tsserver", "ruff_lsp", "lua_ls", force = true }
for _, server in ipairs(servers) do
  nvim_lsp[server].setup { on_attach = on_attach }
end

nvim_lsp.gopls.setup { on_attach = on_attach, cmd_env = { GOOS = "js", GOARCH = "wasm" } }
nvim_lsp.golangci_lint_ls.setup { on_attach = on_attach, cmd_env = { GOOS = "js", GOARCH = "wasm" } }

nvim_lsp.nil_ls.setup {
    on_attach = on_attach,
    settings = {
      ['nil'] = {
        testSetting = 42,
        formatting = {
          command = { "nixfmt" },
        },
      },
    },
}

require 'nvim-treesitter.configs'.setup {
  sync_install = false,
  highlight = { enable = true, additional_vim_regex_highlighting = false },
}
