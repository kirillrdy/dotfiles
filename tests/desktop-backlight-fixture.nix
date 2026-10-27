{ pkgs }:
let
  desktop = import ../desktop-zig.nix { inherit pkgs; };
  config = import ../labwc.nix { inherit pkgs; lib = pkgs.lib; enableLightDesktop = true; };
  style = pkgs.writeText "desktop-osd-style.css" config.content.environment.etc."xdg/desktop-osd/style.css".text;
in
pkgs.runCommand "desktop-backlight-check" {
  nativeBuildInputs = [
    (pkgs.python3.withPackages (python: [ python.pygobject3 ]))
    pkgs.dbus pkgs.glib pkgs.xorg-server pkgs.grim pkgs.wlr-randr pkgs.wtype
    config.content.programs.labwc.package
  ];
} ''
  export PYTHONPATH=${./.}
  export GSETTINGS_BACKEND=memory
  export GSETTINGS_SCHEMA_DIR=${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}/glib-2.0/schemas
  export XDG_DATA_DIRS=${pkgs.adwaita-icon-theme}/share
  export GDK_PIXBUF_MODULE_FILE=${pkgs.librsvg}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache
  Xvfb :98 -nolisten tcp &
  xvfb_pid=$!
  trap 'kill "$xvfb_pid"' EXIT
  for attempt in $(seq 1 100); do
    test -S /tmp/.X11-unix/X98 && break
    sleep 0.05
  done
  DISPLAY=:98 GDK_BACKEND=x11 python3 ${./check-desktop-backlight.py} \
    --fixture ${desktop.tests}/bin/desktop-backlight-fixture \
    --dbus-config ${pkgs.dbus}/share/dbus-1/session.conf
  dbus-run-session --config-file=${pkgs.dbus}/share/dbus-1/session.conf -- \
    python3 ${./check-desktop-osd.py} \
      --binary ${desktop.tests}/bin/desktop-backlight-fixture --style ${style} \
      --loader-cache "$GDK_PIXBUF_MODULE_FILE" \
      --dbus-config ${pkgs.dbus}/share/dbus-1/session.conf
  touch "$out"
''
