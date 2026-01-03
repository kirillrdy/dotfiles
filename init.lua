vim.opt.relativenumber = true
vim.opt.clipboard = "unnamedplus"
vim.cmd('colorscheme kanagawa')

vim.g.mapleader = " "

local builtin = require('telescope.builtin')
vim.keymap.set('n', '<leader>f', builtin.git_files, {})
vim.keymap.set('n', '<leader>pf', builtin.find_files, {})
vim.keymap.set('n', '<leader>s', function() builtin.lsp_document_symbols { symbol_width = 50 } end, {})
vim.keymap.set('n', '<leader>c', builtin.commands, {})
vim.keymap.set('n', '<leader>t', builtin.treesitter, {})
vim.keymap.set('n', '<leader>d', function() builtin.diagnostics({ bufnr = 0 }) end, {})
vim.keymap.set('n', '<leader>D', vim.diagnostic.open_float, {})
vim.keymap.set('n', 'gd', builtin.lsp_definitions, {})
vim.keymap.set('n', 'gr', builtin.lsp_references, {})
vim.keymap.set('n', 'gi', builtin.lsp_implementations, {})
vim.keymap.set('n', '<leader>b', builtin.buffers, {})
vim.keymap.set('n', '<C-g>', builtin.grep_string, {})
vim.keymap.set('n', 'L', builtin.live_grep, {})
vim.keymap.set('n', 'z=', builtin.spell_suggest, {})
vim.keymap.set("n", "<leader>ca", vim.lsp.buf.code_action, {})
vim.keymap.set("n", "<leader>rn", vim.lsp.buf.rename, {})
vim.keymap.set("i", "<C-h>", vim.lsp.buf.signature_help, {})

vim.diagnostic.config({ virtual_text = { current_line = true } })
vim.api.nvim_create_autocmd("BufWritePre", { callback = function() vim.lsp.buf.format() end })

local cmp = require('cmp')
cmp.setup({
	sources = { { name = 'nvim_lsp', keyword_length = 2 }, { name = 'path' }, { name = 'buffer', keyword_length = 2 } },
	mapping = cmp.mapping.preset.insert({
		['<CR>'] = cmp.mapping.confirm({ select = true }),
		['<Up>'] = cmp.mapping.select_prev_item(),
		['<Down>'] = cmp.mapping.select_next_item(),
	}),
	window = {
		completion = cmp.config.window.bordered(),
		documentation = cmp.config.window.bordered()
	},
})

vim.lsp.config('gopls', { cmd_env = { GOOS = "js", GOARCH = "wasm" } })
vim.lsp.config('golangci_lint_ls', { cmd_env = { GOOS = "js", GOARCH = "wasm" } })
vim.lsp.config('nil_ls', { settings = { ['nil'] = { formatting = { command = { "nixfmt" } } } } })

local lsps = { "pyrefly", "golangci_lint_ls", "gopls", "lua_ls", "nil_ls", "pyright", "rubocop", "ts_ls", "zls",
	'superhtml' }
for _, name in ipairs(lsps) do
	vim.lsp.enable(name)
end

vim.api.nvim_create_autocmd('FileType', {
  pattern = { 'c', 'cpp', 'go', 'javascript', 'just', 'nix', 'lua', 'python', 'ruby', 'sql', 'terraform', 'typescript', 'zig' },
  callback = function() vim.treesitter.start() end,
})
