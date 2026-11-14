{ pkgs }:
import ./fixture.nix { inherit pkgs; } {
  name = "desktop-memory-check";
  fixture = {
    name = "desktop-memory-tests";
    steps = "memory-tests";
    debug = true;
  };
  pygobject = true;
  gtkEnv = true;
  fonts = true;
  cacheDir = true;
  headless = true;
  nativeBuildInputs = [
    pkgs.dbus
    pkgs.pipewire
    pkgs.wireplumber
  ];
  script =
    { fixture, dbusRun, ... }:
    ''
      ${dbusRun} python3 ${./check-desktop-memory.py} --binary ${fixture}/bin/desktop-memory-tests \
        --valgrind ${pkgs.valgrind}/bin/valgrind --strip ${pkgs.binutils}/bin/strip
    '';
}
