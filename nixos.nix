{
  pkgs,
  lib,
  hostName,
  enableNvidia ? false,
  enableOpencl ? false,
  enableOpenvino ? false,
  ...
}:
{
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
  boot.kernelPackages = pkgs.linuxPackages_7_2;
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
    noto-fonts-cjk-sans
    source-code-pro
  ];
  hardware.nvidia = {
    modesetting.enable = enableNvidia;
    nvidiaSettings = false;
    open = true;
  };
  hardware.cpu.intel.updateMicrocode = true;
  i18n.defaultLocale = "en_AU.UTF-8";
  networking.firewall.enable = false;
  networking.hostId = "00000000";
  networking.networkmanager.enable = true;
  networking.networkmanager.plugins = lib.mkForce [ ];
  networking.hostName = hostName;
  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    allow-import-from-derivation = false;
    trusted-public-keys = [
      "silverpond:DvvEdyKZvc86cR1o/a+iJxnb7JxMCBzvSTjjEQIY8+g="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];
    trusted-users = [ "kirillvr" ];
  };
  nixpkgs.config.allowUnfree = true;
  programs.git.config = {
    user.name = "Kirill Radzikhovskyy";
    user.email = "kirillrdy@gmail.com";
  };
  services.desktopManager.gnome.enable = true;
  services.displayManager.gdm.enable = true;
  services.displayManager.gdm.autoSuspend = false;
  programs.dconf.profiles.user.databases = [
    {
      settings = {
        "org/gnome/desktop/interface" = {
          gtk-enable-primary-paste = true;
        };
      };
    }
  ];
  hardware.enableRedistributableFirmware = true;
  programs.git.enable = true;
  programs.bash.interactiveShellInit = ''
    # tss            -> toggle to the other logged-in tailscale account
    # tss <name|id>  -> switch to a specific account
    tss() {
      if [ -n "$1" ]; then
        tailscale switch "$1"
        return
      fi
      local target
      target=$(tailscale switch --list | awk 'NR>1 && $NF !~ /\*$/ {print $1; exit}')
      if [ -z "$target" ]; then
        echo "tss: no other tailscale account to switch to" >&2
        tailscale switch --list >&2
        return 1
      fi
      tailscale switch "$target"
    }
  '';
  programs.steam.enable = enableNvidia;
  services.avahi.enable = true;
  services.avahi.nssmdns4 = true;
  services.avahi.publish.addresses = true;
  services.avahi.publish.enable = true;
  services.fprintd.enable = !enableNvidia;
  services.flatpak.enable = enableNvidia;
  services.gnome.tinysparql.enable = false;
  services.gnome.localsearch.enable = false;
  services.openssh.enable = true;
  services.printing.enable = true;
  services.tailscale.enable = true;
  services.xserver.videoDrivers = if enableNvidia then [ "nvidia" ] else [ "modesetting" ];
  services.xserver.xkb.options = "caps:none";
  swapDevices = [ { device = "/dev/nvme0n1p2"; } ];
  zramSwap.enable = true;
  system.stateVersion = "29.11"; # I come from the future
  time.timeZone = "Asia/Tokyo";
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
  hardware.graphics = {
    enable = true;
    enable32Bit = enableNvidia;
    extraPackages = lib.optionals (!enableNvidia) [
      pkgs.intel-compute-runtime
    ];
  };
  environment.systemPackages =
    (import ./common.nix pkgs)
    ++ (with pkgs; [
      (if enableNvidia then btop-cuda else btop)
      (if enableNvidia then nvtopPackages.nvidia else nvtopPackages.intel)
      antigravity-ide
      file
      firefox
      ghostty
      gnomeExtensions.battery-time
      gnomeExtensions.codex-usage
      gnomeExtensions.freon
      gnomeExtensions.maximize-new-windows
      gnomeExtensions.executor
      gnomeExtensions.system-monitor-next
      google-chrome
      slack
      wl-clipboard
    ])
    ++ lib.optionals enableOpencl [
      pkgs.clinfo
      pkgs.ocl-icd
    ]
    ++ lib.optional enableOpenvino pkgs.openvino;
}
