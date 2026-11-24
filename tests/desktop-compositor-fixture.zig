//! End-to-end probe for workspace control and actual per-window capture.
const std = @import("std");
const d = @import("desktop");
const mainloop = @import("desktop").mainloop;
const capture = d.capture;
fn changed(data: ?*anyopaque) void {
    const count: *usize = @ptrCast(@alignCast(data.?));
    count.* += 1;
}
pub fn main(init: std.process.Init) !void {
    d.util.io = init.io;
    const args = try init.minimal.args.toSlice(std.heap.page_allocator);
    if (args.len < 2) return error.ExpectedOperation;
    var changes: usize = 0;
    const client = try capture.Client.create(init.gpa, &changes, &changed);
    defer client.destroy();
    client.refresh();
    client.connection.roundtrip() catch return error.Disconnected;
    if (std.mem.eql(u8, args[1], "workspace")) {
        client.switchWorkspace(try std.fmt.parseInt(u32, args[2], 10));
    } else if (args.len > 2) {
        var found = false;
        for (client.windows.items) |window| {
            if (window.title == null or !std.mem.eql(u8, std.mem.span(window.title), args[2])) continue;
            found = true;
            if (std.mem.eql(u8, args[1], "move")) client.move(window, try std.fmt.parseInt(u32, args[3], 10)) else if (std.mem.eql(u8, args[1], "activate")) client.activate(window) else if (std.mem.eql(u8, args[1], "close")) client.close(window);
            break;
        }
        if (!found) return error.WindowNotFound;
    }
    if (std.mem.eql(u8, args[1], "capture")) {
        client.visible(true);
        const timer = d.util.Timer.start();
        while (timer.read() < 5 * std.time.ns_per_s) {
            client.tick();
            while (mainloop.iteration(false)) {}
            var complete = client.windows.items.len > 0;
            for (client.windows.items) |window| if (window.image == null) {
                complete = false;
                break;
            };
            if (complete) break;
            d.util.sleep(10 * std.time.ns_per_ms);
        }
        for (client.windows.items) |window| if (window.image == null) return error.MissingCapture;
        var before: u64 = 0;
        for (client.windows.items) |window| before = std.hash.Wyhash.hash(before, window.image.?.pixels);
        client.visible(false);
        var after: u64 = 0;
        for (client.windows.items) |window| {
            const image = window.image.?;
            try std.testing.expect(image.width > 0 and image.width <= 1024 and image.height > 0 and image.height <= 1024);
            try std.testing.expect(window.mapped == null and window.buffer == null and window.session == null);
            // The saved thumbnail remains readable after its SHM mapping is gone.
            try std.testing.expectEqual(@as(usize, image.width) * image.height * 4, image.pixels.len);
            after = std.hash.Wyhash.hash(after, image.pixels);
        }
        try std.testing.expectEqual(before, after);
        const previous = changes;
        client.visible(true);
        const resumed = d.util.Timer.start();
        while (changes == previous and resumed.read() < 5 * std.time.ns_per_s) {
            client.tick();
            while (mainloop.iteration(false)) {}
            d.util.sleep(10 * std.time.ns_per_ms);
        }
        if (changes == previous) return error.CaptureDidNotResume;
    }
    client.refresh();
    client.connection.roundtrip() catch return error.Disconnected;
    d.util.printOut("workspace {d}/{d}\n", .{ client.current, client.count });
    for (client.windows.items) |window| d.util.printOut("window {s} workspace {d} size {d}x{d} captured {d}\n", .{ std.mem.span(window.title), window.workspace, @as(u32, @intFromFloat(window.geometry.w)), @as(u32, @intFromFloat(window.geometry.h)), @as(u32, @intFromBool(window.image != null)) });
}
