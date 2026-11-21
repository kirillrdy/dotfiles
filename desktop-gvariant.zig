//! GVariant's serialized format (normal form), as found in GVDB files such as
//! compiled GSettings schemas and dconf databases, read into and written from
//! D-Bus values. This is not the D-Bus wire format: containers are framed by
//! offsets at their end instead of length prefixes.
const std = @import("std");
const dbus = @import("dbus");
const Value = dbus.Value;

pub const Error = error{ OutOfMemory, InvalidData, UnsupportedType };

fn alignmentOf(signature: []const u8) usize {
    return switch (signature[0]) {
        'b', 'y', 's', 'o', 'g' => 1,
        'n', 'q' => 2,
        'i', 'u', 'h' => 4,
        'x', 't', 'd', 'v' => 8,
        'a', 'm' => alignmentOf(signature[1..]),
        '(', '{' => blk: {
            var result: usize = 1;
            var at: usize = 1;
            while (signature[at] != ')' and signature[at] != '}') {
                const next = completeType(signature, at);
                result = @max(result, alignmentOf(signature[at..next]));
                at = next;
            }
            break :blk result;
        },
        else => 1,
    };
}
/// The size of a fixed-size type, or null for variable-size ones.
fn fixedSize(signature: []const u8) ?usize {
    return switch (signature[0]) {
        'b', 'y' => 1,
        'n', 'q' => 2,
        'i', 'u', 'h' => 4,
        'x', 't', 'd' => 8,
        '(', '{' => blk: {
            var offset: usize = 0;
            var at: usize = 1;
            while (signature[at] != ')' and signature[at] != '}') {
                const next = completeType(signature, at);
                const member = signature[at..next];
                offset = std.mem.alignForward(usize, offset, alignmentOf(member));
                offset += fixedSize(member) orelse return null;
                at = next;
            }
            // The unit tuple occupies one byte.
            if (offset == 0) break :blk 1;
            break :blk std.mem.alignForward(usize, offset, alignmentOf(signature));
        },
        else => null,
    };
}
fn completeType(signature: []const u8, start: usize) usize {
    var at = start;
    var depth: usize = 0;
    while (at < signature.len) : (at += 1) {
        switch (signature[at]) {
            'a', 'm' => continue,
            '(', '{' => depth += 1,
            ')', '}' => depth -= 1,
            else => {},
        }
        if (depth == 0) return at + 1;
    }
    return signature.len;
}
/// Bytes per framing offset in a container of `size` bytes.
fn offsetSize(size: usize) usize {
    if (size == 0) return 0;
    if (size <= 0xff) return 1;
    if (size <= 0xffff) return 2;
    if (size <= 0xffffffff) return 4;
    return 8;
}
fn readOffset(bytes: []const u8, width: usize) usize {
    var result: usize = 0;
    for (0..width) |i| result |= @as(usize, bytes[i]) << @intCast(8 * i);
    return result;
}

/// Decodes `bytes` as a value of type `signature`, allocating from `arena`.
/// GVariant never fails on malformed data; like GLib, invalid framing yields
/// default values only where GLib would, and an error elsewhere.
pub fn decode(arena: std.mem.Allocator, signature: []const u8, bytes: []const u8) Error!Value {
    return decodeDepth(arena, signature, bytes, 0);
}
fn decodeDepth(arena: std.mem.Allocator, signature: []const u8, bytes: []const u8, depth: usize) Error!Value {
    if (depth > 64) return error.InvalidData;
    if (fixedSize(signature)) |size| if (bytes.len != size) return error.InvalidData;
    return switch (signature[0]) {
        'b' => .{ .boolean = bytes[0] != 0 },
        'y' => .{ .byte = bytes[0] },
        'n' => .{ .int16 = std.mem.readInt(i16, bytes[0..2], .little) },
        'q' => .{ .uint16 = std.mem.readInt(u16, bytes[0..2], .little) },
        'i' => .{ .int32 = std.mem.readInt(i32, bytes[0..4], .little) },
        'u' => .{ .uint32 = std.mem.readInt(u32, bytes[0..4], .little) },
        'h' => .{ .fd = std.mem.readInt(i32, bytes[0..4], .little) },
        'x' => .{ .int64 = std.mem.readInt(i64, bytes[0..8], .little) },
        't' => .{ .uint64 = std.mem.readInt(u64, bytes[0..8], .little) },
        'd' => .{ .double = @bitCast(std.mem.readInt(u64, bytes[0..8], .little)) },
        's', 'o', 'g' => blk: {
            if (bytes.len == 0 or bytes[bytes.len - 1] != 0) return error.InvalidData;
            const text = try arena.dupe(u8, bytes[0 .. bytes.len - 1]);
            break :blk switch (signature[0]) {
                's' => .{ .string = text },
                'o' => .{ .object_path = text },
                else => .{ .signature = text },
            };
        },
        'v' => blk: {
            const separator = std.mem.lastIndexOfScalar(u8, bytes, 0) orelse return error.InvalidData;
            const inner_signature = bytes[separator + 1 ..];
            if (!dbus.isSingleType(inner_signature)) return error.InvalidData;
            const inner = try arena.create(Value);
            inner.* = try decodeDepth(arena, try arena.dupe(u8, inner_signature), bytes[0..separator], depth + 1);
            break :blk .{ .variant = inner };
        },
        'a' => array(arena, signature[1..], bytes, depth),
        '(', '{' => blk: {
            const fields = try tuple(arena, signature, bytes, depth);
            if (signature[0] == '(') break :blk .{ .structure = fields };
            const entry = try arena.create([2]Value);
            entry.* = .{ fields[0], fields[1] };
            break :blk .{ .dict_entry = entry };
        },
        // D-Bus values have no maybe type.
        else => error.UnsupportedType,
    };
}
fn array(arena: std.mem.Allocator, element: []const u8, bytes: []const u8, depth: usize) Error!Value {
    if (std.mem.eql(u8, element, "y")) return .{ .bytes = try arena.dupe(u8, bytes) };
    var items: std.ArrayList(Value) = .empty;
    if (fixedSize(element)) |size| {
        if (bytes.len % size != 0) return error.InvalidData;
        var at: usize = 0;
        while (at < bytes.len) : (at += size) try items.append(arena, try decodeDepth(arena, element, bytes[at..][0..size], depth + 1));
    } else if (bytes.len > 0) {
        const width = offsetSize(bytes.len);
        const last_end = readOffset(bytes[bytes.len - width ..], width);
        if (last_end > bytes.len or (bytes.len - last_end) % width != 0) return error.InvalidData;
        const count = (bytes.len - last_end) / width;
        const alignment = alignmentOf(element);
        var start: usize = 0;
        for (0..count) |i| {
            const end = readOffset(bytes[last_end + i * width ..], width);
            start = std.mem.alignForward(usize, start, alignment);
            if (end < start or end > last_end) return error.InvalidData;
            try items.append(arena, try decodeDepth(arena, element, bytes[start..end], depth + 1));
            start = end;
        }
    }
    return .{ .array = .{ .element = try arena.dupe(u8, element), .items = items.items } };
}
fn tuple(arena: std.mem.Allocator, signature: []const u8, bytes: []const u8, depth: usize) Error![]Value {
    var fields: std.ArrayList(Value) = .empty;
    const width = offsetSize(bytes.len);
    // Framing offsets for all variable-size members but the last, stored from the end.
    var offsets_used: usize = 0;
    var position: usize = 0;
    var at: usize = 1;
    while (signature[at] != ')' and signature[at] != '}') {
        const next = completeType(signature, at);
        const member = signature[at..next];
        const last = signature[next] == ')' or signature[next] == '}';
        position = std.mem.alignForward(usize, position, alignmentOf(member));
        const end = if (fixedSize(member)) |size| position + size else if (last) blk: {
            if (bytes.len < width * offsets_used) return error.InvalidData;
            break :blk bytes.len - width * offsets_used;
        } else blk: {
            offsets_used += 1;
            if (bytes.len < width * offsets_used) return error.InvalidData;
            break :blk readOffset(bytes[bytes.len - width * offsets_used ..], width);
        };
        if (end < position or end > bytes.len) return error.InvalidData;
        try fields.append(arena, try decodeDepth(arena, member, bytes[position..end], depth + 1));
        position = end;
        at = next;
    }
    return fields.items;
}

/// Encodes `value` in normal form, returning bytes owned by `allocator`.
pub fn encode(allocator: std.mem.Allocator, value: Value) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try write(allocator, &out, value);
    return out.toOwnedSlice(allocator);
}
pub const Change = struct { key: []const u8, value: ?Value };
/// A dconf changeset, `a{smv}`: keys with new values, or null to reset them.
pub fn encodeChangeset(allocator: std.mem.Allocator, changes: []const Change) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var offsets: std.ArrayList(usize) = .empty;
    defer offsets.deinit(allocator);
    for (changes) |change| {
        // Each {smv} entry: the key, then the maybe variant at 8-byte alignment,
        // then the key's end as the entry's only framing offset.
        try pad(allocator, &out, 0, 8);
        const start = out.items.len;
        try out.appendSlice(allocator, change.key);
        try out.append(allocator, 0);
        const key_end = out.items.len - start;
        try pad(allocator, &out, start, 8);
        if (change.value) |value| {
            const boxed = try allocator.create(Value);
            defer allocator.destroy(boxed);
            boxed.* = value;
            try write(allocator, &out, .{ .variant = boxed });
            try out.append(allocator, 0);
        }
        try writeOffsets(allocator, &out, start, &.{key_end});
        try offsets.append(allocator, out.items.len);
    }
    try writeOffsets(allocator, &out, 0, offsets.items);
    return out.toOwnedSlice(allocator);
}
fn pad(allocator: std.mem.Allocator, out: *std.ArrayList(u8), start: usize, alignment: usize) Error!void {
    while ((out.items.len - start) % alignment != 0) try out.append(allocator, 0);
}
fn writeOffsets(allocator: std.mem.Allocator, out: *std.ArrayList(u8), start: usize, offsets: []const usize) Error!void {
    // The offset width depends on the total size, including the offsets themselves.
    const body = out.items.len - start;
    var width: usize = 1;
    while (true) : (width *= 2) {
        const total = body + width * offsets.len;
        if (offsetSize(total) <= width or width == 8) break;
    }
    for (offsets) |offset| {
        for (0..width) |i| try out.append(allocator, @truncate(offset >> @intCast(8 * i)));
    }
}
fn write(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: Value) Error!void {
    const start = out.items.len;
    switch (value) {
        .boolean => |v| try out.append(allocator, @intFromBool(v)),
        .byte => |v| try out.append(allocator, v),
        .int16 => |v| try out.appendSlice(allocator, std.mem.asBytes(&std.mem.nativeToLittle(i16, v))),
        .uint16 => |v| try out.appendSlice(allocator, std.mem.asBytes(&std.mem.nativeToLittle(u16, v))),
        .int32, .fd => |v| try out.appendSlice(allocator, std.mem.asBytes(&std.mem.nativeToLittle(i32, v))),
        .uint32 => |v| try out.appendSlice(allocator, std.mem.asBytes(&std.mem.nativeToLittle(u32, v))),
        .int64 => |v| try out.appendSlice(allocator, std.mem.asBytes(&std.mem.nativeToLittle(i64, v))),
        .uint64 => |v| try out.appendSlice(allocator, std.mem.asBytes(&std.mem.nativeToLittle(u64, v))),
        .double => |v| try out.appendSlice(allocator, std.mem.asBytes(&std.mem.nativeToLittle(u64, @bitCast(v)))),
        .string, .object_path, .signature => |v| {
            try out.appendSlice(allocator, v);
            try out.append(allocator, 0);
        },
        .bytes => |v| try out.appendSlice(allocator, v),
        .variant => |inner| {
            try write(allocator, out, inner.*);
            try out.append(allocator, 0);
            var buffer: [256]u8 = undefined;
            try out.appendSlice(allocator, inner.signatureInto(&buffer) catch return error.UnsupportedType);
        },
        .array => |list| {
            const alignment = alignmentOf(list.element);
            if (fixedSize(list.element) != null) {
                for (list.items) |item| try write(allocator, out, item);
                return;
            }
            var offsets: std.ArrayList(usize) = .empty;
            defer offsets.deinit(allocator);
            for (list.items) |item| {
                try pad(allocator, out, start, alignment);
                try write(allocator, out, item);
                try offsets.append(allocator, out.items.len - start);
            }
            try writeOffsets(allocator, out, start, offsets.items);
        },
        .structure, .dict_entry => {
            const fields: []const Value = switch (value) {
                .structure => |items| items,
                .dict_entry => |entry| entry,
                else => unreachable,
            };
            var buffer: [256]u8 = undefined;
            const signature = value.signatureInto(&buffer) catch return error.UnsupportedType;
            if (fields.len == 0) return out.append(allocator, 0);
            var offsets: std.ArrayList(usize) = .empty;
            defer offsets.deinit(allocator);
            for (fields, 0..) |field, i| {
                var field_buffer: [256]u8 = undefined;
                const member = field.signatureInto(&field_buffer) catch return error.UnsupportedType;
                try pad(allocator, out, start, alignmentOf(member));
                try write(allocator, out, field);
                if (fixedSize(member) == null and i + 1 < fields.len) try offsets.append(allocator, out.items.len - start);
            }
            if (fixedSize(signature)) |size| {
                while (out.items.len - start < size) try out.append(allocator, 0);
                return;
            }
            // Offsets are stored in reverse order: the first one is last.
            std.mem.reverse(usize, offsets.items);
            try writeOffsets(allocator, out, start, offsets.items);
        },
    }
}

test "serialized values match GLib in both directions" {
    const c = @import("desktop-glib.zig");
    const g = struct {
        extern fn g_variant_get_data(*c.GVariant) ?*const anyopaque;
        extern fn g_variant_get_size(*c.GVariant) usize;
        extern fn g_variant_get_type_string(*c.GVariant) [*:0]const u8;
        extern fn g_variant_new_from_data(*const c.GVariantType, ?*const anyopaque, usize, c.gboolean, ?*anyopaque, ?*anyopaque) *c.GVariant;
        extern fn g_variant_print(*c.GVariant, c.gboolean) [*:0]u8;
        extern fn g_variant_type_new([*:0]const u8) *c.GVariantType;
        extern fn g_variant_type_free(*c.GVariantType) void;
    };
    const text = @import("desktop-dbus-text.zig");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][]const u8{
        "true",                                                                 "byte 0x7f",
        "int16 -2",                                                             "uint32 7",
        "int64 -9",                                                             "1.5",
        "'text'",                                                               "objectpath '/a/b'",
        "<'inner'>",                                                            "['a', 'bc', '']",
        "@as []",                                                               "[1, 2, 3]",
        "{'a': <1>, 'b': <'x'>}",                                               "(1, 'two', true)",
        "('first', 'second')",                                                  "(byte 0x01, 2)",
        "[('Text', [(uint32 0, '*.txt')]), ('Images', [(uint32 1, 'png')])]", "[b'one', b'two']",
        "{'org/gnome/desktop/interface': {'clock-format': <'24h'>}}",
    };
    for (cases) |case| {
        const parsed = c.g_variant_take_ref(c.g_variant_parse(null, @ptrCast((try a.dupeSentinel(u8, case, 0)).ptr), null, null, null)).?;
        defer c.g_variant_unref(parsed);
        const signature = std.mem.span(g.g_variant_get_type_string(parsed));
        const size = g.g_variant_get_size(parsed);
        const glib_bytes: []const u8 = if (g.g_variant_get_data(parsed)) |data| @as([*]const u8, @ptrCast(data))[0..size] else &.{};
        // GLib's bytes decode to the same value, printed the same way.
        const value = try decode(a, signature, glib_bytes);
        const printed = std.mem.span(g.g_variant_print(parsed, 1));
        defer c.g_free(printed.ptr);
        const native_text = try text.print(a, value);
        const native_back = try text.parse(a, signature, native_text);
        const glib_back = try text.parse(a, signature, printed);
        try std.testing.expectEqualStrings(try text.print(a, glib_back), try text.print(a, native_back));
        // And the native encoding is byte-for-byte what GLib produces.
        const encoded = try encode(a, value);
        std.testing.expectEqualSlices(u8, glib_bytes, encoded) catch |err| {
            std.debug.print("encoding differs for {s}\n", .{case});
            return err;
        };
        const kind = g.g_variant_type_new(@ptrCast((try a.dupeSentinel(u8, signature, 0)).ptr));
        defer g.g_variant_type_free(kind);
        const reread = c.g_variant_take_ref(g.g_variant_new_from_data(kind, encoded.ptr, encoded.len, 1, null, null)).?;
        defer c.g_variant_unref(reread);
        const reread_text = std.mem.span(g.g_variant_print(reread, 1));
        defer c.g_free(reread_text.ptr);
        try std.testing.expectEqualStrings(printed, reread_text);
    }
}

test "dconf changesets match GLib" {
    const c = @import("desktop-glib.zig");
    const g = struct {
        extern fn g_variant_get_data(*c.GVariant) ?*const anyopaque;
        extern fn g_variant_get_size(*c.GVariant) usize;
    };
    const text = "{'/org/gnome/desktop/interface/color-scheme': <'prefer-dark'>, '/org/x/reset': nothing, '/a': <true>}";
    const parsed = c.g_variant_take_ref(c.g_variant_parse(@ptrCast("a{smv}"), text, null, null, null)).?;
    defer c.g_variant_unref(parsed);
    const expected = @as([*]const u8, @ptrCast(g.g_variant_get_data(parsed).?))[0..g.g_variant_get_size(parsed)];
    const encoded = try encodeChangeset(std.testing.allocator, &.{
        .{ .key = "/org/gnome/desktop/interface/color-scheme", .value = .{ .string = "prefer-dark" } },
        .{ .key = "/org/x/reset", .value = null },
        .{ .key = "/a", .value = .{ .boolean = true } },
    });
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualSlices(u8, expected, encoded);
}
