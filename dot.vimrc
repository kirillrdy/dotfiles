call plug#begin()

Plug 'w0rp/ale'
Plug 'fatih/vim-go'

" rust
Plug 'rust-lang/rust.vim'
Plug 'racer-rust/vim-racer'
Plug 'roxma/nvim-cm-racer'

Plug 'roxma/nvim-completion-manager'
Plug 'tpope/vim-fugitive'
Plug 'kchmck/vim-coffee-script'
Plug 'iCyMind/NeoSolarized'
Plug 'slim-template/vim-slim'
Plug 'scrooloose/nerdtree'
Plug 'junegunn/fzf', { 'dir': '~/.fzf', 'do': './install --all' }
Plug 'junegunn/fzf.vim'

call plug#end()

set background=dark
colorscheme NeoSolarized

set tabstop=2
set shiftwidth=2
set expandtab
set noswapfile
set number
set relativenumber

" bind K to grep word under cursor
nnoremap K :Ag <C-R><C-W><CR>
nnoremap L :Ag <CR>
inoremap <expr> <Tab> pumvisible() ? "\<C-n>" : "\<Tab>"
inoremap <expr> <S-Tab> pumvisible() ? "\<C-p>" : "\<S-Tab>"

nnoremap <C-P> :GFiles<CR>
nnoremap <C-B> :Buffers<CR>
