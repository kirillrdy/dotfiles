call plug#begin()

Plug 'dense-analysis/ale'
Plug 'tpope/vim-fugitive'
Plug 'scrooloose/nerdtree'
Plug 'junegunn/fzf', { 'dir': '~/.fzf', 'do': './install --all' }
Plug 'junegunn/fzf.vim'
Plug 'airblade/vim-rooter'
Plug 'arcticicestudio/nord-vim'
Plug 'leafgarland/typescript-vim'
Plug 'peitalin/vim-jsx-typescript'
Plug 'LnL7/vim-nix'

call plug#end()

set tabstop=2
set shiftwidth=2
set expandtab
set noswapfile
set number
set relativenumber
set autoread
set nowb
au FocusGained * :checktime

" bind K to grep word under cursor
nnoremap <C-K> :Ag <C-R><C-W><CR>
nnoremap L :Ag <CR>
nnoremap <F2> :NERDTreeFind <CR>
nnoremap <F3> :NERDTreeToggle <CR>
nnoremap <F4> :ALEFindReferences <CR>
nnoremap <F5> :ALENext <CR>

nnoremap <C-P> :GFiles --cached --others --exclude-standard<CR>
nnoremap <C-B> :Buffers<CR>
nnoremap <C-H> :History<CR>
nnoremap <C-X> :bufdo bwipeout<CR>
nnoremap <silent> gd :ALEGoToDefinition<CR>

let g:ale_completion_enabled = 1
let g:ale_linters = {}
let g:ale_linters.go = ['gopls', 'golangci-lint']
let g:ale_linters.rust = ['analyzer', 'cargo', 'rustc']
let g:ale_fixers = {'*': ['remove_trailing_lines', 'trim_whitespace']}
let g:ale_fixers.go = ['gofmt']
let g:ale_fixers.rust = ['rustfmt']
let g:ale_fix_on_save = 1

inoremap <silent><expr> <Tab>
      \ pumvisible() ? "\<C-n>" : "\<TAB>"
