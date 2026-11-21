//! Observe desktop commands without blocking the compositor or UI thread.
const std = @import("std");
const c = @import("desktop-glib.zig");

pub fn commandLine(a: std.mem.Allocator, name: [:0]const u8, command: [:0]const u8) void {
    var argv: [*c][*c]u8 = null;
    var err: [*c]c.GError = null;
    if (c.g_shell_parse_argv(command, null, &argv, &err) == 0) {
        report(a, name, err);
        return;
    }
    defer c.g_strfreev(argv);
    launch(a, name, @ptrCast(argv));
}

pub fn launch(a: std.mem.Allocator, name: [:0]const u8, argv: [*c]const [*c]const u8) void {
    var err: [*c]c.GError = null;
    const process = c.g_subprocess_newv(argv, c.G_SUBPROCESS_FLAGS_NONE, &err) orelse {
        report(a, name, err);
        return;
    };
    const pending = a.create(Pending) catch @panic("command allocation");
    pending.* = .{ .allocator = a, .name = a.dupeSentinel(u8, name, 0) catch @panic("command allocation") };
    c.g_subprocess_wait_check_async(process, null, &exited, pending);
}

const Pending = struct {
    allocator: std.mem.Allocator,
    name: [:0]u8,
};

fn exited(source: ?*c.GObject, result: ?*c.GAsyncResult, data: c.gpointer) callconv(.c) void {
    const process: *c.GSubprocess = @ptrCast(source.?);
    defer c.g_object_unref(process);
    const pending: *Pending = @ptrCast(@alignCast(data.?));
    defer pending.allocator.destroy(pending);
    defer pending.allocator.free(pending.name);
    var err: [*c]c.GError = null;
    if (c.g_subprocess_wait_check_finish(process, result, &err) == 0) report(pending.allocator, pending.name, err);
}

fn report(a: std.mem.Allocator, name: [:0]const u8, err: [*c]c.GError) void {
    defer if (err != null) c.g_error_free(err);
    const reason = if (err != null) std.mem.span(err.*.message) else "Unknown process failure";
    std.log.err("{s}: {s}", .{ name, reason });
    const message = std.fmt.allocPrintSentinel(a, "{s}: {s}", .{ name, reason }, 0) catch return;
    defer a.free(message);
    const escaped = c.g_markup_escape_text(message.ptr, -1);
    defer c.g_free(escaped);
    // The reply is ignored, so a missing notification service cannot interfere
    // with the original command's status reporting.
    @import("desktop-dbus-loop.zig").notify(a, "Desktop", "dialog-error-symbolic", "Desktop command failed", std.mem.span(escaped), null);
}
