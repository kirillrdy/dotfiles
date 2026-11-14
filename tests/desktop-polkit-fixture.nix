{ pkgs }:
import ./fixture.nix { inherit pkgs; } {
  name = "desktop-polkit-check";
  fixture = {
    name = "desktop-polkit-agent-fixture";
    steps = "shell polkit-fixture polkit-agent-fixture";
    stripZigRef = true;
  };
  pygobject = true;
  gtkEnv = true;
  fonts = true;
  nativeBuildInputs = [
    pkgs.dbus
    pkgs.wtype
  ];
  script =
    { fixture, dbusRun, ... }:
    ''
      ${dbusRun} python3 ${./check-desktop-polkit.py} --binary ${fixture}/bin/desktop-polkit-agent-fixture \
        --compositor ${fixture}/bin/desktop-zig --dialog-fixture ${fixture}/bin/desktop-polkit-fixture
    '';
}
