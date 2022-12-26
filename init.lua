

return require('packer').startup(function(use)
  use 'wbthomason/packer.nvim'

  use {
 	  'nvim-telescope/telescope.nvim', tag = '0.1.0',
 	  requires = { {'nvim-lua/plenary.nvim'} }
   }
 
   use({
 	  'rose-pine/neovim',
 	  as = 'rose-pine',
 	  config = function()
 		  vim.cmd('colorscheme rose-pine')
 	  end
   })
 
   use({'nvim-treesitter/nvim-treesitter', run = ':TSUpdate'})
   use('nvim-treesitter/playground')
   use('tpope/vim-fugitive')
 
   use {
 	  'VonHeikemen/lsp-zero.nvim',
 	  requires = {
 		  -- LSP Support
 		  {'neovim/nvim-lspconfig'},
 		  {'williamboman/mason.nvim'},
 		  {'williamboman/mason-lspconfig.nvim'},
 
 		  -- Autocompletion
 		  {'hrsh7th/nvim-cmp'},
 		  {'hrsh7th/cmp-buffer'},
 		  {'hrsh7th/cmp-path'},
 		  {'saadparwaiz1/cmp_luasnip'},
 		  {'hrsh7th/cmp-nvim-lsp'},
 		  {'hrsh7th/cmp-nvim-lua'},
 
 		  -- Snippets
 		  {'L3MON4D3/LuaSnip'},
 		  {'rafamadriz/friendly-snippets'},
 	  }
   }
 
   use("folke/zen-mode.nvim")
end)
