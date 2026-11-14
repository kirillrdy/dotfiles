{ pkgs }:
import ./fixture.nix { inherit pkgs; } {
  name = "desktop-audio-check";
  fixture = {
    name = "desktop-audio-fixture";
    steps = "audio-fixture";
  };
  nativeBuildInputs = [
    pkgs.dbus
    pkgs.pipewire
    pkgs.wireplumber
  ];
  gtkEnv = true;
  headless = true;
  script =
    { fixture, dbusRun, ... }:
    ''
      ${dbusRun} python3 ${./check-desktop-audio.py} --fixture ${fixture}/bin/desktop-audio-fixture
    '';
}
