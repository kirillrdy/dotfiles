{ pkgs }:
let
  desktop = import ../desktop-zig.nix { inherit pkgs; };
  fixture = import ./fixture-build.nix {
    inherit desktop;
    name = "desktop-session-fixture";
    steps = "session-fixture";
    debug = true;
  };
in
pkgs.runCommand "desktop-session-check"
  {
    nativeBuildInputs = [
      (pkgs.python3.withPackages (p: [ p.pygobject3 ]))
      pkgs.dbus
    ];
    FONTCONFIG_FILE = pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts ]; };
  }
  ''
    export NO_AT_BRIDGE=1
    export GSETTINGS_BACKEND=memory
    export GSETTINGS_SCHEMA_DIR=${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}/glib-2.0/schemas
    export XDG_DATA_DIRS=${pkgs.adwaita-icon-theme}/share
    export GDK_PIXBUF_MODULE_FILE=${pkgs.librsvg}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache
    ${import ./headless-session.nix { inherit desktop; }}
    G_DEBUG=fatal-criticals dbus-run-session --config-file=${pkgs.dbus}/share/dbus-1/session.conf -- \
      python3 ${./check-desktop-session.py} --binary ${fixture}/bin/desktop-session-fixture
    touch "$out"
  ''
