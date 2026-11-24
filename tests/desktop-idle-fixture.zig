const std = @import("std");
const mainloop = @import("desktop").mainloop;
const idle = @import("desktop").idle;
var stopping = false;
var service_ptr: ?*idle.Service = null;
var audio_inhibited = false;
fn stop(_: void) bool {
    stopping = true;
    return true;
}
fn toggleAudio(_: void) bool {
    audio_inhibited = !audio_inhibited;
    if (service_ptr) |service| service.setAudioInhibited(audio_inhibited);
    return true;
}
pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const args = try init.minimal.args.toSlice(arena.allocator());
    const session = args.len == 4 and std.mem.eql(u8, args[3], "--session");
    if (args.len != 3 and !session) return error.ExpectedTimeoutAndLocker;
    const locker = try arena.allocator().dupeSentinel(u8, args[2], 0);
    const service = try idle.Service.create(init.gpa, .{
        .timeout_ms = try std.fmt.parseInt(u32, args[1], 10),
        .lock_executable = locker,
        .session_inhibit = session,
    });
    service_ptr = service;
    const term = mainloop.signal(mainloop.SIGTERM, {}, stop);
    defer _ = mainloop.remove(term);
    const usr1 = mainloop.signal(@as(c_int, @intCast(@backingInt(std.posix.SIG.USR1))), {}, toggleAudio);
    defer _ = mainloop.remove(usr1);
    while (!stopping) _ = mainloop.iteration(true);
    service_ptr = null;
    service.destroy();
    while (mainloop.iteration(false)) {}
}
