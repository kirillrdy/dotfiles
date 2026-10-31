//! GLib adapter shared by native surface clients until the session event loop migrates.
const std = @import("std");
const c = @import("desktop-gtk.zig");
const surface = @import("desktop-surface.zig");
pub const Loop = struct {
    client: ?*surface.Client = null,
    label: []const u8 = "surface",
    reader: c.guint = 0,
    writer: c.guint = 0,

    pub fn start(self: *Loop, client: *surface.Client, label: []const u8) !void {
        self.client = client;
        self.label = label;
        errdefer self.stop();
        self.reader = c.g_unix_fd_add(c.wl_display_get_fd(client.display), c.G_IO_IN | c.G_IO_ERR | c.G_IO_HUP, readable, self);
        if (self.reader == 0) return error.EventSourceFailed;
        try self.flush();
    }
    pub fn flush(self: *Loop) !void {
        const client = self.client orelse return error.WaylandDisconnected;
        if (!try client.flush() and self.writer == 0) {
            self.writer = c.g_unix_fd_add(c.wl_display_get_fd(client.display), c.G_IO_OUT | c.G_IO_ERR | c.G_IO_HUP, writable, self);
            if (self.writer == 0) return error.EventSourceFailed;
        }
    }
    pub fn stop(self: *Loop) void {
        if (self.reader != 0) _ = c.g_source_remove(self.reader);
        if (self.writer != 0) _ = c.g_source_remove(self.writer);
        self.reader = 0;
        self.writer = 0;
        self.client = null;
    }
    fn failed(self: *Loop, err: anyerror) void {
        std.log.err("{s}: {s}", .{ self.label, @errorName(err) });
        self.stop();
    }
    fn readable(_: c_int, condition: c.GIOCondition, data: ?*anyopaque) callconv(.c) c.gboolean {
        const self: *Loop = @ptrCast(@alignCast(data));
        if (condition & (c.G_IO_ERR | c.G_IO_HUP) != 0) {
            self.failed(error.WaylandDisconnected);
            return 0;
        }
        self.client.?.dispatch() catch |err| {
            self.failed(err);
            return 0;
        };
        self.flush() catch |err| {
            self.failed(err);
            return 0;
        };
        return 1;
    }
    fn writable(_: c_int, condition: c.GIOCondition, data: ?*anyopaque) callconv(.c) c.gboolean {
        const self: *Loop = @ptrCast(@alignCast(data));
        if (condition & (c.G_IO_ERR | c.G_IO_HUP) != 0) {
            self.failed(error.WaylandDisconnected);
            return 0;
        }
        const flushed = self.client.?.flush() catch |err| {
            self.failed(err);
            return 0;
        };
        if (!flushed) return 1;
        self.writer = 0;
        return 0;
    }
};
