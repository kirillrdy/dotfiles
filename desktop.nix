{
  lib,
  pkgs,
  config ? null,
  enableLightDesktop ? false,
  enableNvidia ? false,
  enableNativeCompositor ? false,
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
  desktopZig = import ./desktop-zig.nix { inherit pkgs; };
  secretsPam = service: {
    enableGnomeKeyring = false;
    rules.auth = {
      # The final pam_unix is "sufficient" and ends the stack, so prompt with an
      # optional pam_unix first, capture the token, and let try_first_pass reuse it.
      desktop-secrets-unix = {
        order = service.rules.auth.unix.order - 20;
        control = "optional";
        modulePath = config.security.pam.pam_unixModulePath;
        settings.nullok = service.allowNullPassword;
      };
      desktop-secrets = {
        order = service.rules.auth.unix.order - 10;
        control = "optional";
        modulePath = "${desktopZig}/lib/libpam_desktop_secrets.so";
      };
    };
    # After pam_systemd, which provides XDG_SESSION_ID.
    rules.session.desktop-secrets = {
      order = service.rules.session.systemd.order + 1;
      control = "optional";
      modulePath = "${desktopZig}/lib/libpam_desktop_secrets.so";
      settings.helper = "${shell}";
    };
  };

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
  systemd.defaultUnit = "graphical.target";
  users.users.greeter = {
    isSystemUser = true;
    group = "greeter";
    home = "/var/lib/greeter";
    createHome = true;
  };
  users.groups.greeter = { };
  systemd.services.desktop-display-manager = {
    description = "Native GDM-like display manager";
    wantedBy = [ "graphical.target" ];
    # Like upstream display-manager.service: restarting it on switch would kill
    # the logged-in session. The new build is used from the next login/boot.
    restartIfChanged = false;
    conflicts = [ "getty@tty1.service" ];
    after = [
      "systemd-user-sessions.service"
      "plymouth-quit-wait.service"
      "systemd-logind.service"
      "dbus.service"
    ];
    environment =
      lib.optionalAttrs enableNvidia {
        WLR_RENDERER = "vulkan";
      }
      // lib.optionalAttrs enableNativeCompositor {
        # Forwarded by the display manager to the greeter and the session.
        DESKTOP_COMPOSITOR = "native";
      };
    serviceConfig = {
      ExecStart = "${shell} dm";
      Restart = "always";
      RestartSec = 1;
      TTYPath = "/dev/tty1";
      StandardInput = "tty";
      StandardOutput = "journal";
      StandardError = "journal";
      TTYReset = true;
      TTYVHangup = true;
      TTYVTDisallocate = true;
    };
  };
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
  security.pam.services.desktop-greeter = {
    startSession = true;
    enableGnomeKeyring = false;
  };
  security.pam.services.desktop-login = secretsPam config.security.pam.services.desktop-login // {
    startSession = true;
  };
  security.pam.services.login = secretsPam config.security.pam.services.login;
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
    desktop-zig = {
      description = "Desktop compositor and shell";
      after = [ "graphical-session-pre.target" ];
      # Only the display manager starts the compositor; a switch must not restart it.
      restartIfChanged = false;
      environment = {
        XDG_CURRENT_DESKTOP = "desktop:wlroots";
        XDG_SESSION_DESKTOP = "desktop";
        XDG_SESSION_TYPE = "wayland";
        XCURSOR_THEME = cursorTheme;
        XCURSOR_SIZE = toString cursorSize;
        # NixOS gives units a coreutils-only PATH; the compositor imports PATH into
        # the user manager, which hides every app whose Exec= is not absolute.
        PATH = lib.mkForce null;
      }
      // lib.optionalAttrs enableNvidia {
        WLR_RENDERER = "vulkan";
      };
      serviceConfig = {
        Type = "simple";
        # Match the former tty1 login session: environment.variables (GIO_EXTRA_MODULES,
        # XCURSOR_PATH, GTK_PATH, ...) and the full user PATH only come from /etc/profile.
        ExecStart = "${pkgs.writeShellScript "desktop-zig-session" ''
          . /etc/profile
          # A dead compositor's WAYLAND_DISPLAY lingers in the user manager; inheriting
          # it makes wlroots pick the nested Wayland backend instead of DRM.
          unset WAYLAND_DISPLAY DISPLAY
          exec ${shell} session ${gnomeWallpaper}
        ''}";
        Slice = "session.slice";
        Restart = "no";
      };
    };
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
        {
          name = "gnome-codex";
          source = "codex";
        }
        {
          name = "gnome-claude";
          source = "claude";
        }
        {
          name = "gnome-antigravity";
          source = "antigravity";
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
          name = "gnome-monitors";
          kind = "monitors";
          source = "monitors";
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
