//! Converts between native D-Bus values and GVariant, for code whose data
//! comes from GLib (GSettings, GIcon) rather than from the wire.
//!
//! Descriptors cross as handles holding the descriptor number itself, not an
//! index into a GUnixFDList; the message still owns them.
const std = @import("std");
const c = @import("desktop-glib.zig");
const dbus = @import("dbus");

const g = struct {
    extern fn g_variant_classify(*c.GVariant) c_int;
    extern fn g_variant_get_type_string(*c.GVariant) [*:0]const u8;
    extern fn g_variant_get_int16(*c.GVariant) i16;
    extern fn g_variant_get_uint16(*c.GVariant) u16;
    extern fn g_variant_get_int64(*c.GVariant) i64;
    extern fn g_variant_get_uint64(*c.GVariant) u64;
    extern fn g_variant_get_double(*c.GVariant) f64;
    extern fn g_variant_get_handle(*c.GVariant) i32;
    extern fn g_variant_get_variant(*c.GVariant) *c.GVariant;
    extern fn g_variant_get_fixed_array(*c.GVariant, *usize, usize) ?*const anyopaque;
    extern fn g_variant_new_byte(u8) *c.GVariant;
    extern fn g_variant_new_boolean(c.gboolean) *c.GVariant;
    extern fn g_variant_new_int16(i16) *c.GVariant;
    extern fn g_variant_new_uint16(u16) *c.GVariant;
    extern fn g_variant_new_int32(i32) *c.GVariant;
    extern fn g_variant_new_uint32(u32) *c.GVariant;
    extern fn g_variant_new_int64(i64) *c.GVariant;
    extern fn g_variant_new_uint64(u64) *c.GVariant;
    extern fn g_variant_new_double(f64) *c.GVariant;
    extern fn g_variant_new_handle(i32) *c.GVariant;
    extern fn g_variant_new_take_string([*:0]u8) *c.GVariant;
    extern fn g_variant_new_object_path([*:0]const u8) *c.GVariant;
    extern fn g_variant_new_signature([*:0]const u8) *c.GVariant;
    extern fn g_variant_new_variant(*c.GVariant) *c.GVariant;
    extern fn g_variant_new_fixed_array(*const c.GVariantType, ?*const anyopaque, usize, usize) *c.GVariant;
    extern fn g_variant_new_array(?*const c.GVariantType, [*]const *c.GVariant, usize) *c.GVariant;
    extern fn g_variant_new_tuple([*]const *c.GVariant, usize) *c.GVariant;
    extern fn g_variant_new_dict_entry(*c.GVariant, *c.GVariant) *c.GVariant;
    extern fn g_variant_type_new([*:0]const u8) *c.GVariantType;
    extern fn g_variant_type_free(*c.GVariantType) void;
    extern fn g_variant_is_object_path([*:0]const u8) c.gboolean;
    extern fn g_variant_is_signature([*:0]const u8) c.gboolean;
    extern fn g_utf8_validate([*]const u8, isize, ?*[*]const u8) c.gboolean;
    extern fn g_strndup([*]const u8, usize) [*:0]u8;
};

pub const Dict = dbus.Dict([]const u8, dbus.Value);

/// A new floating GVariant holding `value`, or null when GLib would reject it
/// (invalid UTF-8, paths or signatures, or a type too deep to describe).
pub fn toVariant(value: dbus.Value) ?*c.GVariant {
    return switch (value) {
        .byte => |v| g.g_variant_new_byte(v),
        .boolean => |v| g.g_variant_new_boolean(@intFromBool(v)),
        .int16 => |v| g.g_variant_new_int16(v),
        .uint16 => |v| g.g_variant_new_uint16(v),
        .int32 => |v| g.g_variant_new_int32(v),
        .uint32 => |v| g.g_variant_new_uint32(v),
        .int64 => |v| g.g_variant_new_int64(v),
        .uint64 => |v| g.g_variant_new_uint64(v),
        .double => |v| g.g_variant_new_double(v),
        .fd => |v| g.g_variant_new_handle(v),
        .string => |v| string(v),
        .object_path, .signature => |v| blk: {
            if (std.mem.indexOfScalar(u8, v, 0) != null) break :blk null;
            const owned = g.g_strndup(v.ptr, v.len);
            defer c.g_free(owned);
            if (value == .object_path) {
                if (g.g_variant_is_object_path(owned) == 0) break :blk null;
                break :blk g.g_variant_new_object_path(owned);
            }
            if (g.g_variant_is_signature(owned) == 0) break :blk null;
            break :blk g.g_variant_new_signature(owned);
        },
        .bytes => |v| g.g_variant_new_fixed_array(@ptrCast("y"), v.ptr, v.len, 1),
        .variant => |inner| g.g_variant_new_variant(toVariant(inner.*) orelse return null),
        .dict_entry => |entry| blk: {
            const key = toVariant(entry[0]) orelse break :blk null;
            const item = toVariant(entry[1]) orelse {
                sink(key);
                break :blk null;
            };
            break :blk g.g_variant_new_dict_entry(key, item);
        },
        .structure => |fields| children(fields, null),
        .array => |array| blk: {
            var buffer: [256]u8 = undefined;
            if (array.element.len >= buffer.len) break :blk null;
            @memcpy(buffer[0..array.element.len], array.element);
            buffer[array.element.len] = 0;
            const element = g.g_variant_type_new(@ptrCast(&buffer));
            defer g.g_variant_type_free(element);
            break :blk children(array.items, element);
        },
    };
}
/// An `a{sv}` GVariant for a dictionary read from a message.
pub fn dictToVariant(dict: Dict) ?*c.GVariant {
    var items: std.ArrayList(*c.GVariant) = .empty;
    defer items.deinit(std.heap.page_allocator);
    defer for (items.items) |item| sink(item);
    for (dict.entries) |entry| {
        const key = string(entry.key) orelse return null;
        const inner = toVariant(entry.value) orelse {
            sink(key);
            return null;
        };
        const item = c.g_variant_take_ref(g.g_variant_new_dict_entry(key, g.g_variant_new_variant(inner))).?;
        items.append(std.heap.page_allocator, item) catch {
            c.g_variant_unref(item);
            return null;
        };
    }
    return g.g_variant_new_array(@ptrCast("{sv}"), items.items.ptr, items.items.len);
}

fn string(value: []const u8) ?*c.GVariant {
    if (std.mem.indexOfScalar(u8, value, 0) != null or g.g_utf8_validate(value.ptr, @intCast(value.len), null) == 0) return null;
    return g.g_variant_new_take_string(g.g_strndup(value.ptr, value.len));
}
/// Drops a floating or owned reference.
fn sink(value: *c.GVariant) void {
    c.g_variant_unref(c.g_variant_take_ref(value));
}
fn children(values: []const dbus.Value, element: ?*const c.GVariantType) ?*c.GVariant {
    var items: std.ArrayList(*c.GVariant) = .empty;
    defer items.deinit(std.heap.page_allocator);
    defer for (items.items) |item| c.g_variant_unref(item);
    for (values) |value| {
        const item = c.g_variant_take_ref(toVariant(value) orelse return null).?;
        items.append(std.heap.page_allocator, item) catch {
            c.g_variant_unref(item);
            return null;
        };
    }
    if (element) |kind| return g.g_variant_new_array(kind, items.items.ptr, items.items.len);
    if (items.items.len == 0) return null; // D-Bus has no empty structure.
    return g.g_variant_new_tuple(items.items.ptr, items.items.len);
}

/// Converts a GVariant into a Value whose storage lives in `arena`. The variant
/// is only borrowed; a floating one is sunk and released.
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
/// Converts an `a{sv}` GVariant into a dictionary for a typed message argument.
pub fn dictFromVariant(arena: std.mem.Allocator, variant: ?*c.GVariant) !Dict {
    const value = c.g_variant_take_ref(variant orelse return .{ .entries = &.{} }).?;
    defer c.g_variant_unref(value);
    if (!std.mem.eql(u8, std.mem.span(g.g_variant_get_type_string(value)), "a{sv}")) return error.UnsupportedVariant;
    const entries = try arena.alloc(Dict.Entry, c.g_variant_n_children(value));
    for (entries, 0..) |*entry, index| {
        const pair = c.g_variant_get_child_value(value, index).?;
        defer c.g_variant_unref(pair);
        const fields = try childValues(arena, pair);
        entry.* = .{ .key = fields[0].string, .value = fields[1].variant.* };
    }
    return .{ .entries = entries };
}

/// A message's arguments as an owned GVariant tuple (empty for no arguments),
/// or null when they cannot be represented, such as invalid UTF-8.
pub fn argumentsVariant(message: *const dbus.Message) ?*c.GVariant {
    const values = message.values() catch return null;
    if (values.len == 0) return c.g_variant_take_ref(g.g_variant_new_tuple(&[_]*c.GVariant{}, 0));
    return c.g_variant_take_ref(toVariant(.{ .structure = values }) orelse return null);
}
/// The children of a tuple GVariant as a message body; a floating tuple is sunk and released.
pub fn bodyFromVariant(arena: std.mem.Allocator, tuple: *c.GVariant) !dbus.Body {
    return switch (try fromVariant(arena, tuple)) {
        .structure => |fields| .{ .values = fields },
        else => error.UnsupportedVariant,
    };
}

test "values survive a round trip through GVariant" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const inner: dbus.Value = .{ .string = "hello" };
    const entries = [_]Dict.Entry{
        .{ .key = "text", .value = inner },
        .{ .key = "pixels", .value = .{ .bytes = "\x01\x02" } },
        .{ .key = "pair", .value = .{ .structure = &.{ .{ .int32 = -3 }, .{ .boolean = true } } } },
        .{ .key = "list", .value = .{ .array = .{ .element = "s", .items = &.{} } } },
        .{ .key = "nested", .value = .{ .variant = &inner } },
    };
    const variant = dictToVariant(.{ .entries = &entries }).?;
    const back = try dictFromVariant(arena.allocator(), variant);
    try std.testing.expectEqual(entries.len, back.entries.len);
    try std.testing.expectEqualStrings("hello", back.entries[0].value.string);
    try std.testing.expectEqualStrings("\x01\x02", back.entries[1].value.bytes);
    try std.testing.expectEqual(@as(i32, -3), back.entries[2].value.structure[0].int32);
    try std.testing.expectEqualStrings("s", back.entries[3].value.array.element);
    try std.testing.expectEqualStrings("hello", back.entries[4].value.variant.string);
    // Invalid UTF-8 is rejected rather than handed to GLib.
    try std.testing.expect(toVariant(.{ .string = "\xff" }) == null);
}
