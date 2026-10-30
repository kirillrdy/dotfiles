{ pkgs }:
let
  desktop = import ../desktop-zig.nix { inherit pkgs; };
in
pkgs.runCommand "desktop-battery-check"
  {
    nativeBuildInputs = [
      (pkgs.python3.withPackages (python: [ python.pygobject3 ]))
      pkgs.dbus
      desktop
    ];
    FONTCONFIG_FILE = pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts ]; };
  }
  ''
    export GSETTINGS_SCHEMA_DIR=${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}/glib-2.0/schemas
    export XDG_DATA_DIRS=${pkgs.adwaita-icon-theme}/share
    export GDK_PIXBUF_MODULE_FILE=${pkgs.librsvg}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache
    export PYTHONDONTWRITEBYTECODE=1
    dbus-run-session --config-file=${pkgs.dbus}/share/dbus-1/session.conf -- \
      python3 ${./check-desktop-battery.py} --fixture ${desktop.tests}/bin/desktop-battery-fixture
    touch "$out"
  ''
