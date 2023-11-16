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
        environment.variables = { EDITOR = "nvim"; } // pkgs.lib.optionalAttrs enableNvidia { WLR_NO_HARDWARE_CURSORS = "1"; };
        fileSystems."/" = { device = "zroot/root"; fsType = "zfs"; };
        fileSystems."/boot" = { device = "/dev/nvme0n1p3"; fsType = "vfat"; };
        fonts.enableDefaultPackages = true;
        fonts.packages = with pkgs; [ kochi-substitute font-awesome cantarell-fonts dejavu_fonts source-code-pro source-sans ];
        i18n.defaultLocale = "en_AU.UTF-8";
        imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];
        networking.hostId = "00000000";
        networking.hostName = hostName;
        networking.networkmanager.enable = true;
        nix.extraOptions = ''experimental-features = nix-command flakes'';
        nix.settings.max-jobs = buildJobs;
        nixpkgs.config.allowUnfree = true;
        powerManagement.cpuFreqGovernor = if !enableNvidia then "powersave" else null;
        programs.git.config = { user.name = "Kirill Radzikhovskyy"; user.email = "kirillrdy@gmail.com"; };
        programs.git.enable = true;
        programs.hyprland.enable = true;
        programs.hyprland.enableNvidiaPatches = true;
        programs.ssh.startAgent = true;
        security.rtkit.enable = true;
        services.avahi.enable = true;
        services.avahi.nssmdns = true;
        services.avahi.publish.addresses = true;
        services.avahi.publish.enable = true;
        services.logind.extraConfig = "RuntimeDirectorySize=10G";
        services.openssh.enable = true;
        services.pipewire.alsa.enable = true;
        services.pipewire.alsa.support32Bit = true;
        services.pipewire.enable = true;
        services.pipewire.jack.enable = true;
        services.pipewire.pulse.enable = true;
        services.tailscale.enable = true;
        services.xserver.videoDrivers = if enableNvidia then [ "nvidia" ] else [ "modesetting" ];
        sound.enable = true;
        swapDevices = [{ device = "/dev/nvme0n1p2"; }];
        time.timeZone = "Australia/Melbourne";
        xdg.portal.enable = true;
        xdg.portal.extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
        xdg.portal.wlr.enable = true;
        environment.systemPackages = with pkgs; [
          (import ./neovim.nix pkgs)
          (import ./hyprland.nix pkgs)
          acpi
          waybar
          brightnessctl
          dunst
          swww
          networkmanagerapplet
          rofi-wayland
          kitty
          linuxPackages.cpupower
          awscli2
          awsebcli
          file
          (firefox.override { cfg.speechSynthesisSupport = false; })
          go_1_21
          golangci-lint
          golangci-lint-langserver
          gopls
          wl-clipboard
          neovide
          nil
          nix-tree
          nix-update
          nixpkgs-fmt
          btop
          nixpkgs-review
          pamixer
          ripgrep
          slack
          tig
        ];
        users.users.kirillvr = { isNormalUser = true; extraGroups = [ "wheel" "docker" "vboxusers" ]; };
        users.users.haru = { isNormalUser = true; extraGroups = [ "wheel" "docker" "vboxusers" ]; };
        virtualisation.docker.enable = true;
        virtualisation.docker.storageDriver = "zfs";
        virtualisation.docker.enableNvidia = enableNvidia;
        hardware.opengl.driSupport32Bit = enableNvidia;
        hardware.nvidia.modesetting.enable = enableNvidia;
        networking.firewall.enable = false;
        system.stateVersion = "24.11"; # I come from the future
      })
  ];
}
