{ pkgs }:
import ./fixture.nix { inherit pkgs; } {
  name = "desktop-session-check";
  fixture = {
    name = "desktop-session-fixture";
    steps = "session-fixture";
    debug = true;
  };
  pygobject = true;
  gtkEnv = true;
  fonts = true;
  noAtBridge = true;
  memorySettings = true;
  headless = true;
  nativeBuildInputs = [ pkgs.dbus ];
  script =
    { fixture, dbusRun, ... }:
    ''
      G_DEBUG=fatal-criticals ${dbusRun} python3 ${./check-desktop-session.py} --binary ${fixture}/bin/desktop-session-fixture
    '';
}
