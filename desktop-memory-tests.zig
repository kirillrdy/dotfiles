//! Leak assertions only. Requires the private desktop-memory-fixture.nix runtime.
const std = @import("std");
const c = @import("gtk");
const audio = @import("audio");
const network = @import("network");
const battery = @import("battery");
const settings = @import("desktop-settings.zig");
const widgets = @import("desktop-widgets.zig");

extern fn pango_cairo_font_map_get_default() *anyopaque;
extern fn pango_cairo_font_map_set_default(?*anyopaque) void;
extern fn pango_fc_font_map_cache_clear(*anyopaque) void;

extern fn g_object_weak_ref(*c.GObject, *const fn (?*anyopaque, ?*c.GObject) callconv(.c) void, ?*anyopaque) void;

fn env(name: [:0]const u8) ?[]const u8 {
    return if (c.g_getenv(name)) |value| std.mem.span(value) else null;
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
        g_object_weak_ref(@ptrCast(@alignCast(object)), &finalized, self);
    }
    fn finalized(data: ?*anyopaque, _: ?*c.GObject) callconv(.c) void {
        const self: *Objects = @ptrCast(@alignCast(data));
        self.live -= 1;
    }
    fn wait(self: *Objects, timeout_us: i64) !void {
        const deadline = c.g_get_monotonic_time() + timeout_us;
        while (self.live != 0 and c.g_get_monotonic_time() < deadline) pump();
        if (self.live != 0) {
            std.debug.print("memory: {d} owned GObjects were not finalized\n", .{self.live});
            return error.RetainedObjects;
        }
    }
};
fn audioChanged(_: ?*anyopaque, _: *audio.Service) void {}
fn batteryChanged(_: ?*anyopaque, _: battery.State) void {}
fn watchAudio(objects: *Objects, service: *audio.Service) void {
    objects.watch(service.cancel);
    if (service.core) |core| objects.watch(core);
    if (service.manager) |manager| objects.watch(manager);
    if (service.mixer != null) objects.watch(service.mixer);
    if (service.defaults != null) objects.watch(service.defaults);
}
fn ready(service: *audio.Service) !void {
    const deadline = c.g_get_monotonic_time() + 15_000_000;
    while ((!service.ready or service.state(.output) == null) and c.g_get_monotonic_time() < deadline) pump();
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
    const service = try audio.Service.create(&audioChanged, null);
    if (settle) try ready(service);
    watchAudio(&objects, service);
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
        // Destroy while the component-loading callbacks still retain the service.
        service.destroy();
        try objects.wait(15_000_000);
    }
}
fn batteryLifetime(settle: bool) !void {
    var objects = Objects{};
    const service = try battery.Service.create(&batteryChanged, null);
    if (settle) {
        const deadline = c.g_get_monotonic_time() + 15_000_000;
        while (service.pending and c.g_get_monotonic_time() < deadline) pump();
        try std.testing.expect(!service.pending);
    }
    objects.watch(service.cancel);
    if (service.proxy) |proxy| objects.watch(proxy);
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
    const client = try network.Client.create(&networkChanged, null);
    const second = try network.Client.create(&networkChanged, null);
    try std.testing.expect(client.service == second.service);
    objects.watch(client.cancel);
    objects.watch(second.cancel);
    objects.watch(client.service.cancel);
    var activation = NetworkCompletion{};
    if (settle) {
        const deadline = c.g_get_monotonic_time() + 15_000_000;
        while ((!client.state().available or client.state().profiles.items.len == 0) and c.g_get_monotonic_time() < deadline) pump();
        try std.testing.expect(client.state().available and client.state().profiles.items.len != 0);
        if (client.service.manager) |manager| objects.watch(manager);
        const cancel = c.g_cancellable_new().?;
        defer c.g_object_unref(cancel);
        objects.watch(cancel);
        var connected = NetworkCompletion{};
        const ap = client.state().access_points.items[0];
        client.perform(.{ .connect = .{ .ssid = ap.ssid, .access_point = ap.path, .password = "memory-secret" } }, cancel, &NetworkCompletion.done, &connected);
        while (!connected.finished and c.g_get_monotonic_time() < deadline) pump();
        try std.testing.expect(connected.finished and connected.succeeded);
        const ui = settings.Settings.create(.network);
        objects.watch(ui.window);
        objects.watch(ui.audio_cancel);
        // Start a real asynchronous action, then cancel it during window teardown.
        ui.refresh();
        c.gtk_widget_destroy(ui.window);
        while (ui.network_operations != 0) pump();
        ui.destroy();
        client.perform(.{ .activate = client.state().profiles.items[0].path }, cancel, &NetworkCompletion.done, &activation);
        while (!activation.finished and client.service.waiting.items.len == 0 and c.g_get_monotonic_time() < deadline) pump();
        try std.testing.expect(activation.finished or client.service.waiting.items.len != 0);
    }
    second.destroy();
    client.destroy();
    try objects.wait(15_000_000);
    if (settle) try std.testing.expect(activation.finished);
}
fn soundLifetime(settle: bool) !void {
    var objects = Objects{};
    const sound = settings.Settings.create(.sound);
    objects.watch(sound.window);
    objects.watch(sound.audio_cancel);
    if (sound.audio_service) |service| {
        if (settle) {
            try ready(service);
            const deadline = c.g_get_monotonic_time() + 15_000_000;
            while (sound.rows.items.len == 0 and c.g_get_monotonic_time() < deadline) pump();
            try std.testing.expect(sound.rows.items.len != 0);
        }
        watchAudio(&objects, service);
    }
    c.gtk_widget_destroy(sound.window);
    const deadline = c.g_get_monotonic_time() + 15_000_000;
    while ((sound.audio_operations != 0 or sound.network_operations != 0) and c.g_get_monotonic_time() < deadline) pump();
    try std.testing.expect(sound.audio_operations == 0 and sound.network_operations == 0);
    sound.destroy();
    try objects.wait(15_000_000);
}
fn widgetLifetime(name: [:0]const u8, kind: [:0]const u8, source: [:0]const u8) !void {
    var objects = Objects{};
    const window = c.gtk_window_new(c.GTK_WINDOW_TOPLEVEL).?;
    objects.watch(window);
    const root = c.gtk_event_box_new().?;
    objects.watch(root);
    c.gtk_container_add(@ptrCast(window), root);
    const module = widgets.init(root, .{ .name = name, .kind = kind, .source = source });
    objects.watch(module.cancel);
    if (module.quick) |controls| {
        objects.watch(controls.cancel);
        objects.watch(controls.popover);
        if (controls.interface) |prefs| objects.watch(prefs);
        if (controls.notifications) |prefs| objects.watch(prefs);
        if (controls.audio_service) |service| watchAudio(&objects, service);
        if (controls.network_client) |client| {
            objects.watch(client.cancel);
            objects.watch(client.service.cancel);
        }
        if (controls.battery_service) |service| objects.watch(service.cancel);
    }
    if (module.calendar != null) objects.watch(module.calendar);
    if (module.codex_menu != null) objects.watch(module.codex_menu);
    // Updating owned strings exercises replacement allocations and final cleanup.
    widgets.update_line(module, "{\"items\":[{\"icon\":\"audio-volume-high-symbolic\",\"text\":\"old\",\"command\":\"true\"}],\"tooltip\":\"old\"}");
    widgets.update_line(module, "{\"items\":[{\"text\":\"new\"}],\"tooltip\":\"new\",\"windows\":[]}");
    widgets.deinit(module);
    c.gtk_widget_destroy(window);
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
    try fixture();
    if (env("DESKTOP_MEMORY_LEAK_PROBE") != null) return error.SkipZigTest;
    if (c.gtk_init_check(null, null) == 0) return error.PrivateDisplayRequired;
    c.g_object_set(c.gtk_settings_get_default(), "gtk-enable-animations", @as(c_int, 0), @as(?*anyopaque, null));
    for (0..4) |_| {
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
        try widgetLifetime("gnome-clock", "clock", "");
    }
    // Release the font backend's process cache after every owned UI object is gone.
    // Keep the C-heap check strict instead of suppressing font allocation stacks.
    pango_fc_font_map_cache_clear(pango_cairo_font_map_get_default());
    pango_cairo_font_map_set_default(null);
}
