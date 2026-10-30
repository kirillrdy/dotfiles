{ pkgs }:
let
  desktop = import ../desktop-zig.nix { inherit pkgs; };
  fixture = desktop.overrideAttrs {
    pname = "desktop-portal-capture-fixtures";
    outputs = [ "out" ];
    buildPhase = ''
      export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
      zig build portal-capture-fixtures --prefix "$out" -Doptimize=ReleaseSafe
    '';
    doCheck = false;
    installPhase = "true";
  };
in
pkgs.runCommand "desktop-portal-capture-check"
  {
    nativeBuildInputs = [
      (pkgs.python3.withPackages (p: [ p.pygobject3 ]))
      pkgs.dbus
      desktop
      pkgs.pipewire
      pkgs.wireplumber
    ];
    FONTCONFIG_FILE = pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts ]; };
    GI_TYPELIB_PATH = "${pkgs.gdk-pixbuf}/lib/girepository-1.0";
  }
  ''
    export PYTHONPATH=${./.}
    export PYTHONDONTWRITEBYTECODE=1
    export GSETTINGS_SCHEMA_DIR=${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}/glib-2.0/schemas
    dbus-run-session --config-file=${pkgs.dbus}/share/dbus-1/session.conf -- \
      python3 ${./check-desktop-portal-capture.py} \
        --binary ${fixture}/bin/desktop-portal-fixture \
        --video-consumer ${fixture}/bin/desktop-portal-video-fixture \
        --pointer ${fixture}/bin/desktop-pointer-fixture
    touch "$out"
  ''
