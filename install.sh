#!/bin/sh

cp -v dot.gitconfig ~/.gitconfig
cp -v dot.tigrc ~/.tigrc
cp -v dot.vimrc ~/.vimrc
mkdir -p ~/.config/nvim
cp -v dot.vimrc ~/.config/nvim/init.vim
cp -v dot.screenrc ~/.screenrc
