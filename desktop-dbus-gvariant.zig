//! Converts GVariants into D-Bus values, for data that comes from GLib
//! (GSettings) rather than from the wire.
const std = @import("std");
const c = @import("desktop-glib.zig");
const dbus = @import("dbus");

const g = struct {
    extern fn g_variant_get_type_string(*c.GVariant) [*:0]const u8;
    extern fn g_variant_get_int16(*c.GVariant) i16;
    extern fn g_variant_get_uint16(*c.GVariant) u16;
    extern fn g_variant_get_int64(*c.GVariant) i64;
    extern fn g_variant_get_uint64(*c.GVariant) u64;
    extern fn g_variant_get_double(*c.GVariant) f64;
    extern fn g_variant_get_handle(*c.GVariant) i32;
    extern fn g_variant_get_variant(*c.GVariant) *c.GVariant;
    extern fn g_variant_get_fixed_array(*c.GVariant, *usize, usize) ?*const anyopaque;
};

/// Converts a GVariant into a Value whose storage lives in `arena`. A floating
/// variant is sunk and released; an owned reference is released.
pub fn fromVariant(arena: std.mem.Allocator, variant: *c.GVariant) !dbus.Value {
    const value = c.g_variant_take_ref(variant).?;
    defer c.g_variant_unref(value);
    return convert(arena, value);
}
const ConvertError = error{ OutOfMemory, UnsupportedVariant };
fn convert(arena: std.mem.Allocator, value: *c.GVariant) ConvertError!dbus.Value {
    const signature = std.mem.span(g.g_variant_get_type_string(value));
    return switch (signature[0]) {
        'y' => .{ .byte = c.g_variant_get_byte(value) },
        'b' => .{ .boolean = c.g_variant_get_boolean(value) != 0 },
        'n' => .{ .int16 = g.g_variant_get_int16(value) },
        'q' => .{ .uint16 = g.g_variant_get_uint16(value) },
        'i' => .{ .int32 = c.g_variant_get_int32(value) },
        'u' => .{ .uint32 = c.g_variant_get_uint32(value) },
        'x' => .{ .int64 = g.g_variant_get_int64(value) },
        't' => .{ .uint64 = g.g_variant_get_uint64(value) },
        'd' => .{ .double = g.g_variant_get_double(value) },
        'h' => .{ .fd = g.g_variant_get_handle(value) },
        's' => .{ .string = try arena.dupe(u8, std.mem.span(c.g_variant_get_string(value, null))) },
        'o' => .{ .object_path = try arena.dupe(u8, std.mem.span(c.g_variant_get_string(value, null))) },
        'g' => .{ .signature = try arena.dupe(u8, std.mem.span(c.g_variant_get_string(value, null))) },
        'v' => blk: {
            const inner = g.g_variant_get_variant(value);
            defer c.g_variant_unref(inner);
            const boxed = try arena.create(dbus.Value);
            boxed.* = try convert(arena, inner);
            break :blk .{ .variant = boxed };
        },
        'a' => blk: {
            if (signature.len == 2 and signature[1] == 'y') {
                var length: usize = 0;
                const data = g.g_variant_get_fixed_array(value, &length, 1);
                const bytes: []const u8 = if (data) |pointer| @as([*]const u8, @ptrCast(pointer))[0..length] else &.{};
                break :blk .{ .bytes = try arena.dupe(u8, bytes) };
            }
            break :blk .{ .array = .{ .element = try arena.dupe(u8, signature[1..]), .items = try childValues(arena, value) } };
        },
        '(' => .{ .structure = try childValues(arena, value) },
        '{' => blk: {
            const fields = try childValues(arena, value);
            const entry = try arena.create([2]dbus.Value);
            entry.* = .{ fields[0], fields[1] };
            break :blk .{ .dict_entry = entry };
        },
        // Maybe types have no D-Bus equivalent.
        else => error.UnsupportedVariant,
    };
}
fn childValues(arena: std.mem.Allocator, value: *c.GVariant) ConvertError![]dbus.Value {
    const result = try arena.alloc(dbus.Value, c.g_variant_n_children(value));
    for (result, 0..) |*item, index| {
        const element = c.g_variant_get_child_value(value, index).?;
        defer c.g_variant_unref(element);
        item.* = try convert(arena, element);
    }
    return result;
}

test "GVariants convert to the same D-Bus values" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const text = "{'text': <'hello'>, 'pixels': <[byte 1, 2]>, 'pair': <(-3, true)>, 'list': <@as []>, 'nested': <<'hello'>>}";
    const parsed = c.g_variant_parse(null, text, null, null, null).?;
    const value = try fromVariant(arena.allocator(), parsed);
    // The native text format prints it the same way GLib parsed it.
    const printed = try @import("desktop-dbus-text.zig").print(arena.allocator(), value);
    const reparsed = try @import("desktop-dbus-text.zig").parse(arena.allocator(), "a{sv}", printed);
    try std.testing.expectEqualStrings(printed, try @import("desktop-dbus-text.zig").print(arena.allocator(), reparsed));
    try std.testing.expectEqualStrings("hello", value.lookup("text").?.string);
    try std.testing.expectEqualSlices(u8, "\x01\x02", value.lookup("pixels").?.bytes);
    try std.testing.expectEqual(@as(i32, -3), value.lookup("pair").?.structure[0].int32);
    try std.testing.expectEqualStrings("s", value.lookup("list").?.array.element);
    try std.testing.expectEqualStrings("hello", value.lookup("nested").?.variant.string);
}
