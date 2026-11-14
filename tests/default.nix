{ pkgs }:
{
  desktop = import ./desktop-vm.nix { inherit pkgs; };
}
// pkgs.lib.genAttrs [
  "accessibility"
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
