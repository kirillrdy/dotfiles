//! Native Wayland windows for private compositor tests.
const std = @import("std");
const c = @import("gtk");
fn cast(comptime T: type, p: anytype) *T {
    return @ptrCast(@alignCast(p));
}
fn activeChanged(object: *c.GObject, _: ?*c.GParamSpec, _: ?*anyopaque) callconv(.c) void {
    const window = cast(c.GtkWindow, object);
    if (c.gtk_window_is_active(window) != 0) {
        c.g_print("%lld %s\n", @as(c_longlong, c.g_get_monotonic_time()), c.gtk_window_get_title(window));
    }
}
fn quit(_: ?*c.GtkWidget, _: ?*anyopaque) callconv(.c) void {
    c.gtk_main_quit();
}
pub fn main(init: std.process.Init) !void {
    const a = std.heap.page_allocator;
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 3) return error.InvalidArguments;
    c.g_set_prgname(args[1]);
    c.gtk_init(null, null);
    const window = c.gtk_window_new(c.GTK_WINDOW_TOPLEVEL);
    c.gtk_window_set_title(cast(c.GtkWindow, window), args[2]);
    c.gtk_window_set_default_size(cast(c.GtkWindow, window), 640, 420);
    c.gtk_container_add(cast(c.GtkContainer, window), c.gtk_label_new(args[2]));
    _ = c.g_signal_connect_data(window, "notify::is-active", @ptrCast(&activeChanged), null, null, 0);
    _ = c.g_signal_connect_data(window, "destroy", @ptrCast(&quit), null, null, 0);
    c.gtk_widget_realize(window);
    c.gdk_wayland_window_set_application_id(c.gtk_widget_get_window(window), args[1]);
    c.gtk_widget_show_all(window);
    c.gtk_main();
}
