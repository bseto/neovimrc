#!/bin/bash

WORK_DIR=`pwd`

#apt-get install curl

#bashrc
#mv ~/.bashrc ~/.bashrc.bak
#ln -s ${WORK_DIR}/.bashrc ~/.bashrc

#pluginstall
mkdir -p ~/.local/share/nvim/site/autoload
curl -fLo ~/.local/share/nvim/site/autoload/plug.vim --create-dirs \
    https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim

mkdir -p ~/.config/nvim
#rm ~/.config/nvim/init.vim
ln -s ${WORK_DIR}/.nvimrc ~/.config/nvim/init.vim

git clone --depth=1 https://github.com/romkatv/powerlevel10k.git $ZSH/custom/themes/powerlevel10k




