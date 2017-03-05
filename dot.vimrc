call plug#begin()

Plug 'Valloric/YouCompleteMe'
" Plug 'ctrlpvim/ctrlp.vim'
Plug 'kien/ctrlp.vim'
Plug 'scrooloose/syntastic'
Plug 'fatih/vim-go'
Plug 'phildawes/racer'
Plug 'tpope/vim-fugitive'
Plug 'junegunn/gv.vim'
Plug 'altercation/vim-colors-solarized'
Plug 'kchmck/vim-coffee-script'
Plug 'junegunn/fzf.vim'
Plug 'FelikZ/ctrlp-py-matcher'
Plug 'scrooloose/nerdtree'
Plug 'jceb/vim-orgmode'
Plug 'rust-lang/rust.vim'


call plug#end()


if has("gui_running")
  set background=light
  colorscheme solarized
endif

set tabstop=2
set shiftwidth=2
set expandtab
set noswapfile
set number
set relativenumber

" The Silver Searcher
"if executable('ag')
"  " Use ag over grep
"  set grepprg=ag\ --nogroup\ --nocolor
"
"  " Use ag in CtrlP for listing files. Lightning fast and respects .gitignore
"  let g:ctrlp_user_command = 'ag %s -l --nocolor -g ""'
"
"  " ag is fast enough that CtrlP doesn't need to cache
"  let g:ctrlp_use_caching = 0
"endif

" bind K to grep word under cursor
"nnoremap K :grep! "\b<C-R><C-W>\b"<CR>:cw<CR>
"
"" bind \ (backward slash) to grep shortcut
"command -nargs=+ -complete=file -bar Ag silent! grep! <args>|cwindow|redraw!
"nnoremap \ :Ag<SPACE>
"set rtp+=~/.fzf

"let g:ctrlp_match_func = { 'match': 'pymatcher#PyMatch' }
