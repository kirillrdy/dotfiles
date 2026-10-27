{ pkgs }:
let
  desktop = import ../desktop-zig.nix { inherit pkgs; };
  config = import ../labwc.nix { inherit pkgs; lib = pkgs.lib; enableLightDesktop = true; };
in
pkgs.runCommand "desktop-output-check" {
  nativeBuildInputs = [ pkgs.python3 pkgs.wlr-randr ];
} ''
  python3 ${./check-desktop-output.py} \
    --binary ${desktop}/bin/desktop-zig \
    --compositor ${config.content.programs.labwc.package}/bin/labwc
  touch "$out"
''
