{ pkgs }:
# Pointers, keyboards and touchpads need only evdev, mtdev and udev. Tablet
# descriptions from libwacom bring GLib (with SELinux and PCRE2) into the
# desktop's closure, and libinput's Lua quirk plugins bring Lua and ncurses.
(pkgs.libinput.override {
  wacomSupport = false;
  luaSupport = false;
}).overrideAttrs
  (old: {
    pname = "desktop-libinput";
    outputChecks.out.disallowedRequisites = [
      pkgs.glib
      pkgs.libwacom
      pkgs.lua5_4
    ];
  })
