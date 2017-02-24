#!/bin/sh

set -ex

#TODO needs to be better, eg check if repos already exists or any unpushed uncommited changes
root_dir=$HOME/src/github.com/kirillrdy
mkdir -p $root_dir
cd $root_dir
#TODO add clone or update option
git clone git@github.com:kirillrdy/nadeshiko.git
git clone git@github.com:kirillrdy/vidos.git
git clone git@github.com:kirillrdy/libkanji.git
git clone git@github.com:kirillrdy/pt.git
git clone git@github.com:kirillrdy/train.git
git clone git@github.com:kirillrdy/osm.git
