{ pkgs }:
{
  desktop = import ./desktop-vm.nix { inherit pkgs; };
}
// pkgs.lib.genAttrs [
  "audio"
  "backlight"
  "battery"
  "idle"
  "lock"
  "memory"
  "network"
  "output"
  "polkit"
  "portal"
  "portal-capture"
  "screenshot"
  "secrets"
  "session"
  "shell"
  "ui"
] (name: import (./. + "/desktop-${name}-fixture.nix") { inherit pkgs; })
# The headless fixtures again, on the wlroots-free compositor.
// pkgs.lib.listToAttrs (
  map
    (name: {
      name = "${name}-native";
      value = import (./. + "/desktop-${name}-fixture.nix") {
        pkgs = pkgs // {
          desktopNativeCompositor = true;
        };
      };
    })
    [
      "audio"
      "memory"
      "network"
      "session"
      "ui"
    ]
)
