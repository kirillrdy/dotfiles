{ pkgs }:
let
  textLibraries = import ./desktop-text-libs.nix { inherit pkgs; };
  glLibraries = import ./desktop-gl-libs.nix { inherit pkgs; };
  inputLibraries = import ./desktop-input-libs.nix { inherit pkgs; };
in
# The Zig compositor implements Wayland clients only; it never creates an
# XWayland server. Avoid its libdecor plugin and second, full GTK dependency.
(pkgs.wlroots_0_20.override {
  enableXWayland = false;
  libGL = glLibraries;
  libinput = inputLibraries;
  libxkbcommon = textLibraries.xkbcommon;
}).overrideAttrs
  (old: {
    patches = (old.patches or [ ]) ++ [ ./wlroots-capture-bounds.patch ];
    # Headers and propagated development inputs belong outside the runtime.
    outputs = old.outputs ++ [ "dev" ];
    # Nested Wayland and headless backends are always built by wlroots. Keep
    # hardware input/DRM support without the optional nested X11 backend.
    mesonFlags = old.mesonFlags ++ [ "-Dbackends=drm,libinput" ];
    buildInputs = pkgs.lib.subtractLists [
      pkgs.libx11
      pkgs.libxcb-errors
      pkgs.libxcb-image
      pkgs.libxcb-render-util
      pkgs.libxcb-wm
    ] old.buildInputs;
    disallowedRequisites = [
      pkgs.libx11
      pkgs.libxcb
    ];
  })
