//! Persistent virtual pointer for isolated headless tests. Commands on stdin.
const std = @import("std");
const c = @import("wayland");
var manager: ?*c.zwlr_virtual_pointer_manager_v1 = null;
fn global(_: ?*anyopaque, registry: ?*c.wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
    if (c.strcmp(interface, "zwlr_virtual_pointer_manager_v1") == 0) manager = @ptrCast(c.wl_registry_bind(registry, name, &c.zwlr_virtual_pointer_manager_v1_interface, @min(version, 2)));
}
fn removed(_: ?*anyopaque, _: ?*c.wl_registry, _: u32) callconv(.c) void {}
const listener = c.wl_registry_listener{ .global = &global, .global_remove = &removed };
pub fn main() !void {
    const display = c.wl_display_connect(null) orelse return error.NoWaylandDisplay;
    defer c.wl_display_disconnect(display);
    const registry = c.wl_display_get_registry(display);
    defer c.wl_registry_destroy(registry);
    _ = c.wl_registry_add_listener(registry, &listener, null);
    if (c.wl_display_roundtrip(display) < 0 or manager == null) return error.NoVirtualPointer;
    defer c.zwlr_virtual_pointer_manager_v1_destroy(manager);
    const pointer = c.zwlr_virtual_pointer_manager_v1_create_virtual_pointer(manager, null);
    defer c.zwlr_virtual_pointer_v1_destroy(pointer);
    if (c.wl_display_roundtrip(display) < 0) return error.Disconnected;
    _ = c.puts("ready");
    _ = c.fflush(c.stdout);
    var buffer: [256]u8 = undefined;
    while (c.fgets(&buffer, buffer.len, c.stdin) != null) {
        var tokens = std.mem.tokenizeAny(u8, std.mem.sliceTo(&buffer, 0), " \r\n");
        const command = tokens.next() orelse continue;
        const x = try std.fmt.parseInt(u32, tokens.next() orelse return error.MissingValue, 10);
        if (std.mem.eql(u8, command, "move")) {
            const y = try std.fmt.parseInt(u32, tokens.next() orelse return error.MissingValue, 10);
            c.zwlr_virtual_pointer_v1_motion_absolute(pointer, 0, x, y, 1728, 1080);
        } else if (std.mem.eql(u8, command, "button")) {
            c.zwlr_virtual_pointer_v1_button(pointer, 0, 272, x);
        } else return error.UnknownCommand;
        c.zwlr_virtual_pointer_v1_frame(pointer);
        if (c.wl_display_roundtrip(display) < 0) return error.Disconnected;
        _ = c.puts("ok");
        _ = c.fflush(c.stdout);
    }
}
