{ pkgs }:
let
  zigDesktop = import ../desktop-zig.nix { inherit pkgs; };
in
zigDesktop.overrideAttrs (old: {
  # Run the quick-settings check while the check phase's compositor is still alive.
  checkPhase = pkgs.lib.replaceStrings
    [ "python3 tests/check-desktop-compositor.py" ]
    [ ''
      G_DEBUG=fatal-criticals "$out/bin/waybar-power-fixture"
      python3 tests/check-desktop-compositor.py'' ]
    old.checkPhase;
})
