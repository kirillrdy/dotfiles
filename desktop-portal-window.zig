//! Parent native portal dialogs to exported application windows.
const std = @import("std");
const c = @import("gtk");
fn cast(comptime T: type, ptr: anytype) *T {
    return @ptrCast(@alignCast(ptr));
}
pub fn parentTo(widget: *c.GtkWidget, allocator: std.mem.Allocator, parent: [:0]const u8) void {
    const display = c.gdk_display_get_default();
    const window = c.gtk_widget_get_window(widget) orelse return;
    if (std.mem.startsWith(u8, parent, "wayland:") and c.g_type_check_instance_is_a(cast(c.GTypeInstance, display), c.gdk_wayland_display_get_type()) != 0) {
        const handle = allocator.dupeSentinel(u8, parent[8..], 0) catch return;
        defer allocator.free(handle);
        _ = c.gdk_wayland_window_set_transient_for_exported(window, handle);
    } else if (std.mem.startsWith(u8, parent, "x11:") and c.g_type_check_instance_is_a(cast(c.GTypeInstance, display), c.gdk_x11_display_get_type()) != 0) {
        const xid = std.fmt.parseInt(c_ulong, parent[4..], 16) catch return;
        if (xid == 0) return;
        const foreign = c.gdk_x11_window_foreign_new_for_display(display, xid) orelse return;
        defer c.g_object_unref(foreign);
        c.gdk_window_set_transient_for(window, foreign);
    }
}
