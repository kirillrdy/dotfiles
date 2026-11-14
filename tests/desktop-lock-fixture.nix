{ pkgs }:
import ./fixture.nix { inherit pkgs; } {
  name = "desktop-lock-check";
  nativeBuildInputs = [
    pkgs.dbus
    pkgs.wtype
    pkgs.wlr-randr
  ];
  script =
    { desktop, dbusRun, ... }:
    ''
      ${dbusRun} python3 ${./check-desktop-lock.py} \
        --binary ${desktop}/bin/desktop-zig \
        --fixture ${desktop.tests}/bin/desktop-lock-fixture \
        --compositor ${desktop}/bin/desktop-zig
    '';
}
