#!/bin/sh

cp -v dot.gitconfig ~/.gitconfig
cp -v dot.tigrc ~/.tigrc
mkdir -p ~/.config/helix
mkdir -p ~/.config/nvim
cp -v config.toml ~/.config/helix/
cp -v init.vim ~/.config/nvim/init.vim
cp -v ginit.vim ~/.config/nvim/ginit.vim
cp -v ./dot.xinitrc ~/.xinitrc
cp -v Xdefaults ~/.Xdefaults
