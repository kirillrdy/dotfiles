{ pkgs }:
let
  desktop = import ../desktop-zig.nix { inherit pkgs; };
  fixture = desktop.overrideAttrs {
    pname = "desktop-network-fixture";
    outputs = [ "out" ];
    buildPhase = ''
      export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
      zig build network-fixture test-network --prefix "$out" -Doptimize=Debug -Dcpu=baseline -j2
    '';
    doCheck = false;
    dontStrip = true;
    installPhase = "true";
  };
in pkgs.runCommand "desktop-network-check" {
  nativeBuildInputs = [ (pkgs.python3.withPackages (p: [ p.pygobject3 ])) pkgs.dbus pkgs.xorg-server ];
  FONTCONFIG_FILE = pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts ]; };
} ''
  export PYTHONPATH=${./.}
  export PYTHONDONTWRITEBYTECODE=1
  export NO_AT_BRIDGE=1
  export GSETTINGS_BACKEND=memory
  export GSETTINGS_SCHEMA_DIR=${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}/glib-2.0/schemas
  export XDG_DATA_DIRS=${pkgs.adwaita-icon-theme}/share
  export GDK_PIXBUF_MODULE_FILE=${pkgs.librsvg}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache
  Xvfb :94 -nolisten tcp &
  network_xvfb=$!
  trap 'kill "$network_xvfb"' EXIT
  for attempt in $(seq 1 100); do
    test -S /tmp/.X11-unix/X94 && break
    sleep 0.05
  done
  DISPLAY=:94 G_DEBUG=fatal-criticals python3 ${./check-desktop-network.py} --binary ${fixture}/bin/desktop-network-fixture --dbus-config ${pkgs.dbus}/share/dbus-1/session.conf
  touch "$out"
''
