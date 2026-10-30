const std = @import("std");
const pointer = @import("../desktop-virtual-pointer.zig");
const transport = @import("desktop-pointer-transport.zig");
const protocols = @import("../desktop-protocols.zig");

test "virtual pointer requests preserve protocol argument order, version and destroy flags" {
    const manager: *pointer.Manager = @ptrFromInt(0x2000);
    const created = pointer.create(manager).?;
    try std.testing.expectEqual(@as(usize, 0x1000), @intFromPtr(created));
    try std.testing.expectEqual(@as(u32, 0), transport.opcode);
    try std.testing.expect(transport.interface == &protocols.zwlr_virtual_pointer_v1_interface);
    try std.testing.expect(transport.arguments[0].o == null and transport.arguments[1].o == null);

    pointer.move(created, 123, 456, 1728, 1080);
    try std.testing.expectEqual(@as(u32, 1), transport.opcode);
    for ([_]u32{ 0, 123, 456, 1728, 1080 }, transport.arguments) |expected, actual| try std.testing.expectEqual(expected, actual.u);
    try std.testing.expectEqual(@as(u32, 2), transport.version);
    try std.testing.expectEqual(@as(u32, 0), transport.flags);

    pointer.button(created, 272, 1);
    try std.testing.expectEqual(@as(u32, 2), transport.opcode);
    for ([_]u32{ 0, 272, 1 }, transport.arguments[0..3]) |expected, actual| try std.testing.expectEqual(expected, actual.u);
    pointer.frame(created);
    try std.testing.expectEqual(@as(u32, 4), transport.opcode);
    try std.testing.expect(transport.empty);
    pointer.destroy(created);
    try std.testing.expectEqual(@as(u32, 8), transport.opcode);
    try std.testing.expectEqual(@as(u32, 1), transport.flags);
    try std.testing.expect(transport.empty);
    pointer.destroyManager(manager);
    try std.testing.expectEqual(@as(u32, 1), transport.opcode);
    try std.testing.expectEqual(@as(u32, 1), transport.flags);
    try std.testing.expect(transport.empty);
}
