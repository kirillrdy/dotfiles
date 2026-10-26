//! Compare native metadata with independently compiled wayland-scanner output.
const std = @import("std");
const protocols = @import("protocols");
const Interface = protocols.Interface;

fn sameMessages(actual: [*c]const @import("gtk").struct_wl_message, expected: [*c]const @import("gtk").struct_wl_message, count: usize) !void {
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
    try std.testing.expectEqual(@as(usize, 21), checked);
}
