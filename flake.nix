{
  description = "my computers in flakes";
  inputs.nixpkgs.url = "github:nixos/nixpkgs";
  outputs = { self, nixpkgs }:
    {
      nixosConfigurations =
        let
          simplesystem = { hostName, enableNvidia ? false, rootPool ? "zroot/root", bootDevice ? "/dev/nvme0n1p3", swapDevice ? "/dev/nvme0n1p2" }: {
            system = "x86_64-linux";
            modules = [
              ({ pkgs, lib, modulesPath, ... }:
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
                  fileSystems."/" = { device = rootPool; fsType = "zfs"; };
                  fileSystems."/boot" = { device = bootDevice; fsType = "vfat"; };
                  swapDevices = [{ device = swapDevice; }];
                  nix = {
                    extraOptions = ''
                      experimental-features = nix-command flakes
                    '';
                  };

                  powerManagement.cpuFreqGovernor = if !enableNvidia then lib.mkDefault "powersave" else null;

                  nixpkgs.config.allowUnfree = true;
                  boot.loader.systemd-boot.enable = true;
                  boot.loader.efi.canTouchEfiVariables = true;
                  boot.kernelPackages = pkgs.linuxPackages_5_18;
                  boot.zfs.enableUnstable = false;

                  networking.hostId = "00000000";
                  networking.hostName = hostName;
                  time.timeZone = "Australia/Melbourne";

                  services.logind.extraConfig = ''
                    RuntimeDirectorySize=10G
                  '';

                  i18n.defaultLocale = "en_AU.UTF-8";
                  services.gnome.core-utilities.enable = false;
                  services.gnome.tracker-miners.enable = false;
                  services.gnome.tracker.enable = false;
                  services.xserver.desktopManager.gnome.enable = true;
                  services.xserver.displayManager.autoLogin.enable = true;
                  services.xserver.displayManager.autoLogin.user = "kirillvr";
                  services.xserver.enable = true;
                  services.xserver.videoDrivers = if enableNvidia then [ "nvidia" ] else [ "modesetting" ];
                  services.xserver.xkbOptions = "caps:none";
                  services.tailscale.enable = false;

                  services.pipewire.media-session.enable = true;
                  services.pipewire.wireplumber.enable = false;

                  environment.systemPackages = with pkgs; [
                    awscli2
                    awsebcli
                    firefox
                    git
                    gnome-console
                    gnome-text-editor
                    gnome.baobab
                    gnome.eog
                    gnome.file-roller
                    gnome.gnome-boxes
                    gnome.gnome-system-monitor
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
                  virtualisation.libvirtd.enable = true;
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
          # Lenovo X1 gen9
          osaka = nixpkgs.lib.nixosSystem (simplesystem { hostName = "osaka"; });
          # intel i7
          tsuruhashi = nixpkgs.lib.nixosSystem (simplesystem { hostName = "tsuruhashi"; rootPool = "tsuruhashi/root"; bootDevice = "/dev/sda3"; swapDevice = "/dev/sda2"; });
          # amd ryzen 5
          shinseikai = nixpkgs.lib.nixosSystem (simplesystem { hostName = "shinseikai"; enableNvidia = true; });
          # legacy, yao: T460s
        };
    };
}
