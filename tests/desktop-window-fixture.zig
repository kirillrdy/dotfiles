//! A real application window built and exercised without linking GTK or GDK.
const std = @import("std");
const desktop = @import("desktop");
const mainloop = desktop.mainloop;
const util = desktop.util;
const wire = desktop.window.wire;
const cast = util.cast;
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
    defer desktop.form.host.deinit();
    const args = try init.minimal.args.toSlice(std.heap.page_allocator);
    defer std.heap.page_allocator.free(args);
    if (args.len == 2 and std.mem.eql(u8, args[1], "forms")) return forms(init.gpa);
    if (args.len == 2 and std.mem.eql(u8, args[1], "consent")) return consent(init);
    if (args.len == 2 and std.mem.eql(u8, args[1], "frames")) return frames(init);
    if (args.len == 2 and std.mem.eql(u8, args[1], "idle")) return idle(init);
    var state: State = .{};
    const client = try wire.Client.createInteractive(init.gpa, .{ .added = &State.output, .removed = &State.output }, &state);
    defer client.destroy();
    if (client.outputs.items.len == 0) return error.NoOutputs;
    const surface = try wire.Surface.createPixels(client.outputs.items[0], .{ .namespace = "desktop-native-fixture", .title = "Native Wayland fixture", .role = .toplevel, .width = 480, .height = 320, .interactive = true, .cursor = .arrow }, &State.paint, &state);
    surface.input = .{ .symbol = &State.symbol, .text = &State.text, .focus = &State.focus };
    surface.close = &State.close;
    try client.start();
    try surface.show();
    const deadline = util.monotonicTime() + 8_000_000;
    while (!state.closed and util.monotonicTime() < deadline) {
        while (mainloop.iteration(false)) {}
        try init.io.sleep(.fromMilliseconds(5), .awake);
    }
    if (!state.closed or !state.painted) {
        std.debug.print("window: painted={}, focus events={d}, key events={d}, text bytes={d}\n", .{ state.painted, state.focus_events, state.key_events, state.len });
        return error.WindowNotExercised;
    }
    try std.testing.expectEqualStrings("Cafe 日本語", state.typed[0..state.len]);
    std.debug.print("PASS GTK-free native window: configure, SHM pixels, focus, Unicode keyboard input and close\n", .{});
}

fn idle(init: std.process.Init) !void {
    const Probe = struct {
        paints: usize = 0,
        fn output(_: ?*anyopaque, _: *wire.Output) void {}
        fn paint(ptr: ?*anyopaque, pixels: wire.Pixels) void {
            if (ptr) |value| cast(@This(), value).paints += 1;
            @memset(pixels.pixels, 0xff245b98);
        }
        fn pump(io: std.Io, milliseconds: i64) !void {
            const until = util.monotonicTime() + milliseconds * 1000;
            while (util.monotonicTime() < until) {
                while (mainloop.iteration(false)) {}
                try io.sleep(.fromMilliseconds(1), .awake);
            }
        }
    };
    var probe: Probe = .{};
    const client = try wire.Client.create(init.gpa, .{ .added = &Probe.output, .removed = &Probe.output }, null);
    defer client.destroy();
    try client.start();
    const output = client.outputs.items[0];
    const window = try wire.Surface.createPixels(output, .{ .namespace = "idle-window", .role = .toplevel, .width = 320, .height = 240 }, &Probe.paint, &probe);
    try window.show();
    const panel = try wire.Surface.createPixels(output, .{ .namespace = "idle-panel", .layer = 2, .anchors = wire.top | wire.left | wire.right, .height = 32, .exclusive_zone = 32 }, &Probe.paint, null);
    try panel.show();
    try Probe.pump(init.io, 500);
    try std.testing.expect(probe.paints > 0);
    try std.testing.expectEqual(@as(u32, @intCast(output.height() - 32)), window.height);
    const paints = probe.paints;
    for (0..5) |_| {
        panel.redraw();
        try Probe.pump(init.io, 80);
    }
    try std.testing.expectEqual(paints, probe.paints);
    panel.hide();
    try Probe.pump(init.io, 200);
    try std.testing.expectEqual(@as(u32, @intCast(output.height())), window.height);
    try panel.show();
    try Probe.pump(init.io, 200);
    try std.testing.expectEqual(@as(u32, @intCast(output.height() - 32)), window.height);
    std.debug.print("PASS idle window: panel repaints preserve sleep; panel map/unmap updates exclusive space\n", .{});
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
    const client = try wire.Client.create(init.gpa, .{ .added = &Animation.output, .removed = &Animation.output }, &animation);
    defer client.destroy();
    const surface = try wire.Surface.createPixels(client.outputs.items[0], .{ .namespace = "desktop-frame-fixture", .layer = 3, .width = 32, .height = 32 }, &Animation.paint, &animation);
    surface.next_frame = &Animation.next;
    try client.start();
    try surface.show();
    const deadline = util.monotonicTime() + 5_000_000;
    while (animation.frames < 60 and util.monotonicTime() < deadline) {
        while (mainloop.iteration(false)) {}
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
    const dialog = try desktop.auth_dialog.Dialog.createWithOptions(allocator.allocator(), .confirm, "An application requests your account information.\nName: 日本語", .{ .title = "Native consent fixture", .role = "desktop-consent", .accept = "Share", .cancel = "Cancel", .response_context = &done, .responded = &Done.completed });
    defer dialog.destroy();
    const deadline = util.monotonicTime() + 8_000_000;
    while (done.accepted == null and util.monotonicTime() < deadline) {
        while (mainloop.iteration(false)) {}
        try init.io.sleep(.fromMilliseconds(5), .awake);
    }
    if (done.accepted == null) return error.ConsentNotExercised;
    std.debug.print("PASS GTK-free consent accepted={}\n", .{done.accepted.?});
}

fn forms(allocator: std.mem.Allocator) !void {
    const Owner = struct {
        fn action(_: ?*anyopaque, _: usize) void {}
        fn changed(_: ?*anyopaque, _: usize) void {}
    };
    const previous = try desktop.form.Form.create(allocator, "Clipboard owner", null, &Owner.action, &Owner.changed);
    const previous_field = try previous.add(.entry, "Name", "", false);
    try previous.setText(previous_field, "Clipboard after window close");
    previous.focusItem(previous_field);
    try std.testing.expect(previous.handleKey('a', 4));
    try std.testing.expect(previous.handleKey('c', 4));
    previous.deinit();
    const form = try desktop.form.Form.create(allocator, "Native form fixture", null, &Owner.action, &Owner.changed);
    defer form.deinit();
    const field = try form.add(.entry, "Name", "", false);
    form.focusItem(field);
    try std.testing.expect(form.handleKey('v', 4));
    try std.testing.expectEqualStrings("Clipboard after window close", form.get(field).value());
    try form.setText(field, "日本語 clipboard");
    form.focusItem(field);
    try std.testing.expect(form.handleKey('a', 4));
    try std.testing.expect(form.handleKey('c', 4));
    try form.setText(field, "");
    try std.testing.expect(form.handleKey('v', 4));
    try std.testing.expectEqualStrings("日本語 clipboard", form.get(field).value());
    const external = try wire.Client.createInteractive(allocator, .{ .added = &State.output, .removed = &State.output }, null);
    defer external.destroy();
    try external.start();
    const device = form.get(field).entry.?.clipboard().?;
    external.seats.items[0].clipboard.?.copy("Text from another client");
    const clipboard_deadline = util.monotonicTime() + 2_000_000;
    while ((device.source != null or device.selection == null) and util.monotonicTime() < clipboard_deadline) {
        _ = mainloop.iteration(false);
        mainloop.sleep(1000);
    }
    try form.setText(field, "");
    form.get(field).entry.?.paste();
    while (device.requests.items.len != 0 and util.monotonicTime() < clipboard_deadline) {
        _ = mainloop.iteration(false);
        mainloop.sleep(1000);
    }
    try std.testing.expectEqualStrings("Text from another client", form.get(field).value());
    const dialog = try desktop.auth_dialog.Dialog.create(allocator, .password, "Native authentication fixture");
    defer dialog.destroy();
    try dialog.entry.?.insert("synthetic-password");
    try std.testing.expect(dialog.handleKey(0xff1b, 0));
    try std.testing.expectEqualStrings("", dialog.entry.?.buffer.value());
    dialog.entry.?.paste();
    dialog.clear();
    while (device.requests.items.len != 0 and util.monotonicTime() < clipboard_deadline) {
        _ = mainloop.iteration(false);
        mainloop.sleep(1000);
    }
    try std.testing.expectEqualStrings("", dialog.entry.?.buffer.value());
    form.show();
    const deadline = util.monotonicTime() + 2_000_000;
    while (!form.window.surface.?.configured and util.monotonicTime() < deadline) {
        _ = mainloop.iteration(false);
        mainloop.sleep(1000);
    }
    try std.testing.expect(form.window.surface.?.configured);
    form.close();
    while (!form.closed) _ = mainloop.iteration(true);
    std.debug.print("PASS GTK-free production forms, clipboard and authentication\n", .{});
}
