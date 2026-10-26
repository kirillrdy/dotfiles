{ pkgs }:
let
  desktop = import ../desktop-zig.nix { inherit pkgs; };
  config = import ../labwc.nix {
    inherit pkgs;
    lib = pkgs.lib;
    enableLightDesktop = true;
  };
in
pkgs.runCommand "desktop-lock-check" {
  nativeBuildInputs = [ pkgs.python3 pkgs.dbus pkgs.wtype pkgs.wlr-randr ];
} ''
  dbus-run-session --config-file=${pkgs.dbus}/share/dbus-1/session.conf -- \
    python3 ${./check-desktop-lock.py} \
      --binary ${desktop}/bin/desktop-zig \
      --fixture ${desktop.tests}/bin/desktop-lock-fixture \
      --compositor ${config.content.programs.labwc.package}/bin/labwc
  touch "$out"
''
