//! Typed portal options and results: `a{sv}` dictionaries of D-Bus values.
const std = @import("std");
const dbus = @import("dbus");

pub const Dict = dbus.Dict([]const u8, dbus.Value);
/// Reports a portal response code and its results; the results are borrowed for the call.
pub const Completion = *const fn (?*anyopaque, u32, Dict) void;
pub const empty: Dict = .{ .entries = &.{} };

pub fn Options(comptime invalid: anyerror) type {
    return struct {
        /// The option's value, null when missing, or `invalid` when it has another type.
        pub fn get(options: Dict, key: []const u8, signature: []const u8) !?dbus.Value {
            for (options.entries) |entry| {
                if (!std.mem.eql(u8, entry.key, key)) continue;
                var buffer: [256]u8 = undefined;
                const actual = entry.value.signatureInto(&buffer) catch return invalid;
                if (!std.mem.eql(u8, actual, signature)) return invalid;
                return entry.value;
            }
            return null;
        }
        pub fn boolean(options: Dict, key: []const u8, fallback: bool) !bool {
            return (try get(options, key, "b") orelse return fallback).boolean;
        }
        pub fn string(options: Dict, key: []const u8) !?[]const u8 {
            return (try get(options, key, "s") orelse return null).string;
        }
    };
}

/// A deep copy of `options` for holders that outlive the message.
pub fn clone(arena: std.mem.Allocator, options: Dict) !Dict {
    const entries = try arena.alloc(Dict.Entry, options.entries.len);
    for (entries, options.entries) |*out, entry| out.* = .{ .key = try arena.dupe(u8, entry.key), .value = try entry.value.clone(arena) };
    return .{ .entries = entries };
}

/// Collects response results.
pub const Results = struct {
    arena: std.mem.Allocator,
    entries: std.ArrayList(Dict.Entry) = .empty,

    pub fn put(self: *Results, key: []const u8, value: dbus.Value) !void {
        try self.entries.append(self.arena, .{ .key = key, .value = value });
    }
    pub fn dict(self: *const Results) Dict {
        return .{ .entries = self.entries.items };
    }
};

test "portal options distinguish missing values from invalid types" {
    const Check = Options(error.InvalidTestOption);
    const entries = [_]Dict.Entry{
        .{ .key = "enabled", .value = .{ .boolean = true } },
        .{ .key = "disabled", .value = .{ .boolean = false } },
        .{ .key = "title", .value = .{ .string = "Print" } },
    };
    const options: Dict = .{ .entries = &entries };
    try std.testing.expectEqual(@as(?dbus.Value, null), try Check.get(options, "missing", "s"));
    try std.testing.expect(try Check.boolean(options, "missing", true));
    try std.testing.expect(!try Check.boolean(options, "missing", false));
    try std.testing.expect(try Check.boolean(options, "enabled", false));
    try std.testing.expect(!try Check.boolean(options, "disabled", true));
    try std.testing.expectError(error.InvalidTestOption, Check.boolean(options, "title", false));
    try std.testing.expectError(error.InvalidEmailOption, Options(error.InvalidEmailOption).get(options, "enabled", "s"));
    try std.testing.expectEqualStrings("Print", (try Check.string(options, "title")).?);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const copy = try clone(arena.allocator(), options);
    try std.testing.expectEqualStrings("Print", (try Check.string(copy, "title")).?);
}
