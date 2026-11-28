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
    desktop.icons.init(init.gpa, init.io);
    defer desktop.gsettings.deinit(init.io);
    defer desktop.icons.deinit();
    const service = try desktop.notifications.Service.create(init.gpa, init.io);
    defer service.destroy();
    const signal = mainloop.signal(init.io, mainloop.SIGTERM, {}, quit);
    defer _ = mainloop.remove(init.io, signal);
    while (running) _ = mainloop.iteration(init.io, true);
}
