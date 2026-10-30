//! Parent native portal dialogs to exported application windows.
const std = @import("std");
const c = @import("gtk");
const cast = c.__zig.cast;
pub fn parentTo(widget: *c.GtkWidget, allocator: std.mem.Allocator, parent: [:0]const u8) void {
    const display = c.gdk_display_get_default();
    const window = c.gtk_widget_get_window(widget) orelse return;
    if (std.mem.startsWith(u8, parent, "wayland:") and c.g_type_check_instance_is_a(cast(c.GTypeInstance, display), c.gdk_wayland_display_get_type()) != 0) {
        const handle = allocator.dupeSentinel(u8, parent[8..], 0) catch return;
        defer allocator.free(handle);
        _ = c.gdk_wayland_window_set_transient_for_exported(window, handle);
    }
}
