{ pkgs }:
let
  desktop = import ../desktop-zig.nix { inherit pkgs; };
  fixture = desktop.overrideAttrs {
    pname = "desktop-memory-tests";
    outputs = [ "out" ];
    buildPhase = ''
      export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
      zig build memory-tests --prefix "$out" -Doptimize=Debug -Dcpu=baseline -j2
    '';
    doCheck = false;
    dontStrip = true;
    installPhase = "true";
  };
in
pkgs.runCommand "desktop-memory-check" {
  nativeBuildInputs = [ (pkgs.python3.withPackages (p: [ p.pygobject3 ])) pkgs.dbus pkgs.xorg-server pkgs.pipewire pkgs.wireplumber ];
  FONTCONFIG_FILE = pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts ]; };
} ''
  export PYTHONPATH=${./.}
  export PYTHONDONTWRITEBYTECODE=1
  export GSETTINGS_SCHEMA_DIR=${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}/glib-2.0/schemas
  export XDG_DATA_DIRS=${pkgs.adwaita-icon-theme}/share
  export GDK_PIXBUF_MODULE_FILE=${pkgs.librsvg}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache
  export XDG_CACHE_HOME=$TMPDIR/cache
  mkdir -p "$XDG_CACHE_HOME"
  Xvfb :93 -nolisten tcp &
  memory_xvfb=$!
  trap 'kill "$memory_xvfb"' EXIT
  for attempt in $(seq 1 100); do
    test -S /tmp/.X11-unix/X93 && break
    sleep 0.05
  done
  DISPLAY=:93 dbus-run-session --config-file=${pkgs.dbus}/share/dbus-1/session.conf -- \
    python3 ${./check-desktop-memory.py} --binary ${fixture}/bin/desktop-memory-tests \
      --valgrind ${pkgs.valgrind}/bin/valgrind --strip ${pkgs.binutils}/bin/strip
  touch "$out"
''
