{
  description = "my computers in flakes";
  inputs.nixpkgs.url = "github:nixos/nixpkgs";
  outputs = { self, nixpkgs }:
    {
      packages.x86_64-linux.neovim = import ./neovim.nix { pkgs = import nixpkgs { system = "x86_64-linux"; }; };
      packages.x86_64-darwin.neovim = import ./neovim.nix { pkgs = import nixpkgs { system = "x86_64-darwin"; }; };
      nixosConfigurations =
        let
          substitute = "s3://wps-0000000000/nix?region=ap-southeast-2";
          pkgs = import nixpkgs { system = "x86_64-linux"; };
          updateScript = pkgs.writeScript "update" ''
            #!/bin/sh

            set -eu
            set -f # disable globbing
            export IFS=' '

            echo "Uploading paths" $OUT_PATHS
            exec nix copy --to "${substitute}" $OUT_PATHS
          '';
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
                  nix = {
                    extraOptions = ''
                      experimental-features = nix-command flakes
                      post-build-hook = ${updateScript}
                    '';
                  };
                  nix.settings.trusted-users = [ "root" "kirillvr" ];
                  nix.settings.substituters = [ substitute ];
                  nix.settings.require-sigs = false;

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
          # Retired 20-10-2022
          #tsuruhashi = nixpkgs.lib.nixosSystem (simplesystem { hostName = "tsuruhashi"; rootPool = "tsuruhashi/root"; bootDevice = "/dev/sda3"; swapDevice = "/dev/sda2"; });
          # amd ryzen 5
          shinseikai = nixpkgs.lib.nixosSystem (simplesystem { hostName = "shinseikai"; enableNvidia = true; });
          # legacy, yao: T460s
        };
    };
}
