{ pkgs }:
let
  desktop = import ../labwc.nix {
    inherit pkgs;
    lib = pkgs.lib;
    enableLightDesktop = true;
  };
  style = pkgs.writeText "waybar-style.css" desktop.content.environment.etc."xdg/waybar/style.css".text;
in
pkgs.stdenv.mkDerivation {
  pname = "waybar-power-fixture";
  version = "1";
  dontUnpack = true;
  nativeBuildInputs = [ pkgs.pkg-config pkgs.xorg-server ];
  buildInputs = [ pkgs.gtk3 pkgs.json-glib ];
  buildPhase = ''
    mkdir tests
    cp ${./waybar-power-fixture.c} tests/waybar-power-fixture.c
    cp ${../waybar-gnome.c} waybar-gnome.c
    $CC -std=gnu11 -Wall -Wextra -Werror tests/waybar-power-fixture.c \
      $(pkg-config --cflags --libs gtk+-3.0 json-glib-1.0) -lm -o fixture
  '';
  doCheck = true;
  checkPhase = ''
    Xvfb :99 -nolisten tcp &
    xvfb_pid=$!
    trap 'kill "$xvfb_pid"' EXIT
    export DISPLAY=:99
    # Wait for Xvfb's socket before GTK connects.
    for attempt in $(seq 1 100); do
      test -S /tmp/.X11-unix/X99 && break
      sleep 0.05
    done
    G_DEBUG=fatal-criticals ./fixture ${style}
  '';
  installPhase = ''
    install -Dm755 fixture "$out/bin/waybar-power-fixture"
  '';
}
