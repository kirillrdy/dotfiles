const std = @import("std");
pub const Value = std.json.Value;
pub const Allocator = std.mem.Allocator;
pub const libc = @cImport({
    @cInclude("time.h");
    @cInclude("unistd.h");
    @cInclude("poll.h");
    @cInclude("stdio.h");
    @cInclude("errno.h");
});
pub fn object(a: Allocator) Value {
    return .{ .object = std.json.ObjectMap.init(a) };
}
pub fn array(a: Allocator) Value {
    return .{ .array = std.ArrayList(Value).init(a) };
}
pub fn put(o: *Value, key: []const u8, value: Value) !void {
    try o.object.put(key, value);
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
    return std.fs.cwd().readFileAlloc(a, path, 4 * 1024 * 1024);
}
pub fn exists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}
pub fn env(name: [:0]const u8) ?[]const u8 {
    return std.posix.getenv(name);
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
pub fn emit(a: Allocator, v: anytype) !void {
    const s = try std.json.stringifyAlloc(a, v, .{});
    try std.io.getStdOut().writeAll(s);
    try std.io.getStdOut().writeAll("\n");
}
pub fn command(a: Allocator, args: []const []const u8, seconds: u32) []const u8 {
    const argv = a.alloc([]const u8, args.len + 3) catch return "";
    argv[0] = "timeout";
    argv[1] = "--signal=KILL";
    argv[2] = fmt(a, "{d}", .{seconds}) catch return "";
    @memcpy(argv[3..], args);
    const result = std.process.Child.run(.{ .allocator = a, .argv = argv, .max_output_bytes = 4 * 1024 * 1024 }) catch return "";
    return switch (result.term) {
        .Exited => |code| if (code == 0) trim(result.stdout) else "",
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
