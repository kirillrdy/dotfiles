//! Default audio devices through PipeWire metadata, without a client plugin.
const std = @import("std");

const Device = struct { name: []const u8 };
fn decode(a: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Device) {
    // Metadata comes from another client; bound parser allocations.
    if (bytes.len > 64 * 1024) return error.InvalidDefaultDevice;
    return std.json.parseFromSlice(Device, a, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}
pub fn encode(a: std.mem.Allocator, name: []const u8) ![:0]u8 {
    const json = try std.json.Stringify.valueAlloc(a, Device{ .name = name }, .{});
    defer a.free(json);
    return a.dupeSentinel(u8, json, 0);
}

pub const Defaults = struct {
    output: ?[]u8 = null,
    input: ?[]u8 = null,
    pub fn deinit(self: *Defaults, a: std.mem.Allocator) void {
        if (self.output) |value| a.free(value);
        if (self.input) |value| a.free(value);
        self.* = .{};
    }
    pub fn name(self: *const Defaults, output: bool) ?[]const u8 {
        return if (output) self.output else self.input;
    }
    pub fn update(self: *Defaults, a: std.mem.Allocator, subject: u32, key: ?[]const u8, kind: ?[]const u8, json: ?[]const u8) bool {
        if (subject != 0) return false;
        if (key == null) {
            const changed = self.output != null or self.input != null;
            self.deinit(a);
            return changed;
        }
        const target = if (std.mem.eql(u8, key.?, "default.audio.sink")) &self.output else if (std.mem.eql(u8, key.?, "default.audio.source")) &self.input else return false;
        var replacement: ?[]u8 = null;
        if (json != null and kind != null and std.mem.eql(u8, kind.?, "Spa:String:JSON")) {
            if (decode(a, json.?)) |device| {
                defer device.deinit();
                replacement = a.dupe(u8, device.value.name) catch return false;
            } else |_| {}
        }
        if (target.* != null and replacement != null and std.mem.eql(u8, target.*.?, replacement.?)) {
            a.free(replacement.?);
            return false;
        }
        const changed = target.* != null or replacement != null;
        if (target.*) |old| a.free(old);
        target.* = replacement;
        return changed;
    }
};

test "default device metadata handles escaping, unknown fields and invalid names" {
    const a = std.testing.allocator;
    const name = "speakers \"USB\" \\ output\n日本語";
    const json = try encode(a, name);
    defer a.free(json);
    const device = try decode(a, json);
    defer device.deinit();
    try std.testing.expectEqualStrings(name, device.value.name);
    const extra = try decode(a, "{\"other\":42,\"name\":\"sink\"}");
    defer extra.deinit();
    try std.testing.expectEqualStrings("sink", extra.value.name);
    try std.testing.expectError(error.MissingField, decode(a, "{}"));
    try std.testing.expectError(error.UnexpectedToken, decode(a, "{\"name\":42}"));
    try std.testing.expectError(error.InvalidDefaultDevice, decode(a, &@as([65537]u8, @splat(' '))));
}

test "metadata updates replace and clear only the selected default" {
    const a = std.testing.allocator;
    var defaults: Defaults = .{};
    defer defaults.deinit(a);
    try std.testing.expect(defaults.update(a, 0, "default.audio.sink", "Spa:String:JSON", "{\"name\":\"speakers\"}"));
    try std.testing.expect(defaults.update(a, 0, "default.audio.source", "Spa:String:JSON", "{\"name\":\"mic\"}"));
    try std.testing.expect(!defaults.update(a, 1, null, null, null));
    try std.testing.expect(!defaults.update(a, 0, "default.audio.sink", "Spa:String:JSON", "{\"name\":\"speakers\"}"));
    try std.testing.expect(defaults.update(a, 0, "default.audio.sink", "wrong", "{}"));
    try std.testing.expect(defaults.name(true) == null);
    try std.testing.expectEqualStrings("mic", defaults.name(false).?);
    try std.testing.expect(defaults.update(a, 0, null, null, null));
    try std.testing.expect(defaults.name(false) == null);
}
