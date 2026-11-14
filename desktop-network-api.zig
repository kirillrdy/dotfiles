//! GIO ABI used by the native NetworkManager client; checked against gio/gio.h.
const c = @import("desktop-gtk.zig");
pub const GDBusObjectManager = opaque {};
pub const GDBusObjectManagerClient = opaque {};
pub const GDBusObject = opaque {};
pub const GDBusInterface = opaque {};
pub const GDBusObjectManagerClientFlags = c_uint;
pub const GDBusProxyTypeFunc = ?*const fn (?*GDBusObjectManagerClient, [*c]const u8, [*c]const u8, c.gpointer) callconv(.c) c.GType;
pub extern fn g_dbus_object_manager_client_new_for_bus(c.GBusType, GDBusObjectManagerClientFlags, [*c]const u8, [*c]const u8, GDBusProxyTypeFunc, c.gpointer, c.GDestroyNotify, [*c]c.GCancellable, c.GAsyncReadyCallback, c.gpointer) void;
pub extern fn g_dbus_object_manager_client_new_for_bus_finish(?*c.GAsyncResult, [*c][*c]c.GError) ?*GDBusObjectManager;
pub extern fn g_dbus_object_manager_client_get_name_owner(*GDBusObjectManagerClient) [*c]u8;
pub extern fn g_dbus_object_manager_client_get_connection(*GDBusObjectManagerClient) ?*c.GDBusConnection;
pub extern fn g_dbus_object_manager_get_objects(*GDBusObjectManager) [*c]c.GList;
pub extern fn g_dbus_object_manager_get_object(*GDBusObjectManager, [*c]const u8) ?*GDBusObject;
pub extern fn g_dbus_object_get_object_path(*GDBusObject) [*c]const u8;
pub extern fn g_dbus_object_get_interface(*GDBusObject, [*c]const u8) ?*GDBusInterface;
pub extern fn g_dbus_proxy_call(*c.GDBusProxy, [*c]const u8, ?*c.GVariant, c.GDBusCallFlags, c_int, [*c]c.GCancellable, c.GAsyncReadyCallback, c.gpointer) void;
pub extern fn g_dbus_proxy_call_finish(*c.GDBusProxy, ?*c.GAsyncResult, [*c][*c]c.GError) ?*c.GVariant;
