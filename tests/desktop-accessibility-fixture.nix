{ pkgs }:
let
  dbus = import ../desktop-dbus-libs.nix { inherit pkgs; };
  toolkit = import ../desktop-gtk-libs.nix {
    inherit pkgs dbus;
    accessibilitySupport = true;
  };
in
import ./fixture.nix { inherit pkgs; } {
  name = "desktop-accessibility-check";
  nativeBuildInputs = [
    pkgs.dbus
    pkgs.glib
  ];
  runtimeDir = true;
  script =
    { dbusRun, ... }:
    ''
      ${dbusRun} python3 ${./check-desktop-accessibility.py} \
        --launcher ${toolkit.accessibility}/libexec/at-spi-bus-launcher
    '';
}
