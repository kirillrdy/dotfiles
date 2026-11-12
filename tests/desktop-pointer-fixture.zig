//! Persistent virtual pointer for isolated headless tests. Commands on stdin.
const std = @import("std");
comptime {
    _ = @import("desktop").protocols;
}
const c = @import("desktop").gtk;
const pointer_api = @import("desktop").virtual_pointer;
var manager: ?*pointer_api.Manager = null;
fn global(_: ?*anyopaque, registry: ?*c.wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
    if (std.mem.eql(u8, std.mem.span(interface), "zwlr_virtual_pointer_manager_v1")) manager = @ptrCast(c.wl_registry_bind(registry, name, &pointer_api.zwlr_virtual_pointer_manager_v1_interface, @min(version, 2)));
}
fn removed(_: ?*anyopaque, _: ?*c.wl_registry, _: u32) callconv(.c) void {}
const listener = c.wl_registry_listener{ .global = &global, .global_remove = &removed };
pub fn main(init: std.process.Init) !void {
    const display = c.wl_display_connect(null) orelse return error.NoWaylandDisplay;
    defer c.wl_display_disconnect(display);
    const registry = c.wl_display_get_registry(display);
    defer c.wl_registry_destroy(registry);
    _ = c.wl_registry_add_listener(registry, &listener, null);
    if (c.wl_display_roundtrip(display) < 0 or manager == null) return error.NoVirtualPointer;
    defer pointer_api.destroyManager(manager.?);
    const pointer = pointer_api.create(manager.?) orelse return error.NoVirtualPointer;
    defer pointer_api.destroy(pointer);
    if (c.wl_display_roundtrip(display) < 0) return error.Disconnected;
    var input_buffer: [256]u8 = undefined;
    var output_buffer: [256]u8 = undefined;
    var reader = std.Io.File.stdin().reader(init.io, &input_buffer);
    var writer = std.Io.File.stdout().writer(init.io, &output_buffer);
    var extent_width: u32 = 1728;
    var extent_height: u32 = 1080;
    try writer.interface.writeAll("ready\n");
    try writer.interface.flush();
    while (try reader.interface.takeDelimiter('\n')) |line| {
        var tokens = std.mem.tokenizeAny(u8, line, " \r\n");
        const command = tokens.next() orelse continue;
        if (std.mem.eql(u8, command, "relative")) {
            const dx = try std.fmt.parseInt(i32, tokens.next() orelse return error.MissingValue, 10);
            const dy = try std.fmt.parseInt(i32, tokens.next() orelse return error.MissingValue, 10);
            pointer_api.relative(pointer, dx, dy, @truncate(@as(u64, @intCast(@divTrunc(c.g_get_monotonic_time(), 1000)))));
            pointer_api.frame(pointer);
            if (c.wl_display_roundtrip(display) < 0) return error.Disconnected;
            try writer.interface.writeAll("ok\n");
            try writer.interface.flush();
            continue;
        }
        const x = try std.fmt.parseInt(u32, tokens.next() orelse return error.MissingValue, 10);
        if (std.mem.eql(u8, command, "move")) {
            const y = try std.fmt.parseInt(u32, tokens.next() orelse return error.MissingValue, 10);
            pointer_api.move(pointer, x, y, extent_width, extent_height);
        } else if (std.mem.eql(u8, command, "size")) {
            const y = try std.fmt.parseInt(u32, tokens.next() orelse return error.MissingValue, 10);
            if (x == 0 or y == 0) return error.InvalidExtent;
            extent_width = x;
            extent_height = y;
        } else if (std.mem.eql(u8, command, "button")) {
            pointer_api.button(pointer, 272, x);
        } else return error.UnknownCommand;
        pointer_api.frame(pointer);
        if (c.wl_display_roundtrip(display) < 0) return error.Disconnected;
        try writer.interface.writeAll("ok\n");
        try writer.interface.flush();
    }
}
