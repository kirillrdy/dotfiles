{ pkgs }:
import ./fixture.nix { inherit pkgs; } {
  name = "desktop-network-check";
  fixture = {
    name = "desktop-network-fixture";
    steps = "network-fixture";
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
    { fixture, dbusConfig, ... }:
    ''
      G_DEBUG=fatal-criticals python3 ${./check-desktop-network.py} --binary ${fixture}/bin/desktop-network-fixture --dbus-config ${dbusConfig}
    '';
}
