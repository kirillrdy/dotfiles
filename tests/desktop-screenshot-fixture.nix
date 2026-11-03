{ pkgs }:
let
  desktop = import ../desktop-zig.nix { inherit pkgs; };
in
pkgs.runCommand "desktop-native-screenshot-check"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.dbus
      pkgs.wl-clipboard
      pkgs.wlr-randr
      pkgs.wtype
      desktop
    ];
  }
  ''
    export FONTCONFIG_FILE=${pkgs.fontconfig.out}/etc/fonts/fonts.conf
    dbus-run-session --config-file=${pkgs.dbus}/share/dbus-1/session.conf -- \
      python3 ${./check-desktop-screenshot.py} --bin-dir ${desktop}/bin \
        --pointer-fixture ${desktop.tests}/bin/desktop-pointer-fixture
    touch "$out"
  ''
