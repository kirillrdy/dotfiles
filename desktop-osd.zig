//! Media-key controller and passive Wayland overlays. Device calls are serialized
//! asynchronously; repeated steps coalesce while a backend is busy.
const std = @import("std");
const c = @import("desktop-gtk.zig");
const audio = @import("desktop-audio.zig");
const backlight = @import("desktop-backlight.zig");
const allocator = std.heap.page_allocator;
const cast = c.__zig.cast;
const surfaces = @import("desktop-surface.zig");
const Loop = @import("desktop-surface-loop.zig").Loop;
const render = @import("desktop-osd-render.zig");
const util = @import("desktop-util.zig");

pub const Kind = render.Kind;
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

pub const Server = struct {
    connection: ?*c.GDBusConnection = null,
    backlight_backend: backlight.Backend = .{},
    brightness_busy: bool = false,
    ready: bool = false,
    dead: bool = false,
    client: ?*surfaces.Client = null,
    loop: Loop = .{},
    config: render.Config = .{},
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

    pub fn start(self: *Server, config_path: [*:0]const u8) !void {
        const contents = try std.Io.Dir.cwd().readFileAlloc(util.io, std.mem.span(config_path), allocator, .limited(16384));
        defer allocator.free(contents);
        const parsed = try std.json.parseFromSlice(render.Config, allocator, contents, .{});
        defer parsed.deinit();
        try parsed.value.validate();
        self.config = parsed.value;
        const client = try surfaces.Client.create(.{
            .namespace = "desktop-osd",
            .layer = .overlay,
            .anchors = 2,
            .width = self.config.width,
            .height = self.config.height,
            .format = .argb,
            .initially_visible = false,
            .bottom_margin_percent = self.config.bottom_margin_percent,
        }, self, &draw);
        errdefer client.destroy();
        try self.loop.start(client, "desktop-osd");
        errdefer self.loop.stop();
        self.audio_service = try audio.Service.create(&audioChanged, self);
        self.client = client;
        self.ready = true;
    }

    fn draw(context: ?*anyopaque, frame: surfaces.Frame) !void {
        const self = cast(Server, context);
        render.paint(frame, self.config, self.last_kind, self.last_state.percent, self.last_state.muted);
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
        if (self.client) |client| {
            client.setVisible(true) catch |err| std.log.err("desktop-osd: {s}", .{@errorName(err)});
            client.invalidate() catch |err| std.log.err("desktop-osd: {s}", .{@errorName(err)});
            self.loop.flush() catch |err| std.log.err("desktop-osd: {s}", .{@errorName(err)});
        }
        if (self.hide_timer != 0) _ = c.g_source_remove(self.hide_timer);
        self.hide_timer = c.g_timeout_add(self.config.duration_ms, &hide, self);
        if (kind == .volume and self.active.?.delta != 0 and !state.muted and state.percent > 0) self.feedback();
    }

    fn finish(self: *Server) void {
        self.active = null;
        self.next();
    }

    fn hide(data: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Server, data);
        self.hide_timer = 0;
        if (self.client) |client| {
            client.setVisible(false) catch |err| std.log.err("desktop-osd: {s}", .{@errorName(err)});
            self.loop.flush() catch |err| std.log.err("desktop-osd: {s}", .{@errorName(err)});
        }
        return 0;
    }

    fn feedback(self: *Server) void {
        const path = c.g_getenv("DESKTOP_OSD_SOUND_FILE") orelse return;
        self.feedback_player.play(@ptrCast(path));
    }

    pub fn deinit(self: *Server) void {
        self.dead = true;
        if (self.hide_timer != 0) _ = c.g_source_remove(self.hide_timer);
        if (self.cancel != null) c.g_cancellable_cancel(self.cancel);
        if (self.audio_service) |service| service.destroy();
        self.audio_service = null;
        self.feedback_player.deinit();
        while (self.audio_busy or self.brightness_busy) _ = c.g_main_context_iteration(null, 1);
        self.loop.stop();
        if (self.client) |client| client.destroy();
        self.client = null;
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
