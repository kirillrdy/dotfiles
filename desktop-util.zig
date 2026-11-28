const std = @import("std");
pub fn number(v: std.json.Value) ?f64 {
    const n: f64 = switch (v) {
        .integer => |n| @floatFromInt(n),
        .float => |n| n,
        else => return null,
    };
    return if (std.math.isFinite(n)) n else null;
}
pub fn read(a: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    // procfs/sysfs files can report size zero while still returning data.
    var reader = file.readerStreaming(io, &.{});
    return reader.interface.allocRemaining(a, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        else => |e| return e,
    };
}
pub fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
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
/// Formats to standard output, for fixtures whose checks read it.
pub fn printOut(comptime format: []const u8, args: anytype) void {
    var buffer: [4096]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, format, args) catch buffer[0..];
    var written: usize = 0;
    while (written < text.len) {
        const result = std.os.linux.write(1, text[written..].ptr, text.len - written);
        if (std.os.linux.errno(result) != .SUCCESS) return;
        written += result;
    }
}
