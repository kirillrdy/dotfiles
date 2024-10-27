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
        services.gnome.gnome-keyring.enable = true;
        virtualisation.waydroid.enable = true;
        boot.loader.systemd-boot.enable = true;
        environment.variables = {
          EDITOR = "nvim";
          NEOVIDE_FORK = 1;
          NIXOS_OZONE_WL = 1;
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
        nixpkgs.flake.setFlakeRegistry = false;
        nixpkgs.flake.setNixPath = false;

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
        services.gnome.core-utilities.enable = false;
        services.gnome.tinysparql.enable = true;
        services.gnome.localsearch.enable = true;
        services.logind.extraConfig = "RuntimeDirectorySize=10G";
        services.openssh.enable = true;
        services.tailscale.enable = true;
        services.xserver.desktopManager.gnome.enable = false;
        services.xserver.displayManager.gdm.enable = false;
        services.xserver.excludePackages = [ pkgs.xterm ];
        services.xserver.displayManager.gdm.autoSuspend = false;
        services.xserver.enable = true;
        services.displayManager.sessionPackages = [ pkgs.niri ];
        services.xserver.xkb.options = "caps:none";
        services.xserver.videoDrivers = if enableNvidia then [ "nvidia" ] else [ "modesetting" ];
        hardware.nvidia.open = true;
        xdg.portal = {
          enable = true;
          configPackages = [ pkgs.niri ];
          # Recommended by upstream, required for screencast support
          # https://github.com/YaLTeR/niri/wiki/Important-Software#portals
          extraPortals = [ pkgs.xdg-desktop-portal-gnome ];
        };
        systemd.packages = [ pkgs.niri ];
        security = {
          polkit.enable = true;
          pam.services.swaylock = { };
        };

        programs = {
          dconf.enable = lib.mkDefault true;
          xwayland.enable = true;
        };

        services.graphical-desktop.enable = true;

        xdg.portal.wlr.enable = false;
        # Window manager only sessions (unlike DEs) don't handle XDG
        # autostart files, so force them to run the service
        services.xserver.desktopManager.runXdgAutostartIfNone = true;

        swapDevices = [ { device = "/dev/nvme0n1p2"; } ];
        zramSwap.enable = true;
        system.stateVersion = "24.11"; # I come from the future
        time.timeZone = "Australia/Melbourne";
        users.users.haru = {
          isNormalUser = true;
          extraGroups = [
            "wheel"
            "docker"
            "vboxusers"
          ];
        };
        users.users.kirillvr = {
          isNormalUser = true;
          initialPassword = "password";
          extraGroups = [
            "wheel"
            "docker"
            "vboxusers"
          ];
        };
        virtualisation.docker.enable = true;
        virtualisation.docker.storageDriver = "zfs";
        hardware.nvidia-container-toolkit.enable = enableNvidia;
        hardware.graphics.enable32Bit = enableNvidia;
        environment.systemPackages = with pkgs; [
          (import ./neovim.nix pkgs)
          (pkgs.writeScriptBin "hx" "GOOS=js GOARCH=wasm ${helix}/bin/hx -c ${./config.toml} $@")
          acpi
          niri
          awscli2
          wl-clipboard
          awsebcli
          baobab
          btop
          file
          file-roller
          firefox
          gnome-system-monitor
          gnome-text-editor
          gnomeExtensions.freon
          gnomeExtensions.system-monitor
          go
          golangci-lint
          golangci-lint-langserver
          gopls
          gnome-console
          #loupe
          lua-language-server
          nautilus
          neovide
          nil
          nix-tree
          nix-update
          nixfmt-rfc-style
          nixpkgs-review
          ripgrep
          slack
          tig
          totem
          xclip
          zig
          zls
          terraform-ls
        ];
      }
    )
  ];
}
