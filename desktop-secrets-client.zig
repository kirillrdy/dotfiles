//! Lock client uses a nonactivating call: it must work without a Secret Service.
const c = @import("desktop-gtk.zig");
const std = @import("std");
const name = "org.freedesktop.secrets";
const root = "/org/freedesktop/secrets";
pub fn screenLocked(locked: bool) void {
    const bus = c.g_bus_get_sync(c.G_BUS_TYPE_SESSION, null, null) orelse return;
    defer c.g_object_unref(bus);
    const reply = c.g_dbus_connection_call_sync(bus, name, root, "org.dotfiles.Desktop.Secrets", "SetScreenLocked", c.g_variant_new("(b)", @as(c_int, @intFromBool(locked))), null, c.G_DBUS_CALL_FLAGS_NO_AUTO_START, 3000, null, null) orelse return;
    c.g_variant_unref(reply);
}
pub fn unlock(password: []const u8) void {
    const bus = c.g_bus_get_sync(c.G_BUS_TYPE_SESSION, null, null) orelse return;
    defer c.g_object_unref(bus);
    const bytes = c.g_variant_new_fixed_array(@ptrCast(@as([*:0]const u8, "y")), password.ptr, password.len, 1);
    const reply = c.g_dbus_connection_call_sync(bus, name, root, "org.dotfiles.Desktop.Secrets", "LoginUnlock", c.g_variant_new("(@ay)", bytes), null, c.G_DBUS_CALL_FLAGS_NO_AUTO_START, 30000, null, null) orelse return;
    c.g_variant_unref(reply);
}
