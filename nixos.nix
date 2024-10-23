{
  hostName,
  enableNvidia ? false,
  buildJobs ? "auto",
  gccarch ? null,
  systemFeatures ? [ ],
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
        nixpkgs.hostPlatform =
          if gccarch == null then
            { system = "x86_64-linux"; }
          else
            {
              gcc.arch = gccarch;
              gcc.tune = gccarch;
              system = "x86_64-linux";
            };
        boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
        boot.initrd.availableKernelModules = [ "nvme" ];
        boot.kernelPackages = pkgs.linuxPackages_6_10;
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
        networking.hostName = hostName;
        nix.extraOptions = ''
          experimental-features = nix-command flakes
          allow-import-from-derivation = false
        '';
        nix.settings.max-jobs = buildJobs;
        nix.settings.trusted-users = [ "kirillvr" ];
        nix.settings.system-features = [
          "nixos-test"
          "benchmark"
          "big-parallel"
          "kvm"
        ] ++ systemFeatures;
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
        services.xserver.desktopManager.gnome.enable = true;
        services.xserver.displayManager.gdm.enable = true;
        services.xserver.excludePackages = [ pkgs.xterm ];
        services.xserver.displayManager.gdm.autoSuspend = false;
        services.xserver.enable = true;
        services.xserver.xkb.options = "caps:none";
        services.xserver.videoDrivers = if enableNvidia then [ "nvidia" ] else [ "modesetting" ];
        hardware.nvidia.open = true;
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
          awscli2
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
