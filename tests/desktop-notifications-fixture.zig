//! Standalone notification service for private headless D-Bus/input tests.
const desktop = @import("desktop");
const c = desktop.gtk;
fn quit(_: ?*anyopaque) callconv(.c) c.gboolean {
    c.gtk_main_quit();
    return 1;
}
pub fn main() !void {
    c.gtk_init(null, null);
    const service = try desktop.notifications.Service.create();
    defer service.destroy();
    const signal = c.g_unix_signal_add(15, &quit, null);
    defer _ = c.g_source_remove(signal);
    c.gtk_main();
}
