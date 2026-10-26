{ pkgs }:
let
  desktop = import ../labwc.nix {
    inherit pkgs;
    lib = pkgs.lib;
    enableLightDesktop = true;
  };
  style =
    pkgs.writeText "waybar-style.css"
      desktop.content.environment.etc."xdg/desktop-panel/style.css".text;
  zigDesktop = import ../desktop-zig.nix { inherit pkgs; };
in
zigDesktop.overrideAttrs (old: {
  checkPhase = old.checkPhase + ''
    G_DEBUG=fatal-criticals "$out/bin/waybar-power-fixture" ${style}
  '';
})
