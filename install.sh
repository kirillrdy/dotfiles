#!/bin/sh

cp -v dot.gitconfig ~/.gitconfig
cp -v dot.tigrc ~/.tigrc
mkdir -p ~/.config/nvim
cp -v init.vim ~/.config/nvim/init.vim
cp -v ginit.vim ~/.config/nvim/ginit.vim
cp -v init.vim ~/.vimrc
cp -v dot.screenrc ~/.screenrc
mkdir -p ~/.local/share/icons/hicolor/scalable/apps
mkdir -p ~/.local/share/applications
cp -v icons/* ~/.local/share/icons/hicolor/scalable/apps/
cp -v org.daa.NeovimGtk.desktop ~/.local/share/applications/
cp -v Xdefaults ~/.Xdefaults
cp -v git-completion.bash ~/.git-completion.bash
cp -v git-completion.tcsh ~/.git-completion.tcsh
cp -v firefox.png ~/.local/share/icons/hicolor/scalable/apps/
