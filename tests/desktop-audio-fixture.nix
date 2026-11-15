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
    pkgs.wtype
    pkgs.wlrctl
  ];
  gtkEnv = true;
  headless = true;
  script =
    {
      fixture,
      desktop,
      dbusRun,
      ...
    }:
    ''
      ${dbusRun} python3 ${./check-desktop-audio.py} --fixture ${fixture}/bin/desktop-audio-fixture \
        --desktop ${desktop}/bin/desktop-zig --pointer ${desktop.tests}/bin/desktop-pointer-fixture
    '';
}
