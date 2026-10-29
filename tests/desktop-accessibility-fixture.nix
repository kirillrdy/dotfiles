{ pkgs }:
let
  dbus = import ../desktop-dbus-libs.nix { inherit pkgs; };
  toolkit = import ../desktop-gtk-libs.nix {
    inherit pkgs dbus;
    accessibilitySupport = true;
  };
in
pkgs.runCommand "desktop-accessibility-check"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.dbus
      pkgs.glib
    ];
  }
  ''
    export XDG_RUNTIME_DIR="$TMPDIR/runtime"
    mkdir -m 700 "$XDG_RUNTIME_DIR"
    dbus-run-session --config-file=${pkgs.dbus}/share/dbus-1/session.conf -- \
      python3 ${./check-desktop-accessibility.py} \
        --launcher ${toolkit.accessibility}/libexec/at-spi-bus-launcher
    touch "$out"
  ''
