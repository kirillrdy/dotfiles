{ pkgs }:
let desktop = import ../desktop-zig.nix { inherit pkgs; };
in pkgs.runCommand "desktop-audio-check" {
  nativeBuildInputs = [ pkgs.python3 pkgs.dbus pkgs.xorg-server pkgs.pipewire pkgs.wireplumber ];
} ''
  export PYTHONPATH=${./.}
  export GSETTINGS_SCHEMA_DIR=${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}/glib-2.0/schemas
  export XDG_DATA_DIRS=${pkgs.adwaita-icon-theme}/share
  export GDK_PIXBUF_MODULE_FILE=${pkgs.librsvg}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache
  Xvfb :94 -nolisten tcp &
  audio_xvfb=$!
  trap 'kill "$audio_xvfb"' EXIT
  for attempt in $(seq 1 100); do
    test -S /tmp/.X11-unix/X94 && break
    sleep 0.05
  done
  DISPLAY=:94 GDK_BACKEND=x11 dbus-run-session --config-file=${pkgs.dbus}/share/dbus-1/session.conf -- \
    python3 ${./check-desktop-audio.py} --fixture ${desktop.tests}/bin/desktop-audio-fixture
  touch "$out"
''
