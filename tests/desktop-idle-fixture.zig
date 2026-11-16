const std = @import("std");
const c = @import("desktop").gtk;
const idle = @import("desktop").idle;
var stopping = false;
var service_ptr: ?*idle.Service = null;
var audio_inhibited = false;
fn stop(_: ?*anyopaque) callconv(.c) c_int {
    stopping = true;
    return 1;
}
fn toggleAudio(_: ?*anyopaque) callconv(.c) c_int {
    audio_inhibited = !audio_inhibited;
    if (service_ptr) |service| service.setAudioInhibited(audio_inhibited);
    return 1;
}
pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const args = try init.minimal.args.toSlice(arena.allocator());
    const session = args.len == 4 and std.mem.eql(u8, args[3], "--session");
    if (args.len != 3 and !session) return error.ExpectedTimeoutAndLocker;
    const locker = try arena.allocator().dupeSentinel(u8, args[2], 0);
    const service = try idle.Service.create(.{
        .timeout_ms = try std.fmt.parseInt(u32, args[1], 10),
        .lock_executable = locker,
        .session_inhibit = session,
    });
    service_ptr = service;
    const term = c.g_unix_signal_add(c.SIGTERM, &stop, null);
    defer _ = c.g_source_remove(term);
    const usr1 = c.g_unix_signal_add(@as(c_int, @intCast(@backingInt(std.posix.SIG.USR1))), &toggleAudio, null);
    defer _ = c.g_source_remove(usr1);
    while (!stopping) _ = c.g_main_context_iteration(null, 1);
    service_ptr = null;
    service.destroy();
    while (c.g_main_context_iteration(null, 0) != 0) {}
}
