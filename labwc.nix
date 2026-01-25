{ pkgs, ... }:
let
  waybarConfig = {
    layer = "top";
    position = "top";
    height = 30;
    modules-left = [ "labwc/workspaces" "wlr/taskbar" ];
    modules-center = [ "clock" ];
    modules-right = [ "network" "battery" "tray" ];
    
    "labwc/workspaces" = {
        format = "{name}";
    };
    "wlr/taskbar" = {
        format = "{icon}";
        on-click = "activate";
    };
    clock = {
        format = "{:%H:%M %d/%m/%Y}";
        tooltip-format = "{:%Y-%m-%d %H:%M:%S}";
    };
    network = {
        format-wifi = "{essid} ({signalStrength}%)";
        format-ethernet = "{ipaddr}/{cidr}";
        format-disconnected = "Disconnected";
    };
    battery = {
        format = "{capacity}% {icon}";
        format-icons = ["" "" "" "" ""];
    };
  };

  waybarStyle = ''
    * {
      border: none;
      border-radius: 0;
      font-family: "Sans Serif";
      font-size: 14px;
      min-height: 0;
    }
    window#waybar {
      background: rgba(30, 30, 30, 0.9);
      color: #ffffff;
    }
    #workspaces button {
      padding: 0 5px;
      background: transparent;
      color: #ffffff;
      border-bottom: 3px solid transparent;
    }
    #workspaces button.focused {
      background: #64727D;
      border-bottom: 3px solid #ffffff;
    }
    #clock, #battery, #network, #tray {
      padding: 0 10px;
      margin: 0 4px;
      background-color: rgba(255, 255, 255, 0.1);
      border-radius: 4px;
    }
  '';

  labwcRc = ''
    <labwc_config>
      <core>
        <decoration>server</decoration>
        <gap>5</gap>
      </core>

      <keyboard>
        <default />
        <keybind key="W-Return"><action name="Execute" command="ghostty" /></keybind>
        <keybind key="W-d"><action name="Execute" command="nwg-drawer" /></keybind>
        <keybind key="W-q"><action name="Close" /></keybind>
        
        <!-- Snap to edges -->
        <keybind key="W-Left"><action name="SnapToEdge" direction="left" /></keybind>
        <keybind key="W-Right"><action name="SnapToEdge" direction="right" /></keybind>
        <keybind key="W-Up"><action name="SnapToEdge" direction="top" /></keybind>
        <keybind key="W-Down"><action name="SnapToEdge" direction="bottom" /></keybind>
      </keyboard>

      <theme>
        <name>Adwaita</name>
        <cornerRadius>8</cornerRadius>
        <font name="Sans" size="10" />
      </theme>
    </labwc_config>
  '';
  
  # GTK Settings for adw-gtk3 and Papirus
  gtkSettings = ''
    [Settings]
    gtk-theme-name=adw-gtk3
    gtk-icon-theme-name=Papirus
    gtk-cursor-theme-name=Adwaita
    gtk-application-prefer-dark-theme=1
  '';

in
{
  # Configure Labwc defaults in /etc/xdg/labwc
  environment.etc."xdg/labwc/rc.xml".text = labwcRc;
  environment.etc."xdg/labwc/autostart".text = ''
    # Set environment
    export XCURSOR_THEME=Adwaita
    export GTK_THEME=adw-gtk3
    
    # Start components
    swaybg -c "#242424" >/dev/null 2>&1 &
    waybar >/dev/null 2>&1 &
    nwg-dock-hyprland -d -p bottom -i 32 -w 5 >/dev/null 2>&1 &
  '';

  # Configure Waybar defaults
  environment.etc."xdg/waybar/config".text = builtins.toJSON waybarConfig;
  environment.etc."xdg/waybar/style.css".text = waybarStyle;

  # Global GTK settings
  environment.etc."gtk-3.0/settings.ini".text = gtkSettings;
  # environment.etc."gtk-4.0/settings.ini".text = gtkSettings; # GTK4 usually uses dconf/gsettings but this might help some apps

  # Ensure dconf is enabled so GTK apps store settings
  programs.dconf.enable = true;
  
  # Install necessary packages (if not already in nixos.nix, but duplicating here ensures this module is self-contained-ish)
  # environment.systemPackages = with pkgs; [ ... ]; 
}
