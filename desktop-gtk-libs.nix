{
  pkgs,
  dbus ? pkgs.dbus,
  printingSupport ? false,
  accessibilitySupport ? false,
}:
let
  # GTK still requires ATK's widget types. Build those without the AT-SPI
  # bridge, registry, bus launcher, or their D-Bus/X11 dependencies for now.
  accessibility =
    if accessibilitySupport then
      (pkgs.at-spi2-core.override {
        inherit dbus;
        makeWrapper = pkgs.makeBinaryWrapper;
        withIntrospection = false;
      }).overrideAttrs
        (old: {
          outputs = old.outputs ++ [ "xwayland" ];
          postInstall = (old.postInstall or "") + ''
            moveToOutput etc/xdg/Xwayland-session.d "$xwayland"
          '';
        })
    else
      (pkgs.at-spi2-core.override {
        systemdSupport = false;
        withDconf = false;
        withIntrospection = false;
      }).overrideAttrs
        (old: {
          pname = "desktop-atk";
          separateDebugInfo = false;
          buildInputs = [ pkgs.libxml2 ];
          propagatedBuildInputs = [ pkgs.glib ];
          mesonFlags = old.mesonFlags ++ [
            "-Datk_only=true"
            "-Dx11=disabled"
            "-Ddefault_bus=dbus-daemon"
            "-Dgtk2_atk_adaptor=false"
          ];
          postFixup = "";
        });
  # Keep X11 for the isolated Xvfb fixtures. Printer discovery/spooling and
  # accessibility integration are deferred; the file backend still exports PDF.
  gtk =
    (pkgs.gtk3.override {
      atk = accessibility;
      at-spi2-atk = accessibility;
      trackerSupport = false;
      cupsSupport = printingSupport;
      broadwaySupport = false;
      withIntrospection = false;
    }).overrideAttrs
      (old: {
        pname = "desktop-gtk";
        separateDebugInfo = false;
        mesonFlags = old.mesonFlags ++ [
          "-Dprint_backends=file${pkgs.lib.optionalString printingSupport ",cups"}"
          "-Ddemos=false"
          "-Dexamples=false"
        ];
        # GTK's Meson build unconditionally enables the bridge for X11.
        # Retain ATK's widget ABI while omitting the optional bus integration.
        postPatch =
          (old.postPatch or "")
          + pkgs.lib.optionalString (!accessibilitySupport) ''
            substituteInPlace meson.build \
              --replace-fail "atkbridge_dep  = dependency('atk-bridge-2.0', version: at_spi2_atk_req)" "atkbridge_dep = []" \
              --replace-fail "atk_pkgs += ['atk-bridge-2.0']" "# AT-SPI bridge disabled for desktop-zig"
            substituteInPlace gtk/a11y/gtkaccessibility.c \
              --replace-fail '#include <atk-bridge.h>' '/* AT-SPI bridge disabled for desktop-zig */' \
              --replace-fail 'atk_bridge_adaptor_init (NULL, NULL);' '/* AT-SPI bridge disabled for desktop-zig */'
          '';
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
