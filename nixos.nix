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
        nix.extraOptions = ''experimental-features = nix-command flakes'';
        nix.settings.max-jobs = buildJobs;
        nixpkgs.config.allowUnfree = true;
        programs.git.config = { user.name = "Kirill Radzikhovskyy"; user.email = "kirillrdy@gmail.com"; };
        programs.git.enable = true;
        services.avahi.enable = true;
        services.avahi.nssmdns = true;
        services.avahi.publish.addresses = true;
        services.avahi.publish.enable = true;
        services.logind.extraConfig = "RuntimeDirectorySize=10G";
        services.openssh.enable = true;
        services.tailscale.enable = true;
        services.xserver.desktopManager.gnome.enable = true;
        services.xserver.displayManager.gdm.enable = true;
        services.xserver.enable = true;
        services.xserver.videoDrivers = if enableNvidia then [ "nvidia" ] else [ "modesetting" ];
        swapDevices = [{ device = "/dev/nvme0n1p2"; }];
        system.stateVersion = "24.11"; # I come from the future
        time.timeZone = "Australia/Melbourne";
        users.users.haru = { isNormalUser = true; extraGroups = [ "wheel" "docker" "vboxusers" ]; };
        users.users.kirillvr = { isNormalUser = true; extraGroups = [ "wheel" "docker" "vboxusers" ]; };
        virtualisation.docker.enable = true;
        virtualisation.docker.storageDriver = "zfs";
        environment.systemPackages = with pkgs; [
          (import ./neovim.nix pkgs)
          acpi
          kitty
          #awscli2
          awsebcli
          file
          (firefox.override { cfg.speechSynthesisSupport = false; })
          go_1_21
          golangci-lint
          golangci-lint-langserver
          gopls
          neovide
          nil
          nix-tree
          nix-update
          nixpkgs-fmt
          btop
          nixpkgs-review
          ripgrep
          slack
          tig
          xclip
        ];
      })
  ];
}