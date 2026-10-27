{ pkgs }:
let desktop = import ../desktop-zig.nix { inherit pkgs; };
in pkgs.runCommand "desktop-battery-check" {
  nativeBuildInputs = [
    (pkgs.python3.withPackages (python: [ python.pygobject3 ]))
    pkgs.dbus pkgs.xorg-server
  ];
} ''
  export GSETTINGS_SCHEMA_DIR=${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}/glib-2.0/schemas
  export XDG_DATA_DIRS=${pkgs.adwaita-icon-theme}/share
  export GDK_PIXBUF_MODULE_FILE=${pkgs.librsvg}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache
  Xvfb :97 -nolisten tcp &
  xvfb_pid=$!
  trap 'kill "$xvfb_pid"' EXIT
  for attempt in $(seq 1 100); do
    test -S /tmp/.X11-unix/X97 && break
    sleep 0.05
  done
  DISPLAY=:97 GDK_BACKEND=x11 python3 ${./check-desktop-battery.py} \
    --fixture ${desktop.tests}/bin/desktop-battery-fixture \
    --dbus-config ${pkgs.dbus}/share/dbus-1/session.conf
  touch "$out"
''
