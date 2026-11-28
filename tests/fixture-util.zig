//! Shared helpers for isolated Zig test fixtures.
const std = @import("std");
const desktop = @import("desktop");
const mainloop = desktop.mainloop;
const util = desktop.util;

pub fn pump(io: std.Io) void {
    while (mainloop.iteration(io, false)) {}
    mainloop.sleep(1000);
}

pub fn pumpFor(io: std.Io, duration_us: i64) void {
    const deadline = util.monotonicTime(io) + duration_us;
    while (util.monotonicTime(io) < deadline) pump(io);
}

pub fn assertEq(actual: [*c]const u8, expected: []const u8) void {
    std.debug.assert(std.mem.eql(u8, std.mem.span(actual), expected));
}
