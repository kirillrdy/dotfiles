{ pkgs }:
pkgs.stdenv.mkDerivation {
  pname = "labwc-switcher-fixture";
  version = "1";
  dontUnpack = true;
  nativeBuildInputs = [ pkgs.pkg-config ];
  buildInputs = [ pkgs.gtk3 ];
  buildPhase = ''
    $CC -Wall -Wextra -Werror ${./labwc-switcher-fixture.c} \
      $(pkg-config --cflags --libs gtk+-3.0) -o labwc-switcher-fixture
  '';
  installPhase = ''
    install -Dm755 labwc-switcher-fixture "$out/bin/labwc-switcher-fixture"
  '';
}
