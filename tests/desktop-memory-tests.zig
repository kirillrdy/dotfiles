//! Leak assertions only. Requires the private desktop-memory-fixture.nix runtime.
const std = @import("std");
const c = @import("desktop").glib;
const audio = @import("desktop").audio;
const network = @import("desktop").network;
const battery = @import("desktop").battery;
const settings = @import("desktop").settings;
const editor = @import("desktop").network_editor;
const widgets = @import("desktop").widgets;

fn env(name: [:0]const u8) ?[]const u8 {
    return if (c.__zig.getenv(name)) |value| std.mem.span(value) else null;
}
fn pump() void {
    while (c.g_main_context_iteration(null, 0) != 0) {}
    c.g_usleep(1000);
}
fn fixture() !void {
    if (!std.mem.eql(u8, env("DESKTOP_MEMORY_TEST_RUN") orelse "", "1")) return error.PrivateMemoryFixtureRequired;
}
const Objects = struct {
    live: usize = 0,
    fn watch(self: *Objects, object: anytype) void {
        self.live += 1;
        c.g_object_weak_ref(@ptrCast(@alignCast(object)), &finalized, self);
    }
    fn finalized(data: ?*anyopaque, _: ?*c.GObject) callconv(.c) void {
        const self: *Objects = @ptrCast(@alignCast(data));
        self.live -= 1;
    }
    fn wait(self: *Objects, timeout_us: i64) !void {
        const deadline = c.__zig.monotonicTime() + timeout_us;
        while (self.live != 0 and c.__zig.monotonicTime() < deadline) pump();
        if (self.live != 0) {
            std.debug.print("memory: {d} owned GObjects were not finalized\n", .{self.live});
            return error.RetainedObjects;
        }
    }
};
fn audioChanged(_: ?*anyopaque, _: *audio.Service) void {}
fn batteryChanged(_: ?*anyopaque, _: battery.State) void {}
fn ready(service: *audio.Service) !void {
    const deadline = c.__zig.monotonicTime() + 15_000_000;
    while ((!service.ready or service.state(.output) == null) and c.__zig.monotonicTime() < deadline) pump();
    if (!service.ready or service.state(.output) == null) return error.PrivateAudioNotReady;
}
const Completion = struct {
    finished: bool = false,
    fn done(ptr: ?*anyopaque, _: audio.Result) void {
        const self: *Completion = @ptrCast(@alignCast(ptr));
        self.finished = true;
    }
};
fn audioLifetime(settle: bool) !void {
    var objects = Objects{};
    const service = try audio.Service.create(std.testing.allocator, &audioChanged, null);
    if (settle) try ready(service);
    if (settle) {
        const cancel = c.g_cancellable_new().?;
        objects.watch(cancel);
        var completion = Completion{};
        service.apply(.output, .{ .volume = 43 }, cancel, &Completion.done, &completion);
        c.g_cancellable_cancel(cancel);
        service.destroy();
        c.g_object_unref(cancel);
        try objects.wait(15_000_000);
        try std.testing.expect(completion.finished);
    } else {
        // Native registry ownership is checked by the Zig allocator and Valgrind.
        service.destroy();
        try objects.wait(15_000_000);
    }
}
fn batteryLifetime(settle: bool) !void {
    var objects = Objects{};
    const service = try battery.Service.create(std.testing.allocator, &batteryChanged, null);
    if (settle) {
        const deadline = c.__zig.monotonicTime() + 15_000_000;
        while (service.pending and c.__zig.monotonicTime() < deadline) pump();
        try std.testing.expect(!service.pending);
    }
    objects.watch(service.cancel);
    service.destroy();
    try objects.wait(15_000_000);
}
fn networkChanged(_: ?*anyopaque, _: *network.Client) void {}
const NetworkCompletion = struct {
    finished: bool = false,
    succeeded: bool = false,
    fn done(ptr: ?*anyopaque, result: network.Result) void {
        const self: *NetworkCompletion = @ptrCast(@alignCast(ptr));
        self.finished = true;
        self.succeeded = result == .success;
    }
};
fn networkLifetime(settle: bool) !void {
    var objects = Objects{};
    const client = try network.Client.create(std.testing.allocator, &networkChanged, null);
    const second = try network.Client.create(std.testing.allocator, &networkChanged, null);
    try std.testing.expect(client.service == second.service);
    objects.watch(client.cancel);
    objects.watch(second.cancel);
    var activation = NetworkCompletion{};
    if (settle) {
        const deadline = c.__zig.monotonicTime() + 15_000_000;
        while ((!client.state().available or client.state().profiles.items.len == 0) and c.__zig.monotonicTime() < deadline) pump();
        try std.testing.expect(client.state().available and client.state().profiles.items.len != 0);
        const cancel = c.g_cancellable_new().?;
        defer c.g_object_unref(cancel);
        objects.watch(cancel);
        var connected = NetworkCompletion{};
        const ap = client.state().access_points.items[0];
        client.perform(.{ .connect = .{ .ssid = ap.ssid, .access_point = ap.path, .password = "memory-secret" } }, cancel, &NetworkCompletion.done, &connected);
        while (!connected.finished and c.__zig.monotonicTime() < deadline) pump();
        try std.testing.expect(connected.finished and connected.succeeded);
        const ui = settings.Settings.create(std.testing.allocator, .network);
        objects.watch(ui.audio_cancel);
        const connection_editor = editor.Editor.create(ui.window, client.state().profiles.items[0]);
        objects.watch(connection_editor.cancel);
        // A close during profile saving must release the editor after the reply.
        connection_editor.save();
        connection_editor.ui.close();
        const new_connection = editor.Editor.create(ui.window, null);
        const new_settings = try new_connection.values();
        new_settings.unref();
        new_connection.ui.close();
        // Start a real asynchronous action, then cancel it during window teardown.
        ui.refresh();
        ui.ui.close();
        while (!ui.closed) _ = c.g_main_context_iteration(null, 1);
        while (ui.network_operations != 0) pump();
        ui.destroy();
        client.perform(.{ .activate = client.state().profiles.items[0].path }, cancel, &NetworkCompletion.done, &activation);
        while (!activation.finished and client.service.waiting.items.len == 0 and c.__zig.monotonicTime() < deadline) pump();
        try std.testing.expect(activation.finished or client.service.waiting.items.len != 0);
    }
    second.destroy();
    client.destroy();
    try objects.wait(15_000_000);
    if (settle) try std.testing.expect(activation.finished);
}
fn soundLifetime(settle: bool) !void {
    var objects = Objects{};
    const shell = settings.Settings.create(std.testing.allocator, .sound);
    const sound = shell.sound.?;
    objects.watch(shell.audio_cancel);
    objects.watch(sound.cancel);
    if (sound.service) |service| {
        if (settle) {
            try ready(service);
            const deadline = c.__zig.monotonicTime() + 15_000_000;
            while (sound.view.rows.items.len == 0 and c.__zig.monotonicTime() < deadline) pump();
            try std.testing.expect(sound.view.rows.items.len != 0);
        }
    }
    sound.close();
    while (!sound.closed) pump();
    const deadline = c.__zig.monotonicTime() + 15_000_000;
    while ((sound.operations != 0 or shell.network_operations != 0) and c.__zig.monotonicTime() < deadline) pump();
    try std.testing.expect(sound.operations == 0 and shell.network_operations == 0);
    try std.testing.expect(shell.closed);
    shell.destroy();
    try objects.wait(15_000_000);
}
fn widgetLifetime(name: [:0]const u8, kind: [:0]const u8, source: [:0]const u8) !void {
    var objects = Objects{};
    const module = widgets.init(std.testing.allocator, .{ .name = name, .kind = kind, .source = source }, null, null, null);
    objects.watch(module.cancel);
    if (module.quick) |controls| {
        objects.watch(controls.cancel);
        if (controls.devices.network_client) |client| {
            objects.watch(client.cancel);
        }
        if (controls.devices.battery_service) |service| objects.watch(service.cancel);
        for (0..2) |cycle| {
            try controls.show(320, 32);
            const deadline = c.__zig.monotonicTime() + 5_000_000;
            while (!controls.popup.surface.?.configured and c.__zig.monotonicTime() < deadline) pump();
            try std.testing.expect(controls.popup.surface.?.configured);
            if (cycle == 0) controls.hide() else _ = controls.handleKey(0xff1b, 0);
        }
    }
    if (module.usage_menu) |menu| {
        for (0..2) |cycle| {
            try menu.show(320, 32);
            const deadline = c.__zig.monotonicTime() + 5_000_000;
            while (!menu.popup.surface.?.configured and c.__zig.monotonicTime() < deadline) pump();
            try std.testing.expect(menu.popup.surface.?.configured);
            if (cycle == 0) menu.hide() else _ = menu.handleKey(0xff1b);
        }
    }
    if (module.date_controls) |controls| {
        // Exercise native buffers and event sources, then destroy the module
        // with a dismissal still queued rather than merely freeing its model.
        for (0..2) |cycle| {
            try controls.show(320, 32);
            const deadline = c.__zig.monotonicTime() + 5_000_000;
            while (!controls.popup.surface.?.configured and c.__zig.monotonicTime() < deadline) pump();
            try std.testing.expect(controls.popup.surface.?.configured);
            if (cycle == 0) controls.hide() else _ = controls.handleKey(0xff1b, 0);
        }
    }
    // Updating owned strings exercises replacement allocations and final cleanup.
    widgets.update(module, .{ .items = &.{.{ .icon = "audio-volume-high-symbolic", .text = "old", .command = "true" }}, .tooltip = "old" });
    widgets.update(module, .{ .items = &.{.{ .text = "new" }}, .tooltip = "new", .windows = &.{} });
    widgets.deinit(module);
    try objects.wait(15_000_000);
}

test "memory: detector controls" {
    try fixture();
    const probe = env("DESKTOP_MEMORY_LEAK_PROBE") orelse return;
    if (std.mem.eql(u8, probe, "zig")) {
        _ = try std.testing.allocator.alloc(u8, 37);
    } else if (std.mem.eql(u8, probe, "c")) {
        _ = c.g_malloc0_n(37, 1);
    } else if (std.mem.eql(u8, probe, "object")) {
        var objects = Objects{};
        const retained = c.g_cancellable_new().?;
        defer c.g_object_unref(retained);
        objects.watch(retained);
        try objects.wait(50_000);
    } else return error.UnknownLeakProbe;
}

test "memory: repeated asynchronous service and widget teardown releases ownership" {
    defer @import("desktop").gsettings.deinit();
    defer @import("desktop").window.deinit();
    try fixture();
    if (env("DESKTOP_MEMORY_LEAK_PROBE") != null) return error.SkipZigTest;
    const iterations = std.fmt.parseInt(usize, env("DESKTOP_MEMORY_ITERATIONS") orelse "4", 10) catch 4;
    for (0..iterations) |_| {
        try networkLifetime(false);
        try networkLifetime(true);
        try audioLifetime(false);
        try audioLifetime(true);
        try batteryLifetime(false);
        try batteryLifetime(true);
        try soundLifetime(false);
        try soundLifetime(true);
        try widgetLifetime("gnome-status", "indicator", "status");
        try widgetLifetime("gnome-codex", "indicator", "codex");
        try widgetLifetime("gnome-claude", "indicator", "claude");
        try widgetLifetime("gnome-antigravity", "indicator", "antigravity");
        try widgetLifetime("gnome-clock", "clock", "");
    }
}
