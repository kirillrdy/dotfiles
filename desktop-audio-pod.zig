//! Bounded SPA parameter decoding and fixed-buffer encoding in native byte order.
const std = @import("std");
const p = @import("pipewire");
const endian = @import("builtin").cpu.arch.endian();
pub const Error = error{ InvalidPod, WrongPodType, BufferTooSmall };
fn word(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], endian);
}
fn put(bytes: []u8, value: u32) void {
    std.mem.writeInt(u32, bytes[0..4], value, endian);
}
pub const View = struct {
    bytes: []const u8,
    pub fn init(bytes: []const u8) Error!View {
        if (bytes.len < 8 or bytes.len > 1024 * 1024) return error.InvalidPod;
        const size: usize = word(bytes);
        if (size > bytes.len - 8) return error.InvalidPod;
        return .{ .bytes = bytes[0 .. size + 8] };
    }
    pub fn kind(self: View) u32 {
        return word(self.bytes[4..]);
    }
    fn scalar(self: View, expected: u32) Error!u32 {
        if (self.kind() != expected or self.bytes.len != 12) return error.WrongPodType;
        return word(self.bytes[8..]);
    }
    pub fn boolean(self: View) Error!bool {
        return try self.scalar(p.SPA_TYPE_Bool) != 0;
    }
    pub fn integer(self: View) Error!i32 {
        return @bitCast(try self.scalar(p.SPA_TYPE_Int));
    }
    pub fn float(self: View) Error!f32 {
        return @bitCast(try self.scalar(p.SPA_TYPE_Float));
    }
    pub fn floats(self: View) Error![]align(1) const f32 {
        if (self.kind() != p.SPA_TYPE_Array or self.bytes.len < 16) return error.WrongPodType;
        if (word(self.bytes[8..]) != 4 or word(self.bytes[12..]) != p.SPA_TYPE_Float or (self.bytes.len - 16) % 4 != 0) return error.InvalidPod;
        const values: [*]align(1) const f32 = @ptrCast(self.bytes[16..].ptr);
        return values[0 .. (self.bytes.len - 16) / 4];
    }
    pub fn object(self: View, expected: u32) Error!Object {
        if (self.kind() != p.SPA_TYPE_Object or self.bytes.len < 16 or word(self.bytes[8..]) != expected) return error.WrongPodType;
        const result = Object{ .view = self };
        // Validate the entire object, including properties after the ones used.
        var cursor = result.iterator();
        while (try cursor.next() != null) {}
        return result;
    }
};
pub const Object = struct {
    view: View,
    pub fn id(self: Object) u32 {
        return word(self.view.bytes[12..]);
    }
    fn iterator(self: Object) Iterator {
        return .{ .bytes = self.view.bytes[16..] };
    }
    pub fn property(self: Object, key: u32) ?View {
        var cursor = self.iterator();
        while (cursor.next() catch unreachable) |entry| if (entry.key == key) return entry.value;
        return null;
    }
};
const Iterator = struct {
    bytes: []const u8,
    fn next(self: *Iterator) Error!?struct { key: u32, value: View } {
        if (self.bytes.len == 0) return null;
        if (self.bytes.len < 16) return error.InvalidPod;
        const value = try View.init(self.bytes[8..]);
        const length = std.mem.alignForward(usize, 8 + value.bytes.len, 8);
        if (length > self.bytes.len) return error.InvalidPod;
        const key = word(self.bytes);
        self.bytes = self.bytes[length..];
        return .{ .key = key, .value = value };
    }
};
pub const Builder = struct {
    bytes: []align(8) u8,
    used: usize = 16,
    pub fn init(bytes: []align(8) u8, kind: u32, id: u32) Error!Builder {
        if (bytes.len < 16) return error.BufferTooSmall;
        put(bytes, 8);
        put(bytes[4..], p.SPA_TYPE_Object);
        put(bytes[8..], kind);
        put(bytes[12..], id);
        return .{ .bytes = bytes };
    }
    fn add(self: *Builder, key: u32, kind: u32, body: []const u8) Error!void {
        const remaining = self.bytes.len - self.used;
        if (remaining < 16 or body.len > remaining - 16) return error.BufferTooSmall;
        const length = std.mem.alignForward(usize, 16 + body.len, 8);
        if (length > remaining) return error.BufferTooSmall;
        const dest = self.bytes[self.used..][0..length];
        @memset(dest, 0);
        put(dest, key);
        put(dest[8..], @intCast(body.len));
        put(dest[12..], kind);
        @memcpy(dest[16..][0..body.len], body);
        self.used += length;
        put(self.bytes, @intCast(self.used - 8));
    }
    pub fn identifier(self: *Builder, key: u32, value: u32) Error!void {
        var bytes: [4]u8 = undefined;
        put(&bytes, value);
        try self.add(key, p.SPA_TYPE_Id, &bytes);
    }
    pub fn pair(self: *Builder, key: u32, kind: u32, first: u32, second: u32) Error!void {
        var bytes: [8]u8 = undefined;
        put(&bytes, first);
        put(bytes[4..], second);
        try self.add(key, kind, &bytes);
    }
    pub fn boolean(self: *Builder, key: u32, value: bool) Error!void {
        var bytes: [4]u8 = undefined;
        put(&bytes, @intFromBool(value));
        try self.add(key, p.SPA_TYPE_Bool, &bytes);
    }
    pub fn integer(self: *Builder, key: u32, value: i32) Error!void {
        var bytes: [4]u8 = undefined;
        put(&bytes, @bitCast(value));
        try self.add(key, p.SPA_TYPE_Int, &bytes);
    }
    pub fn float(self: *Builder, key: u32, value: f32) Error!void {
        var bytes: [4]u8 = undefined;
        put(&bytes, @bitCast(value));
        try self.add(key, p.SPA_TYPE_Float, &bytes);
    }
    pub fn floats(self: *Builder, key: u32, values: []const f32) Error!void {
        var bytes: [8 + 64 * 4]u8 = undefined;
        if (values.len > 64) return error.BufferTooSmall;
        put(&bytes, 4);
        put(bytes[4..], p.SPA_TYPE_Float);
        @memcpy(bytes[8..][0 .. values.len * 4], std.mem.sliceAsBytes(values));
        try self.add(key, p.SPA_TYPE_Array, bytes[0 .. 8 + values.len * 4]);
    }
    pub fn object(self: *Builder, key: u32, value: View) Error!void {
        try self.add(key, value.kind(), value.bytes[8..]);
    }
    pub fn view(self: Builder) View {
        return .{ .bytes = self.bytes[0..self.used] };
    }
};

test "SPA objects reject truncated headers, values and property padding" {
    try std.testing.expectError(error.InvalidPod, View.init(&.{ 0, 0, 0 }));
    var bytes: [128]u8 align(8) = undefined;
    var builder = try Builder.init(&bytes, p.SPA_TYPE_OBJECT_Props, p.SPA_PARAM_Props);
    try builder.boolean(p.SPA_PROP_mute, true);
    const object = try builder.view().object(p.SPA_TYPE_OBJECT_Props);
    try std.testing.expect(try object.property(p.SPA_PROP_mute).?.boolean());
    try std.testing.expectError(error.WrongPodType, object.property(p.SPA_PROP_mute).?.float());
    for (0..builder.used) |length| try std.testing.expectError(error.InvalidPod, View.init(bytes[0..length]));
    put(&bytes, @intCast(builder.used - 9));
    const short = try View.init(bytes[0..builder.used]);
    try std.testing.expectError(error.InvalidPod, short.object(p.SPA_TYPE_OBJECT_Props));
    put(bytes[24..], std.math.maxInt(u32));
    try std.testing.expectError(error.InvalidPod, short.object(p.SPA_TYPE_OBJECT_Props));
}
test "SPA builders fail cleanly when fields or their alignment do not fit" {
    var bytes: [39]u8 align(8) = undefined;
    var builder = try Builder.init(&bytes, p.SPA_TYPE_OBJECT_Props, p.SPA_PARAM_Props);
    try std.testing.expectError(error.BufferTooSmall, builder.boolean(p.SPA_PROP_mute, true));
    try std.testing.expectEqual(@as(usize, 16), builder.used);
    _ = try builder.view().object(p.SPA_TYPE_OBJECT_Props);
}
