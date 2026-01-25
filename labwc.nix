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
      </keyboard>

      <theme>
        <cornerRadius>8</cornerRadius>
        <font name="Sans" size="10" />
      </theme>
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
    osd.window-switcher.style-thumbnail.item.width: 140
    osd.window-switcher.style-thumbnail.item.height: 160
    osd.window-switcher.style-thumbnail.item.icon.size: 128
    osd.window-switcher.style-thumbnail.item.padding: 4
    osd.window-switcher.style-thumbnail.item.active.border.width: 2
    osd.window-switcher.style-thumbnail.item.active.border.color: #3584e4
    osd.window-switcher.style-thumbnail.item.active.bg.color: #353535
  '';
  
  # C Code helper for rounded corners
  roundedHelper = ''
    #include "buffer.h"
    #include <cairo/cairo.h>
    #include <math.h>

    #ifndef M_PI
    #define M_PI 3.14159265358979323846
    #endif

    static struct wlr_buffer *
    create_rounded_rect_buffer(int width, int height, int radius,
                               float *bg, float *border, int border_width)
    {
        struct lab_data_buffer *buf = buffer_create_cairo(width, height, 1.0);
        cairo_t *cr = cairo_create(buf->surface);
        double x = border_width / 2.0;
        double y = border_width / 2.0;
        double w = width - border_width;
        double h = height - border_width;
        double r = radius;
        double degrees = M_PI / 180.0;
        cairo_new_sub_path(cr);
        cairo_arc(cr, x + w - r, y + r, r, -90 * degrees, 0 * degrees);
        cairo_arc(cr, x + w - r, y + h - r, r, 0 * degrees, 90 * degrees);
        cairo_arc(cr, x + r, y + h - r, r, 90 * degrees, 180 * degrees);
        cairo_arc(cr, x + r, y + r, r, 180 * degrees, 270 * degrees);
        cairo_close_path(cr);
        cairo_set_source_rgba(cr, bg[0], bg[1], bg[2], bg[3]);
        cairo_fill_preserve(cr);
        if (border_width > 0) {
            cairo_set_source_rgba(cr, border[0], border[1], border[2], border[3]);
            cairo_set_line_width(cr, border_width);
            cairo_stroke(cr);
        }
        cairo_destroy(cr);
        return &buf->base;
    }
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
  environment.etc."xdg/labwc/themerc".text = labwcTheme;
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
  
  nixpkgs.overlays = [
    (final: prev: {
      labwc = prev.labwc.overrideAttrs (old: {
        buildInputs = (old.buildInputs or []) ++ [ prev.pkgs.librsvg prev.pkgs.libsfdo ];
        
        postPatch = (old.postPatch or "") + ''
          # Find the file (handle potential path differences)
          THUMB_FILE=$(find . -name osd-thumbnail.c)
          RCXML_FILE=$(find . -name rcxml.c)
          THEME_FILE=$(find . -name theme.c)
          echo "Patching files: $THUMB_FILE, $RCXML_FILE, $THEME_FILE"
          
          # --- OSD THUMBNAIL PATCHES ---
          
          # 1. Inject Helper Function
          cat > rounded_helper.c <<EOF
          ${roundedHelper}
          EOF
          # Inject after last include (approx line 15)
          sed -i '/#include "view.h"/r rounded_helper.c' "$THUMB_FILE"

          # 2. Modify Struct
          sed -i 's|struct lab_scene_rect \*active_bg;|struct wlr_scene_buffer *active_bg;|' "$THUMB_FILE"

          # 3. Replace Creation Logic (Use Helper)
          sed -i '/struct lab_scene_rect_options opts = {/,/item->active_bg = lab_scene_rect_create(item->tree, &opts);/c\
          struct wlr_buffer *bg_buf = create_rounded_rect_buffer(switcher_theme->item_width, switcher_theme->item_height, 12, switcher_theme->item_active_bg_color, switcher_theme->item_active_border_color, switcher_theme->item_active_border_width);\
          item->active_bg = wlr_scene_buffer_create(item->tree, bg_buf);\
          wlr_buffer_drop(bg_buf);' "$THUMB_FILE"

          # 4. Update Logic (struct field access)
          sed -i 's|wlr_scene_node_set_enabled(&item->active_bg->tree->node, active);|wlr_scene_node_set_enabled(\&item->active_bg->node, active);|' "$THUMB_FILE"
          
          # 5. Disable Thumbnail & Center Icon
          sed -i -E 's|struct wlr_buffer \*thumb_buffer = render_thumb\(.*\);|struct wlr_buffer *thumb_buffer = NULL;|' "$THUMB_FILE"
          sed -i -E 's|int y = title_y - padding - icon_size.*|int y = padding + (title_y - padding - icon_size) / 2;|' "$THUMB_FILE"
          
          # 6. App Name Lookup
          sed -i '/#include "view.h"/a const char *desktop_entry_name_lookup(struct server *server, const char *app_id);' "$THUMB_FILE"
          sed -i 's|const char \*title = view_get_string_prop(view, "title");|const char *app_id = view_get_string_prop(view, "app_id"); const char *title = desktop_entry_name_lookup(server, app_id); if (!title) title = app_id;|' "$THUMB_FILE"

          # 7. Rounded OSD Container (Background) & Centering
          # Replace background creation block
          sed -i '/struct lab_scene_rect_options bg_opts = {/,/wlr_scene_node_lower_to_bottom(&bg->tree->node);/c\
          int bg_w = nr_cols * switcher_theme->item_width + 2 * padding;\
          int bg_h = nr_rows * switcher_theme->item_height + 2 * padding;\
          struct wlr_buffer *bg_buf_osd = create_rounded_rect_buffer(bg_w, bg_h, 24, theme->osd_bg_color, theme->osd_border_color, theme->osd_border_width);\
          struct wlr_scene_buffer *bg_scene = wlr_scene_buffer_create(output->osd_scene.tree, bg_buf_osd);\
          wlr_buffer_drop(bg_buf_osd);\
          wlr_scene_node_lower_to_bottom(&bg_scene->node);' "$THUMB_FILE"

          # Update centering to use new bg_w/bg_h variables
          sed -i 's|bg_opts.width|bg_w|g' "$THUMB_FILE"
          sed -i 's|bg_opts.height|bg_h|g' "$THUMB_FILE"
          
          # --- FORCE DEFAULTS (src/theme.c) ---
          
          # Dimensions
          sed -i 's|theme->osd_window_switcher_thumbnail.item_width = 300;|theme->osd_window_switcher_thumbnail.item_width = 140;|' "$THEME_FILE"
          sed -i 's|theme->osd_window_switcher_thumbnail.item_height = 250;|theme->osd_window_switcher_thumbnail.item_height = 160;|' "$THEME_FILE"
          sed -i 's|theme->osd_window_switcher_thumbnail.item_icon_size = 60;|theme->osd_window_switcher_thumbnail.item_icon_size = 128;|' "$THEME_FILE"
          
          # Colors (Force Dark Gray BG, Blue Border)
          sed -i -E 's|theme->osd_window_switcher_thumbnail.item_active_bg_color\[0\] = FLT_MIN;|parse_hexstr("#333333", theme->osd_window_switcher_thumbnail.item_active_bg_color);|' "$THEME_FILE"
          sed -i -E 's|theme->osd_window_switcher_thumbnail.item_active_border_color\[0\] = FLT_MIN;|parse_hexstr("#3584e4", theme->osd_window_switcher_thumbnail.item_active_border_color);|' "$THEME_FILE"
          
          # Force OSD Main Background Color (GNOME Dark)
          # Replace initialization to FLT_MIN
          sed -i -E 's|theme->osd_bg_color\[0\] = FLT_MIN;|parse_hexstr("#1e1e1e", theme->osd_bg_color);|' "$THEME_FILE"
          
          # --- FORCE DEFAULTS (src/config/rcxml.c) ---
          sed -i -E 's|[[:space:]]*rc\.window_switcher\.style = WINDOW_SWITCHER_CLASSIC;|rc.window_switcher.style = WINDOW_SWITCHER_THUMBNAIL;|g' "$RCXML_FILE"

          # Verify patches
          # 3. Replace Creation Logic (Use Helper)
          sed -i '/struct lab_scene_rect_options opts = {/,/item->active_bg = lab_scene_rect_create(item->tree, &opts);/c\
          struct wlr_buffer *bg_buf = create_rounded_rect_buffer(switcher_theme->item_width, switcher_theme->item_height, 24, switcher_theme->item_active_bg_color, switcher_theme->item_active_border_color, switcher_theme->item_active_border_width);\
          item->active_bg = wlr_scene_buffer_create(item->tree, bg_buf);\
          wlr_buffer_drop(bg_buf);' "$THUMB_FILE"

          # 4. Update Logic (struct field access)
          sed -i 's|wlr_scene_node_set_enabled(&item->active_bg->tree->node, active);|wlr_scene_node_set_enabled(\&item->active_bg->node, active);|' "$THUMB_FILE"
          
          # 5. Disable Thumbnail & Center Icon
          sed -i -E 's|struct wlr_buffer \*thumb_buffer = render_thumb\(.*\);|struct wlr_buffer *thumb_buffer = NULL;|' "$THUMB_FILE"
          sed -i -E 's|int y = title_y - padding - icon_size.*|int y = padding + (title_y - padding - icon_size) / 2;|' "$THUMB_FILE"
          
          # 6. App Name Lookup
          sed -i '/#include "view.h"/a const char *desktop_entry_name_lookup(struct server *server, const char *app_id);' "$THUMB_FILE"
          sed -i 's|const char \*title = view_get_string_prop(view, "title");|const char *app_id = view_get_string_prop(view, "app_id"); const char *title = desktop_entry_name_lookup(server, app_id); if (!title) title = app_id;|' "$THUMB_FILE"

          # 7. Rounded OSD Container (Background) & Centering
          sed -i '/struct lab_scene_rect_options bg_opts = {/,/wlr_scene_node_lower_to_bottom(&bg->tree->node);/c\
          int bg_w = nr_cols * switcher_theme->item_width + 2 * padding;\
          int bg_h = nr_rows * switcher_theme->item_height + 2 * padding;\
          struct wlr_buffer *bg_buf_osd = create_rounded_rect_buffer(bg_w, bg_h, 24, theme->osd_bg_color, theme->osd_border_color, theme->osd_border_width);\
          struct wlr_scene_buffer *bg_scene = wlr_scene_buffer_create(output->osd_scene.tree, bg_buf_osd);\
          wlr_buffer_drop(bg_buf_osd);\
          wlr_scene_node_lower_to_bottom(&bg_scene->node);' "$THUMB_FILE"

          sed -i 's|bg_opts.width|bg_w|g' "$THUMB_FILE"
          sed -i 's|bg_opts.height|bg_h|g' "$THUMB_FILE"
          
          # --- FORCE DEFAULTS (src/theme.c) ---
          
          # Dimensions
          sed -i 's|theme->osd_window_switcher_thumbnail.item_width = 300;|theme->osd_window_switcher_thumbnail.item_width = 140;|' "$THEME_FILE"
          sed -i 's|theme->osd_window_switcher_thumbnail.item_height = 250;|theme->osd_window_switcher_thumbnail.item_height = 160;|' "$THEME_FILE"
          sed -i 's|theme->osd_window_switcher_thumbnail.item_icon_size = 60;|theme->osd_window_switcher_thumbnail.item_icon_size = 128;|' "$THEME_FILE"
          
          # Colors
          # Replace BG Color (Selected Item)
          sed -i -E 's|theme->osd_window_switcher_thumbnail.item_active_bg_color\[0\] = FLT_MIN;|parse_hexstr("#333333", theme->osd_window_switcher_thumbnail.item_active_bg_color);|' "$THEME_FILE"
          
          # Replace Border Color (Selected Item - Match BG to remove blue border)
          sed -i -E 's|theme->osd_window_switcher_thumbnail.item_active_border_color\[0\] = FLT_MIN;|parse_hexstr("#333333", theme->osd_window_switcher_thumbnail.item_active_border_color);|' "$THEME_FILE"
          
          # Force OSD Main Background Color (GNOME Dark)
          sed -i -E 's|theme->osd_bg_color\[0\] = FLT_MIN;|parse_hexstr("#1e1e1e", theme->osd_bg_color);|' "$THEME_FILE"

          # Force OSD Text Color (White)
          sed -i -E 's|theme->osd_label_text_color\[0\] = FLT_MIN;|parse_hexstr("#ffffff", theme->osd_label_text_color);|' "$THEME_FILE"
          
          # --- FORCE DEFAULTS (src/config/rcxml.c) ---
          sed -i -E 's|[[:space:]]*rc\.window_switcher\.style = WINDOW_SWITCHER_CLASSIC;|rc.window_switcher.style = WINDOW_SWITCHER_THUMBNAIL;|g' "$RCXML_FILE"

          # Verify patches
          grep "create_rounded_rect_buffer" "$THUMB_FILE" || { echo "Patch failed: rounded helper"; exit 1; }
          grep "#1e1e1e" "$THEME_FILE" || { echo "Patch failed: OSD bg color"; exit 1; }
          grep "#ffffff" "$THEME_FILE" || { echo "Patch failed: OSD text color"; exit 1; }
        '';
      });
    })
  ];

  # Install necessary packages (if not already in nixos.nix, but duplicating here ensures this module is self-contained-ish)
  # environment.systemPackages = with pkgs; [ ... ]; 
}
