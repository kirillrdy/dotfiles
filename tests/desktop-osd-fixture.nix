{ pkgs }:
let
  desktop = import ../desktop-zig.nix { inherit pkgs; };
  config = import ../labwc.nix {
    inherit pkgs;
    lib = pkgs.lib;
    enableLightDesktop = true;
  };
  style = pkgs.writeText "desktop-osd-style.css" config.content.environment.etc."xdg/desktop-osd/style.css".text;
in
pkgs.runCommand "desktop-native-osd-check"
  {
    nativeBuildInputs = [
      (pkgs.python3.withPackages (python: [ python.pygobject3 ]))
      pkgs.dbus
      pkgs.glib
      pkgs.grim
      pkgs.wlr-randr
      pkgs.wtype
      pkgs.pipewire
      pkgs.wireplumber
      desktop
    ];
  }
  ''
    export PYTHONPATH=${./.}
    export GSETTINGS_BACKEND=memory
    export GSETTINGS_SCHEMA_DIR=${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}/glib-2.0/schemas
    export XDG_DATA_DIRS=${pkgs.adwaita-icon-theme}/share
    export GDK_PIXBUF_MODULE_FILE=${desktop.DESKTOP_RUNTIME_PIXBUF_LOADERS}
    dbus-run-session --config-file=${pkgs.dbus}/share/dbus-1/session.conf -- \
      python3 ${./check-desktop-osd.py} \
        --binary ${desktop.tests}/bin/desktop-backlight-fixture --style ${style} \
        --loader-cache "$GDK_PIXBUF_MODULE_FILE" \
        --dbus-config ${pkgs.dbus}/share/dbus-1/session.conf
    touch "$out"
  ''
