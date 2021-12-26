{ config, pkgs, lib, ... }:
import ./common.nix {
  hostName = "osaka";
  inherit config pkgs lib;
}

