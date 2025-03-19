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
vim.opt.clipboard = "unnamedplus"

vim.cmd('colorscheme kanagawa')
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
vim.keymap.set('n', '<leader>d', function() builtin.diagnostics({ bufnr = 0 }) end, {})
vim.keymap.set('n', 'gd', builtin.lsp_definitions, {})
vim.keymap.set('n', 'gr', builtin.lsp_references, {})
vim.keymap.set('n', 'gi', builtin.lsp_implementations, {})
vim.keymap.set('n', '<leader>f', builtin.git_files, {})
vim.keymap.set('n', '<leader>b', builtin.buffers, {})
vim.keymap.set('n', '<C-g>', builtin.grep_string, {})
vim.keymap.set('n', 'L', builtin.live_grep, {})
vim.keymap.set('n', 'z=', builtin.spell_suggest, {})

local on_attach = function(autoformat)
  return function(client, bufnr)
    if autoformat == true then
      vim.api.nvim_create_autocmd("BufWritePre", {
        buffer = bufnr,
        callback = function() vim.lsp.buf.format() end,
      })
    end
    local opts = { buffer = bufnr, remap = false }
    vim.keymap.set("n", "K", vim.lsp.buf.hover, opts)
    vim.keymap.set("n", "[d", vim.diagnostic.goto_next, opts)
    vim.keymap.set("n", "]d", vim.diagnostic.goto_prev, opts)
    vim.keymap.set("n", "<leader>ca", vim.lsp.buf.code_action, opts)
    vim.keymap.set("n", "<leader>rn", vim.lsp.buf.rename, opts)
    vim.keymap.set("n", "<leader>=", vim.lsp.buf.format, opts)
    vim.keymap.set("i", "<C-h>", vim.lsp.buf.signature_help, opts)
  end
end

local cmp = require('cmp')
cmp.setup({
  sources = { { name = 'nvim_lsp', keyword_length = 2 }, { name = 'path' }, { name = 'buffer', keyword_length = 2 } },
  mapping = cmp.mapping.preset.insert({
    ['<CR>'] = cmp.mapping.confirm({ select = true }),
    ['<Up>'] = cmp.mapping.select_prev_item(),
    ['<Down>'] = cmp.mapping.select_next_item(),
  }),
  window = {
    documentation = cmp.config.window.bordered()
  },
})

local nvim_lsp = require('lspconfig')
local servers = {
  "ts_ls",
  "zls",
  "clangd",
  "pyright",
  "rubocop",
  "templ",
  "rust_analyzer",
  "lua_ls",
  "terraformls",
  force = true
}
for _, server in ipairs(servers) do
  nvim_lsp[server].setup { on_attach = on_attach(true) }
end

local go_options = { on_attach = on_attach(true), cmd_env = { GOOS = "js", GOARCH = "wasm" } }

nvim_lsp.gopls.setup(go_options)
nvim_lsp.golangci_lint_ls.setup(go_options)

nvim_lsp.nil_ls.setup {
  on_attach = on_attach(false),
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
