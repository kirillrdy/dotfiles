//! Standalone notification service for private headless D-Bus/input tests.
const desktop = @import("desktop");
const c = desktop.glib;
var running = true;
fn quit(_: ?*anyopaque) callconv(.c) c.gboolean {
    running = false;
    return 1;
}
pub fn main() !void {
    const service = try desktop.notifications.Service.create();
    defer service.destroy();
    const signal = c.g_unix_signal_add(c.SIGTERM, &quit, null);
    defer _ = c.g_source_remove(signal);
    while (running) _ = c.g_main_context_iteration(null, 1);
}
