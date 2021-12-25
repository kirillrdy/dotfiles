{ config, pkgs, ... }:

{
  imports =
    [
      /etc/nixos/hardware-configuration.nix
    ];
  nix = {
    extraOptions = ''
      experimental-features = nix-command flakes
    '';
  };
  nixpkgs.config.allowUnfree = true;
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.kernelPackages = pkgs.linuxPackages_latest;
  boot.zfs.enableUnstable = true;

  networking.hostId = "00000000";
  networking.hostName = "shinseikai";
  time.timeZone = "Australia/Melbourne";

  services.logind.extraConfig = ''
    RuntimeDirectorySize=20G
  '';

  networking.useDHCP = false;
  networking.interfaces.enp7s0.useDHCP = true;

  i18n.defaultLocale = "en_AU.UTF-8";
  services.xserver.enable = true;
  services.xserver.desktopManager.gnome.enable = true;
  #services.xserver.displayManager.gdm.enable = true;
  services.xserver.displayManager.autoLogin.enable = true;
  services.xserver.displayManager.autoLogin.user = "kirillvr";
  services.xserver.xkbOptions = "caps:none";
  services.xserver.videoDrivers = [ "nvidia" ];

  environment.systemPackages = with pkgs; [
    chromium
    emacs
    firefox
    git
    neovim
    neovim-qt
    peek
    ripgrep
    rnix-lsp
    slack
    tig
    xclip
  ];
  users.users.kirillvr = {
    isNormalUser = true;
    extraGroups = [ "wheel" "docker" "vboxusers" ];
  };
  virtualisation.virtualbox.host.enable = true;
  virtualisation.docker.enable = true;
  virtualisation.docker.storageDriver = "zfs";
  virtualisation.docker.enableNvidia = true;
  hardware.opengl.driSupport32Bit = true;

  networking.firewall.enable = false;
  system.stateVersion = "20.09"; # Did you read the comment?

}

