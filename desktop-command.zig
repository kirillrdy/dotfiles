//! Observe desktop commands without blocking the compositor or UI thread.
const std = @import("std");
const process = @import("desktop-process.zig");

pub fn commandLine(a: std.mem.Allocator, name: [:0]const u8, command: [:0]const u8) void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const argv = process.shellParse(arena.allocator(), command) catch |err| return report(a, name, switch (err) {
        error.EmptyCommand => "Text was empty (or contained only whitespace)",
        else => "Text ended before matching quote was found",
    });
    launch(a, name, argv);
}

pub fn launch(a: std.mem.Allocator, name: [:0]const u8, argv: []const [:0]const u8) void {
    const pending = a.create(Pending) catch @panic("command allocation");
    pending.* = .{ .allocator = a, .name = a.dupeSentinel(u8, name, 0) catch @panic("command allocation") };
    _ = process.Process.spawn(a, argv, .{}, &exited, pending) catch |err| {
        pending.destroy();
        var buffer: [512]u8 = undefined;
        return report(a, name, std.fmt.bufPrint(&buffer, "Failed to execute child process “{s}” ({s})", .{ argv[0], switch (err) {
            error.FileNotFound => "No such file or directory",
            error.AccessDenied => "Permission denied",
            else => @errorName(err),
        } }) catch "Failed to execute child process");
    };
}

const Pending = struct {
    allocator: std.mem.Allocator,
    name: [:0]u8,

    fn destroy(self: *Pending) void {
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }
};

fn exited(data: ?*anyopaque, result: *const process.Result) void {
    const pending: *Pending = @ptrCast(@alignCast(data.?));
    defer pending.destroy();
    if (result.successful()) return;
    var buffer: [128]u8 = undefined;
    report(pending.allocator, pending.name, result.describe(&buffer));
}

fn report(a: std.mem.Allocator, name: []const u8, reason: []const u8) void {
    std.log.err("{s}: {s}", .{ name, reason });
    var message: std.ArrayList(u8) = .empty;
    defer message.deinit(a);
    escapeMarkup(a, &message, name) catch return;
    message.appendSlice(a, ": ") catch return;
    escapeMarkup(a, &message, reason) catch return;
    // The reply is ignored, so a missing notification service cannot interfere
    // with the original command's status reporting.
    @import("desktop-dbus-loop.zig").notify(a, "Desktop", "dialog-error-symbolic", "Desktop command failed", message.items, null);
}

/// Escapes text for notification body markup, as g_markup_escape_text.
pub fn escapeMarkup(a: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |byte| switch (byte) {
        '&' => try out.appendSlice(a, "&amp;"),
        '<' => try out.appendSlice(a, "&lt;"),
        '>' => try out.appendSlice(a, "&gt;"),
        '\'' => try out.appendSlice(a, "&apos;"),
        '"' => try out.appendSlice(a, "&quot;"),
        else => try out.append(a, byte),
    };
}

test "markup escaping encodes XML entities" {
    const a = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "plain", "plain" },
        .{ "a & b <c> \"d\" 'e'", "a &amp; b &lt;c&gt; &quot;d&quot; &apos;e&apos;" },
        .{ "東京 &amp;", "東京 &amp;amp;" },
    };
    for (cases) |case| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(a);
        try escapeMarkup(a, &out, case[0]);
        try std.testing.expectEqualStrings(case[1], out.items);
    }
}
