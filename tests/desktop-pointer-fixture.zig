//! Persistent virtual pointer for isolated headless tests. Commands on stdin.
const std = @import("std");
const desktop = @import("desktop");
const wl = desktop.wayland.protocol;
const wire = desktop.wayland.wire;
var manager: ?wl.zwlr_virtual_pointer_manager_v1 = null;
fn registryEvent(_: *u8, registry: wl.wl_registry, event: wl.wl_registry.Event) void {
    switch (event) {
        .global => |value| if (std.mem.eql(u8, value.interface, "zwlr_virtual_pointer_manager_v1")) {
            manager = registry.bind(value.name, wl.zwlr_virtual_pointer_manager_v1, @min(value.version, 2));
        },
        .global_remove => {},
    }
}
fn milliseconds(io: std.Io) u32 {
    return @truncate(@as(u64, @intCast(@divTrunc(std.Io.Clock.awake.now(io).toMicroseconds(), 1000))));
}
pub fn main(init: std.process.Init) !void {
    const connection = wire.Connection.connect(std.heap.page_allocator) catch return error.NoWaylandDisplay;
    defer connection.deinit();
    const display: wl.wl_display = .{ .proxy = connection.display() };
    const registry = display.get_registry();
    defer registry.destroy();
    var unused: u8 = 0;
    registry.listen(u8, &unused, registryEvent);
    connection.roundtrip() catch return error.Disconnected;
    const pointers = manager orelse return error.NoVirtualPointer;
    defer pointers.destroy();
    const pointer = pointers.create_virtual_pointer(null);
    defer pointer.destroy();
    connection.roundtrip() catch return error.Disconnected;
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
            pointer.motion(milliseconds(init.io), @floatFromInt(dx), @floatFromInt(dy));
        } else {
            const x = try std.fmt.parseInt(u32, tokens.next() orelse return error.MissingValue, 10);
            if (std.mem.eql(u8, command, "move")) {
                const y = try std.fmt.parseInt(u32, tokens.next() orelse return error.MissingValue, 10);
                pointer.motion_absolute(0, x, y, extent_width, extent_height);
            } else if (std.mem.eql(u8, command, "size")) {
                const y = try std.fmt.parseInt(u32, tokens.next() orelse return error.MissingValue, 10);
                if (x == 0 or y == 0) return error.InvalidExtent;
                extent_width = x;
                extent_height = y;
            } else if (std.mem.eql(u8, command, "button")) {
                pointer.button(0, 272, x);
            } else return error.UnknownCommand;
        }
        pointer.frame();
        connection.roundtrip() catch return error.Disconnected;
        try writer.interface.writeAll("ok\n");
        try writer.interface.flush();
    }
}
