{ pkgs }:
let
  desktop = import ../desktop-zig.nix { inherit pkgs; };
  config = import ../labwc.nix {
    inherit pkgs;
    lib = pkgs.lib;
    enableLightDesktop = true;
  };
  etc = config.content.environment.etc;
  panelConfig = pkgs.writeText "desktop-panel-config.json" etc."xdg/desktop-panel/config.json".text;
  panelStyle = pkgs.writeText "desktop-panel-style.css" etc."xdg/desktop-panel/style.css".text;
  notificationStyle =
    pkgs.writeText "desktop-notifications-style.css"
      etc."xdg/desktop-notifications/style.css".text;
  osdStyle = pkgs.writeText "desktop-osd-style.css" etc."xdg/desktop-osd/style.css".text;
in
pkgs.runCommand "desktop-shell-check"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.dbus
      pkgs.glib
      pkgs.pipewire
      pkgs.wireplumber
    ];
  }
  ''
    export PYTHONPATH=${./.}
    export XDG_DATA_DIRS=${pkgs.adwaita-icon-theme}/share
    dbus-run-session --config-file=${pkgs.dbus}/share/dbus-1/session.conf -- python3 ${./check-desktop-shell.py} \
      --binary ${desktop}/bin/desktop-zig \
      --compositor ${desktop}/bin/desktop-zig \
      --panel-config ${panelConfig} --panel-style ${panelStyle} \
      --notification-style ${notificationStyle} --osd-style ${osdStyle}
    touch "$out"
  ''
