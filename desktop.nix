{
  lib,
  pkgs,
  config ? null,
  enableLightDesktop ? false,
  enableNvidia ? false,
  ...
}:
let
  cursorTheme = "Adwaita";
  cursorSize = 24;
  # Use the same default as the NixOS GNOME desktop module.
  gnomeWallpaper = pkgs.nixos-artwork.wallpapers.simple-blue.gnomeFilePath;
  shell = "${desktopZig}/bin/desktop-zig";
  appLauncher = "${shell} overview";
  gtkCursorSettings = ''
    [Settings]
    gtk-cursor-theme-name=${cursorTheme}
    gtk-cursor-theme-size=${toString cursorSize}
  '';
  codexIcon = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/kevinpita/codex-usage-extension/b88a5d0b02b37e9a06b8266bd5f29fa6a5f16213/codex-icon-22.png";
    hash = "sha256-kI1mut3KtZNahi8btZNSdogSrF+Z44yXqaZ4Jxf5L+E=";
  };
  desktopZig = import ./desktop-zig.nix { inherit pkgs; };
  session = pkgs.writeShellScript "desktop-session" ''
    export XDG_CURRENT_DESKTOP=desktop:wlroots
    export XDG_SESSION_DESKTOP=desktop
    export XDG_SESSION_TYPE=wayland
    export XCURSOR_THEME=${cursorTheme}
    export XCURSOR_SIZE=${toString cursorSize}
    export DESKTOP_CODEX_ICON=${codexIcon}
    export DESKTOP_SESSION_MANAGED=1
    ${lib.optionalString enableNvidia "export WLR_RENDERER=vulkan"}
    exec ${shell} compositor ${gnomeWallpaper}
  '';

in
lib.mkIf enableLightDesktop {
  nixpkgs.overlays = [
    (final: prev: {
      xdg-desktop-portal = import ./desktop-portal.nix {
        pkgs = final;
        desktop = desktopZig;
        upstream = prev.xdg-desktop-portal;
      };
    })
  ];
  # The broker is also the implementation; no separate portal backend runs.
  xdg.portal.extraPortals = lib.mkForce [ desktopZig ];
  xdg.portal.config.wlroots.default = lib.mkForce [ ];
  programs.dconf.enable = true;
  services.graphical-desktop.enable = true;
  xdg.portal.enable = true;
  services.xserver.desktopManager.runXdgAutostartIfNone = lib.mkDefault true;
  # getty + login own PAM and the logind session; the tty1 login shell becomes the desktop.
  environment.loginShellInit = ''
    if [ "$(tty)" = /dev/tty1 ]; then exec ${session}; fi
  '';
  networking.networkmanager.enable = true;
  services.power-profiles-daemon.enable = false;
  security.pam.services.desktop-lock = { };
  security.polkit.enable = true;
  security.polkit.enablePkexecWrapper = true;
  systemd.services.desktop-power-restore = {
    description = "Restore the selected desktop power profile";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-modules-load.service" ];
    before = [ "systemd-user-sessions.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${shell} power restore";
      StateDirectory = "desktop-power";
      StateDirectoryMode = "0755";
      UMask = "0022";
    };
  };
  powerManagement.resumeCommands = ''
    ${shell} power restore
  '';
  services.upower.enable = lib.mkForce false;
  services.dbus.packages = [ desktopZig ];
  systemd.services.desktop-battery = {
    description = "Native battery monitoring and critical power protection";
    wantedBy = [ "multi-user.target" ];
    after = [ "dbus.service" ];
    serviceConfig = {
      Type = "dbus";
      BusName = "org.freedesktop.UPower";
      ExecStart = "${shell} battery-monitor";
      Restart = "on-failure";
      RestartSec = 2;
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_NETLINK"
      ];
    };
  };
  services.gnome.gnome-keyring.enable = false;
  security.pam.services.login = {
    enableGnomeKeyring = false;
    rules.auth = {
      # The final pam_unix is "sufficient" and ends the stack, so prompt with an
      # optional pam_unix first, capture the token, and let try_first_pass reuse it.
      desktop-secrets-unix = {
        order = config.security.pam.services.login.rules.auth.unix.order - 20;
        control = "optional";
        modulePath = config.security.pam.pam_unixModulePath;
        settings.nullok = config.security.pam.services.login.allowNullPassword;
      };
      desktop-secrets = {
        order = config.security.pam.services.login.rules.auth.unix.order - 10;
        control = "optional";
        modulePath = "${desktopZig}/lib/libpam_desktop_secrets.so";
      };
    };
    # After pam_systemd, which provides XDG_SESSION_ID.
    rules.session.desktop-secrets = {
      order = config.security.pam.services.login.rules.session.systemd.order + 1;
      control = "optional";
      modulePath = "${desktopZig}/lib/libpam_desktop_secrets.so";
      settings.helper = "${shell}";
    };
  };
  services.gnome.gcr-ssh-agent.enable = false;
  programs.ssh = {
    startAgent = true;
    enableAskPassword = true;
    askPassword = lib.getExe' desktopZig "desktop-askpass";
    extraConfig = "AddKeysToAgent yes";
  };
  fonts.packages = [ pkgs.adwaita-fonts ];
  programs.dconf.profiles.user.databases = [
    {
      settings."org/gnome/desktop/interface" = {
        cursor-theme = cursorTheme;
        cursor-size = lib.gvariant.mkInt32 cursorSize;
      };
    }
  ];
  systemd.user.targets.desktop-session = {
    description = "Desktop compositor session";
    bindsTo = [ "graphical-session.target" ];
    wants = [ "graphical-session-pre.target" ];
    after = [ "graphical-session-pre.target" ];
  };
  systemd.user.services = {
    desktop-secrets = {
      description = "Native desktop Secret Service";
      wantedBy = [ "default.target" ];
      partOf = [ "graphical-session.target" ];
      serviceConfig = {
        Type = "dbus";
        BusName = "org.freedesktop.secrets";
        ExecStart = "${shell} secrets";
        Restart = "on-failure";
        UMask = "0077";
        NoNewPrivileges = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        LimitCORE = 0;
        Environment = "GDK_BACKEND=wayland WAYLAND_DISPLAY=wayland-0";
      };
    };

  };

  environment.systemPackages = with pkgs; [
    adwaita-icon-theme
    desktopZig
  ];

  environment.etc = {
    # Keep GTK clients and compositor-rendered Wayland cursors consistent.
    "xdg/gtk-3.0/settings.ini".text = gtkCursorSettings;
    "xdg/gtk-4.0/settings.ini".text = gtkCursorSettings;
    "xdg/desktop-panel/config.json".text = builtins.toJSON {
      height = 32;
      left = [
        {
          name = "gnome-activities";
          kind = "activities";
          on_click = appLauncher;
        }
      ];
      center = [
        {
          name = "gnome-clock";
          kind = "clock";
        }
      ];
      right = [
        {
          name = "gnome-codex";
          source = "codex";
        }
        {
          name = "gnome-monitors";
          kind = "monitors";
          source = "monitors";
          on_click = "ghostty -e btop";
        }
        {
          name = "gnome-disk";
          source = "disk";
        }
        {
          name = "gnome-status";
          source = "status";
          network_settings_command = "${shell} settings network";
          sound_settings_command = "${shell} settings sound";
        }
      ];
    };
  };
}
