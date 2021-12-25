{ config, pkgs, ... }:
import ./common.nix {
  hostName = "osaka";
  inherit config pkgs;
}

