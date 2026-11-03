//! Observe desktop commands without blocking the compositor or UI thread.
const std = @import("std");
const c = @import("desktop-gtk.zig");
const a = std.heap.page_allocator;

pub fn commandLine(name: [:0]const u8, command: [:0]const u8) void {
    var argv: [*c][*c]u8 = null;
    var err: [*c]c.GError = null;
    if (c.g_shell_parse_argv(command, null, &argv, &err) == 0) {
        report(name, err);
        return;
    }
    defer c.g_strfreev(argv);
    launch(name, @ptrCast(argv));
}

pub fn launch(name: [:0]const u8, argv: [*c]const [*c]const u8) void {
    var err: [*c]c.GError = null;
    const process = c.g_subprocess_newv(argv, c.G_SUBPROCESS_FLAGS_NONE, &err) orelse {
        report(name, err);
        return;
    };
    const label = a.dupeSentinel(u8, name, 0) catch @panic("command allocation");
    c.g_subprocess_wait_check_async(process, null, &exited, label.ptr);
}

fn exited(source: ?*c.GObject, result: ?*c.GAsyncResult, data: c.gpointer) callconv(.c) void {
    const process: *c.GSubprocess = @ptrCast(source.?);
    defer c.g_object_unref(process);
    const name = std.mem.span(@as([*:0]u8, @ptrCast(data.?)));
    defer a.free(name);
    var err: [*c]c.GError = null;
    if (c.g_subprocess_wait_check_finish(process, result, &err) == 0) report(name, err);
}

fn report(name: [:0]const u8, err: [*c]c.GError) void {
    defer if (err != null) c.g_error_free(err);
    const reason = if (err != null) std.mem.span(err.*.message) else "Unknown process failure";
    std.log.err("{s}: {s}", .{ name, reason });
    const message = std.fmt.allocPrintSentinel(a, "{s}: {s}", .{ name, reason }, 0) catch return;
    // Get the bus asynchronously; a missing notification service must not block
    // shortcuts or interfere with the original command's status reporting.
    c.g_bus_get(c.G_BUS_TYPE_SESSION, null, &connected, message.ptr);
}

fn connected(_: ?*c.GObject, result: ?*c.GAsyncResult, data: c.gpointer) callconv(.c) void {
    const message = std.mem.span(@as([*:0]u8, @ptrCast(data.?)));
    defer a.free(message);
    var err: [*c]c.GError = null;
    const bus = c.g_bus_get_finish(result, &err) orelse {
        if (err != null) c.g_error_free(err);
        return;
    };
    const escaped = c.g_markup_escape_text(message.ptr, -1);
    defer c.g_free(escaped);
    const params = c.g_variant_new("(susss@as@a{sv}i)", @as([*:0]const u8, "Desktop"), @as(c_uint, 0), @as([*:0]const u8, "dialog-error-symbolic"), @as([*:0]const u8, "Desktop command failed"), escaped, c.g_variant_new_array(@ptrCast(@as([*:0]const u8, "s")), null, 0), c.g_variant_new_array(@ptrCast(@as([*:0]const u8, "{sv}")), null, 0), @as(c_int, -1));
    c.g_dbus_connection_call(bus, "org.freedesktop.Notifications", "/org/freedesktop/Notifications", "org.freedesktop.Notifications", "Notify", params, @ptrCast(@as([*:0]const u8, "(u)")), 0, 3000, null, &notified, bus);
}

fn notified(_: ?*c.GObject, result: ?*c.GAsyncResult, data: c.gpointer) callconv(.c) void {
    const bus: *c.GDBusConnection = @ptrCast(@alignCast(data.?));
    defer c.g_object_unref(bus);
    var err: [*c]c.GError = null;
    if (c.g_dbus_connection_call_finish(bus, result, &err)) |reply| c.g_variant_unref(reply);
    if (err != null) c.g_error_free(err);
}
