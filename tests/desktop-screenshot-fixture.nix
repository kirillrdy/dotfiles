{ pkgs }:
import ./fixture.nix { inherit pkgs; } {
  name = "desktop-native-screenshot-check";
  withDesktop = true;
  nativeBuildInputs = [
    pkgs.dbus
    pkgs.wl-clipboard
    pkgs.wlr-randr
    pkgs.wtype
  ];
  env.FONTCONFIG_FILE = "${pkgs.fontconfig.out}/etc/fonts/fonts.conf";
  script =
    { desktop, dbusRun, ... }:
    ''
      ${dbusRun} python3 ${./check-desktop-screenshot.py} --bin-dir ${desktop}/bin \
        --pointer-fixture ${desktop.tests}/bin/desktop-pointer-fixture
    '';
}
