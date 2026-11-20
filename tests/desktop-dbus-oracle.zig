//! Cross-check the native D-Bus marshalling against GDBus in both directions.
const std = @import("std");
const dbus = @import("dbus");

const GDBusMessage = opaque {};
const GVariant = opaque {};
const GError = extern struct { domain: u32, code: c_int, message: [*:0]const u8 };
extern fn g_dbus_message_new_from_blob(blob: [*]const u8, size: usize, capabilities: c_uint, err: *?*GError) ?*GDBusMessage;
extern fn g_dbus_message_new_method_call(name: ?[*:0]const u8, path: [*:0]const u8, interface: ?[*:0]const u8, method: [*:0]const u8) *GDBusMessage;
extern fn g_dbus_message_set_body(message: *GDBusMessage, body: *GVariant) void;
extern fn g_dbus_message_set_serial(message: *GDBusMessage, serial: u32) void;
extern fn g_dbus_message_to_blob(message: *GDBusMessage, size: *usize, capabilities: c_uint, err: *?*GError) ?[*]u8;
extern fn g_dbus_message_get_body(message: *GDBusMessage) ?*GVariant;
extern fn g_dbus_message_get_member(message: *GDBusMessage) ?[*:0]const u8;
extern fn g_dbus_message_get_path(message: *GDBusMessage) ?[*:0]const u8;
extern fn g_variant_new_parsed(format: [*:0]const u8, ...) *GVariant;
extern fn g_variant_print(value: *GVariant, annotate: c_int) [*:0]u8;
extern fn g_object_unref(object: *anyopaque) void;
extern fn g_free(memory: ?*anyopaque) void;
extern fn g_error_free(err: *GError) void;

test "GDBus parses natively encoded messages with nested containers and variants" {
    const allocator = std.testing.allocator;
    const nested: dbus.Value = .{ .array = .{ .element = "s", .items = &.{ .{ .string = "a" }, .{ .string = "b" } } } };
    const hints = dbus.Dict([]const u8, dbus.Value){ .entries = &.{
        .{ .key = "urgency", .value = .{ .byte = 2 } },
        .{ .key = "list", .value = nested },
        .{ .key = "big", .value = .{ .uint64 = 1 << 40 } },
    } };
    var message = try dbus.encode(allocator, .{ .kind = .method_call, .serial = 9, .destination = "org.freedesktop.Notifications", .path = "/org/freedesktop/Notifications", .interface = "org.freedesktop.Notifications", .member = "Notify", .arena = undefined }, .{
        "desktop-zig", @as(u32, 0), "icon", "Title", "Body", @as([]const []const u8, &.{"default"}), hints, @as(i32, -1), dbus.ObjectPath{ .value = "/a" }, @as(f64, 0.5), true,
    });
    defer message.deinit();
    var err: ?*GError = null;
    const parsed = g_dbus_message_new_from_blob(message.bytes.items.ptr, message.bytes.items.len, 0, &err) orelse {
        std.debug.print("GDBus rejected the message: {s}\n", .{err.?.message});
        g_error_free(err.?);
        return error.Rejected;
    };
    defer g_object_unref(parsed);
    try std.testing.expectEqualStrings("Notify", std.mem.span(g_dbus_message_get_member(parsed).?));
    try std.testing.expectEqualStrings("/org/freedesktop/Notifications", std.mem.span(g_dbus_message_get_path(parsed).?));
    const text = g_variant_print(g_dbus_message_get_body(parsed).?, 1);
    defer g_free(text);
    try std.testing.expectEqualStrings("('desktop-zig', uint32 0, 'icon', 'Title', 'Body', ['default'], {'urgency': <byte 0x02>, 'list': <['a', 'b']>, 'big': <uint64 1099511627776>}, -1, objectpath '/a', 0.5, true)", std.mem.span(text));
}

test "native parsing reads GDBus-encoded messages" {
    const message = g_dbus_message_new_method_call("org.example", "/org/example/Object", "org.example.Interface", "Method");
    defer g_object_unref(message);
    g_dbus_message_set_body(message, g_variant_new_parsed("(byte 7, int16 -3, uint16 4, 1, uint32 2, int64 -5, uint64 6, 1.25, 'text', objectpath '/p', signature 'a{sv}', [byte 1, 2, 3], {'k': <(1, 'x')>, 'm': <['y']>}, @a(ii) [])"));
    g_dbus_message_set_serial(message, 77);
    var size: usize = 0;
    var err: ?*GError = null;
    const blob = g_dbus_message_to_blob(message, &size, 0, &err) orelse return error.Serialize;
    defer g_free(blob);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try dbus.parse(arena.allocator(), blob[0..size], &.{});
    try std.testing.expectEqual(dbus.Kind.method_call, parsed.kind);
    try std.testing.expectEqual(@as(u32, 77), parsed.serial);
    try std.testing.expectEqualStrings("org.example", parsed.destination.?);
    try std.testing.expectEqualStrings("org.example.Interface", parsed.interface.?);
    const Pair = struct { i32, i32 };
    const body = try parsed.read(struct { u8, i16, u16, i32, u32, i64, u64, f64, []const u8, dbus.ObjectPath, dbus.Signature, dbus.Bytes, dbus.Dict([]const u8, dbus.Value), []const Pair });
    try std.testing.expectEqual(@as(u8, 7), body[0]);
    try std.testing.expectEqual(@as(i16, -3), body[1]);
    try std.testing.expectEqual(@as(u16, 4), body[2]);
    try std.testing.expectEqual(@as(i32, 1), body[3]);
    try std.testing.expectEqual(@as(u32, 2), body[4]);
    try std.testing.expectEqual(@as(i64, -5), body[5]);
    try std.testing.expectEqual(@as(u64, 6), body[6]);
    try std.testing.expectEqual(@as(f64, 1.25), body[7]);
    try std.testing.expectEqualStrings("text", body[8]);
    try std.testing.expectEqualStrings("/p", body[9].value);
    try std.testing.expectEqualStrings("a{sv}", body[10].value);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, body[11].value);
    const dict = body[12];
    try std.testing.expectEqual(@as(usize, 2), dict.entries.len);
    const pair = dict.entries[0].value.structure;
    try std.testing.expectEqual(@as(i32, 1), pair[0].int32);
    try std.testing.expectEqualStrings("x", pair[1].string);
    try std.testing.expectEqualStrings("y", dict.entries[1].value.array.items[0].string);
    try std.testing.expectEqual(@as(usize, 0), body[13].len);
}
