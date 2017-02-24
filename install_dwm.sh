#!/bin/sh

dwm_conf_dir=`pwd`
cd /usr/ports/x11-wm/dwm
make clean
make deinstall
make DWM_CONF=$dwm_conf_dir/dwm_config.h install
make clean
