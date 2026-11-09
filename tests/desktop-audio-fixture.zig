//! Native audio commands and raster control integration against an isolated PipeWire server.
const std = @import("std");
const c = @import("desktop").gtk;
const audio = @import("desktop").audio;
const quick = @import("desktop").quick;
const settings = quick.settings_client;
const assert = std.debug.assert;
const a = std.heap.page_allocator;
var stopping = false;
var watch = false;
const cast = c.__zig.cast;
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
fn click(sound: *settings.Sound, row: usize, control: @import("desktop").settings.SoundControl) void {
    const rect = sound.view.rect(.{ .row = row, .control = control });
    var event = std.mem.zeroes(c.GdkEventButton);
    event.type = c.GDK_BUTTON_PRESS;
    event.button = 1;
    event.x = rect.x + rect.width / 2;
    event.y = rect.y + rect.height / 2;
    var handled: c.gboolean = 0;
    c.g_signal_emit_by_name(sound.canvas, "button-press-event", &event, &handled);
    assert(handled != 0);
    event.type = 7;
    c.g_signal_emit_by_name(sound.canvas, "button-release-event", &event, &handled);
    assert(handled != 0);
}
fn ui(service: *audio.Service) !void {
    if (c.gtk_init_check(null, null) == 0) return error.NoDisplay;
    const window = c.gtk_window_new(c.GTK_WINDOW_TOPLEVEL);
    defer c.gtk_widget_destroy(window);
    const button = c.gtk_button_new();
    c.gtk_container_add(cast(c.GtkContainer, window), button);
    const controls = quick.Controls.create(c.gtk_popover_new(button).?, "true", "true");
    const sound = try settings.Sound.create();
    defer {
        if (!sound.closed) c.gtk_widget_destroy(sound.window);
        controls.deinit();
        while (sound.operations != 0) pump();
        sound.destroy();
    }
    var deadline = c.g_get_monotonic_time() + 8_000_000;
    while ((controls.devices.audio_service == null or controls.devices.audio_service.?.state(.output) == null or sound.view.rows.items.len < 5) and c.g_get_monotonic_time() < deadline) pump();
    assert(sound.view.rows.items.len >= 5);
    assert(controls.view.model.volume != null);
    controls.setSlider(.volume, 63);
    deadline = c.g_get_monotonic_time() + 5_000_000;
    while ((controls.volume_timer != 0 or @abs((service.state(.output) orelse return error.NoOutput).percent - 63) > 0.01) and c.g_get_monotonic_time() < deadline) pump();
    assert(@abs(service.state(.output).?.percent - 63) < 0.01);
    // Rows survive volume-only changes, so dragging cannot target a freed row.
    const row = sound.view.rows.items.ptr;
    sound.setVolume(0, 47);
    deadline = c.g_get_monotonic_time() + 5_000_000;
    while ((sound.timer != 0 or sound.operations != 0 or @abs(service.state(.output).?.percent - 47) > 0.01) and c.g_get_monotonic_time() < deadline) pump();
    assert(sound.view.rows.items.ptr == row);
    assert(@abs(service.state(.output).?.percent - 47) < 0.01);
    assert(@abs(controls.view.model.volume.? - 47) < 0.01);
    click(sound, 1, .mute);
    deadline = c.g_get_monotonic_time() + 5_000_000;
    while ((!service.state(.input).?.muted or sound.operations != 0) and c.g_get_monotonic_time() < deadline) pump();
    assert(service.state(.input).?.muted);
    const previous = service.node(.output).?.id;
    var selected: ?u32 = null;
    sound.setVolume(0, 52); // This pending write belongs to the current device.
    click(sound, 0, .device);
    assert(sound.view.expanded == 0);
    for (sound.view.rows.items, 0..) |candidate, index| {
        if (!candidate.device or candidate.target != .id) continue;
        const id = candidate.target.id;
        const entry = service.node(.{ .id = id }) orelse continue;
        if (entry.class == .output and id != previous) {
            selected = id;
            click(sound, index, .default);
            break;
        }
    }
    assert(selected != null);
    deadline = c.g_get_monotonic_time() + 5_000_000;
    while ((service.node(.output).?.id != selected.? or sound.operations != 0) and c.g_get_monotonic_time() < deadline) pump();
    assert(service.node(.output).?.id == selected.?);
    deadline = c.g_get_monotonic_time() + 5_000_000;
    while ((sound.timer != 0 or sound.operations != 0 or @abs(service.state(.{ .id = previous }).?.percent - 52) > 0.01) and c.g_get_monotonic_time() < deadline) pump();
    assert(@abs(service.state(.{ .id = previous }).?.percent - 52) < 0.01);
    assert(sound.view.expanded == null);
    // The device selector also opens, navigates and dismisses through the keyboard.
    sound.view.focus = .{ .control = .device };
    assert(sound.handleKey(0xff0d, 0));
    assert(sound.view.expanded == 0);
    assert(sound.handleKey(0xff50, 0));
    assert(sound.handleKey(0xff54, 0));
    assert(sound.view.option_cursor == 1);
    assert(sound.handleKey(0xff1b, 0));
    assert(sound.view.expanded == null and !sound.closed);
    click(sound, 0, .levels);
    assert(sound.view.page == .levels);
    var application_classes: u8 = 0;
    for (sound.view.rows.items, 0..) |candidate, index| {
        if (candidate.state == null or (candidate.class != .playback and candidate.class != .recording)) continue;
        application_classes |= if (candidate.class == .playback) @as(u8, 1) else 2;
        const id = candidate.target.id;
        click(sound, index, .volume);
        deadline = c.g_get_monotonic_time() + 5_000_000;
        while ((sound.operations != 0 or @abs((service.state(.{ .id = id }) orelse return error.MissingStream).percent - 50) > 0.01) and c.g_get_monotonic_time() < deadline) pump();
        assert(@abs(service.state(.{ .id = id }).?.percent - 50) < 0.01);
        const muted = service.state(.{ .id = id }).?.muted;
        click(sound, index, .mute);
        deadline = c.g_get_monotonic_time() + 5_000_000;
        while ((sound.operations != 0 or service.state(.{ .id = id }).?.muted == muted) and c.g_get_monotonic_time() < deadline) pump();
        assert(service.state(.{ .id = id }).?.muted != muted);
    }
    assert(application_classes == 3);
    assert(sound.handleKey(0xff1b, 0));
    assert(sound.view.page == .sound and !sound.closed);
    // Keyboard input uses the same path as real GDK key events.
    sound.view.focus = null;
    assert(sound.handleKey(0xff09, 0)); // Tab to the output slider.
    assert(sound.view.focus.?.row == 0 and sound.view.focus.?.control == .volume);
    assert(sound.handleKey(0xff50, 0)); // Home clamps to zero.
    assert(sound.handleKey(0xff53, 0)); // Right increases by five.
    deadline = c.g_get_monotonic_time() + 5_000_000;
    while ((sound.timer != 0 or sound.operations != 0 or @abs(service.state(.output).?.percent - 5) > 0.01) and c.g_get_monotonic_time() < deadline) pump();
    assert(@abs(service.state(.output).?.percent - 5) < 0.01);
    // A pointer press/release on the track sets volume through native hit testing.
    click(sound, 0, .volume);
    deadline = c.g_get_monotonic_time() + 5_000_000;
    while ((sound.operations != 0 or @abs(service.state(.output).?.percent - 50) > 0.01) and c.g_get_monotonic_time() < deadline) pump();
    assert(@abs(service.state(.output).?.percent - 50) < 0.01);
    click(sound, 0, .test_sound);
    assert(sound.feedback.playing());
    // Closing with a debounced write must remove its timeout and drain callbacks.
    sound.setVolume(0, 33);
    assert(sound.timer != 0);
    sound.activate(.{ .control = .mute });
    assert(sound.operations != 0);
    c.gtk_widget_destroy(sound.window);
    assert(sound.closed and sound.timer == 0);
    c.g_print("PASS native sound pointer, keyboard, volume, mute, defaults and pending-close controls\n");
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
    if (std.mem.startsWith(u8, args[1], "preview")) {
        c.gtk_init(null, null);
        const sound = try settings.Sound.create();
        defer {
            if (!sound.closed) c.gtk_widget_destroy(sound.window);
            while (sound.operations != 0) pump();
            sound.destroy();
        }
        const deadline = c.g_get_monotonic_time() + 5_000_000;
        while ((sound.service == null or sound.service.?.state(.output) == null) and c.g_get_monotonic_time() < deadline) pump();
        if (std.mem.eql(u8, args[1], "preview-levels")) sound.showPage(.levels);
        if (std.mem.eql(u8, args[1], "preview-devices")) sound.activate(.{ .control = .device });
        while (!sound.closed) _ = c.g_main_context_iteration(null, 1);
        return;
    }
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
