call plug#begin()

Plug 'dense-analysis/ale'

" rust
Plug 'rust-lang/rust.vim'
Plug 'racer-rust/vim-racer'
Plug 'roxma/nvim-cm-racer'

Plug 'tpope/vim-fugitive'
Plug 'scrooloose/nerdtree'
Plug 'junegunn/fzf', { 'dir': '~/.fzf', 'do': './install --all' }
Plug 'junegunn/fzf.vim'

Plug 'mxw/vim-jsx'
Plug 'airblade/vim-rooter'

Plug 'arcticicestudio/nord-vim'

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

nnoremap <C-P> :GFiles --cached --others --exclude-standard<CR>
nnoremap <C-B> :Buffers<CR>
nnoremap <C-H> :History<CR>
nnoremap <C-X> :bufdo bwipeout<CR>
nnoremap <silent> gd :ALEGoToDefinition<CR>

"let g:mix_format_on_save = 1
"let g:rustfmt_autosave = 1

let g:ale_completion_enabled = 1
let g:ale_linters = {}
let g:ale_linters.elixir = ['credo', 'dialyxir', 'dogma', 'elixir-ls', 'mix']
let g:ale_linters.go = ['gopls', 'golint']
let g:ale_fixers = {'*': ['remove_trailing_lines', 'trim_whitespace']}
let g:ale_fixers.elixir = ['mix_format']
let g:ale_fixers.go = ['gofmt']
let g:ale_fix_on_save = 1

let g:ale_elixir_elixir_ls_release = '/home/kirillvr/elixir-ls/rel'

" Similarly, we can apply it to fzf#vim#grep. To use ripgrep instead of ag:
command! -bang -nargs=* Rg
  \ call fzf#vim#grep(
  \   'rg --column --line-number --no-heading --color=always --smart-case '.shellescape(<q-args>), 1,
  \   <bang>0 ? fzf#vim#with_preview('up:60%')
  \           : fzf#vim#with_preview('right:50%:hidden', '?'),
  \   <bang>0)
