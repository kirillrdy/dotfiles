{ pkgs }:
let
  desktop = import ../desktop-zig.nix { inherit pkgs; };
  config = import ../labwc.nix {
    inherit pkgs;
    lib = pkgs.lib;
    enableLightDesktop = true;
  };
  osdConfig =
    pkgs.writeText "desktop-osd-config.json"
      config.content.environment.etc."xdg/desktop-osd/config.json".text;
in
pkgs.runCommand "desktop-backlight-check"
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
    export GDK_PIXBUF_MODULE_FILE=${pkgs.librsvg}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache
    export XDG_RUNTIME_DIR="$TMPDIR/backlight-runtime"
    mkdir -m 700 "$XDG_RUNTIME_DIR"
    export WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_HEADLESS_OUTPUTS=1
    export WAYLAND_DISPLAY=wayland-0 GDK_BACKEND=wayland
    ${desktop}/bin/desktop-zig compositor-only > "$TMPDIR/backlight-compositor.log" 2>&1 &
    compositor_pid=$!
    trap 'kill "$compositor_pid"' EXIT
    for attempt in $(seq 1 100); do
      test -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" && break
      sleep 0.05
    done
    python3 ${./check-desktop-backlight.py} \
      --fixture ${desktop.tests}/bin/desktop-backlight-fixture \
      --dbus-config ${pkgs.dbus}/share/dbus-1/session.conf
    dbus-run-session --config-file=${pkgs.dbus}/share/dbus-1/session.conf -- \
      python3 ${./check-desktop-osd.py} \
        --binary ${desktop.tests}/bin/desktop-backlight-fixture --config ${osdConfig} \
        --loader-cache "$GDK_PIXBUF_MODULE_FILE" \
        --dbus-config ${pkgs.dbus}/share/dbus-1/session.conf
    touch "$out"
  ''
