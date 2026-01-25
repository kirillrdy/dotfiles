{ pkgs, ... }:
let
  waybarConfig = {
    layer = "top";
    position = "top";
    height = 32;
    spacing = 4;
    modules-left = [ "labwc/workspaces" ];
    modules-center = [ "clock" ];
    modules-right = [ "tray" "cpu" "memory" "group/system" ];
    
    "labwc/workspaces" = {
        format = "{name}";
    };
    clock = {
        format = "{:%b %d %H:%M}";
        tooltip-format = "<big>{:%Y %B}</big>\n<tt>{calendar}</tt>";
    };
    cpu = {
        interval = 2;
        format = "{icon} {usage}%";
        format-icons = [" " "▂" "▃" "▄" "▅" "▆" "▇" "█"];
    };
    memory = {
        interval = 5;
        format = " {percentage}%";
        tooltip-format = "{used:0.1f}G/{total:0.1f}G";
    };
    "group/system" = {
        orientation = "horizontal";
        modules = [ "network" "pulseaudio" "pulseaudio#source" "battery" ];
    };
    network = {
        format-wifi = "";
        format-ethernet = "";
        format-disconnected = "";
        tooltip-format = "{essid} ({signalStrength}%)";
    };
    battery = {
        format = "{capacity}% {icon}";
        format-icons = ["" "" "" "" ""];
    };
    pulseaudio = {
        format = "{icon}";
        format-bluetooth = "{icon}";
        format-bluetooth-muted = " {icon}";
        format-muted = "";
        format-icons = {
            headphone = "";
            hands-free = "";
            headset = "";
            phone = "";
            portable = "";
            car = "";
            default = ["" "" ""];
        };
        on-click = "pavucontrol";
        tooltip-format = "{volume}%";
    };
    "pulseaudio#source" = {
        format = "{format_source}";
        format-source = "";
        format-source-muted = "";
        on-click = "pavucontrol";
        tooltip-format = "{volume}%";
    };
    tray = {
        spacing = 10;
    };
  };

  waybarStyle = ''
    * {
      border: none;
      border-radius: 0;
      font-family: "Adwaita Sans", "Sans Serif";
      font-size: 15px;
      font-weight: bold;
      min-height: 0;
    }
    
    window#waybar {
      background: #000000;
      color: #ffffff;
    }
    
    #workspaces button {
      padding: 0 12px;
      background: transparent;
      color: #ffffff;
      border-radius: 16px;
      margin: 4px;
    }
    
    #workspaces button.focused {
      background: #333333;
      box-shadow: inset 0 -2px #ffffff; /* Underline indicator like some GNOME versions or just pill? GNOME 40+ is just pill */
      background: #333333;
      box-shadow: none;
    }
    
    #workspaces button:hover {
      background: #454545;
    }

    #clock, #cpu, #memory {
        padding: 0 12px;
        margin: 4px 0;
        border-radius: 16px;
    }
    #clock:hover, #cpu:hover, #memory:hover {
        background: #333333;
    }

    #tray {
        margin-right: 8px;
    }
    
    /* Group: System Indicators */
    #group-system {
        background: transparent;
        margin: 4px;
        padding: 0 6px;
        border-radius: 16px;
    }
    
    #group-system:hover {
        background: #333333;
    }

    #network, #battery, #pulseaudio, #pulseaudio.source {
        padding: 0 6px;
    }
  '';

  labwcRc = ''
    <labwc_config>
      <core>
        <decoration>server</decoration>
        <gap>5</gap>
      </core>

      <windowSwitcher preview="no" outlines="no">
        <osd show="yes" style="thumbnail" output="all" thumbnailLabelFormat="%T" />
      </windowSwitcher>

      <keyboard>
        <default />
        <keybind key="W-Return"><action name="Execute" command="ghostty" /></keybind>
        <keybind key="Super_L"><action name="Execute" command="nwg-drawer" /></keybind>
        <keybind key="W-q"><action name="Close" /></keybind>
        
        <!-- Snap to edges -->
        <keybind key="W-Left"><action name="SnapToEdge" direction="left" /></keybind>
        <keybind key="W-Right"><action name="SnapToEdge" direction="right" /></keybind>
        <keybind key="W-Up"><action name="SnapToEdge" direction="top" /></keybind>
        <keybind key="W-Down"><action name="SnapToEdge" direction="bottom" /></keybind>

        <!-- Volume control -->
        <keybind key="XF86AudioRaiseVolume"><action name="Execute" command="wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+" /></keybind>
        <keybind key="XF86AudioLowerVolume"><action name="Execute" command="wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-" /></keybind>
        <keybind key="XF86AudioMute"><action name="Execute" command="wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle" /></keybind>
        <keybind key="XF86AudioMicMute"><action name="Execute" command="wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle" /></keybind>
      </keyboard>

      <theme>
        <cornerRadius>8</cornerRadius>
        <font name="Adwaita Sans" size="11" />
      </theme>

      <windowRules>
        <windowRule type="normal">
          <action name="Maximize" />
        </windowRule>
      </windowRules>

      <mouse>
        <default />
        <context name="Root">
          <mousebind button="Left" action="Press"><action name="None" /></mousebind>
          <mousebind button="Right" action="Press"><action name="None" /></mousebind>
          <mousebind button="Middle" action="Press"><action name="None" /></mousebind>
        </context>
      </mouse>
    </labwc_config>
  '';
  
  # Labwc Theme Configuration (Adwaita-like dark)
  labwcTheme = ''
    border.width: 0
    window.active.border.color: #353535
    window.inactive.border.color: #353535
    window.active.title.bg.color: #353535
    window.inactive.title.bg.color: #242424
    window.active.label.text.color: #ffffff
    window.inactive.label.text.color: #9a9a9a
    window.active.button.unpressed.image.color: #ffffff
    window.inactive.button.unpressed.image.color: #9a9a9a

    # OSD Switcher (Thumbnail style)
    osd.bg.color: #1e1e1e
    osd.border.width: 1
    osd.border.color: #454545
    
    osd.window-switcher.style-thumbnail.width.max: 80%
    osd.window-switcher.style-thumbnail.item.width: 120
    osd.window-switcher.style-thumbnail.item.height: 140
    osd.window-switcher.style-thumbnail.item.icon.size: 96
    osd.window-switcher.style-thumbnail.item.padding: 4
    osd.window-switcher.style-thumbnail.item.active.border.width: 2
    osd.window-switcher.style-thumbnail.item.active.border.color: #353535
    osd.window-switcher.style-thumbnail.item.active.bg.color: #353535
  '';
  
  # GTK Settings for adw-gtk3 and Papirus
  gtkSettings = ''
    [Settings]
    gtk-theme-name=adw-gtk3
    gtk-icon-theme-name=Papirus
    gtk-cursor-theme-name=Adwaita
    gtk-application-prefer-dark-theme=1
    gtk-font-name=Adwaita Sans 11
    gtk-xft-antialias=1
    gtk-xft-hinting=1
    gtk-xft-hintstyle=hintslight
    gtk-xft-rgba=rgb
  '';

in
{
  # Configure Labwc defaults in /etc/xdg/labwc
  environment.etc."xdg/labwc/rc.xml".text = labwcRc;
  environment.etc."xdg/labwc/themerc".text = labwcTheme;
  environment.etc."xdg/labwc/autostart".text = ''
    # Set environment
    export XCURSOR_THEME=Adwaita
    export GTK_THEME=adw-gtk3
    
    # Start components
    wlr-randr --output eDP-1 --scale 2.0
    swaybg -i ${pkgs.nixos-artwork.wallpapers.simple-dark-gray-bottom.src} -m center >/dev/null 2>&1 &
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
  
  nixpkgs.overlays = [
    (final: prev: {
      labwc = prev.labwc.overrideAttrs (old: {
        buildInputs = (old.buildInputs or []) ++ [ prev.pkgs.librsvg prev.pkgs.libsfdo ];
        
        patches = (old.patches or []) ++ [ ./labwc-gnome-alt-tab.patch ];
        
        postPatch = (old.postPatch or "") + ''
          # Find the file (handle potential path differences)
          RCXML_FILE=$(find . -name rcxml.c)
          THEME_FILE=$(find . -name theme.c)
          
          # --- FORCE DEFAULTS (src/theme.c) ---
          
          # Dimensions
          sed -i 's|theme->osd_window_switcher_thumbnail.item_width = 300;|theme->osd_window_switcher_thumbnail.item_width = 140;|' "$THEME_FILE"
          sed -i 's|theme->osd_window_switcher_thumbnail.item_height = 250;|theme->osd_window_switcher_thumbnail.item_height = 160;|' "$THEME_FILE"
          sed -i 's|theme->osd_window_switcher_thumbnail.item_icon_size = 60;|theme->osd_window_switcher_thumbnail.item_icon_size = 128;|' "$THEME_FILE"
          
          # Colors (Force Dark Gray BG, Dark Gray Border to remove blue)
          sed -i -E 's|theme->osd_window_switcher_thumbnail.item_active_bg_color\[0\] = FLT_MIN;|parse_hexstr("#333333", theme->osd_window_switcher_thumbnail.item_active_bg_color);|' "$THEME_FILE"
          sed -i -E 's|theme->osd_window_switcher_thumbnail.item_active_border_color\[0\] = FLT_MIN;|parse_hexstr("#333333", theme->osd_window_switcher_thumbnail.item_active_border_color);|' "$THEME_FILE"
          
          # Force OSD Main Background Color (GNOME Dark)
          # Replace initialization to FLT_MIN
          sed -i -E 's|theme->osd_bg_color\[0\] = FLT_MIN;|parse_hexstr("#1e1e1e", theme->osd_bg_color);|' "$THEME_FILE"

          # Force OSD Text Color (White)
          sed -i -E 's|theme->osd_label_text_color\[0\] = FLT_MIN;|parse_hexstr("#ffffff", theme->osd_label_text_color);|' "$THEME_FILE"
          
          # --- FORCE DEFAULTS (src/config/rcxml.c) ---
          sed -i -E 's|[[:space:]]*rc\.window_switcher\.style = WINDOW_SWITCHER_CLASSIC;|rc.window_switcher.style = WINDOW_SWITCHER_THUMBNAIL;|g' "$RCXML_FILE"

          # Verify patches
          grep "#1e1e1e" "$THEME_FILE" || { echo "Patch failed: OSD bg color"; exit 1; }
          grep "#ffffff" "$THEME_FILE" || { echo "Patch failed: OSD text color"; exit 1; }
        '';
      });
    })
  ];

  # Install necessary packages (if not already in nixos.nix, but duplicating here ensures this module is self-contained-ish)
  # environment.systemPackages = with pkgs; [ ... ]; 
}
