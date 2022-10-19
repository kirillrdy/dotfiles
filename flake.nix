{
  description = "my computers in flakes";
  inputs.nixpkgs.url = "github:nixos/nixpkgs";
  inputs.nixpkgs-binary.url = "nixpkgs";
  outputs = { self, nixpkgs, nixpkgs-binary }:
    {
      nixosConfigurations =
        let
          pkgs-binary = import nixpkgs-binary { system = "x86_64-linux"; };
          simplesystem = { hostName, enableNvidia ? false, rootPool ? "zroot/root", bootDevice ? "/dev/nvme0n1p3", swapDevice ? "/dev/nvme0n1p2" }: {
            system = "x86_64-linux";
            modules = [
              ({ pkgs, lib, modulesPath, ... }:
                {
                  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];
                  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

                  boot.initrd.availableKernelModules = [ "nvme" ];
                  fileSystems."/" = { device = rootPool; fsType = "zfs"; };
                  fileSystems."/boot" = { device = bootDevice; fsType = "vfat"; };
                  swapDevices = [{ device = swapDevice; }];
                  nix = { extraOptions = "experimental-features = nix-command flakes"; };

                  powerManagement.cpuFreqGovernor = if !enableNvidia then lib.mkDefault "powersave" else null;

                  nixpkgs.config.allowUnfree = true;
                  boot.loader.systemd-boot.enable = true;
                  boot.loader.efi.canTouchEfiVariables = true;
                  boot.kernelPackages = pkgs.linuxPackages_5_19;

                  fonts.fonts = with pkgs; [ carlito dejavu_fonts ipafont kochi-substitute source-code-pro ttf_bitstream_vera ];

                  networking.hostId = "00000000";
                  services.avahi.nssmdns = true;
                  services.avahi.publish.enable = true;
                  services.avahi.publish.addresses = true;
                  networking.hostName = hostName;
                  time.timeZone = "Australia/Melbourne";

                  services.logind.extraConfig = "RuntimeDirectorySize=10G";

                  i18n.defaultLocale = "en_AU.UTF-8";
                  i18n.inputMethod = { enabled = "ibus"; ibus.engines = with pkgs.ibus-engines; [ mozc ]; };

                  services.gnome.core-utilities.enable = false;
                  services.gnome.tracker-miners.enable = false;
                  services.gnome.tracker.enable = false;
                  services.xserver.desktopManager.gnome.enable = true;
                  services.xserver.displayManager.gdm.enable = true;
                  services.xserver.enable = true;
                  services.xserver.videoDrivers = if enableNvidia then [ "nvidia" ] else [ "modesetting" ];
                  services.xserver.xkbOptions = "caps:none";
                  services.tailscale.enable = false;
                  services.openssh.enable = true;
                  environment.gnome.excludePackages = [ pkgs.orca ];
                  environment.variables.EDITOR = "nvim";
                  environment.systemPackages = with pkgs; [
                    awscli2
                    nixpkgs-review
                    nix-tree
                    awsebcli
                    evince
                    ffmpeg
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
                    pkgs-binary.chromium
                    pkgs-binary.firefox
                    pkgs-binary.libreoffice
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
                  system.stateVersion = "22.11"; # Did you read the comment?
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
