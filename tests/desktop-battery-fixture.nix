{ pkgs }:
import ./fixture.nix { inherit pkgs; } {
  name = "desktop-battery-check";
  pygobject = true;
  withDesktop = true;
  gtkEnv = true;
  fonts = true;
  nativeBuildInputs = [ pkgs.dbus ];
  script =
    { desktop, dbusRun, ... }:
    ''
      ${dbusRun} python3 ${./check-desktop-battery.py} --fixture ${desktop.tests}/bin/desktop-battery-fixture
    '';
}
