{ pkgs }:
let
  desktop = import ../desktop-zig.nix { inherit pkgs; };
  fixture = import ./fixture-build.nix {
    inherit desktop;
    name = "desktop-network-fixture";
    steps = "network-fixture";
    debug = true;
  };
in
pkgs.runCommand "desktop-network-check"
  {
    nativeBuildInputs = [
      (pkgs.python3.withPackages (p: [ p.pygobject3 ]))
      pkgs.dbus
    ];
    FONTCONFIG_FILE = pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts ]; };
  }
  ''
    export PYTHONPATH=${./.}
    export PYTHONDONTWRITEBYTECODE=1
    export NO_AT_BRIDGE=1
    export GSETTINGS_BACKEND=memory
    export GSETTINGS_SCHEMA_DIR=${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}/glib-2.0/schemas
    export XDG_DATA_DIRS=${pkgs.adwaita-icon-theme}/share
    export GDK_PIXBUF_MODULE_FILE=${pkgs.librsvg}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache
    ${import ./headless-session.nix { inherit desktop; }}
    G_DEBUG=fatal-criticals python3 ${./check-desktop-network.py} --binary ${fixture}/bin/desktop-network-fixture --dbus-config ${pkgs.dbus}/share/dbus-1/session.conf
    touch "$out"
  ''
