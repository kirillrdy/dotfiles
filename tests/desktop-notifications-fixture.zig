//! Standalone notification service for private headless D-Bus/input tests.
const std = @import("std");
const desktop = @import("desktop");
const c = desktop.gtk;
fn quit(_: ?*anyopaque) callconv(.c) c.gboolean {
    c.gtk_main_quit();
    return 1;
}
pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const args = try init.minimal.args.toSlice(arena.allocator());
    if (args.len != 2) return error.ExpectedStylesheet;
    c.gtk_init(null, null);
    const service = try desktop.notifications.Service.create(args[1]);
    defer service.destroy();
    const signal = c.g_unix_signal_add(15, &quit, null);
    defer _ = c.g_source_remove(signal);
    c.gtk_main();
}
