{
  pkgs,
  dbus ? pkgs.dbus,
}:
let
  # Match the desktop's D-Bus client and preserve accessibility bus launching
  # without retaining a Bash interpreter just for its environment wrapper.
  accessibility =
    (pkgs.at-spi2-core.override {
      inherit dbus;
      makeWrapper = pkgs.makeBinaryWrapper;
      withIntrospection = false;
    }).overrideAttrs
      (old: {
        outputs = old.outputs ++ [ "xwayland" ];
        # This system session hook invokes busctl, sed, and xprop. Keep it
        # available separately from the client libraries and accessibility bus.
        postInstall = (old.postInstall or "") + ''
          moveToOutput etc/xdg/Xwayland-session.d "$xwayland"
        '';
      });
  # The desktop uses GTK widgets, accessibility, input methods, and Wayland.
  # Keep X11 for the isolated Xvfb fixtures and CUPS for the native print portal.
  # Indexed file search belongs to applications rather than this shell.
  gtk =
    (pkgs.gtk3.override {
      atk = accessibility;
      at-spi2-atk = accessibility;
      trackerSupport = false;
      cupsSupport = true;
      broadwaySupport = false;
      withIntrospection = false;
    }).overrideAttrs
      (old: {
        pname = "desktop-gtk";
        separateDebugInfo = false;
        mesonFlags = old.mesonFlags ++ [
          "-Dprint_backends=file,cups"
          "-Ddemos=false"
          "-Dexamples=false"
        ];
        # The upstream Nix install hook moves broadwayd unconditionally.
        postInstall =
          pkgs.lib.replaceStrings [ ''moveToOutput bin/broadwayd "$out"'' ] [ "" ]
            old.postInstall;
        # The full package wraps demos, which this build does not install.
        postFixup = "";
      });

  layerShell = (pkgs.gtk-layer-shell.override { gtk3 = gtk; }).overrideAttrs {
    pname = "desktop-gtk-layer-shell";
    outputs = [
      "out"
      "dev"
    ];
    outputBin = "dev";
    nativeBuildInputs = with pkgs; [
      meson
      ninja
      pkg-config
      wayland-scanner
    ];
    mesonFlags = [
      "-Ddocs=false"
      "-Dexamples=false"
      "-Dintrospection=false"
      "-Dvapi=false"
    ];
  };
in
{
  inherit accessibility gtk layerShell;
}
