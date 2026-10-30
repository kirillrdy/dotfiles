{
  lib,
  pkgs,
  config ? null,
  enableLightDesktop ? false,
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
    . /etc/profile
    export XDG_CURRENT_DESKTOP=desktop:wlroots
    export XDG_SESSION_DESKTOP=desktop
    export XDG_SESSION_TYPE=wayland
    export XCURSOR_THEME=${cursorTheme}
    export XCURSOR_SIZE=${toString cursorSize}
    export DESKTOP_CODEX_ICON=${codexIcon}
    export DESKTOP_SESSION_MANAGED=1
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
  services.greetd = {
    enable = true;
    useTextGreeter = true;
    settings.default_session.command = "${shell} greeter --time --remember-file /var/cache/desktop-greeter/last-user --cmd ${session}";
  };
  systemd.tmpfiles.rules = [ "d /var/cache/desktop-greeter 0700 greeter greeter - -" ];
  networking.networkmanager.enable = true;
  services.power-profiles-daemon.enable = false;
  security.pam.services.desktop-lock = { };
  security.polkit.enable = true;
  security.polkit.enablePkexecWrapper = true;
  systemd.services.desktop-power-restore = {
    description = "Restore the selected desktop power profile";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-modules-load.service" ];
    before = [ "greetd.service" ];
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
  security.pam.services.greetd = {
    enableGnomeKeyring = false;
    rules.auth = {
      # greetd runs login as a substack, so capture its token after it returns.
      desktop-secrets = {
        order =
          if config == null then 10001 else config.security.pam.services.greetd.rules.auth.login.order + 1;
        control = "optional";
        modulePath = "${desktopZig}/lib/libpam_desktop_secrets.so";
      };
    };
    rules.session.desktop-secrets = {
      order =
        if config == null then 10001 else config.security.pam.services.greetd.rules.session.login.order + 1;
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
    "xdg/desktop-osd/style.css".text = ''
      window#osd {
        /* GNOME Shell's OSD palette and dimensions. */
        background: #2e2e33;
        color: #fff;
        border: 1px solid rgba(255,255,255,0.02);
        border-radius: 999px;
        font-family: "Adwaita Sans";
        font-size: 11pt;
        font-weight: bold;
      }
      window#osd #container { margin: 12px 18px; }
      window#osd image, window#osd label { color: #fff; }
      window#osd progressbar { min-width: 160px; min-height: 6px; margin-right: 6px; }
      window#osd trough, window#osd progress {
        min-height: 6px;
        border: none;
        border-radius: 999px;
      }
      window#osd trough { background: rgba(255,255,255,0.1); }
      window#osd progress { background: #fff; }
      window#osd progressbar:disabled, window#osd image:disabled { opacity: 0.5; }
    '';
    "xdg/desktop-notifications/style.css".text = builtins.readFile ./desktop-notifications.css;
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
    "xdg/desktop-panel/style.css".text = ''
      /* Keep the reset less specific than the popup and tile rules below. */
      .gnome-panel-module, .gnome-panel-module *,
      .gnome-calendar, .gnome-calendar *,
      .gnome-power-menu, .gnome-power-menu *,
      .gnome-codex-menu, .gnome-codex-menu * {
        font-family: "Adwaita Sans";
        font-size: 11pt;
        font-weight: bold;
        border: none;
        border-radius: 0;
        min-height: 0;
      }
      window#desktop-panel { background: #000; color: #fff; }
      .gnome-panel-module {
        border: 3px solid transparent;
        border-radius: 999px;
        transition: background-color 150ms ease;
      }
      .gnome-panel-module:hover { background: rgba(255,255,255,0.17); }
      #gnome-monitors { border-top-width: 0; border-bottom-width: 0; }
      #gnome-codex .gnome-text { font-size: 12px; }
      #gnome-disk { border: none; border-radius: 0; padding: 0; }
      #gnome-disk:hover { background: transparent; }
      .monitor-name { font-size: 62.5%; color: rgba(255,255,255,0.75); }
      .monitor-value { padding: 0 5px 0 0; }
      tooltip {
        background: #36363a;
        color: #fff;
        border: 1px solid rgba(255,255,255,0.15);
        border-radius: 12px;
      }
      tooltip label { font-size: 10pt; font-weight: normal; padding: 8px; }
      .gnome-calendar, .gnome-codex-menu {
        background: #36363a;
        color: #fff;
        border: 1px solid rgba(255,255,255,0.15);
        border-radius: 28px;
        padding: 12px;
        box-shadow: 0 8px 18px rgba(0,0,0,0.25);
      }
      .gnome-calendar button {
        background: transparent;
        background-image: none;
        color: #fff;
        border: none;
        border-radius: 999px;
        box-shadow: none;
        text-shadow: none;
        padding: 0;
      }
      .gnome-calendar button:hover { background-color: rgba(255,255,255,0.08); }
      .gnome-calendar button:active { background-color: rgba(255,255,255,0.16); }
      .gnome-calendar .calendar-today-button { border-radius: 16px; padding: 9px; }
      .gnome-calendar .calendar-weekday-label { font-size: 11pt; }
      .gnome-calendar .calendar-date-label { font-size: 20pt; font-weight: 800; }
      .gnome-calendar .calendar-pager { min-width: 36px; min-height: 36px; }
      .gnome-calendar .calendar-day-heading { font-size: 9pt; padding: 6px 0; }
      .gnome-calendar .calendar-day {
        font-size: 10pt;
        min-width: 36px;
        min-height: 36px;
        margin: 2px;
      }
      .gnome-calendar .calendar-weekend { color: #b6b6b9; }
      .gnome-calendar .calendar-other-month { color: #949497; font-weight: normal; }
      .gnome-calendar .calendar-selected { box-shadow: inset 0 0 0 2px #b6b6b9; }
      .gnome-calendar .calendar-today { background-color: #3584e4; color: #fff; box-shadow: none; }
      .gnome-calendar .calendar-today:hover { background-color: #4990e7; }
      .gnome-codex-menu {
        background: transparent;
        border: none;
        padding: 0;
        margin: 0;
        box-shadow: none;
      }
      .gnome-codex-menu .codex-menu-content {
        background: #36363a;
        padding: 6px;
        border: 1px solid #424247;
        border-radius: 20px;
        box-shadow: 0 2px 4px rgba(0,0,0,0.2);
      }
      .gnome-codex-menu .codex-usage-section { min-width: 260px; padding: 13px 12px; }
      .gnome-codex-menu .codex-footer { padding: 13px 12px 11px; }
      .gnome-codex-menu .codex-section-title { font-size: 13px; font-weight: 600; color: #e0e0e0; }
      .gnome-codex-menu .codex-percent-label { font-size: 13px; }
      .gnome-codex-menu .codex-reset-label { font-size: 11px; font-weight: normal; color: #a0a0a0; }
      .gnome-codex-menu .codex-checked { font-size: 10px; font-weight: normal; font-style: italic; color: #808080; }
      .gnome-codex-menu separator { min-height: 1px; margin: 0; padding: 0; background: rgba(255,255,255,0.1); }
      .gnome-codex-menu progressbar trough { min-height: 8px; background: rgba(255,255,255,0.1); border-radius: 4px; }
      .gnome-codex-menu progressbar progress { min-height: 8px; border-radius: 4px; border: none; }
      .gnome-codex-menu .usage-low progress { background: #10a37f; }
      .gnome-codex-menu .usage-medium progress { background: #eab308; }
      .gnome-codex-menu .usage-high progress { background: #f97316; }
      .gnome-codex-menu .usage-critical progress { background: #ef4444; }
      .gnome-codex-menu button {
        background: rgba(255,255,255,0.06);
        background-image: none;
        color: #fff;
        border: 1px solid rgba(255,255,255,0.08);
        border-radius: 999px;
        padding: 6px 10px;
        font-size: 12px;
        box-shadow: none;
        text-shadow: none;
      }
      .gnome-codex-menu button label { font-size: 12px; font-weight: 600; }
      .gnome-codex-menu button:hover { background: rgba(255,255,255,0.12); }
      .gnome-codex-menu button:disabled { opacity: 0.5; }
    ''
    + builtins.readFile ./desktop-quick-settings.css
    + builtins.readFile ./desktop-notifications.css;
  };
}
