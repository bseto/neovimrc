set nocompatible
filetype off

set tabstop=4
set shiftwidth=4
set expandtab
set hidden

syntax on
set nu
colorscheme elflord

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


map > <C-W>>
map < <C-W><
map _ <C-W>- 
map + <C-W>+


map <C-n> :NERDTreeToggle<CR>
map <C-b> :tabn<CR>
map <C-v> :tabp<CR>

" ------------------------------- Vim-Plug -------------------------------
set rtp+=~/.nvim/autoload/plug.vim
call plug#begin()
Plug 'junegunn/vim-easy-align'
Plug 'scrooloose/syntastic'
" NERD tree will be loaded on the first invocation of NERDTreeToggle command
Plug 'scrooloose/nerdtree', { 'on': 'NERDTreeToggle' }
Plug 'bling/vim-airline'
Plug 'Valloric/YouCompleteMe', { 'do': './install.sh' }
call plug#end()

