{ hostName, enableNvidia ? false, buildJobs ? "auto" }: {
  system = "x86_64-linux";
  modules = [
    ({ pkgs, lib, modulesPath, ... }:
      {
        boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
        boot.initrd.availableKernelModules = [ "nvme" ];
        boot.kernelPackages = pkgs.zfs.latestCompatibleLinuxPackages;
        boot.loader.efi.canTouchEfiVariables = true;
        boot.loader.systemd-boot.enable = true;
        environment.variables = { EDITOR = "nvim"; };
        fileSystems."/" = { device = "zroot/root"; fsType = "zfs"; };
        fileSystems."/boot" = { device = "/dev/nvme0n1p3"; fsType = "vfat"; };
        fonts.packages = with pkgs; [ kochi-substitute font-awesome cantarell-fonts dejavu_fonts source-code-pro source-sans ];
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
        #i18n.inputMethod = { enabled = "ibus"; ibus.engines = with pkgs.ibus-engines; [ mozc ]; };
        nixpkgs.config.allowUnfree = true;
        programs.git.config = { user.name = "Kirill Radzikhovskyy"; user.email = "kirillrdy@gmail.com"; };
        programs.git.enable = true;
        services.avahi.enable = true;
        services.avahi.nssmdns4 = true;
        services.avahi.publish.addresses = true;
        services.avahi.publish.enable = true;
        services.gnome.core-utilities.enable = false;
        services.gnome.tracker-miners.enable = false;
        services.gnome.tracker.enable = false;
        services.logind.extraConfig = "RuntimeDirectorySize=10G";
        services.openssh.enable = true;
        services.tailscale.enable = true;
        services.xserver.desktopManager.gnome.enable = true;
        services.xserver.displayManager.gdm.enable = true;
        services.xserver.enable = true;
        services.xserver.xkb.options = "caps:none";
        services.xserver.videoDrivers = if enableNvidia then [ "nvidia" ] else [ "modesetting" ];
        swapDevices = [{ device = "/dev/nvme0n1p2"; }];
        system.stateVersion = "24.11"; # I come from the future
        time.timeZone = "Australia/Melbourne";
        users.users.haru = { isNormalUser = true; extraGroups = [ "wheel" "docker" "vboxusers" ]; };
        users.users.kirillvr = { isNormalUser = true; extraGroups = [ "wheel" "docker" "vboxusers" ]; };
        virtualisation.docker.enable = true;
        virtualisation.docker.storageDriver = "zfs";
        environment.systemPackages = with pkgs; [
          (firefox.override { cfg.speechSynthesisSupport = false; })
          (import ./neovim.nix pkgs)
          acpi
          awscli2
          awsebcli
          baobab
          btop
          file
          gnome-console
          gnome-text-editor
          gnome.file-roller
          gnome.gnome-system-monitor
          gnome.nautilus
          gnome.totem
          go
          golangci-lint
          golangci-lint-langserver
          gopls
          loupe
          neovide
          nil
          nix-tree
          nix-update
          nixfmt-rfc-style
          nixpkgs-review
          ripgrep
          slack
          tig
          xclip
          zig
          zls
        ];
      })
  ];
}
