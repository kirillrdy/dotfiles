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
        boot.kernelPackages = pkgs.linuxPackages_6_18;
        boot.zfs.package = pkgs.zfs_2_4;
        boot.loader.efi.canTouchEfiVariables = true;
        boot.loader.systemd-boot.enable = true;
        environment.variables = {
          EDITOR = "nvim";
          NEOVIDE_FORK = 1;
        };
        fileSystems."/" = {
          device = "zroot/root";
          fsType = "zfs";
        };
        fileSystems."/boot" = {
          device = "/dev/nvme0n1p3";
          fsType = "vfat";
        };
        fonts.packages = with pkgs; [ kochi-substitute ];
        hardware.nvidia.modesetting.enable = enableNvidia;
        hardware.nvidia.nvidiaSettings = false;
        nix.settings.cores = 2;
        i18n.defaultLocale = "en_AU.UTF-8";
        imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];
        networking.firewall.enable = false;
        networking.hostId = "00000000";
        networking.networkmanager.enable = true;
        networking.networkmanager.plugins = lib.mkForce [ ];
        networking.hostName = hostName;
        nix.extraOptions = ''
          experimental-features = nix-command flakes
          allow-import-from-derivation = false
        '';
        nix.settings.trusted-public-keys = [
          "silverpond:DvvEdyKZvc86cR1o/a+iJxnb7JxMCBzvSTjjEQIY8+g="
          "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        ];
        nix.settings.trusted-users = [ "kirillvr" ];
        i18n.inputMethod = {
          enable = true;
          type = "ibus";
          ibus.engines = with pkgs.ibus-engines; [ mozc ];
        };
        nixpkgs.config.allowUnfree = true;
        programs.git.config = {
          user.name = "Kirill Radzikhovskyy";
          user.email = "kirillrdy@gmail.com";
        };
        services.desktopManager.gnome.enable = true;
        services.displayManager.gdm.enable = true;
        hardware.nvidia.open = true;
        programs.git.enable = true;
        services.avahi.enable = true;
        services.avahi.nssmdns4 = true;
        services.avahi.publish.addresses = true;
        services.avahi.publish.enable = true;
        services.fprintd.enable = !enableNvidia;
        services.gnome.tinysparql.enable = false;
        services.gnome.localsearch.enable = false;
        services.openssh.enable = true;
        services.tailscale.enable = true;
        services.xserver.excludePackages = [ pkgs.xterm ];
        services.xserver.videoDrivers = if enableNvidia then [ "nvidia" ] else [ "modesetting" ];
        services.xserver.xkb.options = "caps:none";
        swapDevices = [ { device = "/dev/nvme0n1p2"; } ];
        zramSwap.enable = true;
        system.stateVersion = "29.11"; # I come from the future
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
        hardware.nvidia-container-toolkit.enable = false;
        hardware.graphics.enable32Bit = false;
        environment.systemPackages = with pkgs; [
          (if enableNvidia then btop-cuda else btop)
          (import ./neovim.nix pkgs)
          acpi
          antigravity-fhs
          awscli2
          claude-code
          ffmpeg
          file
          firefox
          gemini-cli
          gh
          ghostty
          gnomeExtensions.battery-time
          gnomeExtensions.freon
          gnomeExtensions.maximized-by-default-actually-reborn
          gnomeExtensions.system-monitor-next
          go
          golangci-lint
          golangci-lint-langserver
          google-chrome
          gopls
          jq
          lua-language-server
          neovide
          nil
          nix-tree
          nix-update
          nixfmt
          nixpkgs-review
          opencode
          pyrefly
          python3Packages.fastavro
          ripgrep
          slack
          superhtml
          tig
          typescript-language-server
          wl-clipboard
          zig_0_15
          zls_0_15
        ];
      }
    )
  ];
}
