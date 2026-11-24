//! Media-key controller and passive Wayland overlays. Device calls are serialized
//! asynchronously; repeated steps coalesce while a backend is busy.
const native = @import("desktop-surface.zig");
const view = @import("desktop-osd-view.zig");
const std = @import("std");
const mainloop = @import("desktop-loop.zig");
const util = @import("desktop-util.zig");
const audio = @import("desktop-audio.zig");
const backlight = @import("desktop-backlight.zig");
const cast = util.cast;

pub const Kind = view.Kind;
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
    surface: *native.Surface,
    theme: *const view.Theme,
    kind: Kind = .volume,
    state: State = .{ .percent = 0 },

    fn create(output: *native.Output, theme: *const view.Theme) !*Overlay {
        const allocator = output.client.allocator;
        const self = try allocator.create(Overlay);
        errdefer allocator.destroy(self);
        self.* = .{ .theme = theme, .surface = try native.Surface.createPixels(output, .{
            .namespace = "desktop-osd",
            .layer = 3,
            .anchors = native.bottom,
            .width = theme.width(),
            .height = theme.height(),
            .bottom_margin = @divTrunc(output.height() * 6, 100),
        }, &draw, self) };
        return self;
    }
    fn draw(data: ?*anyopaque, buffer: native.Pixels) void {
        const self = cast(Overlay, data);
        view.paint(buffer, self.surface.output.scale, self.theme.*, self.kind, self.state.percent, self.state.muted);
    }
    fn show(self: *Overlay, kind: Kind, state: State) void {
        self.kind = kind;
        self.state = state;
        self.surface.setBottomMargin(@divTrunc(self.surface.output.height() * 6, 100));
        self.surface.show() catch |err| std.log.err("desktop-osd: {s}", .{@errorName(err)});
    }
    fn destroy(self: *Overlay) void {
        const allocator = self.surface.client.allocator;
        self.surface.destroy();
        allocator.destroy(self);
    }
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    /// The shell's session connection, for DeviceChanged.
    connection: ?*@import("dbus").Connection = null,
    backlight_backend: backlight.Backend = .{},
    brightness_busy: bool = false,
    ready: bool = false,
    dead: bool = false,
    overlays: std.ArrayList(*Overlay) = .empty,
    client: ?*native.Client = null,
    theme: view.Theme = .{},
    queue: std.ArrayList(Work) = .empty,
    active: ?Work = null,
    state: State = .{ .percent = 0 },
    last_kind: Kind = .volume,
    last_state: State = .{ .percent = 0 },
    audio_service: ?*audio.Service = null,
    audio_busy: bool = false,
    cancel: ?*mainloop.Cancellable = null,
    hide_timer: u32 = 0,
    feedback_player: audio.Feedback,

    pub fn init(allocator: std.mem.Allocator) Server {
        return .{ .allocator = allocator, .feedback_player = .{ .allocator = allocator } };
    }

    pub fn start(self: *Server) !void {
        self.theme = .{};
        self.client = try native.Client.create(self.allocator, .{ .added = &added, .removed = &removed, .changed = &changed }, self);
        errdefer {
            for (self.overlays.items) |overlay| overlay.destroy();
            self.overlays.clearRetainingCapacity();
            self.client.?.destroy();
            self.client = null;
        }
        try self.client.?.start();
        self.audio_service = try audio.Service.create(self.allocator, &audioChanged, self);
        self.ready = true;
    }

    fn added(data: ?*anyopaque, output: *native.Output) void {
        const self = cast(Server, data);
        if (self.dead) return;
        const overlay = Overlay.create(output, &self.theme) catch |err| {
            std.log.err("desktop-osd: {s}", .{@errorName(err)});
            return;
        };
        self.overlays.append(self.allocator, overlay) catch @panic("out of memory");
        if (self.hide_timer != 0) overlay.show(self.last_kind, self.last_state);
    }
    fn changed(data: ?*anyopaque, output: *native.Output) void {
        const self = cast(Server, data);
        for (self.overlays.items) |overlay| if (overlay.surface.output == output) {
            overlay.surface.setBottomMargin(@divTrunc(output.height() * 6, 100));
        };
    }
    fn removed(data: ?*anyopaque, output: *native.Output) void {
        const self = cast(Server, data);
        for (self.overlays.items, 0..) |overlay, i| if (overlay.surface.output == output) {
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
        self.queue.append(self.allocator, work) catch @panic("out of memory");
        self.next();
        return true;
    }

    fn next(self: *Server) void {
        if (self.dead or self.active != null or self.queue.items.len == 0) return;
        self.active = self.queue.orderedRemove(0);
        if (self.active.?.kind == .brightness) {
            self.brightness_busy = true;
            self.cancel = mainloop.Cancellable.create();
            self.backlight_backend.start(self.allocator, .{ .step = self.active.?.delta }, self.cancel.?, &brightnessDone, self);
            return;
        }
        const service = self.audio_service orelse {
            self.finish();
            return;
        };
        self.cancel = mainloop.Cancellable.create();
        self.audio_busy = true;
        const work = self.active.?;
        service.apply(if (work.kind == .microphone) .input else .output, if (work.delta == 0) .toggle else .{ .step = work.delta }, self.cancel.?, &audioDone, self);
    }
    fn audioChanged(_: ?*anyopaque, _: *audio.Service) void {}
    fn audioDone(ptr: ?*anyopaque, result: audio.Result) void {
        const self = cast(Server, ptr);
        self.audio_busy = false;
        self.cancel.?.unref();
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
        self.cancel.?.unref();
        self.cancel = null;
        if (self.dead) return;
        switch (result) {
            .value => |device| self.present(.brightness, .{ .percent = device.percent() }),
            .failure => |err| std.log.warn("desktop-osd: brightness: {s}", .{@errorName(err)}),
        }
        self.finish();
    }
    fn present(self: *Server, kind: Kind, state: State) void {
        if (self.connection) |connection| connection.emit("/org/dotfiles/DesktopOsd", "org.dotfiles.DesktopOsd", "DeviceChanged", .{@as([]const u8, @tagName(kind))}) catch {};
        self.last_kind = kind;
        self.last_state = state;
        for (self.overlays.items) |overlay| overlay.show(kind, state);
        if (self.hide_timer != 0) _ = mainloop.remove(self.hide_timer);
        self.hide_timer = mainloop.timeout(1500, self, hide);
        if (kind == .volume and self.active.?.delta != 0 and !state.muted and state.percent > 0) self.feedback();
    }

    fn finish(self: *Server) void {
        self.active = null;
        self.next();
    }

    fn hide(self: *Server) bool {
        self.hide_timer = 0;
        for (self.overlays.items) |overlay| overlay.surface.hide();
        return false;
    }

    fn feedback(self: *Server) void {
        const path = @import("desktop-runtime.zig").sound_file orelse return;
        self.feedback_player.play(path.ptr);
    }

    pub fn deinit(self: *Server) void {
        self.dead = true;
        if (self.hide_timer != 0) _ = mainloop.remove(self.hide_timer);
        if (self.cancel) |cancel| cancel.cancel();
        if (self.audio_service) |service| service.destroy();
        self.audio_service = null;
        self.feedback_player.deinit();
        while (self.audio_busy or self.brightness_busy) _ = mainloop.iteration(true);
        for (self.overlays.items) |overlay| overlay.destroy();
        self.overlays.deinit(self.allocator);
        if (self.client) |client| client.destroy();
        self.client = null;
        self.queue.deinit(self.allocator);
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

test "integration: native OSD paints on the output, coalesces buffers, and restores the desktop when hidden" {
    if (!@import("options").integration_tests) return error.SkipZigTest;
    const capture = @import("tests/desktop-surface-capture.zig");
    const Callbacks = struct {
        fn nothing(_: ?*anyopaque, _: *native.Output) void {}
    };
    const client = try native.Client.create(std.testing.allocator, .{ .added = &Callbacks.nothing, .removed = &Callbacks.nothing }, null);
    defer client.destroy();
    try client.start();
    const theme: view.Theme = .{};
    const overlay = try Overlay.create(client.outputs.items[0], &theme);
    defer overlay.destroy();
    const before = try capture.capture();
    defer before.deinit();
    for (0..30) |_| overlay.show(.volume, .{ .percent = 75 });
    capture.pump();
    try std.testing.expect(overlay.surface.configured);
    try std.testing.expect(overlay.surface.buffers[0] != null);
    const shown = try capture.capture();
    defer shown.deinit();
    const x = shown.width / 2;
    const y = shown.height - @as(u32, @intCast(overlay.surface.options.bottom_margin)) - theme.height() / 2;
    try std.testing.expectEqual(@as(u32, 0xffffff), shown.pixel(x, y));
    try std.testing.expect(client.buffers.items.len <= 2);
    overlay.surface.hide();
    capture.pump();
    const hidden = try capture.capture();
    defer hidden.deinit();
    try std.testing.expectEqual(before.pixel(x, y), hidden.pixel(x, y));
    try std.testing.expectEqual(@as(usize, 0), client.buffers.items.len);
}
