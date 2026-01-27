{
  pkgs,
  config,
  lib,
  ...
}:
let
  volumeRaise = pkgs.writeShellScript "volume-raise" ''
    ${pkgs.swayosd}/bin/swayosd-client --output-volume raise
    ${pkgs.libcanberra-gtk3}/bin/canberra-gtk-play -i audio-volume-change -d "changeVolume"
  '';
  volumeLower = pkgs.writeShellScript "volume-lower" ''
    ${pkgs.swayosd}/bin/swayosd-client --output-volume lower
    ${pkgs.libcanberra-gtk3}/bin/canberra-gtk-play -i audio-volume-change -d "changeVolume"
  '';
  volumeMute = pkgs.writeShellScript "volume-mute" ''
    ${pkgs.swayosd}/bin/swayosd-client --output-volume mute-toggle
  '';

  screenshotRegion = pkgs.writeShellScript "screenshot-region" ''
    ${pkgs.grim}/bin/grim -g "$(${pkgs.slurp}/bin/slurp)" - | ${pkgs.wl-clipboard}/bin/wl-copy
    ${pkgs.libcanberra-gtk3}/bin/canberra-gtk-play -i screen-capture -d "screenshot-region"
  '';

  screenshotFull = pkgs.writeShellScript "screenshot-full" ''
    ${pkgs.grim}/bin/grim - | ${pkgs.wl-clipboard}/bin/wl-copy
    ${pkgs.libcanberra-gtk3}/bin/canberra-gtk-play -i screen-capture -d "screenshot-full"
  '';

  monitorScale = if config.networking.hostName == "hagi" then 2.0 else 1.0;

  waybarConfig = {
    layer = "top";
    position = "top";
    height = 32;
    spacing = 4;
    modules-left = [
      "custom/launcher"
      "labwc/workspaces"
    ];
    modules-center = [ "clock" ];
    modules-right = [
      "tray"
      "cpu"
      "memory"
      "group/system"
    ];

    "custom/launcher" = {
      format = "";
      on-click = "nwg-drawer";
      tooltip = false;
    };
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
      format-icons = [
        " "
        "▂"
        "▃"
        "▄"
        "▅"
        "▆"
        "▇"
        "█"
      ];
    };
    memory = {
      interval = 5;
      format = " {percentage}%";
      tooltip-format = "{used:0.1f}G/{total:0.1f}G";
    };
    "group/system" = {
      orientation = "horizontal";
      modules = [
        "network"
        "pulseaudio"
        "pulseaudio#source"
        "battery"
      ];
    };
    network = {
      format-wifi = "";
      format-ethernet = "";
      format-disconnected = "";
      tooltip-format = "{essid} ({signalStrength}%)";
    };
    battery = {
      format = "{icon} {time}";
      format-charging = "⚡ {icon} {time}";
      format-time = "{H}:{m}";
      format-icons = [
        "󰂎"
        "󰁺"
        "󰁻"
        "󰁼"
        "󰁽"
        "󰁾"
        "󰁿"
        "󰂀"
        "󰂁"
        "󰂂"
        "󰁹"
      ];
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
        default = [
          ""
          ""
          ""
        ];
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

    #custom-launcher {
        padding: 0 12px;
        margin: 4px;
        border-radius: 16px;
    }
    #custom-launcher:hover {
        background: #333333;
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

      <libinput>
        <device category="default">
          <naturalScroll>yes</naturalScroll>
          <tap>no</tap>
        </device>
      </libinput>

      <windowSwitcher preview="no" outlines="no">
        <osd show="yes" style="thumbnail" output="all" thumbnailLabelFormat="%T" />
      </windowSwitcher>

      <keyboard>
        <default />
        <layout>us</layout>
        <options>caps:none</options>
        <keybind key="W-Return"><action name="Execute" command="ghostty" /></keybind>
        <keybind key="Super_L"><action name="Execute" command="nwg-drawer" /></keybind>
        <keybind key="W-q"><action name="Close" /></keybind>
        
        <!-- Snap to edges -->
        <keybind key="W-Left"><action name="SnapToEdge" direction="left" /></keybind>
        <keybind key="W-Right"><action name="SnapToEdge" direction="right" /></keybind>
        <keybind key="W-Up"><action name="SnapToEdge" direction="top" /></keybind>
        <keybind key="W-Down"><action name="SnapToEdge" direction="bottom" /></keybind>

        <!-- Volume control -->
        <keybind key="XF86AudioRaiseVolume"><action name="Execute" command="${volumeRaise}" /></keybind>
        <keybind key="XF86AudioLowerVolume"><action name="Execute" command="${volumeLower}" /></keybind>
        <keybind key="XF86AudioMute"><action name="Execute" command="${volumeMute}" /></keybind>
        <keybind key="XF86AudioMicMute"><action name="Execute" command="${pkgs.swayosd}/bin/swayosd-client --input-volume mute-toggle" /></keybind>

        <!-- Brightness control -->
        <keybind key="XF86MonBrightnessUp"><action name="Execute" command="${pkgs.swayosd}/bin/swayosd-client --brightness raise" /></keybind>
        <keybind key="XF86MonBrightnessDown"><action name="Execute" command="${pkgs.swayosd}/bin/swayosd-client --brightness lower" /></keybind>
<!-- Screenshots -->
        <keybind key="Print"><action name="Execute" command="${screenshotFull}" /></keybind>
        <keybind key="S-Print"><action name="Execute" command="${screenshotRegion}" /></keybind>
      </keyboard>

      <theme>
        <name>Adwaita-Labwc</name>
        <cornerRadius>10</cornerRadius>
        <font name="Cantarell" size="11" />
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



  swayosdStyle = ''
    window {
      background: transparent;
    }

    #container {
      background-color: alpha(#1e1e1e, 0.98);
      border-radius: 99px;
      padding: 16px 24px;
      margin: 16px;
    }

    image {
      color: #ffffff;
      margin-right: 12px;
    }

    progressbar {
      min-height: 6px;
      border-radius: 99px;
      background-color: #454545;
    }

    progressbar > trough > progress {
      background-color: #ffffff;
      border-radius: 99px;
      min-height: 6px;
    }
  '';

  # GTK Settings for adw-gtk3 and Papirus
  gtkSettings = ''
    [Settings]
    gtk-theme-name=adw-gtk3
    gtk-icon-theme-name=Papirus
    gtk-cursor-theme-name=Adwaita
    gtk-application-prefer-dark-theme=1
    gtk-font-name=Cantarell 11
    gtk-xft-antialias=1
    gtk-xft-hinting=1
    gtk-xft-hintstyle=hintslight
    gtk-xft-rgba=rgb
  '';

  # Custom Adwaita Theme for Labwc
  adwaitaLabwcTheme = pkgs.stdenv.mkDerivation {
    name = "adwaita-labwc-theme";
    phases = [ "installPhase" ];
    installPhase = ''
      mkdir -p $out/share/themes/Adwaita-Labwc/openbox-3
      cd $out/share/themes/Adwaita-Labwc/openbox-3

      # --- THEME RC ---
      cat > themerc <<EOF
      # Adwaita-like theme for Labwc
      # Colors based on Adwaita Dark
      
      border.width: 0
      padding.width: 8
      padding.height: 8
      window.active.border.color: #353535
      window.inactive.border.color: #353535
      window.active.title.bg.color: #353535
      window.inactive.title.bg.color: #242424
      window.active.label.text.color: #ffffff
      window.inactive.label.text.color: #9a9a9a
      
      window.active.button.unpressed.image.color: #ffffff
      window.inactive.button.unpressed.image.color: #9a9a9a

      # Button layout and style
      window.button.width: 24
      window.button.spacing: 8

      # Button Icons (SVGs)
      window.active.button.close.unpressed.image: close.svg
      window.active.button.close.hover.image: close_hover.svg
      window.active.button.maximize.unpressed.image: match.svg
      window.active.button.maximize.hover.image: match_hover.svg
      window.active.button.iconify.unpressed.image: iconify.svg
      window.active.button.iconify.hover.image: iconify_hover.svg
      
      # For inactive, reuse unpressed or specific ones
      window.inactive.button.close.unpressed.image: close.svg
      window.inactive.button.maximize.unpressed.image: match.svg
      window.inactive.button.iconify.unpressed.image: iconify.svg

      # OSD Switcher (Thumbnail style)
      osd.bg.color: #1e1e1e
      osd.border.width: 1
      osd.border.color: #454545

      osd.window-switcher.style-thumbnail.width.max: 80%
      osd.window-switcher.style-thumbnail.item.width: 148
      osd.window-switcher.style-thumbnail.item.height: 168
      osd.window-switcher.style-thumbnail.item.icon.size: 96
      osd.window-switcher.style-thumbnail.item.padding: 12
      osd.window-switcher.style-thumbnail.item.active.border.width: 0
      osd.window-switcher.style-thumbnail.item.active.border.color: #353535
      osd.window-switcher.style-thumbnail.item.active.bg.color: #353535
      EOF

      # --- ICONS ---
      
      # CLOSE (Normal: Transparent bg, Icon only)
      cat > close.svg <<EOF
      <svg width="24" height="24" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
        <path d="M7 7L17 17M17 7L7 17" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>
      </svg>
      EOF

      # CLOSE (Hover: Red circle, White icon)
      cat > close_hover.svg <<EOF
      <svg width="24" height="24" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
        <circle cx="12" cy="12" r="12" fill="#E01B24"/>
        <path d="M7 7L17 17M17 7L7 17" stroke="#ffffff" stroke-width="2" stroke-linecap="round"/>
      </svg>
      EOF

      # MAXIMIZE (Normal) - Rect
      cat > match.svg <<EOF
      <svg width="24" height="24" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
        <rect x="6" y="6" width="12" height="12" rx="2" stroke="currentColor" stroke-width="2" fill="none"/>
      </svg>
      EOF

      # MAXIMIZE (Hover: Grey circle)
      cat > match_hover.svg <<EOF
      <svg width="24" height="24" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
        <circle cx="12" cy="12" r="12" fill="#505050"/>
        <rect x="6" y="6" width="12" height="12" rx="2" stroke="#ffffff" stroke-width="2" fill="none"/>
      </svg>
      EOF

      # ICONIFY (Minimize) (Normal) - Line
      cat > iconify.svg <<EOF
      <svg width="24" height="24" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
        <path d="M6 12H18" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>
      </svg>
      EOF

      # ICONIFY (Hover: Grey circle)
      cat > iconify_hover.svg <<EOF
      <svg width="24" height="24" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
        <circle cx="12" cy="12" r="12" fill="#505050"/>
        <path d="M6 12H18" stroke="#ffffff" stroke-width="2" stroke-linecap="round"/>
      </svg>
      EOF
    '';
  };

in
{
  # Configure Labwc defaults in /etc/xdg/labwc
  environment.etc."xdg/labwc/rc.xml".text = labwcRc;

  environment.etc."xdg/labwc/autostart".text = ''
    # Start components
    wlr-randr --output eDP-1 --scale ${toString monitorScale}
    swaybg -i ${pkgs.nixos-artwork.wallpapers.simple-blue.src} -m fill >/dev/null 2>&1 &
    waybar >/dev/null 2>&1 &
    waycorner --config /etc/xdg/waycorner/config.toml >/dev/null 2>&1 &
    swayosd-server >/dev/null 2>&1 &
    nwg-dock-hyprland -d -p bottom -i 32 -w 5 >/dev/null 2>&1 &
  '';

  # Configure Waybar defaults
  environment.etc."xdg/waybar/config".text = builtins.toJSON waybarConfig;
  environment.etc."xdg/waybar/style.css".text = waybarStyle;
  environment.etc."xdg/swayosd/style.css".text = swayosdStyle;

  # Waycorner Configuration (Hot Corner)
  environment.etc."xdg/waycorner/config.toml".text = ''
    [left]
    command = "${pkgs.nwg-drawer}/bin/nwg-drawer"
    locations = ["top_left"]
  '';

  # Global GTK settings
  environment.etc."gtk-3.0/settings.ini".text = gtkSettings;
  # environment.etc."gtk-4.0/settings.ini".text = gtkSettings; # GTK4 usually uses dconf/gsettings but this might help some apps

  # Ensure dconf is enabled so GTK apps store settings
  programs.dconf.enable = true;

  nixpkgs.overlays = [
    (final: prev: {
      labwc = prev.labwc.overrideAttrs (old: {
        buildInputs = (old.buildInputs or [ ]) ++ [
          prev.pkgs.librsvg
          prev.pkgs.libsfdo
        ];

        patches = (old.patches or [ ]) ++ [ ./labwc-gnome-alt-tab.patch ];

        postPatch = (old.postPatch or "") + ''
          # Find the file (handle potential path differences)
          RCXML_FILE=$(find . -name rcxml.c)
          THEME_FILE=$(find . -name theme.c)

          # --- FORCE DEFAULTS (src/theme.c) ---

          # Dimensions
          sed -i 's|theme->osd_window_switcher_thumbnail.item_width = 300;|theme->osd_window_switcher_thumbnail.item_width = 148;|' "$THEME_FILE"
          sed -i 's|theme->osd_window_switcher_thumbnail.item_height = 250;|theme->osd_window_switcher_thumbnail.item_height = 168;|' "$THEME_FILE"
          sed -i 's|theme->osd_window_switcher_thumbnail.item_icon_size = 60;|theme->osd_window_switcher_thumbnail.item_icon_size = 96;|' "$THEME_FILE"

          # Colors (Force Dark Gray BG, Dark Gray Border to remove blue)
          sed -i -E 's|theme->osd_window_switcher_thumbnail.item_active_bg_color\[0\] = FLT_MIN;|parse_hexstr("#353535", theme->osd_window_switcher_thumbnail.item_active_bg_color);|' "$THEME_FILE"
          sed -i -E 's|theme->osd_window_switcher_thumbnail.item_active_border_color\[0\] = FLT_MIN;|parse_hexstr("#353535", theme->osd_window_switcher_thumbnail.item_active_border_color);|' "$THEME_FILE"

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
  environment.systemPackages = with pkgs; [
    grim
    slurp
    adwaitaLabwcTheme
  ];
}
