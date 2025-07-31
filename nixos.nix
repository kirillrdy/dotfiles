{
  hostName,
  enableNvidia ? false,
  remoteBuilders ? [ ],
  bigParallel ? false,
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
        boot.kernelPackages = pkgs.linuxPackages_6_15;
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
        ];
        hardware.nvidia.modesetting.enable = enableNvidia;
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
        nix.sshServe.enable = bigParallel;
        nix.sshServe.write = bigParallel;
        nix.sshServe.trusted = bigParallel;
        nix.sshServe.protocol = "ssh-ng";
        nix.sshServe.keys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGX7dSiU0yWO5oGRZxwAYc2CVa7rXTBQswjFeP0nenKC root@hagi"
        ];
        nix.settings.max-jobs = 1;
        nix.settings.substituters = [ "https://nix-community.cachix.org" ];
        nix.settings.trusted-public-keys = [
          "tsutenkaku:DcD4dlo63BptyBdjGfFQYRwbzZ6YEhDRlmnbUfIFtQU="
          "silverpond:DvvEdyKZvc86cR1o/a+iJxnb7JxMCBzvSTjjEQIY8+g="
          "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
        ];
        nix.settings.trusted-users = [ "kirillvr" ];
        nix.settings.trusted-substituters =
          if bigParallel then [ ] else [ "ssh-ng://nix-ssh@tsutenkaku.local" ];
        nix.buildMachines = remoteBuilders;
        nix.distributedBuilds = false;
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
        hardware.nvidia.open = false;
        programs.git.enable = true;
        services.avahi.enable = true;
        services.avahi.nssmdns4 = true;
        services.avahi.publish.addresses = true;
        services.avahi.publish.enable = true;
        services.fprintd.enable = true;
        services.logind.extraConfig = "RuntimeDirectorySize=10G";
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
        hardware.nvidia-container-toolkit.enable = enableNvidia;
        hardware.graphics.enable32Bit = enableNvidia;
        environment.systemPackages = with pkgs; [
          (import ./neovim.nix pkgs)
          acpi
          awscli2
          (if enableNvidia then btop-cuda else btop)
          file
          firefox
          ghostty
          gnomeExtensions.freon
          gnomeExtensions.system-monitor-next
          go
          golangci-lint
          golangci-lint-langserver
          google-chrome
          gopls
          lua-language-server
          neovide
          nil
          jq
          python3Packages.fastavro
          ffmpeg
          nix-tree
          nix-update
          nixfmt-rfc-style
          nixpkgs-review
          ripgrep
          slack
          tig
          wl-clipboard
          zig
          zls
        ];
      }
    )
  ];
}
