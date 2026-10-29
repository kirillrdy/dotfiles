{ pkgs }:
let
  desktop = import ../desktop-zig.nix { inherit pkgs; };
  fixture = desktop.overrideAttrs {
    pname = "desktop-polkit-agent-fixture";
    outputs = [ "out" ];
    buildPhase = ''
      export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
      zig build polkit-agent-fixture test-gtk-abi test-libc-abi --prefix "$out" -Doptimize=ReleaseSafe
    '';
    doCheck = false;
    installPhase = "true";
  };
in
pkgs.runCommand "desktop-polkit-check"
  {
    nativeBuildInputs = [
      (pkgs.python3.withPackages (p: [ p.pygobject3 ]))
      pkgs.dbus
      pkgs.xorg-server
      pkgs.xdotool
    ];
    FONTCONFIG_FILE = pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts ]; };
  }
  ''
    export GSETTINGS_SCHEMA_DIR=${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}/glib-2.0/schemas
    export XDG_DATA_DIRS=${pkgs.adwaita-icon-theme}/share
    export GDK_PIXBUF_MODULE_FILE=${pkgs.librsvg}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache
    export PYTHONDONTWRITEBYTECODE=1
    Xvfb :93 -nolisten tcp &
    polkit_xvfb=$!
    trap 'kill "$polkit_xvfb"' EXIT
    for attempt in $(seq 1 100); do
      test -S /tmp/.X11-unix/X93 && break
      sleep 0.05
    done
    DISPLAY=:93 GDK_BACKEND=x11 dbus-run-session --config-file=${pkgs.dbus}/share/dbus-1/session.conf -- \
      python3 ${./check-desktop-polkit.py} --binary ${fixture}/bin/desktop-polkit-agent-fixture
    touch "$out"
  ''
