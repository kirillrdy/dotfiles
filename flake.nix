{
  description = "my computers in flakes";
  inputs.nixpkgs.url = "github:nixos/nixpkgs";
  inputs.awsebcli.url = "github:kirillrdy/nixpkgs/awsebcli";
  outputs = { self, nixpkgs, awsebcli }:
    {
      nixosConfigurations =
        let
          simplesystem = { hostName, enableNvidia ? false }: {
            system = "x86_64-linux";
            modules = [
              ({ pkgs
               , lib
               , modulesPath
               , ...
               }:
                {
                  imports =
                    [
                      (modulesPath + "/installer/scan/not-detected.nix")
                      #"${nixpkgs}/nixos/modules/virtualisation/qemu-vm.nix"
                    ];

                  #virtualisation.memorySize = 8000;
                  #virtualisation.cores = 8;
                  #virtualisation.diskSize = 1024 * 10;

                  boot.initrd.availableKernelModules = [ "nvme" ];
                  fileSystems."/" = {
                    device = "zroot/root";
                    fsType = "zfs";
                  };
                  fileSystems."/boot" = {
                    device = "/dev/nvme0n1p3";
                    fsType = "vfat";
                  };
                  swapDevices = [{ device = "/dev/nvme0n1p2"; }];
                  nix = {
                    extraOptions = ''
                      experimental-features = nix-command flakes
                    '';
                  };

                  # TODO maybe not on desktop, check default value
                  powerManagement.cpuFreqGovernor = lib.mkDefault "powersave";

                  nixpkgs.config.allowUnfree = true;
                  boot.loader.systemd-boot.enable = true;
                  boot.loader.efi.canTouchEfiVariables = true;
                  boot.kernelPackages = pkgs.linuxPackages_latest;
                  boot.zfs.enableUnstable = false;

                  networking.hostId = "00000000";
                  networking.hostName = hostName;
                  time.timeZone = "Australia/Melbourne";

                  services.logind.extraConfig = ''
                    RuntimeDirectorySize=10G
                  '';

                  i18n.defaultLocale = "en_AU.UTF-8";
                  services.xserver.enable = true;
                  services.xserver.desktopManager.gnome.enable = true;
                  services.gnome.core-utilities.enable = false;
                  services.gnome.tracker-miners.enable = false;
                  services.gnome.tracker.enable = false;
                  #services.xserver.displayManager.gdm.enable = true;
                  services.xserver.displayManager.autoLogin.enable = true;
                  services.xserver.displayManager.autoLogin.user = "kirillvr";
                  services.xserver.xkbOptions = "caps:none";
                  services.xserver.videoDrivers = if enableNvidia then [ "nvidia" ] else [ "modesetting" ];

                  environment.systemPackages = with pkgs; [
                    awscli2
                    awsebcli.legacyPackages.x86_64-linux.awsebcli
                    chromium
                    emacs
                    firefox
                    git
                    gnome.baobab
                    gnome.eog
                    gnome.file-roller
                    gnome.gnome-system-monitor
                    gnome.gnome-terminal
                    gnome.nautilus
                    gnome.totem
                    neovide
                    neovim
                    obs-studio
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
                  virtualisation.docker.enableNvidia = enableNvidia;
                  hardware.opengl.driSupport32Bit = enableNvidia;
                  systemd.enableUnifiedCgroupHierarchy = false;
                  networking.firewall.enable = false;
                  system.stateVersion = "21.11"; # Did you read the comment?
                })
            ];
          };
        in
        {
          osaka = nixpkgs.lib.nixosSystem (simplesystem { hostName = "osaka"; });
          shinseikai = nixpkgs.lib.nixosSystem (simplesystem { hostName = "shinseikai"; enableNvidia = true; });
        };
    };
}
