{ config, pkgs, ... }:
import ./common.nix {
  hostName = "shinseikai";
  inherit config pkgs;
  enableNvidia = true;
}

