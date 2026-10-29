{
  pkgs,
  dbus ? pkgs.dbus,
  printingSupport ? false,
  accessibilitySupport ? false,
}:
let
  textLibraries = import ./desktop-text-libs.nix { inherit pkgs; };
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
  # Libepoxy provides EGL function pointers for Wayland OpenGL without GLX/X11.
  epoxy =
    let
      base =
        (pkgs.libepoxy.override { x11Support = false; }).overrideAttrs (old: {
          pname = "desktop-libepoxy";
          propagatedBuildInputs = [ pkgs.libGL ];
          mesonFlags = [
            "-Degl=yes"
            "-Dglx=no"
            "-Dx11=false"
            "-Dtests=false"
          ];
        });
    in
    base // { override = _: epoxy; };

  # Pure Wayland desktop toolkit without X11 or accessibility bus dependencies.
  # Printer discovery/spooling is deferred; the file backend still exports PDF.
  gtk =
    (pkgs.gtk3.override {
      inherit (textLibraries) cairo pango;
      libxkbcommon = textLibraries.xkbcommon;
      libepoxy = epoxy;
      isocodes = import ./desktop-language-data.nix { inherit pkgs; };
      atk = accessibility;
      at-spi2-atk = accessibility;
      trackerSupport = false;
      cupsSupport = printingSupport;
      broadwaySupport = false;
      withIntrospection = false;
      x11Support = false;
      xineramaSupport = false;
      waylandSupport = true;
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
