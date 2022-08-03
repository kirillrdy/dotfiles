{
  description = "my computers in flakes";
  inputs.nixpkgs.url = "github:nixos/nixpkgs";
  outputs = { self, nixpkgs }:
    {
      nixosConfigurations =
        let
          simplesystem = { dwm ? false, hostName, enableNvidia ? false, rootPool ? "zroot/root", bootDevice ? "/dev/nvme0n1p3", swapDevice ? "/dev/nvme0n1p2" }: {
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
                  nix = { extraOptions = "experimental-features = nix-command flakes"; };

                  powerManagement.cpuFreqGovernor = if !enableNvidia then lib.mkDefault "powersave" else null;

                  sound.enable = true;
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

                  i18n.defaultLocale = "en_AU.UTF-8";
                  services.gnome.core-utilities.enable = false;
                  services.gnome.tracker-miners.enable = false;
                  services.gnome.tracker.enable = false;
                  services.xserver.windowManager.dwm.enable = dwm;
                  services.xserver.desktopManager.gnome.enable = !dwm;
                  services.xserver.displayManager.autoLogin.enable = true;
                  services.xserver.displayManager.autoLogin.user = "rxiao";
                  services.xserver.enable = true;
                  services.xserver.libinput.enable = true;
                  services.xserver.videoDrivers = if enableNvidia then [ "nvidia" ] else [ "modesetting" ];
                  services.xserver.xkbOptions = "caps:none";
                  services.tailscale.enable = false;
                  nixpkgs.config.pulseaudio = true;

                  environment.variables.EDITOR = "nvim";
                  environment.systemPackages = with pkgs; [
                    awscli2
                    awsebcli
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
                    gnome.totem
                    neovide
                    vim
                    jetbrains.pycharm-community
                    neovim
                    obs-studio
                    ripgrep
                    rnix-lsp
                    slack
                    tig
                    xclip
                    chromium
                    nodejs
                    rustup
                    clang
                    trunk
                    rust-analyzer
                  ] ++ (if dwm then [ acpi dmenu st xterm ] else [ gnome-console ]);
                  users.users.rxiao = {
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
          # Lenovo T490
          apollo = nixpkgs.lib.nixosSystem (simplesystem { hostName = "apollo"; dwm = false; });
          # amd ryzen 7 1700
          tsuruhashi = nixpkgs.lib.nixosSystem (simplesystem { hostName = "tsuruhashi"; rootPool = "tsuruhashi/root"; bootDevice = "/dev/sda3"; swapDevice = "/dev/sda2"; });
          # amd ryzen 7 3700x
          wotan = nixpkgs.lib.nixosSystem (simplesystem { hostName = "wotan"; enableNvidia = true; });
          # legacy, yao: T460s
        };
    };
}
