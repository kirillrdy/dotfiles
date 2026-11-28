const std = @import("std");
pub fn number(v: std.json.Value) ?f64 {
    const n: f64 = switch (v) {
        .integer => |n| @floatFromInt(n),
        .float => |n| n,
        else => return null,
    };
    return if (std.math.isFinite(n)) n else null;
}
pub fn env(name: [:0]const u8) ?[:0]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.span(value);
}
/// A mutex usable with a std.Io instance.
pub const Mutex = struct {
    inner: std.Io.Mutex = .init,
    pub fn lock(self: *Mutex, io: std.Io) void {
        self.inner.lockUncancelable(io);
    }
    pub fn unlock(self: *Mutex, io: std.Io) void {
        self.inner.unlock(io);
    }
};
/// A value computed once on first use, from any thread.
pub fn Lazy(comptime T: type, comptime compute: fn () T) type {
    return struct {
        var value: T = undefined;
        var state = std.atomic.Value(u8).init(0);
        pub fn get() *const T {
            if (state.load(.acquire) == 2) return &value;
            if (state.cmpxchgStrong(0, 1, .acquire, .monotonic) == null) {
                value = compute();
                state.store(2, .release);
                return &value;
            }
            while (state.load(.acquire) != 2) std.atomic.spinLoopHint();
            return &value;
        }
    };
}
pub fn localTime(a: std.mem.Allocator, stamp: i64, comptime format: [:0]const u8) ![]const u8 {
    const value = @import("desktop-datetime.zig").DateTime.fromUnix(stamp) catch return error.InvalidTime;
    var buffer: [128]u8 = undefined;
    return a.dupe(u8, value.format(&buffer, format) catch return error.InvalidTime);
}
