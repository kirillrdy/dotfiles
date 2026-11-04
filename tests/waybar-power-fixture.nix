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
  # Run the stylesheet check while the check phase's compositor is still alive.
  checkPhase = pkgs.lib.replaceStrings
    [ "python3 tests/check-desktop-compositor.py" ]
    [ ''
      G_DEBUG=fatal-criticals "$out/bin/waybar-power-fixture" ${style}
      python3 tests/check-desktop-compositor.py'' ]
    old.checkPhase;
})
