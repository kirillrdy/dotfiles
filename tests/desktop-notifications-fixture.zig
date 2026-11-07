//! Standalone notification service for private headless D-Bus/input tests.
const std = @import("std");
const desktop = @import("desktop");
const c = desktop.gtk;
fn quit(_: ?*anyopaque) callconv(.c) c.gboolean {
    c.gtk_main_quit();
    return 1;
}
var open_timer: c.guint = 0;
fn openDateMenu(ptr: c.gpointer) callconv(.c) c.gboolean {
    const module: *desktop.widgets.Module = @ptrCast(@alignCast(ptr));
    if (module.session == null) return 1;
    var event = std.mem.zeroes(c.GdkEventButton);
    event.button = 1;
    _ = desktop.widgets.clock_click(null, &event, module);
    open_timer = 0;
    return 0;
}
fn runDateMenu() void {
    const window = c.gtk_window_new(c.GTK_WINDOW_TOPLEVEL).?;
    c.gtk_window_set_title(@ptrCast(window), "Date menu test");
    c.gtk_window_set_decorated(@ptrCast(window), 0);
    c.gtk_window_set_default_size(@ptrCast(window), 160, 32);
    c.gtk_window_set_position(@ptrCast(window), c.GTK_WIN_POS_CENTER);
    const root = c.gtk_event_box_new().?;
    c.gtk_container_add(@ptrCast(window), root);
    const module = desktop.widgets.init(root, .{ .kind = "clock" });
    c.gtk_widget_show_all(window);
    open_timer = c.g_timeout_add(100, &openDateMenu, module);
    c.gtk_main();
    if (open_timer != 0) _ = c.g_source_remove(open_timer);
    desktop.widgets.deinit(module);
    c.gtk_widget_destroy(window);
    const deadline = c.g_get_monotonic_time() + 100_000;
    while (c.g_get_monotonic_time() < deadline) {
        while (c.g_main_context_iteration(null, 0) != 0) {}
        c.g_usleep(1000);
    }
}
pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const args = try init.minimal.args.toSlice(arena.allocator());
    if (args.len > 3) return error.InvalidArguments;
    c.gtk_init(null, null);
    const service = try desktop.notifications.Service.create();
    defer service.destroy();
    const signal = c.g_unix_signal_add(15, &quit, null);
    defer _ = c.g_source_remove(signal);
    if (args.len > 1 and std.mem.eql(u8, args[args.len - 1], "date-menu")) runDateMenu() else c.gtk_main();
}
