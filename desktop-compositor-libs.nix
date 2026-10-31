{ pkgs }:
let
  textLibraries = import ./desktop-text-libs.nix { inherit pkgs; };
in
# The Zig compositor implements Wayland clients only; it never creates an
# XWayland server. Avoid its libdecor plugin and second, full GTK dependency.
(pkgs.wlroots_0_20.override {
  enableXWayland = false;
  libxkbcommon = textLibraries.xkbcommon;
}).overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [ ./wlroots-capture-bounds.patch ];
})
