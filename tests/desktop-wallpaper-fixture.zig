//! Run the production wallpaper without initializing GTK or GDK.
const std = @import("std");
const d = @import("desktop");
const c = d.gtk;
var running = true;
fn quit(_: ?*anyopaque) callconv(.c) c.gboolean {
    running = false;
    return 1;
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(std.heap.page_allocator);
    if (args.len != 2) return error.ExpectedImage;
    const term = c.g_unix_signal_add(c.SIGTERM, quit, null);
    defer _ = c.g_source_remove(term);
    const service = try d.wallpaper.Service.create(args[1]);
    defer service.destroy();
    while (running) _ = c.g_main_context_iteration(null, 1);
}
