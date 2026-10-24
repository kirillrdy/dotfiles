{
  lib,
  pkgs,
  enableLightDesktop ? false,
  ...
}:
let
  cursorTheme = "Adwaita";
  cursorSize = 24;
  # Use the same default as the NixOS GNOME desktop module.
  gnomeWallpaper = pkgs.nixos-artwork.wallpapers.simple-blue.gnomeFilePath;
  appLauncher = pkgs.writeShellScriptBin "desktop-apps" ''
    exec ${pkgs.nwg-drawer}/bin/nwg-drawer -s /etc/xdg/nwg-drawer/drawer.css \
      -c 6 -is 96 -spacing 24 -nocats -nofs -term ghostty -i Adwaita "$@"
  '';
  gtkCursorSettings = ''
    [Settings]
    gtk-cursor-theme-name=${cursorTheme}
    gtk-cursor-theme-size=${toString cursorSize}
  '';
  desktopCompositor = pkgs.labwc.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./labwc-gnome-switcher.patch ];
  });
  codexIcon = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/kevinpita/codex-usage-extension/b88a5d0b02b37e9a06b8266bd5f29fa6a5f16213/codex-icon-22.png";
    hash = "sha256-kI1mut3KtZNahi8btZNSdogSrF+Z44yXqaZ4Jxf5L+E=";
  };
  desktopZig = import ./desktop-zig.nix { inherit pkgs; };
  nativeModule = name: kind: {
    module_path = "${desktopZig}/lib/libwaybar-gnome.so";
    inherit name kind;
  };
  volumeControl = pkgs.writeShellApplication {
    name = "desktop-volume";
    runtimeInputs = [
      pkgs.wireplumber
      pkgs.swayosd
      pkgs.pipewire
      pkgs.util-linux
    ];
    text = ''
      case "''${1:-}" in
        up) step=5 ;;
        down) step=-5 ;;
        *) echo "Usage: desktop-volume up|down" >&2; exit 1 ;;
      esac

      wpctl set-mute @DEFAULT_AUDIO_SINK@ 0
      swayosd-client --output-volume "$step"

      # Keep key repeat responsive without overlapping feedback sounds.
      exec 9>"$XDG_RUNTIME_DIR/desktop-volume-feedback.lock"
      flock --nonblock 9 || exit 0
      exec pw-play --properties='{"media.role":"event"}' \
        ${pkgs.sound-theme-freedesktop}/share/sounds/freedesktop/stereo/audio-volume-change.oga
    '';
  };
  session = pkgs.writeShellScript "labwc-session" ''
    . /etc/profile
    export XDG_CURRENT_DESKTOP=labwc:wlroots
    export XDG_SESSION_DESKTOP=labwc
    export XDG_SESSION_TYPE=wayland
    trap '${pkgs.systemd}/bin/systemctl --user stop labwc-session.target' EXIT
    ${desktopCompositor}/bin/labwc
  '';
  sessionService = command: {
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    enableDefaultPath = false;
    serviceConfig = {
      ExecStart = command;
      Restart = "on-failure";
    };
  };
in
lib.mkIf enableLightDesktop {
  programs.labwc.enable = true;
  programs.labwc.package = desktopCompositor;
  programs.thunar.enable = true;
  services.greetd = {
    enable = true;
    useTextGreeter = true;
    settings.default_session.command = "${lib.getExe pkgs.tuigreet} --time --remember --cmd ${session}";
  };
  networking.networkmanager.enable = true;
  hardware.bluetooth.enable = true;
  services.blueman.enable = true;
  services.power-profiles-daemon.enable = true;
  services.upower.enable = true;
  services.gnome.gnome-keyring.enable = true;
  fonts.packages = [ pkgs.adwaita-fonts ];
  programs.dconf.profiles.user.databases = [
    {
      settings."org/gnome/desktop/interface" = {
        cursor-theme = cursorTheme;
        cursor-size = lib.gvariant.mkInt32 cursorSize;
      };
    }
  ];
  systemd.packages = [ desktopCompositor ];
  systemd.user.services = {
    wallpaper = sessionService "${pkgs.swaybg}/bin/swaybg -i ${gnomeWallpaper} -m fill";
    waybar = sessionService "${pkgs.waybar}/bin/waybar";
    mako = sessionService "${pkgs.mako}/bin/mako --config /etc/xdg/mako/config";
    swayosd = sessionService "${pkgs.swayosd}/bin/swayosd-server --config /etc/xdg/swayosd/config.toml --style /etc/xdg/swayosd/style.css";
    polkit-agent = sessionService "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1";
    swayidle = sessionService "${pkgs.swayidle}/bin/swayidle -w timeout 600 'swaylock -f -c 1e1e2e' before-sleep 'swaylock -f -c 1e1e2e'";
  };

  environment.systemPackages = with pkgs; [
    adwaita-icon-theme
    brightnessctl
    appLauncher
    grim
    mako
    pavucontrol
    networkmanagerapplet
    slurp
    swayidle
    swaylock
    swayosd
    waybar
    wl-clipboard
    wlr-randr
  ];

  environment.etc = {
    "xdg/nwg-drawer/drawer.css".text = ''
      window {
        background: rgba(46,46,51,0.98);
        color: #fff;
        font-family: "Adwaita Sans";
        font-size: 11pt;
      }
      entry {
        background: #45454b;
        color: #fff;
        border: 1px solid rgba(255,255,255,0.12);
        border-radius: 999px;
        padding: 12px 20px;
        margin: 32px 0;
        min-width: 320px;
        box-shadow: none;
      }
      entry:focus { border-color: #78aeed; }
      button, image { background: none; border: none; box-shadow: none; color: #fff; }
      button { border-radius: 24px; padding: 16px; }
      button:hover, button:focus { background: rgba(255,255,255,0.1); }
      button:active { background: rgba(255,255,255,0.18); }
      #pinned-box { padding-bottom: 24px; }
    '';
    # Keep GTK clients and compositor-rendered Wayland cursors consistent.
    "xdg/gtk-3.0/settings.ini".text = gtkCursorSettings;
    "xdg/gtk-4.0/settings.ini".text = gtkCursorSettings;
    "xdg/swayosd/config.toml".text = ''
      [server]
      top_margin = 0.94
      max_volume = 100
      min_brightness = 5
      show_percentage = false
      duration = 1500
    '';
    "xdg/swayosd/style.css".text = ''
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
    "xdg/mako/config".text = ''
      font=Adwaita Sans 11
      background-color=#36363a
      text-color=#ffffff
      border-color=#ffffff26
      border-size=1
      border-radius=16
      width=400
      height=200
      padding=16
      margin=6,12
      outer-margin=12,0
      anchor=top-center
      icons=1
      max-icon-size=48
      icon-location=left
      icon-border-radius=8
      icon-path=${pkgs.adwaita-icon-theme}/share/icons/Adwaita:/run/current-system/sw/share/icons/hicolor
      format=<b>%s</b>\n%b
      progress-color=over #ffffff26
    '';
    "xdg/labwc/rc.xml".text = ''
      <?xml version="1.0"?>
      <labwc_config>
        <core>
          <!-- Let applications draw their own GNOME-style window frames. -->
          <decoration>client</decoration>
        </core>
        <theme>
          <icon>Adwaita</icon>
          <font place="OnScreenDisplay" name="Adwaita Sans" size="11" />
        </theme>
        <windowSwitcher preview="no" outlines="no">
          <osd show="yes" style="applications" output="focused" />
        </windowSwitcher>
        <keyboard>
          <default />
          <keybind key="W-Tab"><action name="NextWindow" /></keybind>
          <keybind key="W-S-Tab"><action name="PreviousWindow" /></keybind>
          <keybind key="A-grave"><action name="NextWindow" identifier="current" /></keybind>
          <keybind key="A-S-grave"><action name="PreviousWindow" identifier="current" /></keybind>
          <keybind key="W-Return"><action name="Execute" command="ghostty" /></keybind>
          <keybind key="W-d"><action name="Execute" command="${lib.getExe appLauncher}" /></keybind>
          <keybind key="W-a"><action name="Execute" command="${lib.getExe appLauncher}" /></keybind>
          <keybind key="Super_L" onRelease="yes"><action name="Execute" command="${lib.getExe appLauncher}" /></keybind>
          <keybind key="W-e"><action name="Execute" command="thunar" /></keybind>
          <keybind key="W-l"><action name="Execute" command="swaylock -f -c 1e1e2e" /></keybind>
          <keybind key="W-S-e"><action name="Exit" /></keybind>
          <keybind key="XF86AudioRaiseVolume"><action name="Execute" command="${lib.getExe volumeControl} up" /></keybind>
          <keybind key="XF86AudioLowerVolume"><action name="Execute" command="${lib.getExe volumeControl} down" /></keybind>
          <keybind key="XF86AudioMute"><action name="Execute" command="${pkgs.swayosd}/bin/swayosd-client --output-volume mute-toggle" /></keybind>
          <keybind key="XF86AudioMicMute"><action name="Execute" command="${pkgs.swayosd}/bin/swayosd-client --input-volume mute-toggle" /></keybind>
          <keybind key="XF86MonBrightnessUp"><action name="Execute" command="${pkgs.swayosd}/bin/swayosd-client --brightness +5" /></keybind>
          <keybind key="XF86MonBrightnessDown"><action name="Execute" command="${pkgs.swayosd}/bin/swayosd-client --brightness -5" /></keybind>
          <keybind key="Print"><action name="Execute" command="sh -c 'grim -g &quot;$(slurp)&quot; - | wl-copy'" /></keybind>
        </keyboard>
        <mouse><default /></mouse>
        <libinput><device category="touchpad"><tap>no</tap><naturalScroll>yes</naturalScroll></device></libinput>
        <windowRules>
          <windowRule identifier="*" type="normal"><action name="Maximize" /></windowRule>
        </windowRules>
      </labwc_config>
    '';
    "xdg/labwc/environment".text = ''
      XKB_DEFAULT_OPTIONS=caps:none
      XCURSOR_THEME=${cursorTheme}
      XCURSOR_SIZE=${toString cursorSize}
    '';
    "xdg/labwc/autostart".text = ''
      # Stay near GNOME's 5/3 scale on hagi using an exact multiple of 1/8,
      # representable in both Wayland's 1/256 and fractional-scale's 1/120 units.
      ${pkgs.wlr-randr}/bin/wlr-randr --output eDP-1 --scale 1.625
      ${pkgs.systemd}/bin/systemctl --user import-environment PATH
      ${pkgs.systemd}/bin/systemctl --user --no-block start labwc-session.target
    '';
    "xdg/waybar/config".text = builtins.toJSON {
      layer = "top";
      position = "top";
      height = 32;
      spacing = 0;
      modules-left = [ "cffi/activities" ];
      modules-center = [ "cffi/clock" ];
      modules-right = [
        "cffi/codex"
        "cffi/monitors"
        "cffi/disk"
        "cffi/status"
      ];
      "cffi/activities" = nativeModule "gnome-activities" "activities" // {
        on-click = lib.getExe appLauncher;
        tooltip = false;
      };
      "cffi/codex" = nativeModule "gnome-codex" "indicator" // {
        exec = "${desktopZig}/bin/waybar-panel codex --codex-icon ${codexIcon}";
      };
      "cffi/monitors" = nativeModule "gnome-monitors" "monitors" // {
        exec = "${desktopZig}/bin/waybar-panel monitors";
        on-click = "ghostty -e btop";
      };
      "cffi/disk" = nativeModule "gnome-disk" "indicator" // {
        exec = "${desktopZig}/bin/waybar-panel disk";
      };
      "cffi/status" = nativeModule "gnome-status" "indicator" // {
        exec = "${desktopZig}/bin/waybar-panel status";
        bluetooth-command = "${pkgs.bluez}/bin/bluetoothctl";
        bluetooth-settings-command = "${pkgs.blueman}/bin/blueman-manager";
        network-settings-command = "${pkgs.networkmanagerapplet}/bin/nm-connection-editor";
      };
      "cffi/clock" = nativeModule "gnome-clock" "clock";
    };
    "xdg/waybar/style.css".text = ''
      * {
        font-family: "Adwaita Sans";
        font-size: 11pt;
        font-weight: bold;
        border: none;
        border-radius: 0;
        min-height: 0;
      }
      window#waybar { background: #000; color: #fff; }
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
      .gnome-power-menu {
        background: #36363a;
        color: #fff;
        border: 1px solid rgba(255,255,255,0.15);
        border-radius: 36px;
        padding: 18px;
        box-shadow: 0 8px 18px rgba(0,0,0,0.25);
      }
      .gnome-power-menu button {
        background: #505054;
        background-image: none;
        color: #fff;
        border: none;
        box-shadow: none;
        text-shadow: none;
        transition: background-color 150ms ease;
      }
      .gnome-power-menu button:hover { background: #626266; }
      .gnome-power-menu button:disabled { opacity: 0.5; }
      .gnome-power-menu button:focus { box-shadow: inset 0 0 0 2px #99c1f1; }
      .gnome-power-menu .quick-toggle {
        border-radius: 999px;
        min-width: 160px;
        min-height: 48px;
        padding: 8px 16px;
      }
      .gnome-power-menu .quick-toggle-title { font-size: 11pt; }
      .gnome-power-menu .quick-toggle-subtitle { font-size: 9pt; font-weight: normal; }
      .gnome-power-menu .quick-active { background: #3584e4; }
      .gnome-power-menu .quick-active:hover { background: #4990e7; }
      .gnome-power-menu .quick-split .quick-toggle {
        border-radius: 999px 0 0 999px;
        min-width: 120px;
      }
      .gnome-power-menu .quick-menu-arrow {
        border-radius: 0 999px 999px 0;
        padding: 0 12px;
        border-left: 1px solid rgba(255,255,255,0.15);
      }
      .gnome-power-menu .quick-toggle-menu { background: #454549; border-radius: 24px; padding: 12px; }
      .gnome-power-menu .quick-menu-title { font-size: 14pt; padding: 6px 10px 12px; }
      .gnome-power-menu .profile-choice { background: transparent; border-radius: 12px; padding: 10px; }
      .gnome-power-menu .profile-selected { background: rgba(255,255,255,0.1); }
      .gnome-power-menu .quick-message { font-size: 9pt; font-weight: normal; }
      .gnome-codex-menu { padding: 20px; }
      .gnome-codex-menu .codex-section-title { font-size: 13px; font-weight: 600; color: #e0e0e0; }
      .gnome-codex-menu .codex-percent-label { font-size: 13px; }
      .gnome-codex-menu .codex-reset-label { font-size: 11px; font-weight: normal; color: #a0a0a0; }
      .gnome-codex-menu .codex-checked { font-size: 10px; font-weight: normal; font-style: italic; color: #808080; }
      .gnome-codex-menu separator { min-height: 1px; background: rgba(255,255,255,0.1); }
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
    '';
  };
}
