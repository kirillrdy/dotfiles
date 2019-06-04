#exec gnome-session
#exec startxfce4
export GTK_IM_MODULE=ibus
export QT_IM_MODULE=ibus
export XMODIFIERS=@im=ibus
/usr/local/bin/mozc start
ibus-daemon -drx
xrdb -merge ~/.Xdefaults
exec dwm
