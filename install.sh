#!/bin/sh

cp -v dot.gitconfig ~/.gitconfig
cp -v dot.tigrc ~/.tigrc
mkdir -p ~/.config/nvim
cp -v dot.vimrc ~/.config/nvim/init.vim
cp -v dot.screenrc ~/.screenrc
mkdir -p ~/.local/share/icons/hicolor/scalable/apps
cp -v firefox.png ~/.local/share/icons/hicolor/scalable/apps/
