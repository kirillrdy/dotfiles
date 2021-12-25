{ config, pkgs, ... }:
import ./common.nix {
  hostName = "osaka";
  hardwareConfiguration = ./hardware-configuration-osaka.nix;
  inherit config pkgs;
}

