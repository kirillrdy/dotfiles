{
  description = "my computers in flakes";
  #inputs.nixpkgs.url = "github:nixos/nixpkgs";
  outputs = { self, nixpkgs }:
    {
      packages.x86_64-linux.neovim = import ./neovim.nix { pkgs = import nixpkgs { system = "x86_64-linux"; }; };
      nixosConfigurations =
        let
          simplesystem = { hostName, enableNvidia ? false }: {
            system = "x86_64-linux";
            modules = [
              ({ pkgs, lib, modulesPath, ... }:
                {
                  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];
                  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
                  boot.initrd.availableKernelModules = [ "nvme" ];
                  fileSystems."/" = { device = "zroot/root"; fsType = "zfs"; };
                  fileSystems."/boot" = { device = "/dev/nvme0n1p3"; fsType = "vfat"; };
                  swapDevices = [{ device = "/dev/nvme0n1p2"; }];
                  nix.extraOptions = ''
                    experimental-features = nix-command flakes
                  '';

                  nix.settings.max-jobs = 1;
                  nixpkgs.config.allowUnfree = true;
                  boot.loader.systemd-boot.enable = true;
                  boot.loader.efi.canTouchEfiVariables = true;
                  boot.kernelPackages = pkgs.linuxPackages_6_3;

                  networking.hostId = "00000000";
                  networking.hostName = hostName;
                  time.timeZone = "Australia/Melbourne";

                  i18n.defaultLocale = "en_AU.UTF-8";

                  services.xserver.desktopManager.gnome.enable = true;
                  services.xserver.displayManager.gdm.enable = !enableNvidia;
                  services.xserver.enable = true;
                  services.xserver.videoDrivers = if enableNvidia then [ "nvidia" ] else [ "modesetting" ];
                  services.xserver.xkbOptions = "caps:none";
                  services.xserver.displayManager.lightdm.enable = true;
                  services.xserver.displayManager.autoLogin.enable = true;
                  services.xserver.displayManager.autoLogin.user = "kirillvr";
                  environment.systemPackages = with pkgs; [
                    firefox
                  ];
                  users.users.kirillvr = { isNormalUser = true; extraGroups = [ "wheel" "docker" "vboxusers" ]; };
                  system.stateVersion = "24.11"; # I come from the future
                })
            ];
          };
        in
        {
          # Lenovo X1 gen9
          osaka = nixpkgs.lib.nixosSystem (simplesystem { hostName = "osaka"; });

          # intel i7
          # Retired 20-10-2022
          #tsuruhashi = nixpkgs.lib.nixosSystem (simplesystem { hostName = "tsuruhashi"; rootPool = "tsuruhashi/root"; bootDevice = "/dev/sda3"; swapDevice = "/dev/sda2"; });
          # amd ryzen 5
          shinseikai = nixpkgs.lib.nixosSystem (simplesystem { hostName = "shinseikai"; enableNvidia = true; });
          # legacy, yao: T460s

          tsutenkaku = nixpkgs.lib.nixosSystem (simplesystem { hostName = "tsutenkaku"; enableNvidia = true; });
        };
    };
}
