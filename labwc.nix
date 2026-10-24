{
  lib,
  pkgs,
  enableLightDesktop ? false,
  ...
}:
let
  codexIcon = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/kevinpita/codex-usage-extension/b88a5d0b02b37e9a06b8266bd5f29fa6a5f16213/codex-icon-22.png";
    hash = "sha256-kI1mut3KtZNahi8btZNSdogSrF+Z44yXqaZ4Jxf5L+E=";
  };
  codexUsage = pkgs.writeShellScriptBin "waybar-codex" ''
    exec ${pkgs.python3}/bin/python3 ${./waybar-codex.py} "$@"
  '';
  panelData = pkgs.writeShellApplication {
    name = "waybar-panel-data";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.wireplumber
      pkgs.upower
      pkgs.networkmanager
    ];
    text = ''exec ${pkgs.python3}/bin/python3 ${./waybar-panel.py} "$@"'';
  };
  panelModule = pkgs.stdenv.mkDerivation {
    pname = "waybar-gnome-panel";
    version = "0.1.0";
    dontUnpack = true;
    nativeBuildInputs = [ pkgs.pkg-config ];
    buildInputs = [
      pkgs.gtk3
      pkgs.json-glib
    ];
    buildPhase = ''
      $CC -std=gnu11 -O2 -Wall -Wextra -Werror -fPIC -shared \
        ${./waybar-gnome.c} -o libwaybar-gnome.so \
        $(pkg-config --cflags --libs gtk+-3.0 json-glib-1.0) -lm
    '';
    installPhase = ''
      install -Dm755 libwaybar-gnome.so "$out/lib/libwaybar-gnome.so"
    '';
  };
  nativeModule = name: kind: {
    module_path = "${panelModule}/lib/libwaybar-gnome.so";
    inherit name kind;
  };
  session = pkgs.writeShellScript "labwc-session" ''
    . /etc/profile
    export XDG_CURRENT_DESKTOP=labwc:wlroots
    export XDG_SESSION_DESKTOP=labwc
    export XDG_SESSION_TYPE=wayland
    trap '${pkgs.systemd}/bin/systemctl --user stop labwc-session.target' EXIT
    ${pkgs.labwc}/bin/labwc
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
  programs.thunar.enable = true;
  services.greetd = {
    enable = true;
    useTextGreeter = true;
    settings.default_session.command = "${lib.getExe pkgs.tuigreet} --time --remember --cmd ${session}";
  };
  networking.networkmanager.enable = true;
  hardware.bluetooth.enable = true;
  services.power-profiles-daemon.enable = true;
  services.upower.enable = true;
  services.gnome.gnome-keyring.enable = true;
  fonts.packages = [ pkgs.adwaita-fonts ];
  systemd.packages = [ pkgs.labwc ];
  systemd.user.services = {
    waybar = sessionService "${pkgs.waybar}/bin/waybar";
    mako = sessionService "${pkgs.mako}/bin/mako";
    polkit-agent = sessionService "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1";
    swayidle = sessionService "${pkgs.swayidle}/bin/swayidle -w timeout 600 'swaylock -f -c 1e1e2e' before-sleep 'swaylock -f -c 1e1e2e'";
  };

  environment.systemPackages = with pkgs; [
    brightnessctl
    fuzzel
    grim
    mako
    pavucontrol
    slurp
    swayidle
    swaylock
    waybar
    wl-clipboard
    wlr-randr
  ];

  environment.etc = {
    "xdg/labwc/rc.xml".text = ''
      <?xml version="1.0"?>
      <labwc_config>
        <windowSwitcher preview="yes">
          <osd show="yes" style="thumbnail" />
        </windowSwitcher>
        <keyboard>
          <default />
          <keybind key="W-Return"><action name="Execute" command="ghostty" /></keybind>
          <keybind key="W-d"><action name="Execute" command="fuzzel" /></keybind>
          <keybind key="Super_L" onRelease="yes"><action name="Execute" command="fuzzel" /></keybind>
          <keybind key="W-e"><action name="Execute" command="thunar" /></keybind>
          <keybind key="W-l"><action name="Execute" command="swaylock -f -c 1e1e2e" /></keybind>
          <keybind key="W-S-e"><action name="Exit" /></keybind>
          <keybind key="XF86AudioRaiseVolume"><action name="Execute" command="wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+" /></keybind>
          <keybind key="XF86AudioLowerVolume"><action name="Execute" command="wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-" /></keybind>
          <keybind key="XF86AudioMute"><action name="Execute" command="wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle" /></keybind>
          <keybind key="XF86AudioMicMute"><action name="Execute" command="wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle" /></keybind>
          <keybind key="Print"><action name="Execute" command="sh -c 'grim -g &quot;$(slurp)&quot; - | wl-copy'" /></keybind>
        </keyboard>
        <mouse><default /></mouse>
        <libinput><device category="touchpad"><tap>yes</tap><naturalScroll>yes</naturalScroll></device></libinput>
        <windowRules>
          <windowRule identifier="*" type="normal"><action name="Maximize" /></windowRule>
        </windowRules>
      </labwc_config>
    '';
    "xdg/labwc/environment".text = ''
      XKB_DEFAULT_OPTIONS=caps:none
    '';
    "xdg/labwc/autostart".text = ''
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
        on-click = "fuzzel";
        tooltip = false;
      };
      "cffi/codex" = nativeModule "gnome-codex" "indicator" // {
        exec = "${lib.getExe panelData} codex --codex-command ${lib.getExe codexUsage} --codex-icon ${codexIcon}";
      };
      "cffi/monitors" = nativeModule "gnome-monitors" "monitors" // {
        exec = "${lib.getExe panelData} monitors";
        on-click = "ghostty -e btop";
      };
      "cffi/disk" = nativeModule "gnome-disk" "indicator" // {
        exec = "${lib.getExe panelData} disk";
      };
      "cffi/status" = nativeModule "gnome-status" "indicator" // {
        exec = "${lib.getExe panelData} status";
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
      .gnome-calendar { background: #36363a; color: white; border-radius: 24px; padding: 18px; }
    '';
  };
}
