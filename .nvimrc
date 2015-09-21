" ------------------------------- Vim-Plug -------------------------------
set rtp+=~/.nvim/autoload/plug.vim
call plug#begin()
Plug 'junegunn/vim-easy-align'
Plug 'scrooloose/syntastic'
Plug 'scrooloose/nerdtree', { 'on': 'NERDTreeToggle' }
Plug 'bling/vim-airline'
Plug 'easymotion/vim-easymotion'
Plug 'Valloric/YouCompleteMe', { 'do': './install.sh' }
Plug 'flazz/vim-colorschemes'
call plug#end()
" ------------------------------- Vim-Plug -------------------------------
set nocompatible
filetype off

set tabstop=4
set shiftwidth=4
set expandtab
set hidden
set undofile
let mapleader=","

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
nnoremap / /\v
vnoremap / /\v


" ------------------------------- Navigation -------------------------------
nnoremap <C-n> :NERDTreeToggle<CR>

nnoremap <C-b> :bn<CR>
nnoremap <C-v> :bp<CR>

nnoremap tl :tabnext<CR>
nnoremap th :tabprev<CR>
nnoremap tn :tabnew<CR>

map <C-h> <C-W><
map <C-l> <C-W>>
map <C-j> <C-W>- 
map <C-k> <C-W>+

nnoremap j gj
nnoremap k gk

let g:EasyMotion_smartcase = 1
let g:EasyMotion_do_mapping = 1 " Disable default mappings

map <Leader>s <Plug>(easymotion-s)
map <Leader>j <Plug>(easymotion-j)
map <Leader>k <Plug>(easymotion-k)
map <Leader>w <Plug>(easymotion-w)
