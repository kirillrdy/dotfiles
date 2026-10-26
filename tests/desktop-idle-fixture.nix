{ pkgs }:
let
  desktop = import ../desktop-zig.nix { inherit pkgs; };
  config = import ../labwc.nix {
    inherit pkgs;
    lib = pkgs.lib;
    enableLightDesktop = true;
  };
in
pkgs.runCommand "desktop-idle-check" {
  nativeBuildInputs = [
    (pkgs.python3.withPackages (python: [ python.pygobject3 ]))
    pkgs.dbus
    pkgs.wtype
  ];
} ''
  python3 ${./check-desktop-idle.py} \
    --dbus-config ${pkgs.dbus}/share/dbus-1/session.conf \
    --fixture ${desktop.tests}/bin/desktop-idle-fixture \
    --locker ${desktop.tests}/bin/desktop-lock-fixture \
    --compositor ${config.content.programs.labwc.package}/bin/labwc
  touch "$out"
''
