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
    const deadline = std.Io.Clock.awake.now(io).toMicroseconds() + duration_us;
    while (std.Io.Clock.awake.now(io).toMicroseconds() < deadline) pump(io);
}

pub fn assertEq(actual: [*c]const u8, expected: []const u8) void {
    std.debug.assert(std.mem.eql(u8, std.mem.span(actual), expected));
}

pub fn printOut(io: std.Io, comptime format: []const u8, args: anytype) void {
    var buffer: [4096]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, format, args) catch buffer[0..];
    std.Io.File.stdout().writeStreamingAll(io, text) catch {};
}
