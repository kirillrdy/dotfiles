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
    /// Holders of a shared source (see `acquire`).
    refs: u32 = 1,
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

/// One long-lived connection per bus, shared by the main thread like GLib's bus singletons.
var shared: [2]?*Source = .{ null, null };

/// Returns the shared connection to `bus`, connecting on first use. Pair with `release`.
/// Holders must cancel their pending calls and unsubscribe before releasing.
pub fn acquire(bus: dbus.Bus) !*Source {
    const slot = &shared[@intFromEnum(bus)];
    if (slot.*) |source| if (!source.connection.closed) {
        source.refs += 1;
        return source;
    };
    // A broken connection stays with its current holders; new callers get a fresh one.
    const source = try Source.open(std.heap.page_allocator, bus);
    slot.* = source;
    return source;
}
pub fn release(source: *Source) void {
    source.refs -= 1;
    if (source.refs > 0) return;
    for (&shared) |*slot| {
        if (slot.* == source) slot.* = null;
    }
    source.destroy();
}

/// A single method call on a private connection that closes once the reply arrives.
/// The handler always runs later from the main loop, exactly once, unless the
/// request was cancelled, in which case it receives a failure named `Cancelled`.
pub fn request(bus: dbus.Bus, target: dbus.Connection.Call, args: anytype, timeout_ms: u32, cancel: ?*c.GCancellable, handler: dbus.ReplyHandler, context: ?*anyopaque) void {
    const allocator = std.heap.page_allocator;
    const self = allocator.create(Request) catch {
        // Without memory there is no way to defer; failing synchronously is the only option.
        return handler(context, .{ .failed = .{ .name = "org.freedesktop.DBus.Error.NoMemory", .text = "Out of memory" } });
    };
    self.* = .{ .handler = handler, .context = context, .cancel = cancel };
    if (cancel) |value| {
        _ = c.g_object_ref(value);
        if (c.g_cancellable_is_cancelled(value) != 0) return self.later(.cancelled);
        self.cancel_handler = c.g_cancellable_connect(value, @ptrCast(&Request.cancelled), self, null);
    }
    const source = Source.open(allocator, bus) catch return self.later(.unreachable_bus);
    self.source = source;
    self.serial = source.connection.call(target, args, timeout_ms, &Request.replied, self) catch return self.later(.send_failed);
}

const Request = struct {
    handler: dbus.ReplyHandler,
    context: ?*anyopaque,
    cancel: ?*c.GCancellable,
    cancel_handler: c.gulong = 0,
    source: ?*Source = null,
    serial: u32 = 0,
    idle: c.guint = 0,
    outcome: enum { cancelled, unreachable_bus, send_failed } = .cancelled,

    fn later(self: *Request, outcome: @TypeOf(self.outcome)) void {
        self.outcome = outcome;
        if (self.idle == 0) self.idle = c.g_idle_add(&deferred, self);
    }
    fn deferred(data: c.gpointer) callconv(.c) c.gboolean {
        const self: *Request = @ptrCast(@alignCast(data));
        self.idle = 0;
        self.finish(.{ .failed = switch (self.outcome) {
            .cancelled => .{ .name = "Cancelled", .text = "The request was cancelled" },
            .unreachable_bus => .{ .name = "org.freedesktop.DBus.Error.NoServer", .text = "Could not connect to the message bus" },
            .send_failed => .{ .name = "org.freedesktop.DBus.Error.Disconnected", .text = "Could not send the request" },
        } });
        return 0;
    }
    /// Runs in the cancelling thread; disconnecting there could deadlock, so finish from the loop.
    fn cancelled(_: *c.GCancellable, data: c.gpointer) callconv(.c) void {
        const self: *Request = @ptrCast(@alignCast(data));
        if (self.idle != 0) _ = c.g_source_remove(self.idle);
        self.idle = 0;
        self.later(.cancelled);
    }
    fn replied(data: ?*anyopaque, reply: dbus.Reply) void {
        const self: *Request = @ptrCast(@alignCast(data));
        self.serial = 0;
        if (self.idle != 0) return; // A cancellation already owns completion.
        self.finish(reply);
    }
    fn finish(self: *Request, reply: dbus.Reply) void {
        if (self.idle != 0) _ = c.g_source_remove(self.idle);
        if (self.cancel) |value| {
            if (self.cancel_handler != 0) c.g_cancellable_disconnect(value, self.cancel_handler);
        }
        if (self.source) |source| {
            if (self.serial != 0) source.connection.cancel(self.serial);
            source.destroy();
        }
        self.handler(self.context, reply);
        if (self.cancel) |value| c.g_object_unref(value);
        std.heap.page_allocator.destroy(self);
    }
};

/// A reply handler for calls whose outcome does not matter.
pub fn ignore(_: ?*anyopaque, _: dbus.Reply) void {}

/// Sends a desktop notification and ignores the outcome: a missing
/// notification daemon must never affect the caller.
pub fn notify(app_name: []const u8, icon: []const u8, summary: []const u8, body: []const u8, urgency: ?u8) void {
    const Hints = dbus.Dict([]const u8, dbus.Value);
    const entries = [_]Hints.Entry{.{ .key = "urgency", .value = .{ .byte = urgency orelse 1 } }};
    const hints: Hints = .{ .entries = if (urgency != null) &entries else &.{} };
    request(.session, .{ .destination = "org.freedesktop.Notifications", .path = "/org/freedesktop/Notifications", .interface = "org.freedesktop.Notifications", .member = "Notify" }, .{ app_name, @as(u32, 0), icon, summary, body, @as([]const []const u8, &.{}), hints, @as(i32, -1) }, 3000, null, &ignore, null);
}
