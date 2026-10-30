//! GNOME quick-settings geometry with asynchronous controls for the desktop services.
const std = @import("std");
const c = @import("gtk");
const audio = @import("audio");
const battery_backend = @import("battery");
const backlight = @import("backlight");
pub const settings_client = @import("desktop-settings.zig");
const network_backend = @import("network");
const session = @import("desktop-session.zig");
// Test builds account for service state and asynchronous callback allocations.
const a = if (@import("builtin").is_test) std.testing.allocator else std.heap.page_allocator;
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
    battery_service: ?*battery_backend.Service = null,
    audio_service: ?*audio.Service = null,
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
    backlight_backend: backlight.Backend = .{},
    brightness_busy: bool = false,
    brightness_writing: bool = false,
    brightness_wanted: ?f64 = null,
    network_client: ?*network_backend.Client = null,
    syncing: bool = false,
    dead: bool = false,
    refs: usize = 1,
    session_busy: bool = false,
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
        self.battery_service = battery_backend.Service.create(&batteryChanged, self) catch null;
        self.audio_service = audio.Service.create(&audioChanged, self) catch null;
        self.network_client = network_backend.Client.create(&networkChanged, self) catch null;
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
        if (c.gtk_toggle_button_get_active(button) != 0) self.networkAction(.scan);
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
        const profile_ptr = c.g_object_get_data(cast(c.GObject, button), "profile-index") orelse return;
        const index = @intFromPtr(profile_ptr) - 1;
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
        self.refreshBrightness();
        if (self.network_client) |client| self.renderNetwork(client.state());
    }
    fn wifiToggled(button: *c.GtkToggleButton, ptr: c.gpointer) callconv(.c) void {
        const self = cast(Controls, ptr);
        if (!self.syncing) self.networkAction(.{ .wifi = c.gtk_toggle_button_get_active(button) != 0 });
    }
    fn mute(_: *c.GtkButton, ptr: c.gpointer) callconv(.c) void {
        cast(Controls, ptr).audioAction(.toggle);
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
        self.audioAction(.{ .volume = c.gtk_range_get_value(cast(c.GtkRange, self.volume)) });
        return 0;
    }
    fn writeBrightness(ptr: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Controls, ptr);
        self.brightness_timer = 0;
        self.brightness_wanted = @max(1, c.gtk_range_get_value(cast(c.GtkRange, self.brightness)));
        self.refreshBrightness();
        return 0;
    }
    fn refreshBrightness(self: *Controls) void {
        if (self.dead or self.brightness_busy) return;
        const wanted = self.brightness_wanted;
        self.brightness_wanted = null;
        self.brightness_busy = true;
        self.brightness_writing = wanted != null;
        self.refs += 1;
        self.backlight_backend.start(if (wanted) |value| .{ .set = value } else .read, self.cancel, &brightnessDone, self);
    }
    fn brightnessDone(ptr: ?*anyopaque, result: backlight.Result) void {
        const self = cast(Controls, ptr);
        self.brightness_busy = false;
        if (!self.dead) {
            var reread = false;
            switch (result) {
                .value => |device| {
                    if (self.brightness_writing) c.gtk_widget_set_tooltip_text(self.content, null);
                    if (self.brightness_wanted == null and self.brightness_timer == 0) {
                        self.syncing = true;
                        c.gtk_range_set_value(cast(c.GtkRange, self.brightness), device.percent());
                        self.syncing = false;
                    }
                    c.gtk_widget_set_no_show_all(self.brightness_row, 0);
                    c.gtk_widget_show_all(self.brightness_row);
                    c.gtk_widget_set_no_show_all(self.brightness_row, 1);
                },
                .failure => |err| {
                    if (err == error.NoBacklight or err == error.BacklightUnavailable) c.gtk_widget_hide(self.brightness_row) else if (err != error.Cancelled) c.gtk_widget_set_tooltip_text(self.content, if (self.brightness_writing) "Brightness change failed" else "Brightness unavailable");
                    reread = self.brightness_writing and err != error.Cancelled and err != error.NoBacklight and err != error.BacklightUnavailable;
                },
            }
            if (self.brightness_wanted != null or reread) self.refreshBrightness();
        }
        self.release();
    }
    pub fn sessionAction(self: *Controls, action: session.Action) void {
        if (self.dead or self.session_busy) return;
        self.session_busy = true;
        self.refs += 1;
        session.perform(action, self.cancel, &sessionDone, self);
    }
    fn sessionDone(ptr: ?*anyopaque, result: session.Result) void {
        const self = cast(Controls, ptr);
        defer self.release();
        self.session_busy = false;
        if (self.dead) return;
        switch (result) {
            .success => c.gtk_widget_set_tooltip_text(self.content, null),
            .failure => |message| c.gtk_widget_set_tooltip_text(self.content, message),
            .cancelled => {},
        }
    }
    fn networkChanged(ptr: ?*anyopaque, client: *network_backend.Client) void {
        const self = cast(Controls, ptr);
        if (!self.dead) self.renderNetwork(client.state());
    }
    fn networkAction(self: *Controls, action: network_backend.Action) void {
        if (self.dead) return;
        const client = self.network_client orelse return;
        self.refs += 1;
        client.perform(action, self.cancel, &networkDone, self);
    }
    fn networkDone(ptr: ?*anyopaque, result: network_backend.Result) void {
        const self = cast(Controls, ptr);
        defer self.release();
        if (self.dead) return;
        switch (result) {
            .success => c.gtk_widget_set_tooltip_text(self.content, null),
            .failure => |message| c.gtk_widget_set_tooltip_text(self.content, message),
        }
    }
    pub fn renderNetwork(self: *Controls, state: *const network_backend.State) void {
        self.syncing = true;
        defer self.syncing = false;
        self.wifi_enabled = state.wifi_enabled;
        c.gtk_widget_set_sensitive(self.network.button, @intFromBool(state.available and state.hardware_enabled));
        c.gtk_toggle_button_set_active(cast(c.GtkToggleButton, self.network.button), @intFromBool(state.wifi_enabled));
        const context = c.gtk_widget_get_style_context(self.network.widget);
        if (state.wifi_enabled) c.gtk_style_context_add_class(context, "quick-active") else c.gtk_style_context_remove_class(context, "quick-active");
        var title: [*:0]const u8 = if (!state.available) "Unavailable" else if (!state.hardware_enabled) "Hardware Blocked" else if (!state.wifi_enabled) "Off" else "Not Connected";
        const children = c.gtk_container_get_children(cast(c.GtkContainer, self.network_list));
        var node = children;
        while (node != null) : (node = node.*.next) c.gtk_widget_destroy(cast(c.GtkWidget, node.*.data));
        c.g_list_free(children);
        var count: usize = 0;
        for (state.access_points.items, 0..) |ap, index| {
            if (ap.connected) title = ap.title;
            if (count == 8 or ap.ssid.len == 0) continue;
            var duplicate = false;
            for (state.access_points.items[0..index]) |previous| {
                if (std.mem.eql(u8, previous.ssid, ap.ssid)) duplicate = true;
            }
            if (duplicate) continue;
            count += 1;
            const row = c.gtk_button_new().?;
            css(row, "profile-choice");
            const box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 12).?;
            const check = label("✓");
            c.gtk_widget_set_opacity(check, if (ap.connected) 1 else 0);
            pack(box, check, false);
            pack(box, image(network_backend.wifiIcon(ap.strength)), false);
            const heading = label(ap.title);
            c.gtk_label_set_ellipsize(cast(c.GtkLabel, heading), c.PANGO_ELLIPSIZE_END);
            pack(box, heading, true);
            if (ap.passwordRequired()) pack(box, image("channel-secure-symbolic"), false);
            c.gtk_container_add(cast(c.GtkContainer, row), box);
            c.g_object_set_data_full(cast(c.GObject, row), "ssid", c.g_strdup(ap.path), &freeData);
            c.g_object_set_data(cast(c.GObject, row), "secure", if (ap.passwordRequired()) @ptrFromInt(1) else null);
            connect(row, "clicked", &connectNetwork, self);
            pack(self.network_list, row, false);
        }
        c.gtk_label_set_text(cast(c.GtkLabel, self.network.subtitle), title);
        c.gtk_widget_show_all(self.network_list);
    }
    fn audioChanged(ptr: ?*anyopaque, service: *audio.Service) void {
        const self = cast(Controls, ptr);
        if (self.dead) return;
        const state = service.state(.output) orelse {
            c.gtk_widget_hide(self.volume_row);
            return;
        };
        self.syncing = true;
        defer self.syncing = false;
        if (self.volume_timer == 0) c.gtk_range_set_value(cast(c.GtkRange, self.volume), state.percent);
        c.gtk_image_set_from_icon_name(cast(c.GtkImage, self.volume_icon), if (state.muted or state.percent == 0) "audio-volume-muted-symbolic" else if (state.percent < 33) "audio-volume-low-symbolic" else if (state.percent < 66) "audio-volume-medium-symbolic" else "audio-volume-high-symbolic", c.GTK_ICON_SIZE_MENU);
        c.gtk_widget_set_no_show_all(self.volume_row, 0);
        c.gtk_widget_show_all(self.volume_row);
        c.gtk_widget_set_no_show_all(self.volume_row, 1);
    }
    fn audioAction(self: *Controls, change: audio.Change) void {
        if (self.dead) return;
        const service = self.audio_service orelse return;
        self.refs += 1;
        service.apply(.output, change, self.cancel, &audioDone, self);
    }
    fn audioDone(ptr: ?*anyopaque, result: audio.Result) void {
        const self = cast(Controls, ptr);
        defer self.release();
        if (self.dead) return;
        switch (result) {
            .value => if (self.audio_service) |service| audioChanged(self, service),
            .failure => |err| c.gtk_widget_set_tooltip_text(self.volume_row, @errorName(err).ptr),
        }
    }
    pub fn monitorBattery(self: *Controls, options: battery_backend.Options) void {
        if (self.battery_service) |service| service.destroy();
        self.battery_service = battery_backend.Service.createWithOptions(options, &batteryChanged, self) catch null;
    }
    fn batteryChanged(ptr: ?*anyopaque, state: battery_backend.State) void {
        const self = cast(Controls, ptr);
        if (self.dead) return;
        if (!state.visible()) {
            c.gtk_widget_hide(self.battery);
            return;
        }
        var buffer: [100]u8 = undefined;
        const text = std.fmt.bufPrintSentinel(&buffer, "{d:.0}%", .{state.percent}, 0) catch return;
        c.gtk_label_set_text(cast(c.GtkLabel, self.battery_label), text);
        const icon = state.icon(&buffer) catch return;
        c.gtk_image_set_from_icon_name(cast(c.GtkImage, self.battery_icon), icon, c.GTK_ICON_SIZE_MENU);
        c.gtk_widget_set_no_show_all(self.battery, 0);
        c.gtk_widget_show_all(self.battery);
        c.gtk_widget_set_no_show_all(self.battery, 1);
    }
    fn freeData(ptr: c.gpointer) callconv(.c) void {
        c.g_free(ptr);
    }
    fn connectNetwork(button: *c.GtkButton, ptr: c.gpointer) callconv(.c) void {
        const self = cast(Controls, ptr);
        const ssid: [*:0]const u8 = @ptrCast(c.g_object_get_data(cast(c.GObject, button), "ssid"));
        const client = self.network_client orelse return;
        const ap = client.state().ap(std.mem.span(ssid)) orelse return;
        if (c.g_object_get_data(cast(c.GObject, button), "secure") == null) {
            self.networkAction(.{ .connect = .{ .ssid = ap.ssid, .access_point = ap.path } });
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
        pack(content, label(ap.title), false);
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
            if (self.network_client) |client| if (client.state().ap(std.mem.span(ssid))) |ap| {
                self.networkAction(.{ .connect = .{ .ssid = ap.ssid, .access_point = ap.path, .password = std.mem.span(c.gtk_entry_get_text(entry)) } });
            };
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
        if (self.session_busy) return;
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
            const name = std.mem.span(action);
            const act: ?session.Action = if (std.mem.eql(u8, name, "suspend"))
                .@"suspend"
            else if (std.mem.eql(u8, name, "reboot"))
                .reboot
            else if (std.mem.eql(u8, name, "poweroff"))
                .poweroff
            else if (std.mem.eql(u8, name, "logout"))
                .logout
            else
                null;
            if (act) |selected| self.sessionAction(selected);
        }
        self.dialog = null;
        c.gtk_widget_destroy(@ptrCast(dialog));
        self.release();
    }
    pub fn deinit(self: *Controls) void {
        self.dead = true;
        if (self.battery_service) |service| service.destroy();
        if (self.audio_service) |service| service.destroy();
        if (self.network_client) |client| client.destroy();
        _ = c.g_signal_handlers_disconnect_matched(self.popover, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
        if (self.dialog) |dialog| c.gtk_dialog_response(cast(c.GtkDialog, dialog), c.GTK_RESPONSE_CANCEL);
        _ = c.g_source_remove(self.timer);
        if (self.volume_timer != 0) _ = c.g_source_remove(self.volume_timer);
        if (self.brightness_timer != 0) _ = c.g_source_remove(self.brightness_timer);
        c.g_cancellable_cancel(self.cancel);
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
