//! Media-key controller and passive Wayland overlays. Device calls are serialized
//! asynchronously; repeated steps coalesce while a backend is busy.
const std = @import("std");
const c = @import("desktop-gtk.zig");
const audio = @import("desktop-audio.zig");
const backlight = @import("desktop-backlight.zig");
const allocator = std.heap.page_allocator;
const cast = c.__zig.cast;

pub const Kind = enum { volume, microphone, brightness };
pub const Work = struct { kind: Kind, delta: i16 = 0 };
pub const State = audio.State;

pub fn parseCommand(args: []const []const u8) ?Work {
    if (args.len != 2) return null;
    const k: Kind = if (std.mem.eql(u8, args[0], "volume"))
        .volume
    else if (std.mem.eql(u8, args[0], "microphone"))
        .microphone
    else if (std.mem.eql(u8, args[0], "brightness"))
        .brightness
    else
        return null;
    if (std.mem.eql(u8, args[1], "mute") and k != .brightness) return .{ .kind = k };
    if (k == .microphone) return null;
    const delta: i16 = if (std.mem.eql(u8, args[1], "up")) 5 else if (std.mem.eql(u8, args[1], "down")) -5 else return null;
    return .{ .kind = k, .delta = delta };
}

pub fn target(state: State, work: Work) f64 {
    const minimum: f64 = if (work.kind == .brightness) 5 else 0;
    return std.math.clamp(state.percent + @as(f64, @floatFromInt(work.delta)), minimum, 100);
}

const Overlay = struct {
    monitor: *c.GdkMonitor,
    window: *c.GtkWidget,
    image: *c.GtkWidget,
    progress: *c.GtkWidget,

    fn create(monitor: *c.GdkMonitor) Overlay {
        const window = c.gtk_window_new(c.GTK_WINDOW_TOPLEVEL);
        c.gtk_widget_set_name(window, "osd");
        c.gtk_window_set_title(cast(c.GtkWindow, window), "Desktop OSD");
        c.gtk_window_set_accept_focus(cast(c.GtkWindow, window), 0);
        c.gtk_window_set_resizable(cast(c.GtkWindow, window), 0);
        if (c.gdk_screen_get_rgba_visual(c.gtk_widget_get_screen(window))) |visual| c.gtk_widget_set_visual(window, visual);
        c.gtk_layer_init_for_window(cast(c.GtkWindow, window));
        c.gtk_layer_set_namespace(cast(c.GtkWindow, window), "desktop-osd");
        c.gtk_layer_set_monitor(cast(c.GtkWindow, window), monitor);
        c.gtk_layer_set_layer(cast(c.GtkWindow, window), c.GTK_LAYER_SHELL_LAYER_OVERLAY);
        c.gtk_layer_set_anchor(cast(c.GtkWindow, window), c.GTK_LAYER_SHELL_EDGE_BOTTOM, 1);
        c.gtk_layer_set_exclusive_zone(cast(c.GtkWindow, window), -1);
        c.gtk_layer_set_keyboard_mode(cast(c.GtkWindow, window), c.GTK_LAYER_SHELL_KEYBOARD_MODE_NONE);
        _ = c.g_signal_connect_data(window, "realize", @ptrCast(&realized), null, null, 0);
        const box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 12);
        c.gtk_widget_set_name(box, "container");
        const image = c.gtk_image_new();
        const progress = c.gtk_progress_bar_new();
        c.gtk_widget_set_valign(progress, c.GTK_ALIGN_CENTER);
        c.gtk_box_pack_start(cast(c.GtkBox, box), image, 0, 0, 0);
        c.gtk_box_pack_start(cast(c.GtkBox, box), progress, 0, 0, 0);
        c.gtk_container_add(cast(c.GtkContainer, window), box);
        _ = c.g_object_ref(monitor);
        return .{ .monitor = monitor, .window = window, .image = image, .progress = progress };
    }

    fn realized(widget: *c.GtkWidget, _: c.gpointer) callconv(.c) void {
        // Feedback never intercepts clicks intended for the application below.
        const region = c.cairo_region_create();
        defer c.cairo_region_destroy(region);
        c.gdk_window_input_shape_combine_region(c.gtk_widget_get_window(widget), region, 0, 0);
    }

    fn show(self: *Overlay, kind: Kind, state: State) void {
        var geometry: c.GdkRectangle = undefined;
        c.gdk_monitor_get_geometry(self.monitor, &geometry);
        c.gtk_layer_set_margin(cast(c.GtkWindow, self.window), c.GTK_LAYER_SHELL_EDGE_BOTTOM, @divTrunc(geometry.height * 6, 100));
        const icon: [*:0]const u8 = switch (kind) {
            .brightness => "display-brightness-symbolic",
            .microphone => if (state.muted) "microphone-sensitivity-muted-symbolic" else "microphone-sensitivity-high-symbolic",
            .volume => if (state.muted or state.percent == 0) "audio-volume-muted-symbolic" else if (state.percent < 33) "audio-volume-low-symbolic" else if (state.percent < 66) "audio-volume-medium-symbolic" else "audio-volume-high-symbolic",
        };
        c.gtk_image_set_from_icon_name(cast(c.GtkImage, self.image), icon, c.GTK_ICON_SIZE_LARGE_TOOLBAR);
        c.gtk_progress_bar_set_fraction(cast(c.GtkProgressBar, self.progress), state.percent / 100);
        c.gtk_widget_set_sensitive(self.progress, @intFromBool(!state.muted));
        c.gtk_widget_set_sensitive(self.image, @intFromBool(!state.muted));
        c.gtk_widget_show_all(self.window);
    }

    fn destroy(self: Overlay) void {
        c.gtk_widget_destroy(self.window);
        c.g_object_unref(self.monitor);
    }
};

pub const Server = struct {
    connection: ?*c.GDBusConnection = null,
    backlight_backend: backlight.Backend = .{},
    brightness_busy: bool = false,
    ready: bool = false,
    dead: bool = false,
    overlays: std.ArrayList(Overlay) = .empty,
    queue: std.ArrayList(Work) = .empty,
    active: ?Work = null,
    state: State = .{ .percent = 0 },
    last_kind: Kind = .volume,
    last_state: State = .{ .percent = 0 },
    audio_service: ?*audio.Service = null,
    audio_busy: bool = false,
    cancel: ?*c.GCancellable = null,
    hide_timer: c.guint = 0,
    feedback_player: audio.Feedback = .{},

    pub fn start(self: *Server, style: [*:0]const u8) !void {
        if (c.gtk_layer_is_supported() == 0) return error.LayerShellUnavailable;
        const provider = c.gtk_css_provider_new();
        defer c.g_object_unref(provider);
        var err: [*c]c.GError = null;
        if (c.gtk_css_provider_load_from_path(provider, style, &err) == 0) {
            c.g_printerr("desktop-osd: %s\n", err.*.message);
            c.g_clear_error(&err);
            return error.InvalidStyle;
        }
        c.gtk_style_context_add_provider_for_screen(c.gdk_screen_get_default(), cast(c.GtkStyleProvider, provider), c.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
        const display = c.gdk_display_get_default();
        var i: c_int = 0;
        while (i < c.gdk_display_get_n_monitors(display)) : (i += 1) added(display.?, c.gdk_display_get_monitor(display, i).?, self);
        _ = c.g_signal_connect_data(display, "monitor-added", @ptrCast(&added), self, null, 0);
        _ = c.g_signal_connect_data(display, "monitor-removed", @ptrCast(&removed), self, null, 0);
        self.audio_service = try audio.Service.create(&audioChanged, self);
        self.ready = true;
    }

    fn added(_: *c.GdkDisplay, monitor: *c.GdkMonitor, data: c.gpointer) callconv(.c) void {
        const self = cast(Server, data);
        self.overlays.append(allocator, Overlay.create(monitor)) catch @panic("out of memory");
        if (self.hide_timer != 0) self.overlays.items[self.overlays.items.len - 1].show(self.last_kind, self.last_state);
    }

    fn removed(_: *c.GdkDisplay, monitor: *c.GdkMonitor, data: c.gpointer) callconv(.c) void {
        const self = cast(Server, data);
        for (self.overlays.items, 0..) |overlay, i| if (overlay.monitor == monitor) {
            _ = self.overlays.orderedRemove(i);
            overlay.destroy();
            return;
        };
    }

    pub fn enqueue(self: *Server, work: Work) bool {
        if (self.queue.items.len > 0 and work.delta != 0) {
            const last = &self.queue.items[self.queue.items.len - 1];
            if (last.kind == work.kind and (last.delta > 0 and work.delta > 0 or last.delta < 0 and work.delta < 0)) {
                last.delta = std.math.clamp(last.delta + work.delta, -100, 100);
                return true;
            }
        }
        if (self.queue.items.len == 64) return false;
        self.queue.append(allocator, work) catch @panic("out of memory");
        self.next();
        return true;
    }

    fn next(self: *Server) void {
        if (self.dead or self.active != null or self.queue.items.len == 0) return;
        self.active = self.queue.orderedRemove(0);
        if (self.active.?.kind == .brightness) {
            self.brightness_busy = true;
            self.cancel = c.g_cancellable_new();
            self.backlight_backend.start(.{ .step = self.active.?.delta }, self.cancel.?, &brightnessDone, self);
            return;
        }
        const service = self.audio_service orelse {
            self.finish();
            return;
        };
        self.cancel = c.g_cancellable_new();
        self.audio_busy = true;
        const work = self.active.?;
        service.apply(if (work.kind == .microphone) .input else .output, if (work.delta == 0) .toggle else .{ .step = work.delta }, self.cancel.?, &audioDone, self);
    }
    fn audioChanged(_: ?*anyopaque, _: *audio.Service) void {}
    fn audioDone(ptr: ?*anyopaque, result: audio.Result) void {
        const self = cast(Server, ptr);
        self.audio_busy = false;
        c.g_object_unref(self.cancel);
        self.cancel = null;
        if (self.dead) return;
        switch (result) {
            .value => |value| self.present(self.active.?.kind, value),
            .failure => |err| std.log.warn("desktop-osd: audio: {s}", .{@errorName(err)}),
        }
        self.finish();
    }

    fn brightnessDone(data: ?*anyopaque, result: backlight.Result) void {
        const self = cast(Server, data);
        self.brightness_busy = false;
        c.g_object_unref(self.cancel);
        self.cancel = null;
        if (self.dead) return;
        switch (result) {
            .value => |device| self.present(.brightness, .{ .percent = device.percent() }),
            .failure => |err| std.log.warn("desktop-osd: brightness: {s}", .{@errorName(err)}),
        }
        self.finish();
    }
    fn present(self: *Server, kind: Kind, state: State) void {
        if (self.connection != null) _ = c.g_dbus_connection_emit_signal(self.connection, null, "/org/dotfiles/DesktopOsd", "org.dotfiles.DesktopOsd", "DeviceChanged", c.g_variant_new("(s)", @as([*:0]const u8, @tagName(kind))), null);
        self.last_kind = kind;
        self.last_state = state;
        for (self.overlays.items) |*overlay| overlay.show(kind, state);
        if (self.hide_timer != 0) _ = c.g_source_remove(self.hide_timer);
        self.hide_timer = c.g_timeout_add(1500, &hide, self);
        if (kind == .volume and self.active.?.delta != 0 and !state.muted and state.percent > 0) self.feedback();
    }

    fn finish(self: *Server) void {
        self.active = null;
        self.next();
    }

    fn hide(data: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Server, data);
        self.hide_timer = 0;
        for (self.overlays.items) |overlay| c.gtk_widget_hide(overlay.window);
        return 0;
    }

    fn feedback(self: *Server) void {
        const path = c.g_getenv("DESKTOP_OSD_SOUND_FILE") orelse return;
        self.feedback_player.play(@ptrCast(path));
    }

    pub fn deinit(self: *Server) void {
        self.dead = true;
        if (self.ready) _ = c.g_signal_handlers_disconnect_matched(c.gdk_display_get_default(), c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
        if (self.hide_timer != 0) _ = c.g_source_remove(self.hide_timer);
        if (self.cancel != null) c.g_cancellable_cancel(self.cancel);
        if (self.audio_service) |service| service.destroy();
        self.audio_service = null;
        self.feedback_player.deinit();
        while (self.audio_busy or self.brightness_busy) _ = c.g_main_context_iteration(null, 1);
        for (self.overlays.items) |overlay| overlay.destroy();
        self.overlays.deinit(allocator);
        self.queue.deinit(allocator);
    }
};

test "media key limits preserve zero volume and the five percent brightness floor" {
    try std.testing.expectEqual(@as(f64, 100), target(.{ .percent = 98 }, .{ .kind = .volume, .delta = 5 }));
    try std.testing.expectEqual(@as(f64, 0), target(.{ .percent = 2 }, .{ .kind = .volume, .delta = -5 }));
    try std.testing.expectEqual(@as(f64, 5), target(.{ .percent = 2 }, .{ .kind = .brightness, .delta = -5 }));
    try std.testing.expectEqual(@as(f64, 100), target(.{ .percent = 98 }, .{ .kind = .brightness, .delta = 5 }));
    try std.testing.expect(parseCommand(&.{ "microphone", "up" }) == null);
    try std.testing.expect(parseCommand(&.{ "brightness", "mute" }) == null);
    try std.testing.expect(parseCommand(&.{ "volume", "up", "extra" }) == null);
}
