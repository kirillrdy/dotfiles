{
  pkgs,
  lib,
  hostName,
  enableNvidia ? false,
  enableOpenvino ? false,
  ...
}:
{
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
  boot.initrd.availableKernelModules = [ "nvme" ];
  #boot.kernelPackages = pkgs.linuxPackages_7_1;
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
  hardware.nvidia.modesetting.enable = enableNvidia;
  hardware.nvidia.nvidiaSettings = false;
  hardware.cpu.intel.updateMicrocode = true;
  # NPU driver, firmware and the Level Zero loader OpenVINO dispatches through.
  hardware.cpu.intel.npu.enable = enableOpenvino;
  i18n.defaultLocale = "en_AU.UTF-8";
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
  nixpkgs.overlays = [
    (final: prev: {
      intel-graphics-compiler = prev.intel-graphics-compiler.overrideAttrs (oldAttrs: {
        postPatch = ''
          substituteInPlace igc/IGC/AdaptorOCL/igc-opencl.pc.in \
            --replace-fail '/@CMAKE_INSTALL_INCLUDEDIR@' "/include" \
            --replace-fail '/@CMAKE_INSTALL_LIBDIR@' "/lib"

          chmod +x igc/IGC/Scripts/igc_create_linker_script.sh
          patchShebangs --build igc/IGC/Scripts/igc_create_linker_script.sh

          for patch in llvm-project/llvm/projects/opencl-clang/patches/clang/*.patch; do
            patch -d llvm-project -p1 -F3 --ignore-whitespace -i "$PWD/$patch"
          done
        '';
        cmakeFlags = (oldAttrs.cmakeFlags or [ ]) ++ [
          (lib.cmakeBool "APPLY_PATCHES" false)
        ];
      });
    })
  ];
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
  hardware.nvidia.open = true;
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
  hardware.graphics = {
    enable = true;
    enable32Bit = enableNvidia;
    extraPackages =
      with pkgs;
      (
        if enableNvidia then
          [ nvidia-vaapi-driver ]
        else
          [
            intel-media-driver
            intel-vaapi-driver
          ]
      )
      # OpenCL and Level Zero for the iGPU, which is what OpenVINO's GPU device
      # talks to. The NPU device comes from hardware.cpu.intel.npu above.
      ++ lib.optional enableOpenvino intel-compute-runtime;
  };
  environment.systemPackages =
    (import ./common.nix pkgs)
    ++ (with pkgs; [
      (if enableNvidia then btop-cuda else btop)
      acpi
      antigravity-ide
      file
      firefox
      ghostty
      gnomeExtensions.battery-time
      gnomeExtensions.freon
      gnomeExtensions.maximized-by-default-actually-reborn
      gnomeExtensions.executor
      gnomeExtensions.system-monitor-next
      google-chrome
      slack
      wl-clipboard
    ])
    ++ lib.optional enableOpenvino pkgs.openvino;
}
