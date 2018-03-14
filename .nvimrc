" ------------------------------- Vim-Plug -------------------------------
call plug#begin('~/.local.share/nvim/plugged')
Plug 'Valloric/YouCompleteMe', { 'do': './install.sh' }
Plug 'bling/vim-airline'
Plug 'dagwieers/asciidoc-vim'
Plug 'easymotion/vim-easymotion'
Plug 'flazz/vim-colorschemes'
Plug 'junegunn/vim-easy-align'
"Plug 'kien/ctrlp.vim'
Plug 'kien/rainbow_parentheses.vim'
"Plug 'luochen1990/rainbow'
Plug 'majutsushi/tagbar'
Plug 'rdnetto/YCM-Generator', { 'branch': 'stable'}
Plug 'scrooloose/nerdcommenter'
Plug 'scrooloose/nerdtree', { 'on': 'NERDTreeToggle' }
Plug 'scrooloose/syntastic'
Plug 'fatih/vim-go'
Plug 'chiel92/vim-autoformat'
Plug 'jceb/vim-orgmode'
Plug 'tpope/vim-speeddating'
Plug 'elzr/vim-json'
Plug 'JamshedVesuna/vim-markdown-preview'
Plug 'junegunn/fzf', { 'dir': '~/.fzf', 'do': './install --all' }
Plug 'junegunn/fzf.vim'
Plug 'lyuts/vim-rtags'

call plug#end()
" ------------------------------- General -------------------------------
"COPY AND PASTE
set clipboard+=unnamedplus

set nocompatible
filetype off

set tabstop=4
set shiftwidth=4
set expandtab
set hidden
set undofile
set smartcase
let mapleader=","
set colorcolumn=80,100

inoremap jk <esc>

syntax on
set nu
colorscheme molokai

set wildmenu
set wildmode=longest:full,full

set statusline+=%#warningmsg#
set statusline+=%{SyntasticStatuslineFlag()}
set statusline+=%*

let b:formatdef_custom_c='"astyle --mode=c --suffix=none --options=/home/byron/Documents/Recruit-Resources/Development-Guide/Style-Guide/astylerc"'
let b:formatters_c = ['custom_c']
let vim_markdown_preview_hotkey='<C-m>'
let vim_markdown_preview_github=1

" set Vim-specific sequences for RGB colors  
set termguicolors
let &t_8f = "\<Esc>[38;2;%lu;%lu;%lum" 
let &t_8b = "\<Esc>[48;2;%lu;%lu;%lum"

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


" ------------------------------- aStyle -------------------------------
"augroup autocom
"autocmd!
":au BufWrite * :Autoformat
"augroup END
" ------------------------------- Navigation -------------------------------

let g:ctrlp_cache_dir = $HOME . '/.cache/ctrlp'

if executable('ag')
  let g:ctrlp_user_command = 'ag %s -l --nocolor -g ""'
endif

nnoremap <C-n> :NERDTreeToggle<CR>
nmap <C-m> :TagbarToggle<CR>

nnoremap <Leader>d :bp<CR>
nnoremap <Leader>f :bn<CR>
nnoremap <leader>gd :YcmCompleter GoTo<CR>
nnoremap <leader>gi :YcmCompleter GoToInclude<CR>
nnoremap <leader>gt :YcmCompleter GetType<CR>

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
 "let g:rainbow_active = 1


" ------------------------------- fzf -------------------------------

map <C-p> :Files<CR>
let g:fzf_buffers_jump = 1
nnoremap <silent> <Leader>ag :Ag <C-R><C-W><CR>




