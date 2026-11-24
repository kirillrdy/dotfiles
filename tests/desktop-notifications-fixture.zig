//! Standalone notification service for private headless D-Bus/input tests.
const std = @import("std");
const desktop = @import("desktop");
const mainloop = @import("desktop").mainloop;
var running = true;
fn quit(_: void) bool {
    running = false;
    return true;
}
pub fn main(init: std.process.Init) !void {
    desktop.icons.init(init.gpa);
    defer desktop.gsettings.deinit();
    defer desktop.icons.deinit();
    const service = try desktop.notifications.Service.create(init.gpa);
    defer service.destroy();
    const signal = mainloop.signal(mainloop.SIGTERM, {}, quit);
    defer _ = mainloop.remove(signal);
    while (running) _ = mainloop.iteration(true);
}
