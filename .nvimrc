" ------------------------------- Vim-Plug -------------------------------
set rtp+=~/.nvim/autoload/plug.vim
call plug#begin()
Plug 'junegunn/vim-easy-align'
Plug 'scrooloose/syntastic'
Plug 'scrooloose/nerdtree', { 'on': 'NERDTreeToggle' }
Plug 'bling/vim-airline'
Plug 'Valloric/YouCompleteMe', { 'do': './install.sh' }
Plug 'flazz/vim-colorschemes'
call plug#end()

set nocompatible
filetype off

"let g:molokai_original = 1
"let g:rehash256 = 1

set tabstop=4
set shiftwidth=4
set expandtab
set hidden
set undofile

syntax on
set nu
colorscheme molokai

set wildmenu
set wildmode=longest:full,full

set statusline+=%#warningmsg#
set statusline+=%{SyntasticStatuslineFlag()}
set statusline+=%*

let g:syntastic_always_populate_loc_list = 1
let g:syntastic_auto_loc_list = 1
let g:syntastic_check_on_open = 1
let g:syntastic_check_on_wq = 0
let g:syntastic_error_symbol = "✗"
let g:syntastic_warning_symbol = "⚠"

let g:syntastic_asciidoc_asciidoc_exec = 'asciidoctor'
let g:airline#extensions#tabline#enabled = 1

"----regex----"
nnoremap / /\j
vnoremap / /\v


" ------------------------------- Navigation -------------------------------
nnoremap <C-n> :NERDTreeToggle<CR>

nnoremap <C-b> :bn<CR>
nnoremap <C-v> :bp<CR>

nnoremap tl :tabnext<CR>
nnoremap th :tabprev<CR>
nnoremap tn :tabnew<CR>

map > <C-W>>
map < <C-W><
map _ <C-W>- 
map + <C-W>+


nnoremap j gj
nnoremap k gk


