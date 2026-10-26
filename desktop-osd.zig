//! Media-key controller and passive Wayland overlays. Device calls are serialized
//! asynchronously; repeated steps coalesce while a backend is busy.
const std = @import("std");
const c = @import("gtk");
const allocator = std.heap.page_allocator;
fn cast(comptime T: type, ptr: anytype) *T {
    return @ptrCast(@alignCast(ptr));
}

pub const Kind = enum { volume, microphone, brightness };
pub const Work = struct { kind: Kind, delta: i16 = 0 };
pub const State = struct { percent: f64, muted: bool = false };

pub fn parseCommand(args: []const []const u8) ?Work {
    if (args.len != 2) return null;
    const kind = std.meta.stringToEnum(Kind, args[0]) orelse return null;
    if (std.mem.eql(u8, args[1], "mute") and kind != .brightness) return .{ .kind = kind };
    if (kind == .microphone) return null;
    const delta: i16 = if (std.mem.eql(u8, args[1], "up")) 5 else if (std.mem.eql(u8, args[1], "down")) -5 else return null;
    return .{ .kind = kind, .delta = delta };
}

pub fn parseVolume(output: []const u8) !State {
    var words = std.mem.tokenizeAny(u8, output, " \r\n\t");
    if (!std.mem.eql(u8, words.next() orelse "", "Volume:")) return error.InvalidVolume;
    const value = try std.fmt.parseFloat(f64, words.next() orelse return error.InvalidVolume);
    if (!std.math.isFinite(value) or value < 0 or value > 100) return error.InvalidVolume;
    const flag = words.next();
    if (flag) |text| if (!std.mem.eql(u8, text, "[MUTED]")) return error.InvalidVolume;
    if (words.next() != null) return error.InvalidVolume;
    return .{ .percent = @min(value * 100, 100), .muted = flag != null };
}

pub fn parseBrightness(output: []const u8) !State {
    var fields = std.mem.splitScalar(u8, std.mem.trim(u8, output, " \r\n\t"), ',');
    const device = fields.next() orelse return error.InvalidBrightness;
    if (device.len == 0) return error.InvalidBrightness;
    if (!std.mem.eql(u8, fields.next() orelse "", "backlight")) return error.InvalidBrightness;
    const current = try std.fmt.parseInt(u64, fields.next() orelse "", 10);
    _ = fields.next() orelse return error.InvalidBrightness;
    const maximum = try std.fmt.parseInt(u64, fields.next() orelse "", 10);
    if (maximum == 0 or current > maximum or fields.next() != null) return error.InvalidBrightness;
    return .{ .percent = @as(f64, @floatFromInt(current)) / @as(f64, @floatFromInt(maximum)) * 100 };
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

const Phase = enum { initial, unmute, write, final };
pub const Server = struct {
    connection: ?*c.GDBusConnection = null,
    ready: bool = false,
    dead: bool = false,
    overlays: std.ArrayList(Overlay) = .empty,
    queue: std.ArrayList(Work) = .empty,
    active: ?Work = null,
    state: State = .{ .percent = 0 },
    last_kind: Kind = .volume,
    last_state: State = .{ .percent = 0 },
    phase: Phase = .initial,
    process: ?*c.GSubprocess = null,
    cancel: ?*c.GCancellable = null,
    timeout: c.guint = 0,
    hide_timer: c.guint = 0,
    sound: ?*c.GSubprocess = null,

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
        self.phase = .initial;
        self.read();
    }

    fn audioTarget(self: *Server) [*:0]const u8 {
        return if (self.active.?.kind == .microphone) "@DEFAULT_AUDIO_SOURCE@" else "@DEFAULT_AUDIO_SINK@";
    }

    fn read(self: *Server) void {
        if (self.active.?.kind == .brightness) self.run(&.{ "brightnessctl", "-c", "backlight", "-m" }) else self.run(&.{ "wpctl", "get-volume", self.audioTarget() });
    }

    fn write(self: *Server) void {
        self.phase = .write;
        const work = self.active.?;
        if (work.delta == 0) return self.run(&.{ "wpctl", "set-mute", self.audioTarget(), "toggle" });
        var buffer: [32]u8 = undefined;
        const value = std.fmt.bufPrintSentinel(&buffer, "{d:.0}%", .{target(self.state, work)}, 0) catch unreachable;
        if (work.kind == .brightness) self.run(&.{ "brightnessctl", "-c", "backlight", "set", value }) else self.run(&.{ "wpctl", "set-volume", "-l", "1.0", self.audioTarget(), value });
    }

    fn run(self: *Server, args: []const [*:0]const u8) void {
        var argv: [10:null]?[*:0]const u8 = @splat(null);
        for (args, 0..) |arg, i| argv[i] = arg;
        var err: [*c]c.GError = null;
        self.process = c.g_subprocess_newv(@ptrCast(&argv), c.G_SUBPROCESS_FLAGS_STDOUT_PIPE | c.G_SUBPROCESS_FLAGS_STDERR_PIPE, &err);
        if (self.process == null) {
            c.g_printerr("desktop-osd: %s\n", err.*.message);
            c.g_clear_error(&err);
            self.finish();
            return;
        }
        self.cancel = c.g_cancellable_new();
        self.timeout = c.g_timeout_add(2000, &timedOut, self);
        c.g_subprocess_communicate_utf8_async(self.process, null, self.cancel, &completed, self);
    }

    fn timedOut(data: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Server, data);
        self.timeout = 0;
        c.g_subprocess_force_exit(self.process);
        c.g_cancellable_cancel(self.cancel);
        return 0;
    }

    fn completed(_: [*c]c.GObject, result: ?*c.GAsyncResult, data: c.gpointer) callconv(.c) void {
        const self = cast(Server, data);
        var output: [*c]u8 = null;
        var stderr_output: [*c]u8 = null;
        var err: [*c]c.GError = null;
        const ok = c.g_subprocess_communicate_utf8_finish(self.process, result, &output, &stderr_output, &err) != 0;
        const success = ok and c.g_subprocess_get_successful(self.process) != 0;
        if (self.timeout != 0) _ = c.g_source_remove(self.timeout);
        self.timeout = 0;
        c.g_object_unref(self.process);
        self.process = null;
        c.g_object_unref(self.cancel);
        self.cancel = null;
        defer c.g_free(output);
        defer c.g_free(stderr_output);
        defer c.g_clear_error(&err);
        if (self.dead) return;
        if (!success) {
            const message: [*c]const u8 = if (err != null) err.*.message else if (stderr_output != null) stderr_output else "unknown error";
            c.g_printerr("desktop-osd: backend failed: %s\n", message);
            self.finish();
            return;
        }
        self.advance(if (output != null) std.mem.span(output) else "") catch |failure| {
            std.debug.print("desktop-osd: {s}\n", .{@errorName(failure)});
            self.finish();
        };
    }

    fn advance(self: *Server, output: []const u8) !void {
        const work = self.active.?;
        switch (self.phase) {
            .initial => {
                self.state = if (work.kind == .brightness) try parseBrightness(output) else try parseVolume(output);
                if (work.kind == .volume and work.delta != 0 and self.state.muted) {
                    self.phase = .unmute;
                    self.run(&.{ "wpctl", "set-mute", self.audioTarget(), "0" });
                } else self.write();
            },
            .unmute => self.write(),
            .write => {
                self.phase = .final;
                self.read();
            },
            .final => {
                const state = if (work.kind == .brightness) try parseBrightness(output) else try parseVolume(output);
                if (work.kind != .brightness) _ = c.g_dbus_connection_emit_signal(self.connection, null, "/org/dotfiles/DesktopOsd", "org.dotfiles.DesktopOsd", "DeviceChanged", c.g_variant_new("(s)", @as([*:0]const u8, @tagName(work.kind))), null);
                self.last_kind = work.kind;
                self.last_state = state;
                for (self.overlays.items) |*overlay| overlay.show(work.kind, state);
                if (self.hide_timer != 0) _ = c.g_source_remove(self.hide_timer);
                self.hide_timer = c.g_timeout_add(1500, &hide, self);
                if (work.kind == .volume and work.delta != 0 and !state.muted and state.percent > 0) self.feedback();
                self.finish();
            },
        }
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
        if (self.sound != null) return;
        const path = c.g_getenv("DESKTOP_OSD_SOUND_FILE") orelse return;
        const argv = [_:null]?[*:0]const u8{ "pw-play", "--properties={\"media.role\":\"event\"}", path };
        var err: [*c]c.GError = null;
        self.sound = c.g_subprocess_newv(@ptrCast(&argv), c.G_SUBPROCESS_FLAGS_STDOUT_SILENCE | c.G_SUBPROCESS_FLAGS_STDERR_SILENCE, &err);
        c.g_clear_error(&err);
        if (self.sound != null) c.g_subprocess_wait_async(self.sound, null, &soundDone, self);
    }

    fn soundDone(source: [*c]c.GObject, result: ?*c.GAsyncResult, data: c.gpointer) callconv(.c) void {
        const self = cast(Server, data);
        _ = c.g_subprocess_wait_finish(@ptrCast(source), result, null);
        c.g_object_unref(self.sound);
        self.sound = null;
    }

    pub fn deinit(self: *Server) void {
        self.dead = true;
        if (self.ready) _ = c.g_signal_handlers_disconnect_matched(c.gdk_display_get_default(), c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
        if (self.hide_timer != 0) _ = c.g_source_remove(self.hide_timer);
        if (self.timeout != 0) _ = c.g_source_remove(self.timeout);
        self.timeout = 0;
        if (self.process != null) {
            c.g_subprocess_force_exit(self.process);
            c.g_cancellable_cancel(self.cancel);
        }
        if (self.sound != null) c.g_subprocess_force_exit(self.sound);
        while (self.process != null or self.sound != null) _ = c.g_main_context_iteration(null, 1);
        for (self.overlays.items) |overlay| overlay.destroy();
        self.overlays.deinit(allocator);
        self.queue.deinit(allocator);
    }
};

fn commandLine(app: *c.GApplication, command: *c.GApplicationCommandLine, data: c.gpointer) callconv(.c) c_int {
    const self = cast(Server, data);
    self.connection = c.g_application_get_dbus_connection(app);
    var count: c_int = 0;
    const argv = c.g_application_command_line_get_arguments(command, &count);
    defer c.g_strfreev(argv);
    if (count == 3 and c.g_strcmp0(argv[1], "serve") == 0) {
        if (self.ready) return 0;
        self.start(std.mem.span(argv[2])) catch |err| {
            c.g_application_command_line_printerr(command, "desktop-osd: %s\n", @as([*:0]const u8, @errorName(err)));
            return 1;
        };
        c.g_application_hold(app);
        return 0;
    }
    if (!self.ready) {
        c.g_application_command_line_printerr(command, "desktop-osd: session service is not running\n");
        return 1;
    }
    if (count != 3) return 1;
    const work = parseCommand(&.{ std.mem.span(argv[1]), std.mem.span(argv[2]) }) orelse return 1;
    return if (self.enqueue(work)) 0 else 1;
}

fn quit(data: c.gpointer) callconv(.c) c.gboolean {
    c.g_application_quit(cast(c.GApplication, data));
    return 1;
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const args = try init.minimal.args.toSlice(arena.allocator());
    const serve = args.len == 3 and std.mem.eql(u8, args[1], "serve");
    if (!serve and parseCommand(args[1..]) == null) {
        std.debug.print("Usage: desktop-osd serve STYLE.css | volume up|down|mute | microphone mute | brightness up|down\n", .{});
        return error.InvalidArguments;
    }
    _ = c.g_setenv("GDK_BACKEND", "wayland", 1);
    const app = c.gtk_application_new("org.dotfiles.DesktopOsd", c.G_APPLICATION_HANDLES_COMMAND_LINE);
    defer c.g_object_unref(app);
    var server = Server{};
    defer server.deinit();
    _ = c.g_signal_connect_data(app, "command-line", @ptrCast(&commandLine), &server, null, 0);
    const term = c.g_unix_signal_add(c.SIGTERM, &quit, app);
    const interrupt = c.g_unix_signal_add(c.SIGINT, &quit, app);
    defer _ = c.g_source_remove(term);
    defer _ = c.g_source_remove(interrupt);
    const argv = try arena.allocator().allocSentinel(?[*:0]const u8, args.len, null);
    for (args, 0..) |arg, i| argv[i] = (try arena.allocator().dupeSentinel(u8, arg, 0)).ptr;
    if (c.g_application_run(cast(c.GApplication, app), @intCast(args.len), @ptrCast(argv.ptr)) != 0) return error.CommandFailed;
}

test "audio state accepts mute and amplification and rejects invalid readings" {
    const testing = std.testing;
    try testing.expectEqual(State{ .percent = 65, .muted = true }, try parseVolume("Volume: 0.65 [MUTED]\n"));
    try testing.expectEqual(@as(f64, 100), (try parseVolume("Volume: 1.5")).percent);
    for ([_][]const u8{ "", "Volume: nan", "Volume: inf", "Volume: -0.5", "Volume: 0.5 unexpected", "Volume: 0.5 [MUTED] extra" }) |invalid| {
        if (parseVolume(invalid)) |_| return error.ExpectedInvalidVolume else |_| {}
    }
}

test "brightness derives exact hardware percentage and rejects absent devices" {
    try std.testing.expectEqual(@as(f64, 20), (try parseBrightness("intel,backlight,80,20%,400\n")).percent);
    for ([_][]const u8{ "", "led,leds,80,20%,400", "intel,backlight,1,0%,0", "intel,backlight,401,100%,400", "intel,backlight,no,20%,400" }) |invalid| {
        if (parseBrightness(invalid)) |_| return error.ExpectedInvalidBrightness else |_| {}
    }
}

test "media key limits preserve zero volume and the five percent brightness floor" {
    try std.testing.expectEqual(@as(f64, 100), target(.{ .percent = 98 }, .{ .kind = .volume, .delta = 5 }));
    try std.testing.expectEqual(@as(f64, 0), target(.{ .percent = 2 }, .{ .kind = .volume, .delta = -5 }));
    try std.testing.expectEqual(@as(f64, 5), target(.{ .percent = 2 }, .{ .kind = .brightness, .delta = -5 }));
    try std.testing.expectEqual(@as(f64, 100), target(.{ .percent = 98 }, .{ .kind = .brightness, .delta = 5 }));
    try std.testing.expect(parseCommand(&.{ "microphone", "up" }) == null);
    try std.testing.expect(parseCommand(&.{ "brightness", "mute" }) == null);
    try std.testing.expect(parseCommand(&.{ "volume", "up", "extra" }) == null);
}
