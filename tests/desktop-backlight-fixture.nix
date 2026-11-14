{ pkgs }:
import ./fixture.nix { inherit pkgs; } {
  name = "desktop-backlight-check";
  pygobject = true;
  withDesktop = true;
  gtkEnv = true;
  memorySettings = true;
  nativeBuildInputs = [
    pkgs.dbus
    pkgs.glib
    pkgs.xorg-server
    pkgs.grim
    pkgs.wlr-randr
    pkgs.wtype
    pkgs.pipewire
    pkgs.wireplumber
  ];
  script =
    {
      desktop,
      dbusConfig,
      dbusRun,
      ...
    }:
    ''
      Xvfb :98 -nolisten tcp &
      xvfb_pid=$!
      trap 'kill "$xvfb_pid"' EXIT
      for attempt in $(seq 1 100); do
        test -S /tmp/.X11-unix/X98 && break
        sleep 0.05
      done
      DISPLAY=:98 GDK_BACKEND=x11 python3 ${./check-desktop-backlight.py} \
        --fixture ${desktop.tests}/bin/desktop-backlight-fixture \
        --dbus-config ${dbusConfig}
      ${dbusRun} python3 ${./check-desktop-osd.py} \
        --binary ${desktop.tests}/bin/desktop-backlight-fixture \
        --loader-cache "$GDK_PIXBUF_MODULE_FILE" \
        --dbus-config ${dbusConfig}
    '';
}
