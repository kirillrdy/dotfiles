//! Native capture background; consent is exercised with real Wayland input.
const std = @import("std");
const desktop = @import("desktop");
const wire = @import("desktop").window.wire;
const c = desktop.glib;
var background: ?*wire.Client = null;
var color = [3]f64{ 1, 0, 0 };
fn draw(_: ?*anyopaque, target: wire.Pixels) void {
    var pixel: u32 = 0xff000000;
    for (color, [_]u5{ 16, 8, 0 }) |value, shift| pixel |= @as(u32, @intFromFloat(@round(std.math.clamp(value, 0, 1) * 255))) << shift;
    @memset(target.pixels, pixel);
}
fn added(_: ?*anyopaque, output: *wire.Output) void {
    const surface = wire.Surface.createPixels(output, .{ .namespace = "capture-fixture", .layer = 0, .anchors = wire.top | wire.bottom | wire.left | wire.right }, &draw, null) catch @panic("background allocation");
    surface.show() catch @panic("background surface");
}
fn removed(_: ?*anyopaque, _: *wire.Output) void {}
fn method(_: ?*c.GDBusConnection, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, params: ?*c.GVariant, invocation: ?*c.GDBusMethodInvocation, _: ?*anyopaque) callconv(.c) void {
    for (0..3) |i| {
        const value = c.g_variant_get_child_value(params, i);
        color[i] = c.g_variant_get_double(value);
        c.g_variant_unref(value);
    }
    if (background == null) {
        background = wire.Client.create(.{ .added = &added, .removed = &removed }, null) catch @panic("background client");
        background.?.start() catch @panic("background dispatch");
    }
    for (background.?.surfaces.items) |surface| surface.redraw();
    c.g_dbus_method_invocation_return_value(invocation, null);
}
const vtable = c.GDBusInterfaceVTable{ .method_call = &method };
pub fn main() !void {
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer if (allocator.deinit() == .leak) @panic("portal allocation leak");
    const connection = c.g_bus_get_sync(c.G_BUS_TYPE_SESSION, null, null) orelse return error.NoBus;
    defer c.g_object_unref(connection);
    const node = c.g_dbus_node_info_new_for_xml("<node><interface name='org.dotfiles.CaptureFixture'><method name='Color'><arg type='d' direction='in'/><arg type='d' direction='in'/><arg type='d' direction='in'/></method></interface></node>", null) orelse return error.InvalidXml;
    defer c.g_dbus_node_info_unref(node);
    const registration = if (c.g_getenv("DESKTOP_PORTAL_FIXTURE_CAPTURE") != null) c.g_dbus_connection_register_object(connection, "/org/dotfiles/CaptureFixture", node.*.interfaces[0], &vtable, null, null, null) else 0;
    defer {
        if (registration != 0) _ = c.g_dbus_connection_unregister_object(connection, registration);
    }
    defer if (background) |client| client.destroy();
    try desktop.portal.runWithAllocator(allocator.allocator());
}
