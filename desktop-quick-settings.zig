//! GNOME quick-settings geometry with asynchronous controls for the desktop services.
const std = @import("std");
const c = @import("gtk");
const media = @import("desktop-osd.zig");
const network_fields = @import("desktop-settings.zig").fields;
const a = std.heap.page_allocator;
fn cast(comptime T: type, ptr: anytype) *T {
    return @ptrCast(@alignCast(ptr));
}
fn css(widget: anytype, name: [*:0]const u8) void {
    c.gtk_style_context_add_class(c.gtk_widget_get_style_context(widget), name);
}
fn connect(widget: anytype, signal: [*:0]const u8, callback: anytype, data: anytype) void {
    _ = c.g_signal_connect_data(widget, signal, @ptrCast(callback), data, null, 0);
}
fn pack(box: anytype, child: anytype, expand: bool) void {
    c.gtk_box_pack_start(cast(c.GtkBox, box), child, @intFromBool(expand), @intFromBool(expand), 0);
}
fn image(name: [*:0]const u8) *c.GtkWidget {
    const icon = c.gtk_image_new_from_icon_name(name, c.GTK_ICON_SIZE_MENU).?;
    c.gtk_image_set_pixel_size(cast(c.GtkImage, icon), 16);
    return icon;
}
fn label(text: [*:0]const u8) *c.GtkWidget {
    const widget = c.gtk_label_new(text).?;
    c.gtk_label_set_xalign(cast(c.GtkLabel, widget), 0);
    return widget;
}
pub fn settings(schema: [*:0]const u8) ?*c.GSettings {
    const source = c.g_settings_schema_source_get_default() orelse return null;
    const found = c.g_settings_schema_source_lookup(source, schema, 1) orelse return null;
    defer c.g_settings_schema_unref(found);
    return c.g_settings_new_full(found, null, null);
}
pub fn bannersEnabled() bool {
    const prefs = settings("org.gnome.desktop.notifications") orelse return true;
    defer c.g_object_unref(prefs);
    return c.g_settings_get_boolean(prefs, "show-banners") != 0;
}
pub const Tile = struct { widget: *c.GtkWidget, button: *c.GtkWidget, arrow: ?*c.GtkWidget, icon: *c.GtkWidget, subtitle: *c.GtkWidget };
pub fn tile(title: [*:0]const u8, icon_name: [*:0]const u8, has_subtitle: bool, has_menu: bool) Tile {
    const box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0).?;
    css(box, "quick-tile");
    const button = c.gtk_toggle_button_new().?;
    css(button, "quick-toggle");
    if (has_menu) css(button, "quick-toggle-split");
    const content = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 9).?;
    css(content, "quick-toggle-content");
    const icon = image(icon_name);
    pack(content, icon, false);
    const labels = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0).?;
    c.gtk_widget_set_valign(labels, c.GTK_ALIGN_CENTER);
    const heading = label(title);
    css(heading, "quick-toggle-title");
    c.gtk_label_set_ellipsize(cast(c.GtkLabel, heading), c.PANGO_ELLIPSIZE_END);
    pack(labels, heading, false);
    const subtitle = label("");
    css(subtitle, "quick-toggle-subtitle");
    c.gtk_label_set_ellipsize(cast(c.GtkLabel, subtitle), c.PANGO_ELLIPSIZE_END);
    pack(labels, subtitle, false);
    if (!has_subtitle) c.gtk_widget_set_no_show_all(subtitle, 1);
    pack(content, labels, true);
    c.gtk_container_add(cast(c.GtkContainer, button), content);
    pack(box, button, true);
    var arrow: ?*c.GtkWidget = null;
    if (has_menu) {
        const separator = c.gtk_separator_new(c.GTK_ORIENTATION_VERTICAL).?;
        css(separator, "quick-toggle-separator");
        pack(box, separator, false);
        arrow = c.gtk_toggle_button_new().?;
        css(arrow.?, "quick-toggle-arrow");
        c.gtk_container_add(cast(c.GtkContainer, arrow.?), image("go-next-symbolic"));
        pack(box, arrow.?, false);
    }
    return .{ .widget = box, .button = button, .arrow = arrow, .icon = icon, .subtitle = subtitle };
}
fn reveal(widget: *c.GtkWidget, active: c.gboolean) void {
    c.gtk_widget_set_visible(widget, active);
    c.gtk_revealer_set_reveal_child(cast(c.GtkRevealer, widget), active);
}
fn iconButton(icon_name: [*:0]const u8, tooltip: [*:0]const u8) *c.GtkWidget {
    const button = c.gtk_button_new().?;
    css(button, "quick-icon-button");
    c.gtk_container_add(cast(c.GtkContainer, button), image(icon_name));
    c.gtk_widget_set_tooltip_text(button, tooltip);
    return button;
}
const Read = enum { volume, brightness, network, radio, battery, action };
const Job = struct { owner: *Controls, process: *c.GSubprocess, kind: Read, next: ?*Job, timeout: c.guint = 0, input: ?[:0]u8 = null };
pub const Controls = struct {
    popover: *c.GtkWidget,
    content: *c.GtkWidget,
    tiles: *c.GtkWidget,
    network: Tile,
    power: Tile,
    dark: Tile,
    dnd: Tile,
    volume: *c.GtkWidget,
    volume_row: *c.GtkWidget,
    volume_icon: *c.GtkWidget,
    brightness: *c.GtkWidget,
    brightness_row: *c.GtkWidget,
    battery: *c.GtkWidget,
    battery_label: *c.GtkWidget,
    battery_icon: *c.GtkWidget,
    power_menu: *c.GtkWidget,
    profile_menu: *c.GtkWidget,
    profile_buttons: [3]?*c.GtkWidget = @splat(null),
    network_menu: *c.GtkWidget,
    network_list: *c.GtkWidget,
    wifi_enabled: bool = true,
    network_settings: [:0]u8,
    sound_settings: [:0]u8,
    interface: ?*c.GSettings,
    notifications: ?*c.GSettings,
    timer: c.guint = 0,
    volume_timer: c.guint = 0,
    brightness_timer: c.guint = 0,
    pending: [5]bool = @splat(false),
    syncing: bool = false,
    dead: bool = false,
    refs: usize = 1,
    jobs: ?*Job = null,
    cancel: *c.GCancellable,
    dialog: ?*c.GtkWidget = null,

    pub fn create(popover: *c.GtkWidget, network_command: [*:0]const u8, sound_command: [*:0]const u8) *Controls {
        const self = a.create(Controls) catch @panic("out of memory");
        const content = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 12).?;
        css(content, "quick-settings-content");
        c.gtk_container_add(cast(c.GtkContainer, popover), content);
        const system = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 12).?;
        css(system, "quick-system-row");
        pack(content, system, false);
        const battery = c.gtk_button_new().?;
        css(battery, "quick-battery");
        const battery_content = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 9).?;
        const battery_icon = image("battery-level-100-symbolic");
        const battery_label = label("");
        pack(battery_content, battery_icon, false);
        pack(battery_content, battery_label, false);
        c.gtk_container_add(cast(c.GtkContainer, battery), battery_content);
        c.gtk_widget_set_no_show_all(battery, 1);
        pack(system, battery, false);
        pack(system, c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0), true);
        for ([_][*:0]const u8{ "screenshot", "settings", "lock", "power" }, [_][*:0]const u8{ "screenshooter-symbolic", "emblem-system-symbolic", "system-lock-screen-symbolic", "system-shutdown-symbolic" }, [_][*:0]const u8{ "Take Screenshot", "Settings", "Lock Screen", "Power Off Menu" }) |action, icon, tooltip| {
            const button = iconButton(icon, tooltip);
            c.g_object_set_data(cast(c.GObject, button), "action", @constCast(action));
            connect(button, "clicked", &systemAction, self);
            pack(system, button, false);
        }
        const volume_row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6).?;
        css(volume_row, "quick-slider");
        const volume_button = iconButton("audio-volume-high-symbolic", "Mute");
        const volume_icon = c.gtk_bin_get_child(cast(c.GtkBin, volume_button)).?;
        pack(volume_row, volume_button, false);
        const volume = c.gtk_scale_new_with_range(c.GTK_ORIENTATION_HORIZONTAL, 0, 100, 1).?;
        c.gtk_scale_set_draw_value(cast(c.GtkScale, volume), 0);
        c.gtk_widget_set_tooltip_text(volume, "Volume");
        pack(volume_row, volume, true);
        const sound_settings = iconButton("go-next-symbolic", "Sound Settings");
        connect(sound_settings, "clicked", &soundSettings, self);
        pack(volume_row, sound_settings, false);
        pack(content, volume_row, false);
        const brightness_row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6).?;
        css(brightness_row, "quick-slider");
        const brightness_icon = image("display-brightness-symbolic");
        c.gtk_widget_set_margin_start(brightness_icon, 6);
        c.gtk_widget_set_margin_end(brightness_icon, 6);
        pack(brightness_row, brightness_icon, false);
        const brightness = c.gtk_scale_new_with_range(c.GTK_ORIENTATION_HORIZONTAL, 0, 100, 1).?;
        c.gtk_scale_set_draw_value(cast(c.GtkScale, brightness), 0);
        c.gtk_widget_set_tooltip_text(brightness, "Brightness");
        pack(brightness_row, brightness, true);
        pack(content, brightness_row, false);
        // Unsupported devices disappear after probing, as in GNOME.
        c.gtk_widget_set_no_show_all(volume_row, 1);
        c.gtk_widget_set_no_show_all(brightness_row, 1);
        const tiles = c.gtk_grid_new().?;
        c.gtk_grid_set_row_spacing(cast(c.GtkGrid, tiles), 12);
        c.gtk_grid_set_column_spacing(cast(c.GtkGrid, tiles), 12);
        c.gtk_grid_set_column_homogeneous(cast(c.GtkGrid, tiles), 1);
        pack(content, tiles, false);
        const network = tile("Wi-Fi", "network-wireless-symbolic", true, true);
        const power = tile("Power Mode", "power-profile-balanced-symbolic", true, true);
        const dark = tile("Dark Style", "dark-mode-symbolic", false, false);
        const dnd = tile("Do Not Disturb", "notifications-disabled-symbolic", false, false);
        c.gtk_grid_attach(cast(c.GtkGrid, tiles), network.widget, 0, 0, 1, 1);
        c.gtk_grid_attach(cast(c.GtkGrid, tiles), power.widget, 1, 0, 1, 1);
        c.gtk_grid_attach(cast(c.GtkGrid, tiles), dark.widget, 0, 2, 1, 1);
        c.gtk_grid_attach(cast(c.GtkGrid, tiles), dnd.widget, 1, 2, 1, 1);
        const network_menu = c.gtk_revealer_new().?;
        c.gtk_grid_attach(cast(c.GtkGrid, tiles), network_menu, 0, 1, 2, 1);
        const network_content = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0).?;
        css(network_content, "quick-toggle-menu");
        c.gtk_container_add(cast(c.GtkContainer, network_menu), network_content);
        const network_header = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 12).?;
        css(network_header, "quick-menu-header");
        const network_header_icon = image("network-wireless-symbolic");
        c.gtk_image_set_pixel_size(cast(c.GtkImage, network_header_icon), 24);
        css(network_header_icon, "quick-menu-header-icon");
        pack(network_header, network_header_icon, false);
        const network_heading = label("Wi-Fi");
        css(network_heading, "quick-menu-title");
        pack(network_header, network_heading, true);
        pack(network_content, network_header, false);
        const network_list = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0).?;
        pack(network_content, network_list, false);
        const network_settings = c.gtk_button_new_with_label("Wi-Fi Settings").?;
        css(network_settings, "profile-choice");
        pack(network_content, network_settings, false);
        connect(network_settings, "clicked", &networkSettings, self);
        const profile_menu = c.gtk_revealer_new().?;
        c.gtk_grid_attach(cast(c.GtkGrid, tiles), profile_menu, 0, 1, 2, 1);
        c.gtk_widget_show_all(network_content);
        const power_menu = c.gtk_revealer_new().?;
        pack(content, power_menu, false);
        c.gtk_box_reorder_child(cast(c.GtkBox, content), power_menu, 1);
        for ([_]*c.GtkWidget{ network_menu, profile_menu, power_menu }) |submenu| {
            c.gtk_widget_set_no_show_all(submenu, 1);
            c.gtk_revealer_set_transition_type(cast(c.GtkRevealer, submenu), c.GTK_REVEALER_TRANSITION_TYPE_NONE);
        }
        self.* = .{ .popover = popover, .content = content, .tiles = tiles, .network = network, .power = power, .dark = dark, .dnd = dnd, .volume = volume, .volume_row = volume_row, .volume_icon = volume_icon, .brightness = brightness, .brightness_row = brightness_row, .battery = battery, .battery_label = battery_label, .battery_icon = battery_icon, .power_menu = power_menu, .profile_menu = profile_menu, .network_menu = network_menu, .network_list = network_list, .network_settings = a.dupeSentinel(u8, std.mem.span(network_command), 0) catch @panic("out of memory"), .sound_settings = a.dupeSentinel(u8, std.mem.span(sound_command), 0) catch @panic("out of memory"), .interface = settings("org.gnome.desktop.interface"), .notifications = settings("org.gnome.desktop.notifications"), .cancel = c.g_cancellable_new().? };
        connect(popover, "show", &shown, self);
        connect(popover, "closed", &closed, self);
        connect(battery, "clicked", &batterySettings, self);
        connect(volume, "value-changed", &volumeChanged, self);
        connect(brightness, "value-changed", &brightnessChanged, self);
        connect(volume_button, "clicked", &mute, self);
        connect(network.button, "clicked", &wifiToggled, self);
        connect(network.arrow.?, "toggled", &networkExpanded, self);
        connect(power.arrow.?, "toggled", &profileExpanded, self);
        connect(dark.button, "clicked", &darkToggled, self);
        connect(dnd.button, "clicked", &dndToggled, self);
        if (self.interface) |prefs| connect(prefs, "changed", &preferencesChanged, self);
        if (self.notifications) |prefs| connect(prefs, "changed", &preferencesChanged, self);
        self.syncPreferences();
        self.timer = c.g_timeout_add_seconds(5, &refreshTimer, self);
        return self;
    }
    fn syncPreferences(self: *Controls) void {
        if (self.interface) |prefs| {
            const value = c.g_settings_get_string(prefs, "color-scheme");
            defer c.g_free(value);
            c.gtk_toggle_button_set_active(cast(c.GtkToggleButton, self.dark.button), @intFromBool(c.g_strcmp0(value, "prefer-dark") == 0));
        }
        if (self.notifications) |prefs| c.gtk_toggle_button_set_active(cast(c.GtkToggleButton, self.dnd.button), @intFromBool(c.g_settings_get_boolean(prefs, "show-banners") == 0));
        c.gtk_widget_set_sensitive(self.dark.button, @intFromBool(self.interface != null));
        c.gtk_widget_set_sensitive(self.dnd.button, @intFromBool(self.notifications != null));
    }
    fn preferencesChanged(_: ?*c.GSettings, _: [*c]const u8, ptr: c.gpointer) callconv(.c) void {
        const self = cast(Controls, ptr);
        if (!self.dead) self.syncPreferences();
    }
    fn darkToggled(button: *c.GtkToggleButton, ptr: c.gpointer) callconv(.c) void {
        const self = cast(Controls, ptr);
        if (self.interface) |prefs| {
            _ = c.g_settings_set_string(prefs, "color-scheme", if (c.gtk_toggle_button_get_active(button) != 0) "prefer-dark" else "default");
        }
    }
    fn dndToggled(button: *c.GtkToggleButton, ptr: c.gpointer) callconv(.c) void {
        const self = cast(Controls, ptr);
        if (self.notifications) |prefs| {
            _ = c.g_settings_set_boolean(prefs, "show-banners", @intFromBool(c.gtk_toggle_button_get_active(button) == 0));
        }
    }
    fn networkExpanded(button: *c.GtkToggleButton, ptr: c.gpointer) callconv(.c) void {
        const self = cast(Controls, ptr);
        if (c.gtk_toggle_button_get_active(button) != 0) c.gtk_toggle_button_set_active(cast(c.GtkToggleButton, self.power.arrow.?), 0);
        reveal(self.network_menu, c.gtk_toggle_button_get_active(button));
        self.updateDim();
    }
    fn profileExpanded(button: *c.GtkToggleButton, ptr: c.gpointer) callconv(.c) void {
        const self = cast(Controls, ptr);
        if (c.gtk_toggle_button_get_active(button) != 0) c.gtk_toggle_button_set_active(cast(c.GtkToggleButton, self.network.arrow.?), 0);
        reveal(self.profile_menu, c.gtk_toggle_button_get_active(button));
        self.updateDim();
    }
    fn updateDim(self: *Controls) void {
        const active = c.gtk_revealer_get_reveal_child(cast(c.GtkRevealer, self.profile_menu)) != 0 or c.gtk_revealer_get_reveal_child(cast(c.GtkRevealer, self.network_menu)) != 0 or c.gtk_revealer_get_reveal_child(cast(c.GtkRevealer, self.power_menu)) != 0;
        const context = c.gtk_widget_get_style_context(self.content);
        if (active) c.gtk_style_context_add_class(context, "quick-submenu-open") else c.gtk_style_context_remove_class(context, "quick-submenu-open");
    }
    pub fn addPowerSettings(self: *Controls, profiles: *c.GtkWidget, buttons: [3][*c]c.GtkWidget) void {
        for (buttons, &self.profile_buttons) |button, *target| target.* = button;
        const separator = c.gtk_separator_new(c.GTK_ORIENTATION_HORIZONTAL).?;
        css(separator, "quick-menu-separator");
        pack(profiles, separator, false);
        const button = c.gtk_button_new_with_label("Power Settings").?;
        css(button, "profile-choice");
        c.gtk_button_set_alignment(cast(c.GtkButton, button), 0, 0.5);
        connect(button, "clicked", &powerSettings, self);
        pack(profiles, button, false);
    }
    fn powerSettings(_: *c.GtkButton, ptr: c.gpointer) callconv(.c) void {
        const self = cast(Controls, ptr);
        if (self.dialog) |dialog| {
            c.gtk_window_present(cast(c.GtkWindow, dialog));
            return;
        }
        c.gtk_popover_popdown(cast(c.GtkPopover, self.popover));
        const dialog = c.gtk_dialog_new_with_buttons("Power", null, 0, @as([*:0]const u8, "Close"), @as(c_int, c.GTK_RESPONSE_CLOSE), @as(?*anyopaque, null)).?;
        self.dialog = dialog;
        const box = c.gtk_dialog_get_content_area(cast(c.GtkDialog, dialog));
        c.gtk_container_set_border_width(cast(c.GtkContainer, box), 18);
        c.gtk_box_set_spacing(cast(c.GtkBox, box), 12);
        c.gtk_window_set_default_size(cast(c.GtkWindow, dialog), 420, -1);
        pack(box, label("Power Mode"), false);
        for ([_][*:0]const u8{ "Performance", "Balanced", "Power Saver" }, 0..) |name, i| {
            const button = c.gtk_button_new_with_label(name).?;
            c.g_object_set_data(cast(c.GObject, button), "profile-index", @ptrFromInt(i + 1));
            if (self.profile_buttons[i]) |source| c.gtk_widget_set_sensitive(button, c.gtk_widget_get_visible(source));
            connect(button, "clicked", &dialogProfile, self);
            pack(box, button, false);
        }
        self.refs += 1;
        connect(dialog, "response", &powerSettingsClosed, self);
        c.gtk_widget_show_all(dialog);
    }
    fn dialogProfile(button: *c.GtkButton, ptr: c.gpointer) callconv(.c) void {
        const self = cast(Controls, ptr);
        if (self.dead) return;
        const index = @intFromPtr(c.g_object_get_data(cast(c.GObject, button), "profile-index")) - 1;
        if (self.profile_buttons[index]) |source| c.gtk_button_clicked(cast(c.GtkButton, source));
    }
    fn powerSettingsClosed(dialog: *c.GtkDialog, _: c_int, ptr: c.gpointer) callconv(.c) void {
        const self = cast(Controls, ptr);
        self.dialog = null;
        c.gtk_widget_destroy(@ptrCast(dialog));
        self.release();
    }
    fn batterySettings(_: *c.GtkButton, ptr: c.gpointer) callconv(.c) void {
        const self = cast(Controls, ptr);
        c.gtk_toggle_button_set_active(cast(c.GtkToggleButton, self.power.arrow.?), 1);
    }
    fn networkSettings(_: *c.GtkButton, ptr: c.gpointer) callconv(.c) void {
        const self = cast(Controls, ptr);
        self.launch(self.network_settings);
    }
    fn soundSettings(_: *c.GtkButton, ptr: c.gpointer) callconv(.c) void {
        const self = cast(Controls, ptr);
        self.launch(self.sound_settings);
    }
    fn launch(self: *Controls, command: [:0]const u8) void {
        c.gtk_popover_popdown(cast(c.GtkPopover, self.popover));
        var err: [*c]c.GError = null;
        _ = c.g_spawn_command_line_async(command, &err);
        c.g_clear_error(&err);
    }
    fn shown(_: *c.GtkWidget, ptr: c.gpointer) callconv(.c) void {
        cast(Controls, ptr).refresh();
    }
    fn closed(_: *c.GtkPopover, ptr: c.gpointer) callconv(.c) void {
        const self = cast(Controls, ptr);
        if (self.dead) return;
        c.gtk_toggle_button_set_active(cast(c.GtkToggleButton, self.network.arrow.?), 0);
        c.gtk_toggle_button_set_active(cast(c.GtkToggleButton, self.power.arrow.?), 0);
        reveal(self.power_menu, 0);
        self.updateDim();
    }
    fn refreshTimer(ptr: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Controls, ptr);
        if (c.gtk_widget_get_visible(self.popover) != 0) self.refresh();
        return 1;
    }
    pub fn refresh(self: *Controls) void {
        if (self.dead) return;
        self.syncPreferences();
        self.run(.volume, &.{ "wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@" });
        self.run(.brightness, &.{ "brightnessctl", "-c", "backlight", "-m" });
        self.run(.network, &.{ "nmcli", "-t", "-f", "IN-USE,SSID,SECURITY,SIGNAL", "device", "wifi", "list", "--rescan", "no" });
        self.run(.radio, &.{ "nmcli", "-t", "-f", "WIFI", "general" });
        self.run(.battery, &.{ "upower", "-i", "/org/freedesktop/UPower/devices/DisplayDevice" });
    }
    fn wifiToggled(button: *c.GtkToggleButton, ptr: c.gpointer) callconv(.c) void {
        const self = cast(Controls, ptr);
        self.run(.action, &.{ "nmcli", "radio", "wifi", if (c.gtk_toggle_button_get_active(button) != 0) "on" else "off" });
    }
    fn mute(_: *c.GtkButton, ptr: c.gpointer) callconv(.c) void {
        cast(Controls, ptr).run(.action, &.{ "wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle" });
    }
    fn volumeChanged(_: *c.GtkRange, ptr: c.gpointer) callconv(.c) void {
        const self = cast(Controls, ptr);
        if (self.syncing or self.dead) return;
        if (self.volume_timer != 0) _ = c.g_source_remove(self.volume_timer);
        self.volume_timer = c.g_timeout_add(75, &writeVolume, self);
    }
    fn brightnessChanged(_: *c.GtkRange, ptr: c.gpointer) callconv(.c) void {
        const self = cast(Controls, ptr);
        if (self.syncing or self.dead) return;
        if (self.brightness_timer != 0) _ = c.g_source_remove(self.brightness_timer);
        self.brightness_timer = c.g_timeout_add(75, &writeBrightness, self);
    }
    fn writeVolume(ptr: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Controls, ptr);
        self.volume_timer = 0;
        var buffer: [32]u8 = undefined;
        const value = std.fmt.bufPrintSentinel(&buffer, "{d:.0}%", .{c.gtk_range_get_value(cast(c.GtkRange, self.volume))}, 0) catch unreachable;
        self.run(.action, &.{ "wpctl", "set-volume", "-l", "1.0", "@DEFAULT_AUDIO_SINK@", value });
        return 0;
    }
    fn writeBrightness(ptr: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Controls, ptr);
        self.brightness_timer = 0;
        var buffer: [32]u8 = undefined;
        const value = std.fmt.bufPrintSentinel(&buffer, "{d:.0}%", .{@max(1, c.gtk_range_get_value(cast(c.GtkRange, self.brightness)))}, 0) catch unreachable;
        self.run(.action, &.{ "brightnessctl", "-c", "backlight", "set", value });
        return 0;
    }
    fn run(self: *Controls, kind: Read, args: []const [*:0]const u8) void {
        self.runInput(kind, args, null);
    }
    fn runInput(self: *Controls, kind: Read, args: []const [*:0]const u8, input: ?[:0]const u8) void {
        if (self.dead) return;
        if (kind != .action and self.pending[@backingInt(kind)]) return;
        var argv: [16:null]?[*:0]const u8 = @splat(null);
        for (args, 0..) |arg, i| argv[i] = arg;
        var err: [*c]c.GError = null;
        const process = c.g_subprocess_newv(@ptrCast(&argv), @intCast(c.G_SUBPROCESS_FLAGS_STDOUT_PIPE | c.G_SUBPROCESS_FLAGS_STDERR_PIPE | (if (input != null) @as(c_int, c.G_SUBPROCESS_FLAGS_STDIN_PIPE) else 0)), &err);
        c.g_clear_error(&err);
        if (process == null) return;
        const job = a.create(Job) catch @panic("out of memory");
        job.* = .{ .owner = self, .process = process.?, .kind = kind, .next = self.jobs };
        self.jobs = job;
        self.refs += 1;
        if (kind != .action) self.pending[@backingInt(kind)] = true;
        if (input) |value| job.input = a.dupeSentinel(u8, value, 0) catch @panic("out of memory");
        job.timeout = c.g_timeout_add(if (input != null) 30000 else 4000, &timedOut, job);
        c.g_subprocess_communicate_utf8_async(process, if (job.input) |value| value.ptr else null, self.cancel, &completed, job);
    }
    fn timedOut(ptr: c.gpointer) callconv(.c) c.gboolean {
        const job = cast(Job, ptr);
        job.timeout = 0;
        c.g_subprocess_force_exit(job.process);
        return 0;
    }
    fn completed(_: ?*c.GObject, result: ?*c.GAsyncResult, ptr: c.gpointer) callconv(.c) void {
        const job = cast(Job, ptr);
        const self = job.owner;
        var output: [*c]u8 = null;
        var errors: [*c]u8 = null;
        var err: [*c]c.GError = null;
        const ok = c.g_subprocess_communicate_utf8_finish(job.process, result, &output, &errors, &err) != 0 and c.g_subprocess_get_successful(job.process) != 0;
        defer c.g_free(output);
        defer c.g_free(errors);
        defer c.g_clear_error(&err);
        if (job.timeout != 0) _ = c.g_source_remove(job.timeout);
        var link = &self.jobs;
        while (link.* != job) link = &link.*.?.next;
        link.* = job.next;
        if (job.kind != .action) self.pending[@backingInt(job.kind)] = false;
        if (!self.dead) {
            if (ok) self.apply(job.kind, if (output != null) std.mem.span(output) else "") else if (job.kind == .brightness) c.gtk_widget_hide(self.brightness_row) else if (job.kind == .volume) c.gtk_widget_hide(self.volume_row);
            if (!ok and job.kind == .action) c.gtk_widget_set_tooltip_text(self.content, if (err != null) err.*.message else errors);
        }
        c.g_object_unref(job.process);
        if (job.input) |value| {
            @memset(value, 0);
            a.free(value);
        }
        a.destroy(job);
        self.release();
    }
    fn apply(self: *Controls, kind: Read, output: []const u8) void {
        self.syncing = true;
        defer self.syncing = false;
        switch (kind) {
            .volume => {
                const state = media.parseVolume(output) catch return;
                c.gtk_range_set_value(cast(c.GtkRange, self.volume), state.percent);
                c.gtk_image_set_from_icon_name(cast(c.GtkImage, self.volume_icon), if (state.muted or state.percent == 0) "audio-volume-muted-symbolic" else if (state.percent < 33) "audio-volume-low-symbolic" else if (state.percent < 66) "audio-volume-medium-symbolic" else "audio-volume-high-symbolic", c.GTK_ICON_SIZE_MENU);
                c.gtk_widget_set_no_show_all(self.volume_row, 0);
                c.gtk_widget_show_all(self.volume_row);
                c.gtk_widget_set_no_show_all(self.volume_row, 1);
            },
            .brightness => {
                const state = media.parseBrightness(output) catch return;
                c.gtk_range_set_value(cast(c.GtkRange, self.brightness), state.percent);
                c.gtk_widget_set_no_show_all(self.brightness_row, 0);
                c.gtk_widget_show_all(self.brightness_row);
                c.gtk_widget_set_no_show_all(self.brightness_row, 1);
            },
            .network => {
                const children = c.gtk_container_get_children(cast(c.GtkContainer, self.network_list));
                var node = children;
                while (node != null) : (node = node.*.next) c.gtk_widget_destroy(cast(c.GtkWidget, node.*.data));
                c.g_list_free(children);
                var arena = std.heap.ArenaAllocator.init(a);
                defer arena.deinit();
                var lines = std.mem.splitScalar(u8, output, '\n');
                var active: []const u8 = if (self.wifi_enabled) "Not Connected" else "Off";
                var count: usize = 0;
                while (lines.next()) |line| {
                    const fields = network_fields(4, arena.allocator(), line) catch continue;
                    if (fields[1].len == 0 or count == 8) continue;
                    count += 1;
                    const connected = std.mem.eql(u8, fields[0], "*");
                    if (connected) active = fields[1];
                    const row = c.gtk_button_new().?;
                    css(row, "profile-choice");
                    const box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 12).?;
                    const check = label("✓");
                    css(check, "profile-check");
                    c.gtk_widget_set_opacity(check, if (connected) 1 else 0);
                    pack(box, check, false);
                    const strength = std.fmt.parseInt(u32, fields[3], 10) catch 0;
                    pack(box, image(if (strength >= 80) "network-wireless-signal-excellent-symbolic" else if (strength >= 55) "network-wireless-signal-good-symbolic" else if (strength >= 30) "network-wireless-signal-ok-symbolic" else "network-wireless-signal-weak-symbolic"), false);
                    const ssid = arena.allocator().dupeSentinel(u8, fields[1], 0) catch continue;
                    const title = label(ssid);
                    c.gtk_label_set_ellipsize(cast(c.GtkLabel, title), c.PANGO_ELLIPSIZE_END);
                    pack(box, title, true);
                    const secure = fields[2].len > 0 and !std.mem.eql(u8, fields[2], "--");
                    if (secure) {
                        const lock = image("channel-secure-symbolic");
                        c.gtk_image_set_pixel_size(cast(c.GtkImage, lock), 8);
                        pack(box, lock, false);
                    }
                    c.gtk_container_add(cast(c.GtkContainer, row), box);
                    c.g_object_set_data_full(cast(c.GObject, row), "ssid", c.g_strdup(ssid), &freeData);
                    c.g_object_set_data(cast(c.GObject, row), "secure", if (secure) @ptrFromInt(1) else null);
                    connect(row, "clicked", &connectNetwork, self);
                    pack(self.network_list, row, false);
                }
                c.gtk_widget_show_all(self.network_list);
                const text = a.dupeSentinel(u8, active, 0) catch return;
                defer a.free(text);
                c.gtk_label_set_text(cast(c.GtkLabel, self.network.subtitle), text);
            },
            .radio => {
                const enabled = std.mem.eql(u8, std.mem.trim(u8, output, " \r\n"), "enabled");
                self.wifi_enabled = enabled;
                const context = c.gtk_widget_get_style_context(self.network_menu);
                if (enabled) c.gtk_style_context_add_class(context, "quick-active-menu") else c.gtk_style_context_remove_class(context, "quick-active-menu");
                if (!enabled) c.gtk_label_set_text(cast(c.GtkLabel, self.network.subtitle), "Off");
                c.gtk_toggle_button_set_active(cast(c.GtkToggleButton, self.network.button), @intFromBool(enabled));
                if (enabled) css(self.network.widget, "quick-active") else c.gtk_style_context_remove_class(c.gtk_widget_get_style_context(self.network.widget), "quick-active");
            },
            .battery => {
                var lines = std.mem.splitScalar(u8, output, '\n');
                var percent: ?f64 = null;
                var state: []const u8 = "";
                while (lines.next()) |line| {
                    const text = std.mem.trim(u8, line, " \t");
                    if (std.mem.startsWith(u8, text, "percentage:")) percent = std.fmt.parseFloat(f64, std.mem.trim(u8, text[11..], " \t%")) catch null;
                    if (std.mem.startsWith(u8, text, "state:")) state = std.mem.trim(u8, text[6..], " \t");
                }
                if (percent) |value| {
                    if (!std.math.isFinite(value) or value < 0 or value > 100) return;
                    var buffer: [80]u8 = undefined;
                    const text = std.fmt.bufPrintSentinel(&buffer, "{d:.0}%", .{value}, 0) catch return;
                    c.gtk_label_set_text(cast(c.GtkLabel, self.battery_label), text);
                    const suffix: []const u8 = if (std.mem.eql(u8, state, "fully-charged")) "-charged" else if (std.mem.eql(u8, state, "charging")) "-charging" else "";
                    const icon = std.fmt.bufPrintSentinel(&buffer, "battery-level-{d}{s}-symbolic", .{ @as(u32, @intFromFloat(@floor(value / 10))) * 10, suffix }, 0) catch return;
                    c.gtk_image_set_from_icon_name(cast(c.GtkImage, self.battery_icon), icon, c.GTK_ICON_SIZE_MENU);
                    c.gtk_widget_set_no_show_all(self.battery, 0);
                    c.gtk_widget_show_all(self.battery);
                    c.gtk_widget_set_no_show_all(self.battery, 1);
                } else c.gtk_widget_hide(self.battery);
            },
            .action => self.refresh(),
        }
    }
    fn freeData(ptr: c.gpointer) callconv(.c) void {
        c.g_free(ptr);
    }
    fn connectNetwork(button: *c.GtkButton, ptr: c.gpointer) callconv(.c) void {
        const self = cast(Controls, ptr);
        const ssid: [*:0]const u8 = @ptrCast(c.g_object_get_data(cast(c.GObject, button), "ssid"));
        if (c.g_object_get_data(cast(c.GObject, button), "secure") == null) {
            self.run(.action, &.{ "nmcli", "--wait", "3", "device", "wifi", "connect", ssid });
            return;
        }
        if (self.dialog) |dialog| {
            c.gtk_window_present(cast(c.GtkWindow, dialog));
            return;
        }
        c.gtk_popover_popdown(cast(c.GtkPopover, self.popover));
        const dialog = c.gtk_dialog_new_with_buttons("Authentication Required", null, c.GTK_DIALOG_MODAL, @as([*:0]const u8, "Cancel"), @as(c_int, c.GTK_RESPONSE_CANCEL), @as([*:0]const u8, "Connect"), @as(c_int, c.GTK_RESPONSE_ACCEPT), @as(?*anyopaque, null)).?;
        self.dialog = dialog;
        const content = c.gtk_dialog_get_content_area(cast(c.GtkDialog, dialog));
        c.gtk_container_set_border_width(cast(c.GtkContainer, content), 18);
        c.gtk_box_set_spacing(cast(c.GtkBox, content), 12);
        pack(content, label(ssid), false);
        const password = c.gtk_entry_new().?;
        c.gtk_entry_set_visibility(cast(c.GtkEntry, password), 0);
        c.gtk_entry_set_input_purpose(cast(c.GtkEntry, password), c.GTK_INPUT_PURPOSE_PASSWORD);
        c.gtk_entry_set_placeholder_text(cast(c.GtkEntry, password), "Password");
        c.gtk_entry_set_activates_default(cast(c.GtkEntry, password), 1);
        c.gtk_dialog_set_default_response(cast(c.GtkDialog, dialog), c.GTK_RESPONSE_ACCEPT);
        pack(content, password, false);
        c.g_object_set_data(cast(c.GObject, dialog), "password", password);
        c.g_object_set_data_full(cast(c.GObject, dialog), "ssid", c.g_strdup(ssid), &freeData);
        self.refs += 1;
        connect(dialog, "response", &networkConfirmed, self);
        c.gtk_widget_show_all(dialog);
    }
    fn networkConfirmed(dialog: *c.GtkDialog, response: c_int, ptr: c.gpointer) callconv(.c) void {
        const self = cast(Controls, ptr);
        const entry: *c.GtkEntry = @ptrCast(@alignCast(c.g_object_get_data(cast(c.GObject, dialog), "password")));
        const ssid: [*:0]const u8 = @ptrCast(c.g_object_get_data(cast(c.GObject, dialog), "ssid"));
        if (!self.dead and response == c.GTK_RESPONSE_ACCEPT) {
            const input = std.fmt.allocPrintSentinel(a, "{s}\n", .{std.mem.span(c.gtk_entry_get_text(entry))}, 0) catch @panic("out of memory");
            defer {
                @memset(input, 0);
                a.free(input);
            }
            self.runInput(.action, &.{ "nmcli", "--wait", "25", "--ask", "device", "wifi", "connect", ssid }, input);
        }
        c.gtk_entry_set_text(entry, "");
        self.dialog = null;
        c.gtk_widget_destroy(@ptrCast(dialog));
        self.release();
    }
    fn systemAction(button: *c.GtkButton, ptr: c.gpointer) callconv(.c) void {
        const self = cast(Controls, ptr);
        const action: [*:0]const u8 = @ptrCast(c.g_object_get_data(cast(c.GObject, button), "action"));
        if (std.mem.eql(u8, std.mem.span(action), "power")) {
            if (c.gtk_bin_get_child(cast(c.GtkBin, self.power_menu)) == null) {
                const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0).?;
                css(box, "quick-toggle-menu");
                const title = label("Power Off");
                css(title, "quick-menu-title");
                pack(box, title, false);
                for ([_][*:0]const u8{ "Suspend", "Restart…", "Power Off…", "Log Out…" }, [_][*:0]const u8{ "suspend", "reboot", "poweroff", "logout" }) |name, command| {
                    const row = c.gtk_button_new_with_label(name).?;
                    css(row, "profile-choice");
                    c.g_object_set_data(cast(c.GObject, row), "action", @constCast(command));
                    connect(row, "clicked", &confirmAction, self);
                    pack(box, row, false);
                }
                c.gtk_container_add(cast(c.GtkContainer, self.power_menu), box);
                c.gtk_widget_show_all(box);
            }
            reveal(self.power_menu, @intFromBool(c.gtk_revealer_get_reveal_child(cast(c.GtkRevealer, self.power_menu)) == 0));
            self.updateDim();
        } else if (std.mem.eql(u8, std.mem.span(action), "settings")) self.launch(self.network_settings) else if (std.mem.eql(u8, std.mem.span(action), "lock")) self.launch("desktop-zig lock --daemonize") else {
            c.gtk_popover_popdown(cast(c.GtkPopover, self.popover));
            self.refs += 1;
            _ = c.g_timeout_add(200, &screenshot, self);
        }
    }
    fn screenshot(ptr: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Controls, ptr);
        if (!self.dead) {
            const executable: [*:0]const u8 = if (c.g_getenv("DESKTOP_POWER_HELPER")) |value| @ptrCast(value) else "desktop-zig";
            const argv = [_:null]?[*:0]const u8{ executable, "screenshot" };
            if (c.g_subprocess_newv(@ptrCast(&argv), c.G_SUBPROCESS_FLAGS_NONE, null)) |process| c.g_object_unref(process);
        }
        self.release();
        return 0;
    }
    fn confirmAction(button: *c.GtkButton, ptr: c.gpointer) callconv(.c) void {
        const self = cast(Controls, ptr);
        const action: [*:0]const u8 = @ptrCast(c.g_object_get_data(cast(c.GObject, button), "action"));
        if (self.dialog) |dialog| {
            c.gtk_window_present(cast(c.GtkWindow, dialog));
            return;
        }
        c.gtk_popover_popdown(cast(c.GtkPopover, self.popover));
        const dialog = c.gtk_message_dialog_new(null, c.GTK_DIALOG_MODAL, c.GTK_MESSAGE_QUESTION, c.GTK_BUTTONS_CANCEL, "%s", c.gtk_button_get_label(button)).?;
        self.dialog = dialog;
        _ = c.gtk_dialog_add_button(cast(c.GtkDialog, dialog), "Confirm", c.GTK_RESPONSE_ACCEPT);
        c.g_object_set_data(cast(c.GObject, dialog), "action", @constCast(action));
        self.refs += 1;
        connect(dialog, "response", &confirmed, self);
        c.gtk_widget_show(dialog);
    }
    fn confirmed(dialog: *c.GtkDialog, response: c_int, ptr: c.gpointer) callconv(.c) void {
        const self = cast(Controls, ptr);
        const action: [*:0]const u8 = @ptrCast(c.g_object_get_data(cast(c.GObject, dialog), "action"));
        if (response == c.GTK_RESPONSE_ACCEPT and !self.dead) {
            if (std.mem.eql(u8, std.mem.span(action), "logout")) {
                if (c.g_getenv("XDG_SESSION_ID")) |id| self.run(.action, &.{ "loginctl", "terminate-session", id });
            } else self.run(.action, &.{ "systemctl", action });
        }
        self.dialog = null;
        c.gtk_widget_destroy(@ptrCast(dialog));
        self.release();
    }
    pub fn deinit(self: *Controls) void {
        self.dead = true;
        _ = c.g_signal_handlers_disconnect_matched(self.popover, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
        if (self.dialog) |dialog| c.gtk_dialog_response(cast(c.GtkDialog, dialog), c.GTK_RESPONSE_CANCEL);
        _ = c.g_source_remove(self.timer);
        if (self.volume_timer != 0) _ = c.g_source_remove(self.volume_timer);
        if (self.brightness_timer != 0) _ = c.g_source_remove(self.brightness_timer);
        c.g_cancellable_cancel(self.cancel);
        var job = self.jobs;
        while (job) |value| : (job = value.next) c.g_subprocess_force_exit(value.process);
        if (self.interface) |prefs| {
            _ = c.g_signal_handlers_disconnect_matched(prefs, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
            c.g_object_unref(prefs);
        }
        if (self.notifications) |prefs| {
            _ = c.g_signal_handlers_disconnect_matched(prefs, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
            c.g_object_unref(prefs);
        }
        self.release();
    }
    fn release(self: *Controls) void {
        self.refs -= 1;
        if (self.refs == 0) {
            c.g_object_unref(self.cancel);
            a.free(self.network_settings);
            a.free(self.sound_settings);
            a.destroy(self);
        }
    }
};
