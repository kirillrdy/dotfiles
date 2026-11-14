{ pkgs }:
import ./fixture.nix { inherit pkgs; } {
  name = "desktop-idle-check";
  pygobject = true;
  nativeBuildInputs = [
    pkgs.dbus
    pkgs.wtype
  ];
  script =
    { desktop, dbusConfig, ... }:
    ''
      python3 ${./check-desktop-idle.py} \
        --dbus-config ${dbusConfig} \
        --fixture ${desktop.tests}/bin/desktop-idle-fixture \
        --locker ${desktop.tests}/bin/desktop-lock-fixture \
        --compositor ${desktop}/bin/desktop-zig
    '';
}
