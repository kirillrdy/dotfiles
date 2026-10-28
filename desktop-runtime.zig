//! Package paths and environment setup, performed before starting GTK or helpers.
const std = @import("std");
const options = @import("options");
extern "c" fn setenv([*:0]const u8, [*:0]const u8, c_int) c_int;

pub fn setup(a: std.mem.Allocator) !void {
    const settings = .{
        .{ "DESKTOP_POWER_HELPER", options.POWER_HELPER },
        .{ "DESKTOP_POWER_PKEXEC", options.POWER_PKEXEC },
        .{ "GDK_PIXBUF_MODULE_FILE", options.PIXBUF_LOADERS },
        .{ "DESKTOP_OSD_SOUND_FILE", options.SOUND_FILE },
    };
    inline for (settings) |entry| {
        if (entry[1]) |value| {
            const terminated = try a.dupeSentinel(u8, value, 0);
            defer a.free(terminated);
            if (setenv(entry[0], terminated, 1) != 0) return error.EnvironmentSetupFailed;
        }
    }
    if (options.DATA_DIRS) |prefix| {
        const inherited = std.c.getenv("XDG_DATA_DIRS");
        const dirs = try dataDirs(a, prefix, if (inherited) |value| std.mem.span(value) else "");
        defer a.free(dirs);
        if (setenv("XDG_DATA_DIRS", dirs, 1) != 0) return error.EnvironmentSetupFailed;
    }
}

fn dataDirs(a: std.mem.Allocator, prefix: []const u8, inherited: []const u8) ![:0]u8 {
    var dirs: std.ArrayList([]const u8) = .empty;
    defer dirs.deinit(a);
    for ([_][]const u8{ prefix, inherited }) |paths| {
        var iter = std.mem.splitScalar(u8, paths, ':');
        next: while (iter.next()) |path| {
            if (path.len == 0) continue;
            for (dirs.items) |existing| if (std.mem.eql(u8, existing, path)) continue :next;
            try dirs.append(a, path);
        }
    }
    return std.mem.joinZ(a, ":", dirs.items);
}

test "package data directories precede inherited paths without duplicates" {
    const a = std.testing.allocator;
    const dirs = try dataDirs(a, "/desktop/share:/icons/share:/schemas", "/custom/share:/icons/share:/desktop/share");
    defer a.free(dirs);
    try std.testing.expectEqualStrings("/desktop/share:/icons/share:/schemas:/custom/share", dirs);
    const repeated = try dataDirs(a, "/desktop/share:/icons/share:/schemas", dirs);
    defer a.free(repeated);
    try std.testing.expectEqualStrings(dirs, repeated);
}

test "empty inherited directories do not add the current working directory" {
    const a = std.testing.allocator;
    const dirs = try dataDirs(a, "/desktop/share", "::");
    defer a.free(dirs);
    try std.testing.expectEqualStrings("/desktop/share", dirs);
}

test "configured startup exports helper paths and remains idempotent" {
    const a = std.testing.allocator;
    try setup(a);
    inline for (.{
        .{ "DESKTOP_POWER_HELPER", options.POWER_HELPER },
        .{ "DESKTOP_POWER_PKEXEC", options.POWER_PKEXEC },
        .{ "GDK_PIXBUF_MODULE_FILE", options.PIXBUF_LOADERS },
        .{ "DESKTOP_OSD_SOUND_FILE", options.SOUND_FILE },
    }) |entry| {
        if (entry[1]) |expected| try std.testing.expectEqualStrings(expected, std.mem.span(std.c.getenv(entry[0]).?));
    }
    if (options.DATA_DIRS != null) {
        const first = try a.dupe(u8, std.mem.span(std.c.getenv("XDG_DATA_DIRS").?));
        defer a.free(first);
        try setup(a);
        try std.testing.expectEqualStrings(first, std.mem.span(std.c.getenv("XDG_DATA_DIRS").?));
    }
}
