//! Test-only sysfs injection. Production always reads the fixed kernel paths.
const std = @import("std");
const c = @import("gtk");
const battery = @import("battery");
const quick = @import("quick");
const data = @import("panel-data");
const a = std.heap.page_allocator;
var stopping = false;
var latest: battery.State = .{};
var controls: ?*quick.Controls = null;
var last: ?[]u8 = null;
var alerts = battery.Alerts{};
fn changed(_: ?*anyopaque, state: battery.State) void {
    latest = state;
    if (alerts.update(state)) |level| battery.notifyWarning(level);
}
fn stop(_: ?*anyopaque) callconv(.c) c_int {
    stopping = true;
    return 1;
}
fn report(_: ?*anyopaque) callconv(.c) c_int {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    const info = data.batteryInfo(alloc, latest) catch unreachable;
    const json = std.json.Stringify.valueAlloc(alloc, .{
        .visible = if (controls) |ui| c.gtk_widget_get_visible(ui.battery) != 0 else latest.visible(),
        .text = if (controls) |ui| std.mem.span(c.gtk_label_get_text(@ptrCast(ui.battery_label))) else "",
        .present = latest.present,
        .percent = if (latest.visible()) @as(?f64, latest.percent) else null,
        .state = latest.state,
        .on_battery = latest.on_battery,
        .icon = info.icon,
        .duration = info.label,
        .time_to_empty = latest.time_to_empty,
        .time_to_full = latest.time_to_full,
        .energy = latest.energy,
        .energy_full = latest.energy_full,
        .energy_rate = latest.energy_rate,
        .charge_threshold = latest.charge_threshold,
        .warning = @backingInt(latest.warning()),
    }, .{}) catch unreachable;
    if (last == null or !std.mem.eql(u8, last.?, json)) {
        if (last) |old| a.free(old);
        last = a.dupe(u8, json) catch unreachable;
        const terminated = alloc.dupeSentinel(u8, json, 0) catch unreachable;
        c.g_print("%s\n", terminated.ptr);
    }
    return 1;
}
pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    defer if (last) |old| a.free(old);
    const args = try init.minimal.args.toSlice(arena.allocator());
    if (args.len != 3) return error.ExpectedModeAndFixtureRoot;
    const root = try arena.allocator().dupeSentinel(u8, args[2], 0);
    const options = battery.Options{ .backend = .{ .root = root }, .poll_ms = 100, .events = false };
    if (std.mem.eql(u8, args[1], "--read")) {
        latest = options.backend.read();
        _ = report(null);
        return;
    }
    if (std.mem.eql(u8, args[1], "--monitor")) {
        var checked: std.heap.DebugAllocator(.{}) = .init;
        defer if (checked.deinit() == .leak) @panic("battery monitor allocation leak");
        const lid = try std.fmt.allocPrintSentinel(arena.allocator(), "{s}/../lid", .{root}, 0);
        try @import("battery-monitor").runWithOptions(.{ .source = options, .lid_root = lid, .action_delay_us = 750000 }, checked.allocator());
        return;
    }
    if (c.gtk_init_check(null, null) == 0) return error.NoDisplay;
    const window = c.gtk_window_new(c.GTK_WINDOW_TOPLEVEL);
    defer c.gtk_widget_destroy(window);
    const button = c.gtk_button_new();
    c.gtk_container_add(@ptrCast(window), button);
    const popover = c.gtk_popover_new(button).?;
    controls = quick.Controls.create(popover, "true", "true");
    controls.?.monitorBattery(options);
    const service = try battery.Service.createWithOptions(options, &changed, null);
    if (std.mem.eql(u8, args[1], "--dispose")) {
        controls.?.deinit();
        service.destroy();
        const deadline = c.g_get_monotonic_time() + 500000;
        while (c.g_get_monotonic_time() < deadline) {
            while (c.g_main_context_iteration(null, 0) != 0) {}
            c.g_usleep(1000);
        }
        return;
    }
    const timer = c.g_timeout_add(20, &report, null);
    const term = c.g_unix_signal_add(c.SIGTERM, &stop, null);
    while (!stopping) _ = c.g_main_context_iteration(null, 1);
    _ = c.g_source_remove(timer);
    _ = c.g_source_remove(term);
    service.stop();
    while (service.pending) _ = c.g_main_context_iteration(null, 1);
    service.destroy();
    controls.?.deinit();
    const deadline = c.g_get_monotonic_time() + 250000;
    while (c.g_get_monotonic_time() < deadline) {
        while (c.g_main_context_iteration(null, 0) != 0) {}
        c.g_usleep(1000);
    }
}
