{ pkgs }:
import ./fixture.nix { inherit pkgs; } {
  name = "desktop-output-check";
  nativeBuildInputs = [ pkgs.wlr-randr ];
  script =
    { desktop, ... }:
    ''
      python3 ${./check-desktop-output.py} \
        --binary ${desktop}/bin/desktop-zig \
        --compositor ${desktop}/bin/desktop-zig
    '';
}
