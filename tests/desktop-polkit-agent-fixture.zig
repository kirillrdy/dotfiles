//! Runs only against a private test bus and an unprivileged fake helper.
const std = @import("std");
const polkit = @import("desktop").polkit;
const c = polkit.c;
const libc = @import("desktop").libc;
fn stop(_: c.gpointer) callconv(.c) c.gboolean {
    c.gtk_main_quit();
    return 1;
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
    c.gtk_init(null, null);
    var service = try polkit.Service.initWithOptions(a, .{
        .socket_path = endpoint,
        .peer_uid = if (args.len == 3) try std.fmt.parseInt(u32, args[2], 10) else libc.getuid(),
    });
    defer service.deinit();
    const signal = c.g_unix_signal_add(c.SIGTERM, &stop, null);
    defer _ = c.g_source_remove(signal);
    c.gtk_main();
}
