//! Runs only against a private test bus and an unprivileged fake helper.
const std = @import("std");
const polkit = @import("desktop").polkit;
const mainloop = @import("desktop").mainloop;
const libc = @import("desktop").libc;
var running = true;
fn stop(_: void) bool {
    running = false;
    return true;
}
pub fn main(init: std.process.Init) !void {
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug.deinit() == .ok);
    const a = debug.allocator();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const args = try init.minimal.args.toSlice(arena.allocator());
    if (args.len < 2) return error.ExpectedPrivateSocket;
    const endpoint = try arena.allocator().dupeSentinel(u8, args[1], 0);
    var service = try polkit.Service.initWithOptions(a, init.io, .{
        .socket_path = endpoint,
        .peer_uid = if (args.len == 3) try std.fmt.parseInt(u32, args[2], 10) else libc.getuid(),
    });
    defer service.deinit();
    const signal = mainloop.signal(init.io, mainloop.SIGTERM, {}, stop);
    defer _ = mainloop.remove(init.io, signal);
    while (running) _ = mainloop.iteration(init.io, true);
}
