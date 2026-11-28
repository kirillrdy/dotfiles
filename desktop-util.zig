const std = @import("std");
pub const libc = @import("desktop-libc.zig");
pub fn sleep(io: std.Io, nanoseconds: u64) void {
    io.sleep(.fromNanoseconds(nanoseconds), .awake) catch {};
}
fn micros(clock: std.c.clockid_t) i64 {
    var now: std.c.timespec = undefined;
    _ = std.c.clock_gettime(clock, &now);
    return @as(i64, now.sec) * std.time.us_per_s + @divTrunc(@as(i64, now.nsec), std.time.ns_per_us);
}
/// CLOCK_MONOTONIC in microseconds, matching g_get_monotonic_time().
pub fn monotonicTime() i64 {
    return micros(.MONOTONIC);
}
/// CLOCK_REALTIME in microseconds, matching g_get_real_time().
pub fn realTime() i64 {
    return micros(.REALTIME);
}
pub fn timestamp(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toSeconds();
}
pub const Timer = struct {
    started: std.Io.Timestamp,
    pub fn start(io: std.Io) Timer {
        return .{ .started = std.Io.Clock.awake.now(io) };
    }
    pub fn read(self: Timer, io: std.Io) u64 {
        return @intCast(self.started.untilNow(io, .awake).toNanoseconds());
    }
};
pub fn object() std.json.Value {
    return .{ .object = .empty };
}
pub fn array(a: std.mem.Allocator) std.json.Value {
    return .{ .array = std.array_list.Managed(std.json.Value).init(a) };
}
pub fn put(a: std.mem.Allocator, o: *std.json.Value, key: []const u8, value: std.json.Value) !void {
    try o.object.put(a, key, value);
}
pub fn str(s: []const u8) std.json.Value {
    return .{ .string = s };
}
pub fn num(n: f64) std.json.Value {
    return .{ .float = n };
}
pub fn get(o: std.json.Value, key: []const u8) std.json.Value {
    return if (o == .object) o.object.get(key) orelse .null else .null;
}
pub fn string(v: std.json.Value) []const u8 {
    return if (v == .string) v.string else "";
}
pub fn number(v: std.json.Value) ?f64 {
    const n: f64 = switch (v) {
        .integer => |n| @floatFromInt(n),
        .float => |n| n,
        else => return null,
    };
    return if (std.math.isFinite(n)) n else null;
}
pub fn fmt(a: std.mem.Allocator, comptime format: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(a, format, args);
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
    const value = libc.getenv(name);
    return if (value == null) null else std.mem.span(value);
}
/// A libc mutex: usable from any thread without a std.Io instance.
pub const Mutex = struct {
    inner: std.c.pthread_mutex_t = .{},
    pub fn lock(self: *Mutex) void {
        _ = std.c.pthread_mutex_lock(&self.inner);
    }
    pub fn unlock(self: *Mutex) void {
        _ = std.c.pthread_mutex_unlock(&self.inner);
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
pub fn cast(comptime T: type, ptr: anytype) *T {
    return @ptrCast(@alignCast(ptr));
}
/// Equality of optional C strings: two nulls are equal.
pub fn strEql(left: [*c]const u8, right: [*c]const u8) bool {
    if (left == null or right == null) return left == right;
    return std.mem.orderZ(u8, left, right) == .eq;
}
pub fn dupeZ(allocator: std.mem.Allocator, value: []const u8) [:0]u8 {
    return allocator.dupeSentinel(u8, value, 0) catch @panic("out of memory");
}
pub fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
pub fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \n\r\t");
}
pub fn parse(a: std.mem.Allocator, s: []const u8) !std.json.Value {
    return (try std.json.parseFromSlice(std.json.Value, a, s, .{ .allocate = .alloc_always })).value;
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
