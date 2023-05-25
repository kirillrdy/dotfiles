{
  description = "my computers in flakes";
  inputs.nixpkgs.url = "github:nixos/nixpkgs";
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

                  powerManagement.cpuFreqGovernor = if !enableNvidia then lib.mkDefault "powersave" else null;

                  nixpkgs.config.allowUnfree = true;
                  boot.loader.systemd-boot.enable = true;
                  boot.loader.efi.canTouchEfiVariables = true;
                  boot.kernelPackages = pkgs.linuxPackages_6_1;

                  fonts.enableDefaultFonts = true;
                  fonts.fonts = with pkgs; [ kochi-substitute ];

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
                  hardware.nvidia.open = enableNvidia;
                  services.xserver.xkbOptions = "caps:none";
                  services.tailscale.enable = false;
                  services.openssh.enable = true;
                  environment.gnome.excludePackages = [ pkgs.orca ];
                  environment.variables.EDITOR = "nvim";
                  programs.git.enable = true;
                  programs.git.config = {
                    user.name = "Kirill Radzikhovskyy";
                    user.email = "kirillrdy@gmail.com";
                  };
                  environment.systemPackages = with pkgs; [
                    (writeScriptBin "everything-everywhere-all-at-once" ''
                      set -ex
                      while true ; do
                      nix build -j 1 --no-link github:nixos/nixpkgs/master#awsebcli
                      nix build -j 1 --no-link github:nixos/nixpkgs/master#python3.pkgs.fastai
                      nix build -j 1 --no-link github:nixos/nixpkgs/master#python3.pkgs.mmcv
                      nix build -j 1 --no-link github:nixos/nixpkgs/staging-next#awsebcli
                      nix build -j 1 --no-link github:nixos/nixpkgs/python-updates#awsebcli
                      sleep 1000
                      done
                    '')
                    awscli2
                    microsoft-edge
                    awsebcli
                    evince
                    ffmpeg
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
                    (import ./neovim.nix { inherit pkgs; })
                    nix-tree
                    nixpkgs-review
                    firefox
                    ripgrep
                    rnix-lsp
                    slack
                    tig
                    xclip
                    rustup
                    rust-analyzer
                    wasm-bindgen-cli
                    trunk
                    clang
                    acpi
                    go
                    gopls
                  ];
                  users.users.kirillvr = { isNormalUser = true; extraGroups = [ "wheel" "docker" "vboxusers" ]; };
                  users.users.haru = { isNormalUser = true; extraGroups = [ "wheel" "docker" "vboxusers" ]; };
                  virtualisation.libvirtd.enable = true;
                  virtualisation.docker.enable = true;
                  virtualisation.docker.storageDriver = "zfs";
                  virtualisation.docker.enableNvidia = enableNvidia;
                  hardware.opengl.driSupport32Bit = enableNvidia;
                  networking.firewall.enable = false;
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
        };
    };
}
