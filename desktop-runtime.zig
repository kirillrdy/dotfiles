//! Package paths compiled in at build time, and the environment setup
//! performed before starting the UI or helpers.
const std = @import("std");
const options = @import("options");
extern "c" fn setenv([*:0]const u8, [*:0]const u8, c_int) c_int;

fn terminated(comptime value: ?[]const u8) ?[:0]const u8 {
    return if (value) |text| std.fmt.comptimePrint("{s}", .{text}) else null;
}

/// Values of DESKTOP_RUNTIME_* when the package was built.
pub const sound_file = terminated(options.SOUND_FILE);
pub const codex_icon = terminated(options.CODEX_ICON);
/// The X11 locale directory holding Compose files.
pub const xlocale_dir = terminated(options.XLOCALE_DIR);
/// This executable, for starting its other commands.
pub const executable: [:0]const u8 = terminated(options.POWER_HELPER) orelse "desktop-zig";
/// The power profile helper runs through pkexec; fixtures substitute both.
pub var power_helper = terminated(options.POWER_HELPER);
pub var power_pkexec = terminated(options.POWER_PKEXEC);

/// Prepends package data directories to XDG_DATA_DIRS, which launched
/// applications also read.
pub fn setup(a: std.mem.Allocator) !void {
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

test "configured startup prepends data directories idempotently" {
    const a = std.testing.allocator;
    try setup(a);
    if (options.DATA_DIRS != null) {
        const first = try a.dupe(u8, std.mem.span(std.c.getenv("XDG_DATA_DIRS").?));
        defer a.free(first);
        try setup(a);
        try std.testing.expectEqualStrings(first, std.mem.span(std.c.getenv("XDG_DATA_DIRS").?));
    }
}
