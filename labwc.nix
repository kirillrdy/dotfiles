{
  lib,
  pkgs,
  enableLightDesktop ? false,
  ...
}:
let
  codexUsage = pkgs.writeShellScriptBin "waybar-codex" ''
    exec ${pkgs.python3}/bin/python3 ${./waybar-codex.py}
  '';
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
      height = 30;
      spacing = 8;
      modules-left = [
        "custom/launcher"
        "wlr/taskbar"
      ];
      modules-center = [ "clock" ];
      modules-right = [
        "cpu"
        "memory"
        "temperature"
        "disk"
        "custom/codex"
        "network"
        "pulseaudio"
        "battery"
        "tray"
      ];
      "custom/launcher" = {
        format = "Apps";
        on-click = "fuzzel";
        tooltip = false;
      };
      "wlr/taskbar" = {
        format = "{icon}";
        icon-size = 20;
        on-click = "activate";
        on-click-middle = "close";
        tooltip-format = "{title}";
      };
      clock = {
        format = "{:%a %d %b  %H:%M}";
      };
      cpu = {
        format = "CPU {usage}%";
        interval = 2;
        on-click = "ghostty -e btop";
      };
      memory = {
        format = "RAM {percentage}%";
        interval = 2;
        on-click = "ghostty -e btop";
      };
      temperature = {
        hwmon-path-abs = "/sys/devices/platform/coretemp.0/hwmon";
        input-filename = "temp1_input";
        format = "{temperatureC}°C";
        critical-threshold = 90;
      };
      disk = {
        path = "/";
        format = "Disk {used}/{total}";
        interval = 10;
        on-click = "ghostty -e gdu /";
      };
      "custom/codex" = {
        exec = lib.getExe codexUsage;
        return-type = "json";
        interval = 60;
        escape = true;
      };
      network = {
        format-wifi = "Wi-Fi {signalStrength}%";
        format-ethernet = "Ethernet";
        format-disconnected = "Offline";
        on-click = "ghostty -e nmtui";
      };
      pulseaudio = {
        format = "Vol {volume}%";
        format-muted = "Muted";
        on-click = "pavucontrol";
        on-click-right = "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle";
      };
      battery = {
        format = "BAT {capacity}%";
        format-charging = "BAT {capacity}% +";
        states = {
          warning = 20;
          critical = 10;
        };
      };
      tray.spacing = 8;
    };
    "xdg/waybar/style.css".text = ''
      * { font-family: sans-serif; font-size: 12px; border: none; border-radius: 0; min-height: 0; }
      window#waybar { background: #1e1e2e; color: #cdd6f4; }
      #custom-launcher, #clock, #cpu, #memory, #temperature, #disk,
      #custom-codex, #network, #pulseaudio, #battery, #tray { padding: 0 6px; }
      #taskbar button { padding: 0 5px; }
      #taskbar button.active { background: #45475a; }
      #custom-codex.warning, #battery.warning { color: #f9e2af; }
      #custom-codex.critical, #battery.critical, #temperature.critical { color: #f38ba8; }
      #custom-codex.unavailable { color: #9399b2; }
      tooltip { background: #1e1e2e; color: #cdd6f4; }
    '';
  };
}
