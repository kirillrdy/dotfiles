#!/bin/sh

dwm_conf_dir=`pwd`
cd /usr/dports/x11/sterm
make clean
make deinstall
make ST_CONF=$dwm_conf_dir/st_config.h install
make clean
