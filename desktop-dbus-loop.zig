//! Drives a native D-Bus connection from the GLib main context.
//!
//! Owners may destroy a source from inside any of its callbacks; teardown is
//! then deferred until the connection has finished dispatching.
const std = @import("std");
const c = @import("desktop-glib.zig");
const dbus = @import("dbus");

pub const Source = struct {
    allocator: std.mem.Allocator,
    connection: *dbus.Connection,
    watch: c.guint = 0,
    timer: c.guint = 0,
    busy: u32 = 0,
    dying: bool = false,

    /// Connects to `bus` (blocking for authentication and Hello) and attaches to the default context.
    pub fn open(allocator: std.mem.Allocator, bus: dbus.Bus) !*Source {
        const connection = try dbus.Connection.open(allocator, bus);
        errdefer connection.close();
        const self = try allocator.create(Source);
        self.* = .{ .allocator = allocator, .connection = connection };
        connection.on_schedule = &scheduled;
        connection.schedule_context = self;
        self.watch = c.g_unix_fd_add(connection.getFd(), c.G_IO_IN | c.G_IO_ERR | c.G_IO_HUP, &readable, self);
        return self;
    }

    pub fn destroy(self: *Source) void {
        if (self.busy > 0) {
            self.dying = true;
            return;
        }
        self.finalize();
    }
    fn finalize(self: *Source) void {
        if (self.watch != 0) _ = c.g_source_remove(self.watch);
        if (self.timer != 0) _ = c.g_source_remove(self.timer);
        self.connection.close();
        self.allocator.destroy(self);
    }

    fn readable(_: c_int, condition: c.GIOCondition, data: ?*anyopaque) callconv(.c) c.gboolean {
        const self: *Source = @ptrCast(@alignCast(data));
        self.busy += 1;
        var keep = true;
        if (condition & (c.G_IO_ERR | c.G_IO_HUP) != 0) {
            // Drain anything still buffered, then fail what can no longer be answered.
            self.connection.readAndDispatch() catch {};
            keep = false;
        } else self.connection.readAndDispatch() catch {
            keep = false;
        };
        if (!keep) {
            self.watch = 0;
            self.connection.disconnect();
        }
        self.busy -= 1;
        if (self.dying) {
            self.finalize();
            return 0;
        }
        self.arm();
        return @intFromBool(keep);
    }

    fn scheduled(data: ?*anyopaque) void {
        const self: *Source = @ptrCast(@alignCast(data));
        if (!self.dying) self.arm();
    }
    /// Re-arms the timer for the earliest call deadline.
    fn arm(self: *Source) void {
        if (self.timer != 0) _ = c.g_source_remove(self.timer);
        self.timer = 0;
        const remaining = self.connection.nextTimeout() orelse return;
        self.timer = c.g_timeout_add(@intCast(@min(remaining + 1, std.math.maxInt(c_uint))), &expired, self);
    }
    fn expired(data: ?*anyopaque) callconv(.c) c.gboolean {
        const self: *Source = @ptrCast(@alignCast(data));
        self.timer = 0;
        self.busy += 1;
        _ = self.connection.expire();
        self.busy -= 1;
        if (self.dying) {
            self.finalize();
            return 0;
        }
        self.arm();
        return 0;
    }
};
