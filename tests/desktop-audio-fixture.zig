//! Native audio commands and GTK integration against an isolated PipeWire server.
const std = @import("std");
const c = @import("gtk");
const audio = @import("audio");
const quick = @import("quick");
const settings = quick.settings_client;
const assert = std.debug.assert;
const a = std.heap.page_allocator;
var stopping = false;
var watch = false;
fn cast(comptime T: type, ptr: anytype) *T {
    return @ptrCast(@alignCast(ptr));
}
fn pump() void {
    audio.dispatch();
    c.g_usleep(1000);
}
fn stop(_: ?*anyopaque) callconv(.c) c_int {
    stopping = true;
    return 1;
}
fn changed(_: ?*anyopaque, service: *audio.Service) void {
    if (watch) dump(service) catch @panic("dump failed");
}
fn dump(service: *audio.Service) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const View = struct { id: u32, class: audio.Class, name: []const u8, state: ?audio.State, is_default: bool };
    const nodes = try arena.allocator().alloc(View, service.nodes.items.len);
    for (service.nodes.items, nodes) |*entry, *view| view.* = .{ .id = entry.id, .class = entry.class, .name = std.mem.sliceTo(&entry.name, 0), .state = entry.state, .is_default = entry.is_default };
    const json = try std.json.Stringify.valueAlloc(arena.allocator(), .{ .ready = service.ready, .nodes = nodes }, .{});
    const text = try arena.allocator().dupeSentinel(u8, json, 0);
    c.g_print("%s\n", text.ptr);
}
const Completion = struct {
    result: ?audio.Result = null,
    fn done(ptr: ?*anyopaque, result: audio.Result) void {
        cast(Completion, ptr).result = result;
    }
};
fn apply(service: *audio.Service, target: audio.Target, change: audio.Change) !audio.State {
    const cancel = c.g_cancellable_new().?;
    defer c.g_object_unref(cancel);
    var completion = Completion{};
    service.apply(target, change, cancel, &Completion.done, &completion);
    const deadline = c.g_get_monotonic_time() + 6_000_000;
    while (completion.result == null and c.g_get_monotonic_time() < deadline) pump();
    const result = completion.result orelse return error.AudioOperationHung;
    return switch (result) {
        .value => |value| value,
        .failure => |err| err,
    };
}
fn ready(service: *audio.Service) !void {
    const deadline = c.g_get_monotonic_time() + 8_000_000;
    while ((!service.ready or service.nodes.items.len < 3 or service.state(.output) == null or service.state(.input) == null) and c.g_get_monotonic_time() < deadline) pump();
    if (!service.ready or service.state(.output) == null or service.state(.input) == null) return error.AudioNeverReady;
}
fn ui(service: *audio.Service) !void {
    if (c.gtk_init_check(null, null) == 0) return error.NoDisplay;
    const window = c.gtk_window_new(c.GTK_WINDOW_TOPLEVEL);
    defer c.gtk_widget_destroy(window);
    const button = c.gtk_button_new();
    c.gtk_container_add(cast(c.GtkContainer, window), button);
    const controls = quick.Controls.create(c.gtk_popover_new(button).?, "true", "true");
    const sound = settings.Settings.create(.sound);
    defer {
        c.gtk_widget_destroy(sound.window);
        controls.deinit();
        while (sound.audio_operations != 0 or sound.network_operations != 0) pump();
        sound.destroy();
    }
    var deadline = c.g_get_monotonic_time() + 8_000_000;
    while ((controls.audio_service == null or controls.audio_service.?.state(.output) == null or sound.rows.items.len < 5) and c.g_get_monotonic_time() < deadline) pump();
    assert(sound.rows.items.len >= 5);
    assert(c.gtk_widget_get_visible(controls.volume_row) != 0);
    c.gtk_range_set_value(cast(c.GtkRange, controls.volume), 63);
    deadline = c.g_get_monotonic_time() + 5_000_000;
    while ((controls.volume_timer != 0 or @abs((service.state(.output) orelse return error.NoOutput).percent - 63) > 0.01) and c.g_get_monotonic_time() < deadline) pump();
    assert(@abs(service.state(.output).?.percent - 63) < 0.01);
    // Rows survive volume-only changes, so dragging cannot target a freed row.
    const row = sound.rows.items[0];
    c.gtk_range_set_value(cast(c.GtkRange, row.scale), 47);
    deadline = c.g_get_monotonic_time() + 5_000_000;
    while ((row.timer != 0 or sound.audio_operations != 0 or @abs(service.state(.output).?.percent - 47) > 0.01) and c.g_get_monotonic_time() < deadline) pump();
    assert(sound.rows.items[0] == row);
    assert(@abs(service.state(.output).?.percent - 47) < 0.01);
    assert(@abs(c.gtk_range_get_value(cast(c.GtkRange, controls.volume)) - 47) < 0.01);
    c.gtk_toggle_button_set_active(cast(c.GtkToggleButton, sound.rows.items[1].mute), 1);
    deadline = c.g_get_monotonic_time() + 5_000_000;
    while ((!service.state(.input).?.muted or sound.audio_operations != 0) and c.g_get_monotonic_time() < deadline) pump();
    assert(service.state(.input).?.muted);
    const previous = service.node(.output).?.id;
    var selected: ?u32 = null;
    for (sound.rows.items) |candidate| if (candidate.default_button) |widget| {
        const id = std.fmt.parseInt(u32, candidate.id, 10) catch continue;
        const entry = service.node(.{ .id = id }) orelse continue;
        if (entry.class == .output and id != previous) {
            selected = id;
            c.gtk_button_clicked(cast(c.GtkButton, widget));
            break;
        }
    };
    assert(selected != null);
    deadline = c.g_get_monotonic_time() + 5_000_000;
    while ((service.node(.output).?.id != selected.? or sound.audio_operations != 0) and c.g_get_monotonic_time() < deadline) pump();
    assert(service.node(.output).?.id == selected.?);
    c.g_print("PASS native quick-settings sliders, sound rows, mute and default-device controls\n");
}
pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const args = try init.minimal.args.toSlice(arena.allocator());
    if (args.len < 2) return error.ExpectedCommand;
    watch = std.mem.eql(u8, args[1], "watch");
    const service = try audio.Service.create(&changed, null);
    defer {
        service.destroy();
        audio.dispatch();
    }
    if (watch) {
        try dump(service);
        const term = c.g_unix_signal_add(c.SIGTERM, &stop, null);
        defer _ = c.g_source_remove(term);
        while (!stopping) _ = c.g_main_context_iteration(null, 1);
        return;
    }
    if (std.mem.eql(u8, args[1], "dispose")) return;
    try ready(service);
    if (std.mem.eql(u8, args[1], "feedback") and args.len == 3) {
        var player = audio.Feedback{};
        defer player.deinit();
        const path = try arena.allocator().dupeSentinel(u8, args[2], 0);
        player.play(path);
        assert(player.playing());
        const start_time = c.g_get_monotonic_time();
        while (c.g_get_monotonic_time() < start_time + 600_000) pump();
        assert(player.playing()); // The two-second stream is still delivering audio.
        player.play(path); // Repeated volume keys keep the existing sound.
        while (c.g_get_monotonic_time() < start_time + 2_300_000) pump();
        assert(!player.playing());
        c.g_print("PASS native event-sound playback without overlap\n");
        return;
    }
    if (std.mem.eql(u8, args[1], "list")) return dump(service);
    if (std.mem.eql(u8, args[1], "ui")) return ui(service);
    if (std.mem.eql(u8, args[1], "burst")) {
        _ = try apply(service, .output, .{ .volume = 100 });
        for (0..12) |_| _ = try apply(service, .output, .{ .step = -5 });
        assert(@abs(service.state(.output).?.percent - 40) < 0.01);
        c.g_print("PASS serialized native volume steps preserve every key press\n");
        return;
    }
    if (std.mem.eql(u8, args[1], "cancel")) {
        const cancel = c.g_cancellable_new().?;
        defer c.g_object_unref(cancel);
        var completion = Completion{};
        service.apply(.output, .{ .volume = 25 }, cancel, &Completion.done, &completion);
        c.g_cancellable_cancel(cancel);
        const deadline = c.g_get_monotonic_time() + 6_000_000;
        while (completion.result == null and c.g_get_monotonic_time() < deadline) pump();
        assert(completion.result != null and completion.result.? == .failure);
        c.g_print("PASS pending native audio cancellation\n");
        return;
    }
    if (args.len < 4) return error.ExpectedTargetAndChange;
    const target = try audio.target(args[2]);
    const change: audio.Change = if (std.mem.eql(u8, args[3], "volume") and args.len == 5) .{ .volume = try std.fmt.parseFloat(f64, args[4]) } else if (std.mem.eql(u8, args[3], "step") and args.len == 5) .{ .step = try std.fmt.parseInt(i16, args[4], 10) } else if (std.mem.eql(u8, args[3], "mute") and args.len == 5) .{ .mute = std.mem.eql(u8, args[4], "1") } else if (std.mem.eql(u8, args[3], "toggle")) .toggle else if (std.mem.eql(u8, args[3], "default")) .default else return error.InvalidChange;
    const result = try apply(service, target, change);
    c.g_print("%.3f %d\n", result.percent, @as(c_int, @intFromBool(result.muted)));
}
