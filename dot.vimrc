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
set autoread
au FocusGained * :checktime

" bind K to grep word under cursor
nnoremap K :Rg <C-R><C-W><CR>
nnoremap L :Rg <CR>
inoremap <expr> <Tab> pumvisible() ? "\<C-n>" : "\<Tab>"
inoremap <expr> <S-Tab> pumvisible() ? "\<C-p>" : "\<S-Tab>"

nnoremap <C-P> :GFiles --cached --others --exclude-standard<CR>
nnoremap <C-B> :Buffers<CR>

" Similarly, we can apply it to fzf#vim#grep. To use ripgrep instead of ag:
command! -bang -nargs=* Rg
  \ call fzf#vim#grep(
  \   'rg --column --line-number --no-heading --color=always --smart-case '.shellescape(<q-args>), 1,
  \   <bang>0 ? fzf#vim#with_preview('up:60%')
  \           : fzf#vim#with_preview('right:50%:hidden', '?'),
  \   <bang>0)
