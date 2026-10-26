//! Linked only into the isolated compositor fixture, never desktop-zig.
const std = @import("std");
pub fn authenticate(_: [*:0]const u8, password: [*:0]const u8) bool {
    const success = std.mem.eql(u8, std.mem.span(password), "fixture-password");
    std.debug.print("fixture-auth: {s}\n", .{if (success) "accepted" else "rejected"});
    return success;
}
