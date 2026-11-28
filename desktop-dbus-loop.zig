//! Drives a native D-Bus connection from the GLib main context.
//!
//! Owners may destroy a source from inside any of its callbacks; teardown is
//! then deferred until the connection has finished dispatching.
const std = @import("std");
const mainloop = @import("desktop-loop.zig");
const dbus = @import("dbus");

pub const Source = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    connection: *dbus.Connection,
    watch: u32 = 0,
    timer: u32 = 0,
    /// An idle dispatch for messages buffered by a blocking call.
    backlog: u32 = 0,
    busy: u32 = 0,
    /// Holders of a shared source (see `acquire`).
    refs: u32 = 1,
    dying: bool = false,

    /// Connects to `bus` (blocking for authentication and Hello) and attaches to the default context.
    pub fn open(allocator: std.mem.Allocator, io: std.Io, bus: dbus.Bus) !*Source {
        const connection = try dbus.Connection.open(allocator, bus);
        errdefer connection.close();
        const self = try allocator.create(Source);
        self.* = .{ .allocator = allocator, .io = io, .connection = connection };
        connection.on_schedule = &scheduled;
        connection.on_backlog = &backlogged;
        connection.schedule_context = self;
        self.watch = mainloop.watch(io, connection.getFd(), mainloop.IN | mainloop.ERR | mainloop.HUP, self, readable);
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
        if (self.watch != 0) _ = mainloop.remove(self.io, self.watch);
        if (self.timer != 0) _ = mainloop.remove(self.io, self.timer);
        if (self.backlog != 0) _ = mainloop.remove(self.io, self.backlog);
        self.connection.close();
        self.allocator.destroy(self);
    }

    fn readable(self: *Source, _: c_int, condition: u32) bool {
        self.busy += 1;
        var keep = true;
        if (condition & (mainloop.ERR | mainloop.HUP) != 0) {
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
            return false;
        }
        self.arm();
        return keep;
    }

    fn backlogged(data: ?*anyopaque) void {
        const self: *Source = @ptrCast(@alignCast(data));
        if (self.backlog == 0 and !self.dying) self.backlog = mainloop.idle(self.io, self, drain);
    }
    fn drain(self: *Source) bool {
        self.backlog = 0;
        self.busy += 1;
        self.connection.dispatchPending() catch self.connection.disconnect();
        self.busy -= 1;
        if (self.dying) {
            self.finalize();
            return false;
        }
        self.arm();
        return false;
    }
    fn scheduled(data: ?*anyopaque) void {
        const self: *Source = @ptrCast(@alignCast(data));
        if (!self.dying) self.arm();
    }
    /// Re-arms the timer for the earliest call deadline.
    fn arm(self: *Source) void {
        if (self.timer != 0) _ = mainloop.remove(self.io, self.timer);
        self.timer = 0;
        const remaining = self.connection.nextTimeout() orelse return;
        self.timer = mainloop.timeout(self.io, @intCast(@min(remaining + 1, std.math.maxInt(c_uint))), self, expired);
    }
    fn expired(self: *Source) bool {
        self.timer = 0;
        self.busy += 1;
        _ = self.connection.expire();
        self.busy -= 1;
        if (self.dying) {
            self.finalize();
            return false;
        }
        self.arm();
        return false;
    }
};

/// One long-lived connection per bus, shared by the main thread like GLib's bus singletons.
var shared: [2]?*Source = .{ null, null };

/// Returns the shared connection to `bus`, connecting on first use. Pair with `release`.
/// Holders must cancel their pending calls and unsubscribe before releasing.
/// The allocator used to create the connection must remain valid until its last release.
pub fn acquire(allocator: std.mem.Allocator, io: std.Io, bus: dbus.Bus) !*Source {
    const slot = &shared[@backingInt(bus)];
    if (slot.*) |source| if (!source.connection.closed) {
        source.refs += 1;
        return source;
    };
    // A broken connection stays with its current holders; new callers get a fresh one.
    const source = try Source.open(allocator, io, bus);
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
pub fn request(allocator: std.mem.Allocator, io: std.Io, bus: dbus.Bus, target: dbus.Connection.Call, args: anytype, timeout_ms: u32, cancel: ?*mainloop.Cancellable, handler: dbus.ReplyHandler, context: ?*anyopaque) void {
    const self = allocator.create(Request) catch {
        // Without memory there is no way to defer; failing synchronously is the only option.
        return handler(context, .{ .failed = .{ .name = "org.freedesktop.DBus.Error.NoMemory", .text = "Out of memory" } });
    };
    self.* = .{ .allocator = allocator, .io = io, .handler = handler, .context = context, .cancel = cancel };
    if (cancel) |value| {
        _ = value.ref();
        if (value.isCancelled()) return self.later(.cancelled);
        self.cancel_handler = value.connect(self, Request.cancelled);
    }
    const source = Source.open(allocator, io, bus) catch return self.later(.unreachable_bus);
    self.source = source;
    self.serial = source.connection.call(target, args, timeout_ms, &Request.replied, self) catch return self.later(.send_failed);
}

const Request = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    handler: dbus.ReplyHandler,
    context: ?*anyopaque,
    cancel: ?*mainloop.Cancellable,
    cancel_handler: u64 = 0,
    source: ?*Source = null,
    serial: u32 = 0,
    idle: u32 = 0,
    outcome: enum { cancelled, unreachable_bus, send_failed } = .cancelled,

    fn later(self: *Request, outcome: @TypeOf(self.outcome)) void {
        self.outcome = outcome;
        if (self.idle == 0) self.idle = mainloop.idle(self.io, self, deferred);
    }
    fn deferred(self: *Request) bool {
        self.idle = 0;
        self.finish(.{ .failed = switch (self.outcome) {
            .cancelled => .{ .name = "Cancelled", .text = "The request was cancelled" },
            .unreachable_bus => .{ .name = "org.freedesktop.DBus.Error.NoServer", .text = "Could not connect to the message bus" },
            .send_failed => .{ .name = "org.freedesktop.DBus.Error.Disconnected", .text = "Could not send the request" },
        } });
        return false;
    }
    /// Runs in the cancelling thread; disconnecting there could deadlock, so finish from the loop.
    fn cancelled(self: *Request) void {
        if (self.idle != 0) _ = mainloop.remove(self.io, self.idle);
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
        if (self.idle != 0) _ = mainloop.remove(self.io, self.idle);
        if (self.cancel) |value| {
            value.disconnect(self.cancel_handler);
        }
        if (self.source) |source| {
            if (self.serial != 0) source.connection.cancel(self.serial);
            source.destroy();
        }
        self.handler(self.context, reply);
        if (self.cancel) |value| value.unref();
        self.allocator.destroy(self);
    }
};

/// A reply handler for calls whose outcome does not matter.
pub fn ignore(_: ?*anyopaque, _: dbus.Reply) void {}

/// Sends a desktop notification and ignores the outcome: a missing
/// notification daemon must never affect the caller.
pub fn notify(allocator: std.mem.Allocator, io: std.Io, app_name: []const u8, icon: []const u8, summary: []const u8, body: []const u8, urgency: ?u8) void {
    const Hints = dbus.Dict([]const u8, dbus.Value);
    const entries = [_]Hints.Entry{.{ .key = "urgency", .value = .{ .byte = urgency orelse 1 } }};
    const hints: Hints = .{ .entries = if (urgency != null) &entries else &.{} };
    request(allocator, io, .session, .{ .destination = "org.freedesktop.Notifications", .path = "/org/freedesktop/Notifications", .interface = "org.freedesktop.Notifications", .member = "Notify" }, .{ app_name, @as(u32, 0), icon, summary, body, @as([]const []const u8, &.{}), hints, @as(i32, -1) }, 3000, null, &ignore, null);
}

/// Introspection XML for a single-instance service's `Command(as)` method.
pub fn commandXml(comptime name: []const u8) []const u8 {
    return "<node><interface name='" ++ name ++ "'><method name='Command'><arg type='as' direction='in'/></method></interface></node>";
}
/// Sends `args` to the process owning `name` and waits. A failure is printed as
/// `program: reason` and exits with status 1; with no owner, nothing is started.
pub fn forwardCommand(allocator: std.mem.Allocator, program: []const u8, name: []const u8, path: []const u8, args: []const []const u8) error{ NoSessionBus, SessionNotRunning }!void {
    const connection = dbus.Connection.open(allocator, .session) catch return error.NoSessionBus;
    defer connection.close();
    const result = connection.callBlockingRaw(.{ .destination = name, .path = path, .interface = name, .member = "Command", .no_auto_start = true }, .{args}, 120000) catch return error.NoSessionBus;
    defer result.deinit();
    const reply = result.message();
    if (reply.kind != .@"error") return;
    const error_name = reply.error_name orelse "";
    if (std.mem.eql(u8, error_name, "org.freedesktop.DBus.Error.ServiceUnknown") or std.mem.eql(u8, error_name, "org.freedesktop.DBus.Error.NameHasNoOwner")) return error.SessionNotRunning;
    std.debug.print("{s}: {s}\n", .{ program, reply.errorText() });
    std.process.exit(1);
}
