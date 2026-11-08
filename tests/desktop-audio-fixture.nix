{ pkgs }:
let
  desktop = import ../desktop-zig.nix { inherit pkgs; };
  fixture = import ./fixture-build.nix {
    inherit desktop;
    name = "desktop-audio-fixture";
    steps = "audio-fixture";
  };
in
pkgs.runCommand "desktop-audio-check"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.dbus
      pkgs.pipewire
      pkgs.wireplumber
    ];
  }
  ''
    export PYTHONPATH=${./.}
    export GSETTINGS_SCHEMA_DIR=${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}/glib-2.0/schemas
    export XDG_DATA_DIRS=${pkgs.adwaita-icon-theme}/share
    export GDK_PIXBUF_MODULE_FILE=${pkgs.librsvg}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache
    ${import ./headless-session.nix { inherit desktop; }}
    dbus-run-session --config-file=${pkgs.dbus}/share/dbus-1/session.conf -- \
      python3 ${./check-desktop-audio.py} --fixture ${fixture}/bin/desktop-audio-fixture
    touch "$out"
  ''
