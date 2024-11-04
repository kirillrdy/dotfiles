{
  hostName,
  enableNvidia ? false,
}:
{
  system = "x86_64-linux";
  modules = [
    (
      {
        pkgs,
        lib,
        modulesPath,
        ...
      }:
      {
        boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
        boot.initrd.availableKernelModules = [ "nvme" ];
        #boot.kernelPackages = pkgs.linuxPackages_6_10;
        boot.loader.efi.canTouchEfiVariables = true;
        boot.loader.systemd-boot.enable = true;
        environment.variables = {
          EDITOR = "nvim";
          NEOVIDE_FORK = 1;
          NIXOS_OZONE_WL = 1; # fixes slack
        };
        fileSystems."/" = {
          device = "zroot/root";
          fsType = "zfs";
        };
        fileSystems."/boot" = {
          device = "/dev/nvme0n1p3";
          fsType = "vfat";
        };
        fonts.packages = with pkgs; [
          kochi-substitute
          font-awesome
          roboto
          cantarell-fonts
          dejavu_fonts
          source-code-pro
          source-sans
        ];
        hardware.nvidia.modesetting.enable = enableNvidia;
        i18n.defaultLocale = "en_AU.UTF-8";
        imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];
        networking.firewall.enable = false;
        networking.hostId = "00000000";
        networking.networkmanager.enable = true;
        networking.hostName = hostName;
        nix.extraOptions = ''
          experimental-features = nix-command flakes
          allow-import-from-derivation = false
        '';
        nix.settings.max-jobs = 1;
        nix.settings.trusted-users = [ "kirillvr" ];
        #i18n.inputMethod = { enabled = "ibus"; ibus.engines = with pkgs.ibus-engines; [ mozc ]; };
        nixpkgs.config.allowUnfree = true;
        programs.git.config = {
          user.name = "Kirill Radzikhovskyy";
          user.email = "kirillrdy@gmail.com";
        };
        programs.git.enable = true;
        services.avahi.enable = true;
        services.avahi.nssmdns4 = true;
        services.avahi.publish.addresses = true;
        services.avahi.publish.enable = true;
        services.displayManager.sessionPackages = [ pkgs.niri ];
        services.logind.extraConfig = "RuntimeDirectorySize=10G";
        services.openssh.enable = true;
        services.power-profiles-daemon.enable = true;
        services.tailscale.enable = true;
        services.xserver.enable = true;
        services.xserver.excludePackages = [ pkgs.xterm ];
        services.xserver.videoDrivers = if enableNvidia then [ "nvidia" ] else [ "modesetting" ];
        hardware.nvidia.open = true;
        programs.niri.enable = true;

        swapDevices = [ { device = "/dev/nvme0n1p2"; } ];
        zramSwap.enable = true;
        system.stateVersion = "24.11"; # I come from the future
        time.timeZone = "Australia/Melbourne";
        users.users.kirillvr = {
          isNormalUser = true;
          initialPassword = "password";
          extraGroups = [
            "wheel"
            "docker"
          ];
        };
        virtualisation.docker.enable = true;
        virtualisation.docker.storageDriver = "zfs";
        hardware.nvidia-container-toolkit.enable = enableNvidia;
        hardware.graphics.enable32Bit = enableNvidia;
        environment.systemPackages = with pkgs; [
          (import ./neovim.nix pkgs)
          (pkgs.writeScriptBin "hx" "GOOS=js GOARCH=wasm ${helix}/bin/hx -c ${./config.toml} $@")
          alacritty
          btop
          file
          firefox
          fuzzel
          go
          golangci-lint
          golangci-lint-langserver
          gopls
          imv
          lua-language-server
          mako
          neovide
          nil
          nix-tree
          nix-update
          nixfmt-rfc-style
          nixpkgs-review
          pavucontrol
          ripgrep
          slack
          swayosd
          tig
          waybar
          wl-clipboard
          zig
          zls
        ];
      }
    )
  ];
}
