//! Multi-call dispatcher for isolated desktop test fixtures.
const std = @import("std");

const Entry = struct {
    name: []const u8,
    run: *const fn (std.process.Init) anyerror!void,
};

fn wrapNoInit(comptime f: fn () anyerror!void) fn (std.process.Init) anyerror!void {
    return struct {
        fn call(_: std.process.Init) anyerror!void {
            return f();
        }
    }.call;
}

const entries = [_]Entry{
    .{ .name = "desktop-compositor-fixture", .run = @import("desktop-compositor-fixture.zig").main },
    .{ .name = "desktop-secrets-pam-fixture", .run = @import("desktop-secrets-pam-fixture.zig").main },
    .{ .name = "desktop-secrets-fixture", .run = @import("desktop-secrets-fixture.zig").main },
    .{ .name = "desktop-portal-fixture", .run = wrapNoInit(@import("desktop-portal-fixture.zig").main) },
    .{ .name = "desktop-portal-chooser-fixture", .run = @import("desktop-portal-chooser-fixture.zig").main },
    .{ .name = "desktop-portal-video-fixture", .run = @import("desktop-portal-video-fixture.zig").main },
    .{ .name = "desktop-pointer-fixture", .run = @import("desktop-pointer-fixture.zig").main },
    .{ .name = "desktop-battery-fixture", .run = @import("desktop-battery-fixture.zig").main },
    .{ .name = "desktop-audio-fixture", .run = @import("desktop-audio-fixture.zig").main },
    .{ .name = "desktop-backlight-fixture", .run = @import("desktop-backlight-fixture.zig").main },
    .{ .name = "desktop-network-fixture", .run = @import("desktop-network-fixture.zig").main },
    .{ .name = "desktop-idle-fixture", .run = @import("desktop-idle-fixture.zig").main },
    .{ .name = "desktop-lock-fixture", .run = @import("desktop-lock-fixture.zig").main },
    .{ .name = "desktop-apps-fixture", .run = @import("desktop-apps-fixture.zig").main },
    .{ .name = "desktop-dash-fixture", .run = @import("desktop-dash-fixture.zig").main },
    .{ .name = "desktop-widgets-fixture", .run = @import("desktop-widgets-fixture.zig").main },
    .{ .name = "desktop-switcher-fixture", .run = @import("desktop-switcher-fixture.zig").main },
    .{ .name = "desktop-settings-fixture", .run = @import("desktop-settings-fixture.zig").main },
    .{ .name = "desktop-askpass-fixture", .run = @import("desktop-askpass-fixture.zig").main },
    .{ .name = "desktop-polkit-fixture", .run = @import("desktop-polkit-fixture.zig").main },
    .{ .name = "desktop-polkit-agent-fixture", .run = @import("desktop-polkit-agent-fixture.zig").main },
    .{ .name = "desktop-screenshot-fixture", .run = @import("desktop-screenshot-fixture.zig").main },
    .{ .name = "desktop-command-fixture", .run = @import("desktop-command-fixture.zig").main },
    .{ .name = "desktop-notifications-fixture", .run = @import("desktop-notifications-fixture.zig").main },
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(std.heap.page_allocator);
    const prog = if (args.len > 0) std.fs.path.basename(args[0]) else "";
    inline for (entries) |entry| {
        if (std.mem.eql(u8, prog, entry.name)) return entry.run(init);
    }
    return error.UnknownFixture;
}
