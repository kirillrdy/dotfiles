{ pkgs }:
let
  desktop = import ../desktop-zig.nix { inherit pkgs; };
  fixture = import ./fixture-build.nix {
    inherit desktop;
    name = "desktop-polkit-agent-fixture";
    steps = "shell polkit-fixture polkit-agent-fixture";
    extraAttrs.postFixup = ''
      find "$out" -type f -exec remove-references-to -t ${pkgs.zig_0_17} {} +
    '';
  };
in
pkgs.runCommand "desktop-polkit-check"
  {
    nativeBuildInputs = [
      (pkgs.python3.withPackages (p: [ p.pygobject3 ]))
      pkgs.dbus
      pkgs.wtype
    ];
    FONTCONFIG_FILE = pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts ]; };
  }
  ''
    export GSETTINGS_SCHEMA_DIR=${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}/glib-2.0/schemas
    export XDG_DATA_DIRS=${pkgs.adwaita-icon-theme}/share
    export GDK_PIXBUF_MODULE_FILE=${pkgs.librsvg}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache
    export PYTHONDONTWRITEBYTECODE=1
    dbus-run-session --config-file=${pkgs.dbus}/share/dbus-1/session.conf -- \
      python3 ${./check-desktop-polkit.py} --binary ${fixture}/bin/desktop-polkit-agent-fixture \
        --compositor ${fixture}/bin/desktop-zig --dialog-fixture ${fixture}/bin/desktop-polkit-fixture
    touch "$out"
  ''
