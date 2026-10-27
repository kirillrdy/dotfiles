//! Observe the real quick-settings widgets alongside the native service under a private bus.
const std = @import("std");
const c = @import("gtk");
const battery = @import("battery");
const quick = @import("quick");
const data = @import("panel-data");
const a = std.heap.page_allocator;
var stopping = false;
var latest: battery.State = .{};
var controls: *quick.Controls = undefined;
var last: ?[]u8 = null;
fn changed(_: ?*anyopaque, state: battery.State) void {
    latest = state;
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
        .visible = c.gtk_widget_get_visible(controls.battery) != 0,
        .text = std.mem.span(c.gtk_label_get_text(@ptrCast(controls.battery_label))),
        .present = latest.visible(),
        .percent = if (latest.visible()) latest.percent else 0,
        .icon = info.icon,
        .duration = info.label,
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
    const args = try init.minimal.args.toSlice(arena.allocator());
    if (c.gtk_init_check(null, null) == 0) return error.NoDisplay;
    const window = c.gtk_window_new(c.GTK_WINDOW_TOPLEVEL);
    defer c.gtk_widget_destroy(window);
    const button = c.gtk_button_new();
    c.gtk_container_add(@ptrCast(window), button);
    const popover = c.gtk_popover_new(button).?;
    controls = quick.Controls.create(popover, "true", "true");
    const service = try battery.Service.create(&changed, null);
    if (args.len == 2 and std.mem.eql(u8, args[1], "--dispose")) {
        controls.deinit();
        service.destroy();
        const deadline = c.g_get_monotonic_time() + 500_000;
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
    service.destroy();
    controls.deinit();
    while (c.g_main_context_iteration(null, 0) != 0) {}
    if (last) |old| a.free(old);
}
