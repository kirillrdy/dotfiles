const std = @import("std");
pub const Value = std.json.Value;
pub const Allocator = std.mem.Allocator;
// Executables provide their process I/O implementation; tests use the runner's.
pub var io: std.Io = if (@import("builtin").is_test) std.testing.io else undefined;
pub const libc = @import("libc");
pub fn sleep(nanoseconds: u64) void {
    io.sleep(.fromNanoseconds(nanoseconds), .awake) catch {};
}
pub fn timestamp() i64 {
    return std.Io.Clock.real.now(io).toSeconds();
}
pub const Timer = struct {
    started: std.Io.Timestamp,
    pub fn start() Timer {
        return .{ .started = std.Io.Clock.awake.now(io) };
    }
    pub fn read(self: Timer) u64 {
        return @intCast(self.started.untilNow(io, .awake).toNanoseconds());
    }
};
pub fn object() Value {
    return .{ .object = .empty };
}
pub fn array(a: Allocator) Value {
    return .{ .array = std.array_list.Managed(Value).init(a) };
}
pub fn put(a: Allocator, o: *Value, key: []const u8, value: Value) !void {
    try o.object.put(a, key, value);
}
pub fn str(s: []const u8) Value {
    return .{ .string = s };
}
pub fn num(n: f64) Value {
    return .{ .float = n };
}
pub fn get(o: Value, key: []const u8) Value {
    return if (o == .object) o.object.get(key) orelse .null else .null;
}
pub fn string(v: Value) []const u8 {
    return if (v == .string) v.string else "";
}
pub fn number(v: Value) ?f64 {
    const n: f64 = switch (v) {
        .integer => |n| @floatFromInt(n),
        .float => |n| n,
        else => return null,
    };
    return if (std.math.isFinite(n)) n else null;
}
pub fn fmt(a: Allocator, comptime format: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(a, format, args);
}
pub fn read(a: Allocator, path: []const u8) ![]const u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    // procfs/sysfs files can report size zero while still returning data.
    var reader = file.readerStreaming(io, &.{});
    return reader.interface.allocRemaining(a, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.ReadFailed => return reader.err.?,
        else => |e| return e,
    };
}
pub fn exists(path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}
pub fn env(name: [:0]const u8) ?[]const u8 {
    const value = libc.getenv(name);
    return if (value == null) null else std.mem.span(value);
}
pub fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
pub fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \n\r\t");
}
pub fn parse(a: Allocator, s: []const u8) !Value {
    return (try std.json.parseFromSlice(Value, a, s, .{ .allocate = .alloc_always })).value;
}
pub fn command(a: Allocator, args: []const []const u8, seconds: u32) []const u8 {
    const argv = a.alloc([]const u8, args.len + 3) catch return "";
    argv[0] = "timeout";
    argv[1] = "--signal=KILL";
    argv[2] = fmt(a, "{d}", .{seconds}) catch return "";
    @memcpy(argv[3..], args);
    const result = std.process.run(a, io, .{ .argv = argv, .stdout_limit = .limited(4 * 1024 * 1024), .stderr_limit = .limited(4 * 1024 * 1024) }) catch return "";
    return switch (result.term) {
        .exited => |code| if (code == 0) trim(result.stdout) else "",
        else => "",
    };
}
pub fn localTime(a: Allocator, stamp: i64, comptime format: [:0]const u8) ![]const u8 {
    var t: libc.time_t = @intCast(stamp);
    var tm: libc.struct_tm = undefined;
    if (libc.localtime_r(&t, &tm) == null) return error.InvalidTime;
    var buffer: [128]u8 = undefined;
    const len = libc.strftime(&buffer, buffer.len, format, &tm);
    if (len == 0) return error.InvalidTime;
    return a.dupe(u8, buffer[0..len]);
}
