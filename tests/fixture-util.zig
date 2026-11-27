//! Shared helpers for isolated Zig test fixtures.
const std = @import("std");
const desktop = @import("desktop");
const mainloop = desktop.mainloop;
const util = desktop.util;

pub fn pump() void {
    while (mainloop.iteration(false)) {}
    mainloop.sleep(1000);
}

pub fn pumpFor(duration_us: i64) void {
    const deadline = util.monotonicTime() + duration_us;
    while (util.monotonicTime() < deadline) pump();
}

pub fn assertEq(actual: [*c]const u8, expected: []const u8) void {
    std.debug.assert(std.mem.eql(u8, std.mem.span(actual), expected));
}
