const std = @import("std");
const c = @import("gtk");
const idle = @import("idle");
var stopping = false;
fn stop(_: ?*anyopaque) callconv(.c) c_int {
    stopping = true;
    return 1;
}
pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const args = try init.minimal.args.toSlice(arena.allocator());
    if (args.len != 3) return error.ExpectedTimeoutAndLocker;
    const locker = try arena.allocator().dupeSentinel(u8, args[2], 0);
    const service = try idle.Service.create(.{ .timeout_ms = try std.fmt.parseInt(u32, args[1], 10), .lock_executable = locker });
    const term = c.g_unix_signal_add(c.SIGTERM, &stop, null);
    defer _ = c.g_source_remove(term);
    while (!stopping) _ = c.g_main_context_iteration(null, 1);
    service.destroy();
    while (c.g_main_context_iteration(null, 0) != 0) {}
}
