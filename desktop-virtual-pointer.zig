//! Explicit requests for the virtual pointer used by headless integration tests.
const std = @import("std");
const gtk = @import("desktop-gtk.zig");
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
const c = if (@import("builtin").is_test) transport else gtk;
pub const Manager = opaque {};
pub const Pointer = opaque {};
pub extern const zwlr_virtual_pointer_manager_v1_interface: c.wl_interface;
extern const zwlr_virtual_pointer_v1_interface: c.wl_interface;

fn request(proxy: *c.wl_proxy, opcode: u32, interface: ?*const c.wl_interface, flags: u32, args: []c.wl_argument) ?*c.wl_proxy {
    return c.wl_proxy_marshal_array_flags(proxy, opcode, interface, c.wl_proxy_get_version(proxy), flags, if (args.len == 0) null else args.ptr);
}

pub fn create(manager: *Manager) ?*Pointer {
    const proxy: *c.wl_proxy = @ptrCast(manager);
    var args = [_]c.wl_argument{ .{ .o = null }, .{ .o = null } };
    return @ptrCast(request(proxy, 0, &zwlr_virtual_pointer_v1_interface, 0, &args));
}
pub fn destroyManager(manager: *Manager) void {
    const proxy: *c.wl_proxy = @ptrCast(manager);
    _ = request(proxy, 1, null, 1, &.{});
}
pub fn destroy(pointer: *Pointer) void {
    const proxy: *c.wl_proxy = @ptrCast(pointer);
    _ = request(proxy, 8, null, 1, &.{});
}
pub fn move(pointer: *Pointer, x: u32, y: u32, width: u32, height: u32) void {
    const proxy: *c.wl_proxy = @ptrCast(pointer);
    var args = [_]c.wl_argument{ .{ .u = 0 }, .{ .u = x }, .{ .u = y }, .{ .u = width }, .{ .u = height } };
    _ = request(proxy, 1, null, 0, &args);
}
pub fn button(pointer: *Pointer, code: u32, state: u32) void {
    const proxy: *c.wl_proxy = @ptrCast(pointer);
    var args = [_]c.wl_argument{ .{ .u = 0 }, .{ .u = code }, .{ .u = state } };
    _ = request(proxy, 2, null, 0, &args);
}
pub fn frame(pointer: *Pointer) void {
    const proxy: *c.wl_proxy = @ptrCast(pointer);
    _ = request(proxy, 4, null, 0, &.{});
}

test "virtual pointer requests preserve protocol argument order, version and destroy flags" {
    const protocols = @import("desktop-protocols.zig");
    const manager: *Manager = @ptrFromInt(0x2000);
    const created = create(manager).?;
    try std.testing.expectEqual(@as(usize, 0x1000), @intFromPtr(created));
    try std.testing.expectEqual(@as(u32, 0), transport.opcode);
    try std.testing.expect(transport.interface == &protocols.zwlr_virtual_pointer_v1_interface);
    try std.testing.expect(transport.arguments[0].o == null and transport.arguments[1].o == null);

    move(created, 123, 456, 1728, 1080);
    try std.testing.expectEqual(@as(u32, 1), transport.opcode);
    for ([_]u32{ 0, 123, 456, 1728, 1080 }, transport.arguments) |expected, actual| try std.testing.expectEqual(expected, actual.u);
    try std.testing.expectEqual(@as(u32, 2), transport.version);
    try std.testing.expectEqual(@as(u32, 0), transport.flags);

    button(created, 272, 1);
    try std.testing.expectEqual(@as(u32, 2), transport.opcode);
    for ([_]u32{ 0, 272, 1 }, transport.arguments[0..3]) |expected, actual| try std.testing.expectEqual(expected, actual.u);
    frame(created);
    try std.testing.expectEqual(@as(u32, 4), transport.opcode);
    try std.testing.expect(transport.empty);
    destroy(created);
    try std.testing.expectEqual(@as(u32, 8), transport.opcode);
    try std.testing.expectEqual(@as(u32, 1), transport.flags);
    try std.testing.expect(transport.empty);
    destroyManager(manager);
    try std.testing.expectEqual(@as(u32, 1), transport.opcode);
    try std.testing.expectEqual(@as(u32, 1), transport.flags);
    try std.testing.expect(transport.empty);
}
