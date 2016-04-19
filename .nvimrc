" ------------------------------- Vim-Plug -------------------------------
set rtp+=~/.nvim/autoload/plug.vim
call plug#begin()
Plug 'Valloric/YouCompleteMe', { 'do': './install.sh' }
Plug 'bling/vim-airline'
Plug 'dagwieers/asciidoc-vim'
Plug 'easymotion/vim-easymotion'
Plug 'flazz/vim-colorschemes'
Plug 'junegunn/vim-easy-align'
Plug 'kien/ctrlp.vim'
Plug 'kien/rainbow_parentheses.vim'
Plug 'majutsushi/tagbar'
Plug 'rdnetto/YCM-Generator', { 'branch': 'stable'}
Plug 'scrooloose/nerdcommenter'
Plug 'scrooloose/nerdtree', { 'on': 'NERDTreeToggle' }
Plug 'scrooloose/syntastic'
Plug 'fatih/vim-go'
call plug#end()
" ------------------------------- General -------------------------------
set nocompatible
filetype off

set tabstop=4
set shiftwidth=4
set expandtab
set hidden
set undofile
set smartcase
let mapleader=","

inoremap jk <esc>

syntax on
set relativenumber
set nu
colorscheme molokai

set wildmenu
set wildmode=longest:full,full

set statusline+=%#warningmsg#
set statusline+=%{SyntasticStatuslineFlag()}
set statusline+=%*

" ------------------------------- Syntastic -------------------------------

let g:syntastic_go_checkers = ['golint', 'govet', 'errcheck']
let g:syntastic_mode_map = { 'mode': 'active', 'passive_filetypes': ['go'] }

let g:syntastic_always_populate_loc_list = 1
let g:syntastic_auto_loc_list = 1
let g:syntastic_check_on_open = 1
let g:syntastic_check_on_wq = 0
let g:syntastic_error_symbol = "✗"
let g:syntastic_warning_symbol = "⚠"

let g:syntastic_asciidoc_asciidoc_exec = 'asciidoctor'
let g:airline#extensions#tabline#enabled = 1
" ------------------------------- Ctags -------------------------------

"build tags of your own project with CTRL+F12      
"map <C-F12> :!ctags -R --c++-kinds=+p --fields=+iaS --extra=+q .<CR>      
noremap <F12> :!ctags -R --c++-kinds=+p --fields=+iaS --extra=+q .<cr>      
inoremap <F12> <Esc>:!ctags -R --c++-kinds=+p --fields=+iaS --extra=+q .<cr> 

"set tags+=~/.nvim/tags/sdl2/tags,~/.nvim/tags/opencv/tags
set tags+=~/.config/nvim/tags/tags_include
set tags+=~/.config/nvim/tags/tags_local
"let g:ycm_global_ycm_extra_conf = '/home/byron/Documents/TerminalFighter/.ycm_global_ycm_extra_conf.py'
let g:ycm_collect_identifiers_from_tags_files = 1
let g:ycm_extra_conf_globlist = ['.*']

" ------------------------------- Regex -------------------------------
nnoremap / /\c
vnoremap / /\c


" ------------------------------- Navigation -------------------------------
nnoremap <C-n> :NERDTreeToggle<CR>
nmap <C-m> :TagbarToggle<CR>

nnoremap <Leader>d :bp<CR>
nnoremap <Leader>f :bn<CR>

nnoremap tl :tabnext<CR>
nnoremap th :tabprev<CR>
nnoremap tn :tabnew<CR>

let g:EasyMotion_smartcase = 1

map <Leader>s <Plug>(easymotion-s)
map <Leader>j <Plug>(easymotion-j)
map <Leader>k <Plug>(easymotion-k)
map <Leader>w <Plug>(easymotion-w)
map <Leader>b <Plug>(easymotion-b)
map <Leader>e <Plug>(easymotion-e)
map <Leader>/ <Plug>(easymotion-jumptoanywhere)

" ------------------------------- Buffer Resize -------------------------------
map <C-h> <C-W><
map <C-l> <C-W>>
map <C-j> <C-W>- 
map <C-k> <C-W>+

" ------------------------------- Rainbow Parentheses -------------------------------
let g:rbpt_colorpairs = [
    \ ['brown',       'RoyalBlue3'],
    \ ['Darkblue',    'SeaGreen3'],
    \ ['darkgreen',   'firebrick3'],
    \ ['darkcyan',    'RoyalBlue3'],
    \ ['darkred',     'SeaGreen3'],
    \ ['gray',        'RoyalBlue3'],
    \ ['black',       'SeaGreen3'],
    \ ['darkgreen',   'RoyalBlue3'],
    \ ['darkcyan',    'SeaGreen3'],
    \ ]
let g:rbpt_max = 13
au VimEnter * RainbowParenthesesToggle
au Syntax * RainbowParenthesesLoadRound
au Syntax * RainbowParenthesesLoadSquare
au Syntax * RainbowParenthesesLoadBraces
