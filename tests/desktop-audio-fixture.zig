//! Native audio commands and raster control integration against an isolated PipeWire server.
const std = @import("std");
const mainloop = @import("desktop").mainloop;
const util = @import("desktop").util;
const audio = @import("desktop").audio;
const quick = @import("desktop").quick;
const settings = @import("desktop").settings;
const assert = std.debug.assert;
var stopping = false;
var watch = false;
const cast = util.cast;
fn pump() void {
    audio.dispatch();
    mainloop.sleep(1000);
}
fn stop(_: void) bool {
    stopping = true;
    return true;
}
fn changed(_: ?*anyopaque, service: *audio.Service) void {
    if (watch) dump(service) catch @panic("dump failed");
}
fn dump(service: *audio.Service) !void {
    var arena = std.heap.ArenaAllocator.init(service.allocator);
    defer arena.deinit();
    const View = struct { id: u32, class: audio.Class, name: []const u8, state: ?audio.State, is_default: bool };
    const nodes = try arena.allocator().alloc(View, service.nodes.items.len);
    for (service.nodes.items, nodes) |*entry, *view| view.* = .{ .id = entry.id, .class = entry.class, .name = std.mem.sliceTo(&entry.name, 0), .state = entry.state, .is_default = entry.is_default };
    const json = try std.json.Stringify.valueAlloc(arena.allocator(), .{ .ready = service.ready, .nodes = nodes }, .{});
    const text = try arena.allocator().dupeSentinel(u8, json, 0);
    @import("desktop").util.printOut("{s}\n", .{text});
}
const Completion = struct {
    result: ?audio.Result = null,
    fn done(ptr: ?*anyopaque, result: audio.Result) void {
        cast(Completion, ptr).result = result;
    }
};
fn apply(service: *audio.Service, target: audio.Target, change: audio.Change) !audio.State {
    const cancel = mainloop.Cancellable.create();
    defer cancel.unref();
    var completion = Completion{};
    service.apply(target, change, cancel, &Completion.done, &completion);
    const deadline = util.monotonicTime() + 6_000_000;
    while (completion.result == null and util.monotonicTime() < deadline) pump();
    const result = completion.result orelse return error.AudioOperationHung;
    return switch (result) {
        .value => |value| value,
        .failure => |err| err,
    };
}
fn ready(service: *audio.Service) !void {
    const deadline = util.monotonicTime() + 8_000_000;
    while ((!service.ready or service.nodes.items.len < 3 or service.state(.output) == null or service.state(.input) == null) and util.monotonicTime() < deadline) pump();
    if (!service.ready or service.state(.output) == null or service.state(.input) == null) return error.AudioNeverReady;
}
fn click(sound: *settings.Sound, row: usize, control: @import("desktop").settings.SoundControl) void {
    const rect = sound.view.rect(.{ .row = row, .control = control });
    sound.pointerButton(true, rect.x + rect.width / 2, rect.y + rect.height / 2);
    sound.pointerButton(false, rect.x + rect.width / 2, rect.y + rect.height / 2);
}
fn ui(service: *audio.Service, io: std.Io) !void {
    const controls = quick.Controls.create(service.allocator, "true", "true");
    var dialogs: settings.Service = .{ .allocator = service.allocator, .io = io };
    defer {
        controls.deinit();
        dialogs.deinit();
    }
    try dialogs.show(.sound);
    const shell = dialogs.windows.items[0];
    const sound = shell.sound.?;
    // Both shortcuts must reuse one native window and its audio controller.
    try dialogs.show(.network);
    assert(dialogs.windows.items.len == 1 and shell.mode == .network);
    shell.showPage(.wifi);
    shell.ui.activate(shell.view.sound_nav);
    assert(shell.mode == .sound and shell.sound.? == sound);
    try dialogs.show(.network);
    try dialogs.show(.sound);
    assert(dialogs.windows.items.len == 1 and shell.window == sound.window);
    var deadline = util.monotonicTime() + 8_000_000;
    while ((controls.devices.audio_service == null or controls.devices.audio_service.?.state(.output) == null or sound.view.rows.items.len < 5) and util.monotonicTime() < deadline) pump();
    assert(sound.view.rows.items.len >= 5);
    assert(controls.view.model.volume != null);
    controls.setSlider(.volume, 63);
    deadline = util.monotonicTime() + 5_000_000;
    while ((controls.volume_timer != 0 or @abs((service.state(.output) orelse return error.NoOutput).percent - 63) > 0.01) and util.monotonicTime() < deadline) pump();
    assert(@abs(service.state(.output).?.percent - 63) < 0.01);
    // Rows survive volume-only changes, so dragging cannot target a freed row.
    const row = sound.view.rows.items.ptr;
    sound.setVolume(0, 47);
    deadline = util.monotonicTime() + 5_000_000;
    while ((sound.timer != 0 or sound.operations != 0 or @abs(service.state(.output).?.percent - 47) > 0.01) and util.monotonicTime() < deadline) pump();
    assert(sound.view.rows.items.ptr == row);
    assert(@abs(service.state(.output).?.percent - 47) < 0.01);
    assert(@abs(controls.view.model.volume.? - 47) < 0.01);
    click(sound, 1, .mute);
    deadline = util.monotonicTime() + 5_000_000;
    while ((!service.state(.input).?.muted or sound.operations != 0) and util.monotonicTime() < deadline) pump();
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
    deadline = util.monotonicTime() + 5_000_000;
    while ((service.node(.output).?.id != selected.? or sound.operations != 0) and util.monotonicTime() < deadline) pump();
    assert(service.node(.output).?.id == selected.?);
    deadline = util.monotonicTime() + 5_000_000;
    while ((sound.timer != 0 or sound.operations != 0 or @abs(service.state(.{ .id = previous }).?.percent - 52) > 0.01) and util.monotonicTime() < deadline) pump();
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
        deadline = util.monotonicTime() + 5_000_000;
        while ((sound.operations != 0 or @abs((service.state(.{ .id = id }) orelse return error.MissingStream).percent - 50) > 0.01) and util.monotonicTime() < deadline) pump();
        assert(@abs(service.state(.{ .id = id }).?.percent - 50) < 0.01);
        const muted = service.state(.{ .id = id }).?.muted;
        click(sound, index, .mute);
        deadline = util.monotonicTime() + 5_000_000;
        while ((sound.operations != 0 or service.state(.{ .id = id }).?.muted == muted) and util.monotonicTime() < deadline) pump();
        assert(service.state(.{ .id = id }).?.muted != muted);
    }
    assert(application_classes == 3);
    assert(sound.handleKey(0xff1b, 0));
    assert(sound.view.page == .sound and !sound.closed);
    // Keyboard input uses the same path as native Wayland key events.
    sound.view.focus = null;
    assert(sound.handleKey(0xff09, 0)); // Tab to the output slider.
    assert(sound.view.focus.?.row == 0 and sound.view.focus.?.control == .volume);
    assert(sound.handleKey(0xff50, 0)); // Home clamps to zero.
    assert(sound.handleKey(0xff53, 0)); // Right increases by five.
    deadline = util.monotonicTime() + 5_000_000;
    while ((sound.timer != 0 or sound.operations != 0 or @abs(service.state(.output).?.percent - 5) > 0.01) and util.monotonicTime() < deadline) pump();
    assert(@abs(service.state(.output).?.percent - 5) < 0.01);
    // A pointer press/release on the track sets volume through native hit testing.
    click(sound, 0, .volume);
    deadline = util.monotonicTime() + 5_000_000;
    while ((sound.operations != 0 or @abs(service.state(.output).?.percent - 50) > 0.01) and util.monotonicTime() < deadline) pump();
    assert(@abs(service.state(.output).?.percent - 50) < 0.01);
    click(sound, 0, .test_sound);
    assert(sound.feedback.playing());
    // Closing with a debounced write must remove its timeout and drain callbacks.
    sound.setVolume(0, 33);
    assert(sound.timer != 0);
    sound.activate(.{ .control = .mute });
    assert(sound.operations != 0);
    sound.close();
    while (!sound.closed) pump();
    assert(sound.closed and sound.timer == 0);
    @import("desktop").util.printOut("PASS native sound pointer, keyboard, volume, mute, defaults and pending-close controls\n", .{});
}
pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const args = try init.minimal.args.toSlice(arena.allocator());
    if (args.len < 2) return error.ExpectedCommand;
    watch = std.mem.eql(u8, args[1], "watch");
    const service = try audio.Service.create(init.gpa, &changed, null);
    defer {
        service.destroy();
        audio.dispatch();
    }
    if (watch) {
        try dump(service);
        const term = mainloop.signal(mainloop.SIGTERM, {}, stop);
        defer _ = mainloop.remove(term);
        while (!stopping) _ = mainloop.iteration(true);
        return;
    }
    if (std.mem.eql(u8, args[1], "dispose")) return;
    try ready(service);
    if (std.mem.startsWith(u8, args[1], "preview")) {
        const shell = settings.Settings.create(init.gpa, init.io, .sound);
        const sound = shell.sound.?;
        defer {
            shell.ui.close();
            while (!shell.closed) pump();
            while (sound.operations != 0 or shell.network_operations != 0) pump();
            shell.destroy();
        }
        const deadline = util.monotonicTime() + 5_000_000;
        while ((sound.service == null or sound.service.?.state(.output) == null) and util.monotonicTime() < deadline) pump();
        if (std.mem.eql(u8, args[1], "preview-levels")) sound.showPage(.levels);
        if (std.mem.eql(u8, args[1], "preview-devices")) sound.activate(.{ .control = .device });
        while (!sound.closed) _ = mainloop.iteration(true);
        return;
    }
    if (std.mem.eql(u8, args[1], "feedback") and args.len == 3) {
        var player = audio.Feedback{ .allocator = init.gpa };
        defer player.deinit();
        const path = try arena.allocator().dupeSentinel(u8, args[2], 0);
        player.play(path);
        assert(player.playing());
        const start_time = util.monotonicTime();
        while (util.monotonicTime() < start_time + 600_000) pump();
        assert(player.playing()); // The two-second stream is still delivering audio.
        player.play(path); // Repeated volume keys keep the existing sound.
        while (util.monotonicTime() < start_time + 2_300_000) pump();
        assert(!player.playing());
        @import("desktop").util.printOut("PASS native event-sound playback without overlap\n", .{});
        return;
    }
    if (std.mem.eql(u8, args[1], "list")) return dump(service);
    if (std.mem.eql(u8, args[1], "ui")) return ui(service, init.io);
    if (std.mem.eql(u8, args[1], "burst")) {
        _ = try apply(service, .output, .{ .volume = 100 });
        for (0..12) |_| _ = try apply(service, .output, .{ .step = -5 });
        assert(@abs(service.state(.output).?.percent - 40) < 0.01);
        @import("desktop").util.printOut("PASS serialized native volume steps preserve every key press\n", .{});
        return;
    }
    if (std.mem.eql(u8, args[1], "cancel")) {
        const cancel = mainloop.Cancellable.create();
        defer cancel.unref();
        var completion = Completion{};
        service.apply(.output, .{ .volume = 25 }, cancel, &Completion.done, &completion);
        cancel.cancel();
        const deadline = util.monotonicTime() + 6_000_000;
        while (completion.result == null and util.monotonicTime() < deadline) pump();
        assert(completion.result != null and completion.result.? == .failure);
        @import("desktop").util.printOut("PASS pending native audio cancellation\n", .{});
        return;
    }
    if (args.len < 4) return error.ExpectedTargetAndChange;
    const target = try audio.target(args[2]);
    const change: audio.Change = if (std.mem.eql(u8, args[3], "volume") and args.len == 5) .{ .volume = try std.fmt.parseFloat(f64, args[4]) } else if (std.mem.eql(u8, args[3], "step") and args.len == 5) .{ .step = try std.fmt.parseInt(i16, args[4], 10) } else if (std.mem.eql(u8, args[3], "mute") and args.len == 5) .{ .mute = std.mem.eql(u8, args[4], "1") } else if (std.mem.eql(u8, args[3], "toggle")) .toggle else if (std.mem.eql(u8, args[3], "default")) .default else return error.InvalidChange;
    const result = try apply(service, target, change);
    @import("desktop").util.printOut("{d:.3} {d}\n", .{ result.percent, @intFromBool(result.muted) });
}
