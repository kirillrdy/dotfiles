//! Compare the generated Zig protocol bindings with independently compiled wayland-scanner output.
const std = @import("std");
const wl = @import("wayland-client");
const wire = @import("wayland-wire");

/// libwayland's C metadata layout, as emitted by `wayland-scanner private-code`.
const Interface = extern struct {
    name: [*:0]const u8,
    version: c_int,
    method_count: c_int,
    methods: [*]const Message,
    event_count: c_int,
    events: [*]const Message,
};
const Message = extern struct {
    name: [*:0]const u8,
    signature: [*:0]const u8,
    types: [*]const ?*const Interface,
};

fn sameMessages(actual: []const wire.Message, expected: [*]const Message) !void {
    for (actual, 0..) |message, i| {
        try std.testing.expectEqualStrings(std.mem.span(expected[i].name), message.name);
        // libwayland prefixes the `since` version; the wire runtime keeps it separately.
        const full = std.mem.span(expected[i].signature);
        const digits = std.mem.indexOfNone(u8, full, "0123456789") orelse full.len;
        const since = if (digits == 0) 1 else try std.fmt.parseInt(u32, full[0..digits], 10);
        try std.testing.expectEqual(since, message.since);
        try std.testing.expectEqualStrings(full[digits..], message.signature);
        // Typed new_id arguments must create objects of the same interface.
        var argument: usize = 0;
        var created: ?*const Interface = null;
        for (full[digits..]) |kind| {
            if (kind == '?') continue;
            if (kind == 'n') {
                if (expected[i].types[argument]) |target| created = target;
            }
            argument += 1;
        }
        if (created) |target| {
            const resolver = message.new_id orelse return error.MissingNewIdInterface;
            try std.testing.expectEqualStrings(std.mem.span(target.name), resolver().name);
            try std.testing.expectEqual(@as(u32, @intCast(target.version)), resolver().version);
        } else try std.testing.expect(message.new_id == null);
    }
}

test "generated Wayland bindings match every reference interface and message" {
    @setEvalBranchQuota(100000);
    const names = @import("options").reference_interfaces;
    inline for (names) |name| {
        const generated = @field(wl, name[0 .. name.len - "_interface".len]).interface;
        const expected = @extern(*const Interface, .{ .name = "reference_" ++ name });
        try std.testing.expectEqualStrings(std.mem.span(expected.name), generated.name);
        try std.testing.expectEqual(@as(u32, @intCast(expected.version)), generated.version);
        try std.testing.expectEqual(@as(usize, @intCast(expected.method_count)), generated.requests.len);
        try std.testing.expectEqual(@as(usize, @intCast(expected.event_count)), generated.events.len);
        try sameMessages(generated.requests, expected.methods);
        try sameMessages(generated.events, expected.events);
    }
    try std.testing.expectEqual(@as(usize, 49), names.len);
}
