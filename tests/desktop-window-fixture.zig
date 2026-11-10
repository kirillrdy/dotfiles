//! A real application window built and exercised without linking GTK or GDK.
const std = @import("std");
const native = @import("native");
const c = native.c;
const wire = native.surface;
const cast = c.__zig.cast;
const State = struct {
    painted: bool = false,
    focused: bool = false,
    closed: bool = false,
    focus_events: usize = 0,
    key_events: usize = 0,
    typed: [256]u8 = @splat(0),
    len: usize = 0,
    fn output(_: ?*anyopaque, _: *wire.Output) void {}
    fn paint(ptr: ?*anyopaque, pixels: wire.Pixels) void {
        const self = cast(State, ptr);
        @memset(pixels.pixels, 0xff245b98);
        self.painted = true;
    }
    fn close(ptr: ?*anyopaque) void {
        cast(State, ptr).closed = true;
    }
    fn focus(ptr: ?*anyopaque, _: *wire.Surface, active: bool) void {
        cast(State, ptr).focused = active;
        if (active) cast(State, ptr).focus_events += 1;
    }
    fn text(ptr: ?*anyopaque, _: *wire.Surface, value: []const u8) void {
        const self = cast(State, ptr);
        const n = @min(value.len, self.typed.len - self.len);
        @memcpy(self.typed[self.len..][0..n], value[0..n]);
        self.len += n;
    }
    fn symbol(ptr: ?*anyopaque, surface: *wire.Surface, sym: u32, _: u32, pressed: bool) bool {
        cast(State, ptr).key_events += 1;
        if (sym == 0xff1b and pressed) {
            surface.hide();
            cast(State, ptr).closed = true;
            return true;
        }
        return false;
    }
};
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(std.heap.page_allocator);
    defer std.heap.page_allocator.free(args);
    if (args.len == 2 and std.mem.eql(u8, args[1], "consent")) return consent(init);
    if (args.len == 2 and std.mem.eql(u8, args[1], "frames")) return frames(init);
    var state: State = .{};
    const client = try wire.Client.createInteractive(.{ .added = &State.output, .removed = &State.output }, &state);
    defer client.destroy();
    if (client.outputs.items.len == 0) return error.NoOutputs;
    const surface = try wire.Surface.createPixels(client.outputs.items[0], .{ .namespace = "desktop-native-fixture", .title = "Native Wayland fixture", .role = .toplevel, .width = 480, .height = 320, .interactive = true, .cursor = .arrow }, &State.paint, &state);
    surface.input = .{ .symbol = &State.symbol, .text = &State.text, .focus = &State.focus };
    surface.close = &State.close;
    try client.start();
    try surface.show();
    const deadline = c.g_get_monotonic_time() + 8_000_000;
    while (!state.closed and c.g_get_monotonic_time() < deadline) {
        while (c.g_main_context_iteration(null, 0) != 0) {}
        try init.io.sleep(.fromMilliseconds(5), .awake);
    }
    if (!state.closed or !state.painted) {
        std.debug.print("window: painted={}, focus events={d}, key events={d}, text bytes={d}\n", .{ state.painted, state.focus_events, state.key_events, state.len });
        return error.WindowNotExercised;
    }
    try std.testing.expectEqualStrings("Cafe 日本語", state.typed[0..state.len]);
    std.debug.print("PASS GTK-free native window: configure, SHM pixels, focus, Unicode keyboard input and close\n", .{});
}

fn frames(init: std.process.Init) !void {
    const Animation = struct {
        frames: u32 = 0,
        first: u32 = 0,
        last: u32 = 0,
        fn output(_: ?*anyopaque, _: *wire.Output) void {}
        fn paint(_: ?*anyopaque, pixels: wire.Pixels) void {
            @memset(pixels.pixels, 0xff245b98);
        }
        fn next(ptr: ?*anyopaque, _: *wire.Surface, time: u32) bool {
            const self = cast(@This(), ptr);
            if (self.frames == 0) self.first = time;
            self.last = time;
            self.frames += 1;
            return self.frames < 60;
        }
    };
    var animation: Animation = .{};
    const client = try wire.Client.create(.{ .added = &Animation.output, .removed = &Animation.output }, &animation);
    defer client.destroy();
    const surface = try wire.Surface.createPixels(client.outputs.items[0], .{ .namespace = "desktop-frame-fixture", .layer = 3, .width = 32, .height = 32 }, &Animation.paint, &animation);
    surface.next_frame = &Animation.next;
    try client.start();
    try surface.show();
    const deadline = c.g_get_monotonic_time() + 5_000_000;
    while (animation.frames < 60 and c.g_get_monotonic_time() < deadline) {
        while (c.g_main_context_iteration(null, 0) != 0) {}
        try init.io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqual(@as(u32, 60), animation.frames);
    std.debug.print("PASS native frame pacing: {d} callbacks, {d:.2} ms/frame\n", .{ animation.frames, @as(f64, @floatFromInt(animation.last -% animation.first)) / 59 });
}

fn consent(init: std.process.Init) !void {
    const Done = struct {
        accepted: ?bool = null,
        fn completed(ptr: ?*anyopaque, accepted: bool) void {
            cast(@This(), ptr).accepted = accepted;
        }
    };
    var done: Done = .{};
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer if (allocator.deinit() == .leak) @panic("native consent allocation leak");
    const dialog = try native.consent.Dialog.create(allocator.allocator(), "Native consent fixture", "An application requests your account information.\nName: 日本語", "Share", "", &done, &Done.completed);
    defer dialog.destroy();
    const deadline = c.g_get_monotonic_time() + 8_000_000;
    while (done.accepted == null and c.g_get_monotonic_time() < deadline) {
        while (c.g_main_context_iteration(null, 0) != 0) {}
        try init.io.sleep(.fromMilliseconds(5), .awake);
    }
    if (done.accepted == null) return error.ConsentNotExercised;
    std.debug.print("PASS GTK-free consent accepted={}\n", .{done.accepted.?});
}
