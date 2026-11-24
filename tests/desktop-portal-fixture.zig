//! Native capture background; consent is exercised with real Wayland input.
const std = @import("std");
const desktop = @import("desktop");
const wire = @import("desktop").window.wire;
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
const dbus = desktop.dbus;
const loop = desktop.dbus_loop;
var bus: ?*loop.Source = null;
fn method(_: ?*anyopaque, message: *const dbus.Message) void {
    const connection = bus.?.connection;
    const args = message.read(struct { f64, f64, f64 }) catch return connection.replyError(message, "org.freedesktop.DBus.Error.InvalidArgs", "Expected (ddd)") catch {};
    color = .{ args[0], args[1], args[2] };
    if (background == null) {
        background = wire.Client.create(bus.?.allocator, .{ .added = &added, .removed = &removed }, null) catch @panic("background client");
        background.?.start() catch @panic("background dispatch");
    }
    for (background.?.surfaces.items) |surface| surface.redraw();
    connection.reply(message, .{}) catch {};
}
pub fn main() !void {
    var allocator: std.heap.DebugAllocator(.{}) = .init;
    defer if (allocator.deinit() == .leak) @panic("portal allocation leak");
    // The portal shares this connection, so tests reach the fixture at the portal's unique name.
    desktop.icons.init(allocator.allocator());
    defer desktop.gsettings.deinit();
    defer desktop.icons.deinit();
    defer desktop.window.deinit();
    const source = try loop.acquire(allocator.allocator(), .session);
    bus = source;
    defer loop.release(source);
    var introspection = try dbus.Introspection.parse(allocator.allocator(), "<node><interface name='org.dotfiles.CaptureFixture'><method name='Color'><arg type='d' direction='in'/><arg type='d' direction='in'/><arg type='d' direction='in'/></method></interface></node>");
    defer introspection.deinit();
    const registration = if (std.c.getenv("DESKTOP_PORTAL_FIXTURE_CAPTURE") != null) try source.connection.exportObject("/org/dotfiles/CaptureFixture", &introspection.interfaces[0], &method, null, null) else 0;
    defer {
        if (registration != 0) source.connection.unregister(registration);
    }
    defer if (background) |client| client.destroy();
    try desktop.portal.runWithAllocator(allocator.allocator());
}
