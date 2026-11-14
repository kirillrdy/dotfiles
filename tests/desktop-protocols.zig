//! Compare native metadata with independently compiled wayland-scanner output.
const std = @import("std");
const protocols = @import("../desktop-protocols.zig");
const Interface = protocols.Interface;

fn sameMessages(actual: [*c]const @import("../desktop-gtk.zig").struct_wl_message, expected: [*c]const @import("../desktop-gtk.zig").struct_wl_message, count: usize) !void {
    for (0..count) |i| {
        try std.testing.expectEqualStrings(std.mem.span(expected[i].name), std.mem.span(actual[i].name));
        const signature = std.mem.span(expected[i].signature);
        try std.testing.expectEqualStrings(signature, std.mem.span(actual[i].signature));
        var argument: usize = 0;
        for (signature) |kind| {
            if (std.mem.indexOfScalar(u8, "iufsonah", kind) == null) continue;
            const left = actual[i].types[argument];
            const right = expected[i].types[argument];
            try std.testing.expectEqual(right == null, left == null);
            if (right != null) {
                try std.testing.expectEqualStrings(std.mem.span(right.*.name), std.mem.span(left.*.name));
                try std.testing.expectEqual(right.*.version, left.*.version);
            }
            argument += 1;
        }
    }
}

test "native Wayland metadata matches every reference interface and message" {
    @setEvalBranchQuota(10000);
    var checked: usize = 0;
    inline for (comptime std.meta.declarations(protocols)) |name| {
        if (comptime !std.mem.endsWith(u8, name, "_interface")) continue;
        if (comptime std.mem.startsWith(u8, name, "wl_")) continue;
        const actual = &@field(protocols, name);
        const expected = @extern(*const Interface, .{ .name = "reference_" ++ name });
        try std.testing.expectEqualStrings(std.mem.span(expected.name), std.mem.span(actual.name));
        try std.testing.expectEqual(expected.version, actual.version);
        try std.testing.expectEqual(expected.method_count, actual.method_count);
        try std.testing.expectEqual(expected.event_count, actual.event_count);
        try sameMessages(actual.methods, expected.methods, @intCast(actual.method_count));
        try sameMessages(actual.events, expected.events, @intCast(actual.event_count));
        checked += 1;
    }
    try std.testing.expectEqual(@as(usize, 47), checked);
}

test "virtual pointer requests preserve protocol argument order, version and destroy flags" {
    const gtk = @import("../desktop-gtk.zig");
    const transport = struct {
        pub const wl_proxy = gtk.wl_proxy;
        pub const wl_interface = gtk.wl_interface;
        pub const wl_argument = gtk.wl_argument;
        var opcode: u32 = 0;
        var flags: u32 = 0;
        var version: u32 = 0;
        var interface: ?*const wl_interface = null;
        var arguments: [5]wl_argument = undefined;
        var empty: bool = false;
        pub fn wl_proxy_get_version(_: ?*wl_proxy) u32 {
            return 2;
        }
        pub fn wl_proxy_marshal_array_flags(_: ?*wl_proxy, req: u32, iface: ?*const wl_interface, req_version: u32, req_flags: u32, args: [*c]wl_argument) ?*wl_proxy {
            opcode = req;
            flags = req_flags;
            version = req_version;
            interface = iface;
            empty = args == null;
            const count: usize = if (req_flags == 1 or req == 4) 0 else if (iface != null) 2 else if (req == 1) 5 else 3;
            for (0..count) |i| arguments[i] = args[i];
            return @ptrFromInt(0x1000);
        }
    };
    const vp = @import("desktop-virtual-pointer.zig").Client(transport, protocols);
    const manager: *vp.Manager = @ptrFromInt(0x2000);
    const created = vp.create(manager).?;
    try std.testing.expectEqual(@as(usize, 0x1000), @intFromPtr(created));
    try std.testing.expectEqual(@as(u32, 0), transport.opcode);
    try std.testing.expect(transport.interface == &protocols.zwlr_virtual_pointer_v1_interface);
    try std.testing.expect(transport.arguments[0].o == null and transport.arguments[1].o == null);

    vp.move(created, 123, 456, 1728, 1080);
    try std.testing.expectEqual(@as(u32, 1), transport.opcode);
    for ([_]u32{ 0, 123, 456, 1728, 1080 }, transport.arguments) |expected, actual| try std.testing.expectEqual(expected, actual.u);
    try std.testing.expectEqual(@as(u32, 2), transport.version);
    try std.testing.expectEqual(@as(u32, 0), transport.flags);

    vp.relative(created, -40, 15, 1234);
    try std.testing.expectEqual(@as(u32, 0), transport.opcode);
    try std.testing.expectEqual(@as(u32, 1234), transport.arguments[0].u);
    try std.testing.expectEqual(@as(i32, -40 * 256), transport.arguments[1].f);
    try std.testing.expectEqual(@as(i32, 15 * 256), transport.arguments[2].f);

    vp.button(created, 272, 1);
    try std.testing.expectEqual(@as(u32, 2), transport.opcode);
    for ([_]u32{ 0, 272, 1 }, transport.arguments[0..3]) |expected, actual| try std.testing.expectEqual(expected, actual.u);
    vp.frame(created);
    try std.testing.expectEqual(@as(u32, 4), transport.opcode);
    try std.testing.expect(transport.empty);
    vp.destroy(created);
    try std.testing.expectEqual(@as(u32, 8), transport.opcode);
    try std.testing.expectEqual(@as(u32, 1), transport.flags);
    try std.testing.expect(transport.empty);
    vp.destroyManager(manager);
    try std.testing.expectEqual(@as(u32, 1), transport.opcode);
    try std.testing.expectEqual(@as(u32, 1), transport.flags);
    try std.testing.expect(transport.empty);
}
