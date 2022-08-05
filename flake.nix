{
  description = "my computers in flakes";
  inputs.nixpkgs.url = "github:nixos/nixpkgs";
  outputs = { self, nixpkgs }:
    {
      nixosConfigurations =
        let
          simplesystem = { hostName,
                           enableSsh ? false,
                           enableNvidia ? false,
                           enableCardanoDev ? false,
                           enableTailScale ? false,
                           rootPool ? "zroot/root",
                           bootDevice ? "/dev/nvme0n1p3",
                           swapDevice ? "/dev/nvme0n1p2" }: {
            system = "x86_64-linux";
            modules = [
              ({ pkgs, lib, modulesPath, ... }:
                {
                  imports =
                    [
                      (modulesPath + "/installer/scan/not-detected.nix")
                    ];

                  boot.initrd.availableKernelModules = [ "nvme" ];
                  fileSystems."/" = { device = rootPool; fsType = "zfs"; };
                  fileSystems."/boot" = { device = bootDevice; fsType = "vfat"; };
                  swapDevices = [{ device = swapDevice; }];
                  nix = {
                    extraOptions = "experimental-features = nix-command flakes";
                  } // (if enableCardanoDev then {
                    settings = {
                      substituters = [ "https://hydra.iohk.io" "https://iohk.cachix.org" ];
                      trusted-public-keys = [ "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ=" "iohk.cachix.org-1:DpRUyj7h7V830dp/i6Nti+NEO2/nhblbov/8MW7Rqoo=" ];
                    };

                  } else {});

                  powerManagement.cpuFreqGovernor = if !enableNvidia then lib.mkDefault "powersave" else null;
                  # sound
                  sound.enable = true;
                  nixpkgs.config.pulseaudio = true;
                  nixpkgs.config.allowUnfree = true;
                  boot.loader.systemd-boot.enable = true;
                  boot.loader.efi.canTouchEfiVariables = true;
                  boot.kernelPackages = pkgs.linuxPackages_5_18;
                  boot.zfs.enableUnstable = false;

                  networking.hostId = "00000000";
                  networking.hostName = hostName;
                  networking.networkmanager.enable = true;
                  time.timeZone = "Australia/Melbourne";

                  services.logind.extraConfig = ''
                    RuntimeDirectorySize=10G
                  '';

                  services.openssh = {
                    enable = enableSsh;
                    #passwordAuthentication = true;
                  };
                  i18n.defaultLocale = "en_AU.UTF-8";
                  services.gnome.core-utilities.enable = false;
                  services.gnome.tracker-miners.enable = false;
                  services.gnome.tracker.enable = false;
                  services.xserver.desktopManager.gnome.enable = true;
                  # set to true cause blank screen when boot
                  services.xserver.displayManager.gdm.enable = false;
                  services.xserver.displayManager.autoLogin.enable = true;
                  services.xserver.displayManager.autoLogin.user = "rxiao";
                  services.xserver.enable = true;
                  services.xserver.libinput.enable = true;
                  services.xserver.videoDrivers = if enableNvidia then [ "nvidia" ] else [ "modesetting" ];
                  services.xserver.xkbOptions = "caps:none";
                  services.tailscale.enable = enableTailScale;
                  services.pcscd.enable = true;

                  # enable gpg
                  programs.gnupg.agent = {
                    enable = true;
                    pinentryFlavor = "curses";
                    enableSSHSupport = true;
                  };

                  programs.steam = {
                    enable = true;
                    remotePlay.openFirewall = true; # Open ports in the firewall for Steam Remote Play
                    dedicatedServer.openFirewall = true; # Open ports in the firewall for Source Dedicated Server
                  };
                  programs.gnome-disks.enable = true;
                  environment.systemPackages = with pkgs; [
                    awscli2
                    awsebcli
                    docker-compose
                    evince
                    firefox
                    git
                    gnome-text-editor
                    gnome.baobab
                    gnome.eog
                    gnome.file-roller
                    gnome.gnome-boxes
                    gnome.gnome-system-monitor
                    gnome.nautilus
                    vlc
                    pinentry-curses
                    htop
                    vim
                    lm_sensors
                    jetbrains.pycharm-community
                    jetbrains.goland
                    mendeley
                    obs-studio
                    silver-searcher
                    rnix-lsp
                    slack
                    helix
                    tig
                    xclip
                    chromium
                    nodejs
                    rustup
                    clang
                    trunk
                    rust-analyzer
                    gopls
                    haskell-language-server
                    python39Packages.python-lsp-server
                    gnome-console];
                  users.users.rxiao = {
                    isNormalUser = true;
                    extraGroups = [ "wheel" "docker" "vboxusers" ];
                  };
                  virtualisation.libvirtd.enable = true;
                  virtualisation.docker.enable = true;
                  virtualisation.docker.storageDriver = "zfs";
                  virtualisation.docker.enableNvidia = enableNvidia;
                  hardware.opengl.enable = true;
                  hardware.opengl.driSupport32Bit = enableNvidia;
                  systemd.enableUnifiedCgroupHierarchy = false;
                  networking.firewall.enable = false;
                  system.stateVersion = "22.05"; # Did you read the comment?
                  environment.interactiveShellInit = ''
                      alias athena='ssh rxiao@192.168.50.69'
                      alias artemis='ssh rxiao@artemis.silverpond.com.au'
                    '';
                })
            ];
          };
        in
        {
          # Lenovo T490
          apollo = nixpkgs.lib.nixosSystem (simplesystem { hostName = "apollo"; });
          # amd ryzen 7 1700
          athena = nixpkgs.lib.nixosSystem (simplesystem { hostName = "athena"; enableNvidia = true; enableSsh = true; enableCardanoDev = true;});
          # amd ryzen 7 3700x
          wotan = nixpkgs.lib.nixosSystem (simplesystem { hostName = "wotan"; enableNvidia = true; enableCardanoDev = true;});
          # amd ryzen 3950x
          dante = nixpkgs.lib.nixosSystem (simplesystem { hostName = "dante";  enableNvidia = true; enableTailScale = true;});
        };
    };
}
