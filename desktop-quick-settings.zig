//! GNOME quick-settings geometry with asynchronous controls for the desktop services.
const std = @import("std");
const c = @import("desktop-gtk.zig");
const audio = @import("desktop-audio.zig");
const battery_backend = @import("desktop-battery.zig");
const backlight = @import("desktop-backlight.zig");
pub const settings_client = @import("desktop-settings.zig");
const network_backend = @import("desktop-network.zig");
const session = @import("desktop-session.zig");
const native = @import("desktop-quick-settings-view.zig");
pub const Target = native.Target;
const power_backend = @import("desktop-power.zig");
// Test builds account for service state and asynchronous callback allocations.
const a = if (@import("builtin").is_test) std.testing.allocator else std.heap.page_allocator;
const cast = c.__zig.cast;
fn css(widget: anytype, name: [*:0]const u8) void {
    c.gtk_style_context_add_class(c.gtk_widget_get_style_context(widget), name);
}
fn connect(widget: anytype, signal: [*:0]const u8, callback: anytype, data: anytype) void {
    _ = c.g_signal_connect_data(widget, signal, @ptrCast(callback), data, null, 0);
}
fn pack(box: anytype, child: anytype, expand: bool) void {
    c.gtk_box_pack_start(cast(c.GtkBox, box), child, @intFromBool(expand), @intFromBool(expand), 0);
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
pub const Controls = struct {
    popover: *c.GtkWidget,
    content: *c.GtkWidget,
    canvas: *c.GtkWidget,
    view: native.View = .{},
    network_paths: [8]?[:0]u8 = @splat(null),
    profile_context: ?*anyopaque = null,
    profile_selected: ?*const fn (?*anyopaque, usize) void = null,
    battery_service: ?*battery_backend.Service = null,
    audio_service: ?*audio.Service = null,
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
    dead: bool = false,
    refs: usize = 1,
    session_busy: bool = false,
    cancel: *c.GCancellable,
    dialog: ?*c.GtkWidget = null,

    pub fn redraw(self: *Controls) void {
        if (self.dead) return;
        self.view.layout();
        c.gtk_widget_set_size_request(self.canvas, @intCast(self.view.width), @intCast(self.view.height));
        c.gtk_widget_queue_draw(self.canvas);
    }
    pub fn setMessage(self: *Controls, message: []const u8) void {
        self.view.model.message.set(message);
        self.redraw();
    }
    pub fn setPowerState(self: *Controls, state: power_backend.State, pending: bool) void {
        self.view.model.power_state = state;
        self.view.model.power_pending = pending;
        self.redraw();
    }
    fn selectProfile(self: *Controls, index: usize) void {
        if (self.dead or self.view.model.power_pending or !self.view.model.power_state.available[index]) return;
        if (self.profile_selected) |callback| callback(self.profile_context, index);
    }
    pub fn activate(self: *Controls, target: native.Target) void {
        if (self.dead or !self.view.enabled(target)) return;
        switch (target) {
            .battery, .profiles => self.view.submenu = if (self.view.submenu == .profiles) .none else .profiles,
            .network => {
                self.view.submenu = if (self.view.submenu == .network) .none else .network;
                if (self.view.submenu == .network) self.networkAction(.scan);
            },
            .power => self.view.submenu = if (self.view.submenu == .power) .none else .power,
            .wifi => self.networkAction(.{ .wifi = !self.view.model.wifi_enabled }),
            .profile_toggle => self.selectProfile(if (self.view.model.power_state.active == .balanced) 2 else 1),
            .profile0, .profile1, .profile2 => self.selectProfile(@backingInt(target) - @backingInt(native.Target.profile0)),
            .dark => if (self.interface) |prefs| {
                _ = c.g_settings_set_string(prefs, "color-scheme", if (self.view.model.dark) "default" else "prefer-dark");
                self.syncPreferences();
            },
            .dnd => if (self.notifications) |prefs| {
                _ = c.g_settings_set_boolean(prefs, "show-banners", @intFromBool(self.view.model.dnd));
                self.syncPreferences();
            },
            .mute => self.audioAction(.toggle),
            .sound => self.launch(self.sound_settings),
            .settings, .network_settings => self.launch(self.network_settings),
            .lock => self.launch("desktop-zig lock --daemonize"),
            .screenshot => {
                c.gtk_popover_popdown(cast(c.GtkPopover, self.popover));
                self.refs += 1;
                _ = c.g_timeout_add(200, &screenshot, self);
            },
            .power_settings => powerSettings(null, self),
            .network0, .network1, .network2, .network3, .network4, .network5, .network6, .network7 => self.connectNetwork(@backingInt(target) - @backingInt(native.Target.network0)),
            .suspend_action => self.confirmAction("suspend", "Suspend"),
            .reboot => self.confirmAction("reboot", "Restart…"),
            .poweroff => self.confirmAction("poweroff", "Power Off…"),
            .logout => self.confirmAction("logout", "Log Out…"),
            else => {},
        }
        self.redraw();
        if (self.view.keyboard_focus and (target == .network or target == .profiles or target == .power or target == .battery) and self.view.submenu != .none) {
            for (self.view.items[0..self.view.item_count]) |entry| if (entry.row and entry.enabled) {
                self.view.focus = entry.target;
                break;
            };
        }
    }
    pub fn setSlider(self: *Controls, target: native.Target, value: f64) void {
        if (self.dead or !self.view.enabled(target) or !std.math.isFinite(value)) return;
        const percent = std.math.clamp(value, if (target == .brightness) @as(f64, 1) else @as(f64, 0), 100);
        if ((target == .volume and self.view.model.volume == percent) or (target == .brightness and self.view.model.brightness == percent)) return;
        switch (target) {
            .volume => {
                self.view.model.volume = percent;
                if (self.volume_timer != 0) _ = c.g_source_remove(self.volume_timer);
                self.volume_timer = c.g_timeout_add(75, &writeVolume, self);
            },
            .brightness => {
                self.view.model.brightness = percent;
                if (self.brightness_timer != 0) _ = c.g_source_remove(self.brightness_timer);
                self.brightness_timer = c.g_timeout_add(75, &writeBrightness, self);
            },
            else => return,
        }
        self.redraw();
    }
    fn draw(_: *c.GtkWidget, cr: *c.cairo_t, ptr: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Controls, ptr);
        if (self.dead) return 1;
        const scale: u32 = @intCast(@max(1, c.gtk_widget_get_scale_factor(self.canvas)));
        const width = self.view.width * scale;
        const height = self.view.height * scale;
        // GTK may retain this source in its drawing cache. Keep the storage
        // owned by the image for as long as any Cairo reference survives.
        const image = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, @intCast(width), @intCast(height));
        defer c.cairo_surface_destroy(image);
        if (c.cairo_surface_status(image) != 0) return 1;
        const pixels: [*]u32 = @ptrCast(@alignCast(c.cairo_image_surface_get_data(image)));
        self.view.paint(a, .{ .pixels = pixels[0 .. width * height], .width = width, .height = height }, scale) catch |err| {
            std.log.err("quick-settings render: {s}", .{@errorName(err)});
            return 1;
        };
        // GTK hosts the popup; Cairo only transfers the completed native pixels.
        c.cairo_surface_mark_dirty(image);
        c.cairo_surface_set_device_scale(image, @floatFromInt(scale), @floatFromInt(scale));
        c.cairo_set_source_surface(cr, image, 0, 0);
        c.cairo_paint(cr);
        return 1;
    }
    fn press(_: *c.GtkWidget, event: *c.GdkEventButton, ptr: c.gpointer) callconv(.c) c.gboolean {
        if (event.button != 1) return 0;
        const self = cast(Controls, ptr);
        c.gtk_widget_grab_focus(self.canvas);
        self.view.keyboard_focus = false;
        self.view.hover = self.view.hit(event.x, event.y);
        self.view.pressed = self.view.hover;
        self.view.focus = self.view.hover;
        if (native.View.slider(self.view.pressed)) self.setSlider(self.view.pressed, self.view.sliderValue(self.view.pressed, event.x));
        self.redraw();
        return 1;
    }
    fn buttonReleased(_: *c.GtkWidget, event: *c.GdkEventButton, ptr: c.gpointer) callconv(.c) c.gboolean {
        if (event.button != 1) return 0;
        const self = cast(Controls, ptr);
        const target = self.view.pressed;
        self.view.pressed = .none;
        if (native.View.slider(target) and self.view.enabled(target)) self.setSlider(target, self.view.sliderValue(target, event.x)) else if (target != .none and target == self.view.hit(event.x, event.y)) self.activate(target);
        self.redraw();
        return 1;
    }
    fn motion(_: *c.GtkWidget, event: *c.GdkEventMotion, ptr: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Controls, ptr);
        const previous = self.view.hover;
        self.view.hover = self.view.hit(event.x, event.y);
        if (previous != self.view.hover) c.gtk_widget_set_tooltip_text(self.canvas, switch (self.view.hover) {
            .battery, .profiles, .profile_toggle => "Power Mode",
            .screenshot => "Take Screenshot",
            .settings => "Settings",
            .lock => "Lock Screen",
            .power => "Power Off Menu",
            .mute => if (self.view.model.muted) "Unmute" else "Mute",
            .volume => "Volume",
            .sound => "Sound Settings",
            .brightness => "Brightness",
            .network => "Wi-Fi Networks",
            .wifi => "Wi-Fi",
            .dark => "Dark Style",
            .dnd => "Do Not Disturb",
            else => null,
        });
        if (native.View.slider(self.view.pressed)) self.setSlider(self.view.pressed, self.view.sliderValue(self.view.pressed, event.x));
        self.redraw();
        return 1;
    }
    fn leave(_: *c.GtkWidget, _: *c.GdkEventCrossing, ptr: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Controls, ptr);
        self.view.hover = .none;
        self.redraw();
        return 0;
    }
    fn key(_: *c.GtkWidget, event: *c.GdkEvent, ptr: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Controls, ptr);
        var symbol: c.guint = 0;
        _ = c.gdk_event_get_keyval(event, &symbol);
        var modifiers: c.GdkModifierType = 0;
        _ = c.gdk_event_get_state(event, &modifiers);
        return self.handleKey(symbol, modifiers);
    }
    pub fn handleKey(self: *Controls, symbol: c.guint, modifiers: c.GdkModifierType) c.gboolean {
        if (self.dead) return 0;
        self.view.pressed = .none;
        if (symbol == 0xff1b) {
            if (self.view.submenu != .none) {
                self.view.focus = switch (self.view.submenu) {
                    .network => .network,
                    .profiles => .profiles,
                    .power => .power,
                    .none => unreachable,
                };
                self.view.submenu = .none;
            } else c.gtk_popover_popdown(cast(c.GtkPopover, self.popover));
        } else if (symbol == 0xff09 or symbol == 0xfe20 or symbol == 0xff52 or symbol == 0xff54) {
            self.view.stepFocus(symbol == 0xfe20 or symbol == 0xff52 or (symbol == 0xff09 and modifiers & c.GDK_SHIFT_MASK != 0));
        } else if (native.View.slider(self.view.focus) and (symbol == 0xff51 or symbol == 0xff53 or symbol == 0xff50 or symbol == 0xff57)) {
            const value = if (self.view.focus == .volume) self.view.model.volume.? else self.view.model.brightness.?;
            self.setSlider(self.view.focus, if (symbol == 0xff50) 0 else if (symbol == 0xff57) 100 else value + (if (symbol == 0xff51) @as(f64, -5) else @as(f64, 5)));
        } else if (symbol == 0x20 or symbol == 0xff0d or symbol == 0xff8d) self.activate(self.view.focus) else return 0;
        self.view.keyboard_focus = true;
        self.redraw();
        if (self.view.item(self.view.focus)) |entry| c.gtk_adjustment_clamp_page(c.gtk_scrolled_window_get_vadjustment(cast(c.GtkScrolledWindow, self.content)), entry.rect.y, entry.rect.y + entry.rect.height);
        return 1;
    }
    fn scroll(_: *c.GtkWidget, event: *c.GdkEvent, ptr: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Controls, ptr);
        var x: f64 = 0;
        var y: f64 = 0;
        _ = c.gdk_event_get_coords(event, &x, &y);
        const target = self.view.hit(x, y);
        if (!native.View.slider(target)) return 0;
        var dx: f64 = 0;
        var dy: f64 = 0;
        if (c.gdk_event_get_scroll_deltas(event, &dx, &dy) == 0) {
            var direction: c.GdkScrollDirection = 0;
            _ = c.gdk_event_get_scroll_direction(event, &direction);
            dy = if (direction == c.GDK_SCROLL_UP or direction == c.GDK_SCROLL_LEFT) -1 else 1;
        }
        const value = if (target == .volume) self.view.model.volume.? else self.view.model.brightness.?;
        self.setSlider(target, value - (dy + dx) * 5);
        return 1;
    }

    pub fn create(popover: *c.GtkWidget, network_command: [*:0]const u8, sound_command: [*:0]const u8) *Controls {
        const self = a.create(Controls) catch @panic("out of memory");
        const content = c.gtk_scrolled_window_new(null, null).?;
        css(content, "quick-native-host");
        c.gtk_scrolled_window_set_policy(cast(c.GtkScrolledWindow, content), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
        c.gtk_scrolled_window_set_propagate_natural_height(cast(c.GtkScrolledWindow, content), 1);
        c.gtk_scrolled_window_set_max_content_height(cast(c.GtkScrolledWindow, content), 640);
        c.gtk_container_add(cast(c.GtkContainer, popover), content);
        const canvas = c.gtk_drawing_area_new().?;
        c.gtk_widget_set_can_focus(canvas, 1);
        c.gtk_widget_add_events(canvas, c.GDK_BUTTON_PRESS_MASK | c.GDK_BUTTON_RELEASE_MASK | c.GDK_POINTER_MOTION_MASK | c.GDK_LEAVE_NOTIFY_MASK | c.GDK_KEY_PRESS_MASK | c.GDK_SCROLL_MASK | c.GDK_SMOOTH_SCROLL_MASK);
        c.gtk_container_add(cast(c.GtkContainer, content), canvas);
        self.* = .{ .popover = popover, .content = content, .canvas = canvas, .network_settings = a.dupeSentinel(u8, std.mem.span(network_command), 0) catch @panic("out of memory"), .sound_settings = a.dupeSentinel(u8, std.mem.span(sound_command), 0) catch @panic("out of memory"), .interface = settings("org.gnome.desktop.interface"), .notifications = settings("org.gnome.desktop.notifications"), .cancel = c.g_cancellable_new().? };
        connect(popover, "show", &shown, self);
        connect(popover, "closed", &closed, self);
        connect(canvas, "draw", &draw, self);
        connect(canvas, "button-press-event", &press, self);
        connect(canvas, "button-release-event", &buttonReleased, self);
        connect(canvas, "motion-notify-event", &motion, self);
        connect(canvas, "leave-notify-event", &leave, self);
        connect(canvas, "key-press-event", &key, self);
        connect(canvas, "scroll-event", &scroll, self);
        if (self.interface) |prefs| connect(prefs, "changed", &preferencesChanged, self);
        if (self.notifications) |prefs| connect(prefs, "changed", &preferencesChanged, self);
        self.syncPreferences();
        self.battery_service = battery_backend.Service.create(&batteryChanged, self) catch null;
        self.audio_service = audio.Service.create(&audioChanged, self) catch null;
        self.network_client = network_backend.Client.create(&networkChanged, self) catch null;
        self.timer = c.g_timeout_add_seconds(5, &refreshTimer, self);
        self.redraw();
        c.gtk_widget_show_all(content);
        return self;
    }
    fn syncPreferences(self: *Controls) void {
        if (self.interface) |prefs| {
            const value = c.g_settings_get_string(prefs, "color-scheme");
            defer c.g_free(value);
            self.view.model.dark = c.g_strcmp0(value, "prefer-dark") == 0;
        }
        if (self.notifications) |prefs| self.view.model.dnd = c.g_settings_get_boolean(prefs, "show-banners") == 0;
        self.view.model.dark_sensitive = self.interface != null;
        self.view.model.dnd_sensitive = self.notifications != null;
        self.redraw();
    }
    fn preferencesChanged(_: ?*c.GSettings, _: [*c]const u8, ptr: c.gpointer) callconv(.c) void {
        const self = cast(Controls, ptr);
        if (!self.dead) self.syncPreferences();
    }

    fn powerSettings(_: ?*c.GtkButton, ptr: c.gpointer) callconv(.c) void {
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
            c.gtk_widget_set_sensitive(button, @intFromBool(self.view.model.power_state.available[i] and !self.view.model.power_pending));
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
        self.selectProfile(index);
    }
    fn powerSettingsClosed(dialog: *c.GtkDialog, _: c_int, ptr: c.gpointer) callconv(.c) void {
        const self = cast(Controls, ptr);
        self.dialog = null;
        c.gtk_widget_destroy(@ptrCast(dialog));
        self.release();
    }

    fn launch(self: *Controls, command: [:0]const u8) void {
        c.gtk_popover_popdown(cast(c.GtkPopover, self.popover));
        var err: [*c]c.GError = null;
        _ = c.g_spawn_command_line_async(command, &err);
        c.g_clear_error(&err);
    }
    fn shown(_: *c.GtkWidget, ptr: c.gpointer) callconv(.c) void {
        const self = cast(Controls, ptr);
        var geometry: c.GdkRectangle = undefined;
        const monitor = c.gdk_display_get_monitor_at_window(c.gtk_widget_get_display(self.popover), c.gtk_widget_get_window(self.popover));
        if (monitor != null) {
            c.gdk_monitor_get_geometry(monitor, &geometry);
            c.gtk_scrolled_window_set_max_content_height(cast(c.GtkScrolledWindow, self.content), @max(120, geometry.height - 80));
        }
        self.refresh();
        self.view.focus = .none;
        self.view.stepFocus(false);
        c.gtk_widget_grab_focus(self.canvas);
    }
    fn closed(_: *c.GtkPopover, ptr: c.gpointer) callconv(.c) void {
        const self = cast(Controls, ptr);
        if (self.dead) return;
        self.view.submenu = .none;
        self.view.pressed = .none;
        self.view.hover = .none;
        self.view.focus = .none;
        self.redraw();
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

    fn writeVolume(ptr: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Controls, ptr);
        self.volume_timer = 0;
        if (self.view.model.volume) |value| self.audioAction(.{ .volume = value });
        return 0;
    }
    fn writeBrightness(ptr: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Controls, ptr);
        self.brightness_timer = 0;
        self.brightness_wanted = @max(1, self.view.model.brightness orelse return 0);
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
                    if (self.brightness_writing) self.setMessage("");
                    if (self.brightness_wanted == null and self.brightness_timer == 0) {
                        if (self.view.pressed != .brightness) self.view.model.brightness = device.percent();
                    }
                    if (self.view.model.brightness == null) self.view.model.brightness = device.percent();
                },
                .failure => |err| {
                    if (err == error.NoBacklight or err == error.BacklightUnavailable) self.view.model.brightness = null else if (err != error.Cancelled) self.setMessage(if (self.brightness_writing) "Brightness change failed" else "Brightness unavailable");
                    reread = self.brightness_writing and err != error.Cancelled and err != error.NoBacklight and err != error.BacklightUnavailable;
                },
            }
            self.redraw();
            if (self.brightness_wanted != null or reread) self.refreshBrightness();
        }
        self.release();
    }
    pub fn sessionAction(self: *Controls, action: session.Action) void {
        if (self.dead or self.session_busy) return;
        self.session_busy = true;
        self.view.model.session_busy = true;
        self.redraw();
        self.refs += 1;
        session.perform(action, self.cancel, &sessionDone, self);
    }
    fn sessionDone(ptr: ?*anyopaque, result: session.Result) void {
        const self = cast(Controls, ptr);
        defer self.release();
        self.session_busy = false;
        if (self.dead) return;
        self.view.model.session_busy = false;
        self.redraw();
        switch (result) {
            .success => self.setMessage(""),
            .failure => |message| self.setMessage(message),
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
            .success => self.setMessage(""),
            .failure => |message| self.setMessage(message),
        }
    }
    pub fn renderNetwork(self: *Controls, state: *const network_backend.State) void {
        const focused_path = if (@backingInt(self.view.focus) >= @backingInt(Target.network0) and @backingInt(self.view.focus) <= @backingInt(Target.network7)) self.network_paths[@backingInt(self.view.focus) - @backingInt(Target.network0)] else null;
        const restore_focus = if (focused_path) |path| a.dupeSentinel(u8, path, 0) catch @panic("out of memory") else null;
        defer if (restore_focus) |path| a.free(path);
        if (restore_focus != null) self.view.focus = .none;
        const model = &self.view.model;
        model.wifi_enabled = state.wifi_enabled;
        model.wifi_sensitive = state.available and state.hardware_enabled;
        model.network_title.set(if (!state.available) "Unavailable" else if (!state.hardware_enabled) "Hardware Blocked" else if (!state.wifi_enabled) "Off" else "Not Connected");
        // Never activate a different AP if discovery reorders rows mid-click.
        if (@backingInt(self.view.pressed) >= @backingInt(native.Target.network0) and @backingInt(self.view.pressed) <= @backingInt(native.Target.network7)) self.view.pressed = .none;
        self.clearNetworks();
        for (state.access_points.items, 0..) |ap, index| {
            if (ap.connected) model.network_title.set(ap.title);
            if (model.network_count == 8 or ap.ssid.len == 0) continue;
            var duplicate = false;
            for (state.access_points.items[0..index]) |previous| if (std.mem.eql(u8, previous.ssid, ap.ssid)) {
                duplicate = true;
            };
            if (duplicate) continue;
            const i = model.network_count;
            self.network_paths[i] = a.dupeSentinel(u8, ap.path, 0) catch @panic("out of memory");
            if (restore_focus) |path| if (std.mem.eql(u8, path, ap.path)) {
                self.view.focus = @fromBackingInt(@intCast(@backingInt(Target.network0) + i));
            };
            model.networks[i] = .{ .connected = ap.connected, .secure = ap.passwordRequired(), .icon = network_backend.wifiIcon(ap.strength) };
            model.networks[i].title.set(ap.title);
            model.network_count += 1;
        }
        self.redraw();
    }
    fn clearNetworks(self: *Controls) void {
        for (&self.network_paths) |*path| {
            if (path.*) |value| a.free(value);
            path.* = null;
        }
        self.view.model.network_count = 0;
    }
    fn audioChanged(ptr: ?*anyopaque, service: *audio.Service) void {
        const self = cast(Controls, ptr);
        if (self.dead) return;
        if (service.state(.output)) |state| {
            if (self.volume_timer == 0 and self.view.pressed != .volume) self.view.model.volume = state.percent;
            self.view.model.muted = state.muted;
        } else self.view.model.volume = null;
        self.redraw();
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
            .failure => |err| self.setMessage(@errorName(err)),
        }
    }
    pub fn monitorBattery(self: *Controls, options: battery_backend.Options) void {
        if (self.battery_service) |service| service.destroy();
        self.battery_service = battery_backend.Service.createWithOptions(options, &batteryChanged, self) catch null;
    }
    fn batteryChanged(ptr: ?*anyopaque, state: battery_backend.State) void {
        const self = cast(Controls, ptr);
        if (self.dead) return;
        if (state.visible()) {
            var buffer: [100]u8 = undefined;
            self.view.model.battery.set(std.fmt.bufPrint(&buffer, "{d:.0}%", .{state.percent}) catch "");
            self.view.model.battery_icon.set(state.icon(&buffer) catch "battery-symbolic");
        } else self.view.model.battery.set("");
        self.redraw();
    }
    fn freeData(ptr: c.gpointer) callconv(.c) void {
        c.g_free(ptr);
    }
    fn connectNetwork(self: *Controls, index: usize) void {
        const path = self.network_paths[index] orelse return;
        const ssid = path.ptr;
        const client = self.network_client orelse return;
        const ap = client.state().ap(std.mem.span(ssid)) orelse return;
        if (!ap.passwordRequired()) {
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

    fn screenshot(ptr: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Controls, ptr);
        if (!self.dead) {
            const executable: [*:0]const u8 = if (c.g_getenv("DESKTOP_POWER_HELPER")) |value| @ptrCast(value) else "desktop-zig";
            const argv = [_:null]?[*:0]const u8{ executable, "screenshot" };
            @import("desktop-command.zig").launch("Screenshot", @ptrCast(&argv));
        }
        self.release();
        return 0;
    }
    fn confirmAction(self: *Controls, action: [:0]const u8, title: [:0]const u8) void {
        if (self.session_busy) return;
        if (self.dialog) |dialog| {
            c.gtk_window_present(cast(c.GtkWindow, dialog));
            return;
        }
        c.gtk_popover_popdown(cast(c.GtkPopover, self.popover));
        const dialog = c.gtk_message_dialog_new(null, c.GTK_DIALOG_MODAL, c.GTK_MESSAGE_QUESTION, c.GTK_BUTTONS_CANCEL, "%s", title.ptr).?;
        self.dialog = dialog;
        _ = c.gtk_dialog_add_button(cast(c.GtkDialog, dialog), "Confirm", c.GTK_RESPONSE_ACCEPT);
        c.g_object_set_data(cast(c.GObject, dialog), "action", @constCast(action.ptr));
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
        _ = c.g_signal_handlers_disconnect_matched(self.canvas, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
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
            self.clearNetworks();
            self.view.deinit(a);
            c.g_object_unref(self.cancel);
            a.free(self.network_settings);
            a.free(self.sound_settings);
            a.destroy(self);
        }
    }
};
