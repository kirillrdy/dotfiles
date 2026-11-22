//! Asynchronous logind actions. Result messages are valid for the callback only.
const std = @import("std");
const c = @import("desktop-glib.zig");
const dbus = @import("dbus");
const loop = @import("desktop-dbus-loop.zig");
const name = "org.freedesktop.login1";
const path = "/org/freedesktop/login1";
const manager = name ++ ".Manager";

pub const Action = enum { @"suspend", reboot, poweroff, logout };
pub const Result = union(enum) { success, cancelled, failure: [:0]const u8 };
pub const Callback = *const fn (?*anyopaque, Result) void;

pub fn perform(a: std.mem.Allocator, action: Action, cancel: *c.GCancellable, callback: Callback, data: ?*anyopaque) void {
    if (c.g_cancellable_is_cancelled(cancel) != 0) return callback(data, .cancelled);
    const job = a.create(Job) catch return callback(data, .{ .failure = "Could not allocate session action" });
    job.* = .{ .allocator = a, .action = action, .cancel = cancel, .callback = callback, .data = data };
    if (action == .logout) {
        if (c.__zig.getenv("XDG_SESSION_ID")) |id| {
            if (id[0] != 0) job.session_id = a.dupeSentinel(u8, std.mem.span(id), 0) catch {
                a.destroy(job);
                return callback(data, .{ .failure = "Could not allocate session ID" });
            };
        }
    }
    _ = c.g_object_ref(cancel);
    job.cancel_handler = c.g_cancellable_connect(cancel, @ptrCast(&Job.cancelled), job, null);
    // Connect from the main loop, so a cancellation right after `perform` sends nothing.
    job.idle = c.g_idle_add(&Job.start, job);
}

const Job = struct {
    allocator: std.mem.Allocator,
    action: Action,
    cancel: *c.GCancellable,
    cancel_handler: c.gulong = 0,
    idle: c.guint = 0,
    callback: Callback,
    data: ?*anyopaque,
    source: ?*loop.Source = null,
    serial: u32 = 0,
    session_id: ?[:0]u8 = null,
    stage: enum { capability, session, action } = .capability,
    message: [512:0]u8 = @splat(0),

    fn finish(self: *Job, result: Result) void {
        if (self.idle != 0) _ = c.g_source_remove(self.idle);
        if (self.cancel_handler != 0) c.g_cancellable_disconnect(self.cancel, self.cancel_handler);
        if (self.source) |source| {
            source.connection.cancel(self.serial);
            source.destroy();
        }
        self.callback(self.data, result);
        c.g_object_unref(self.cancel);
        if (self.session_id) |id| self.allocator.free(id);
        self.allocator.destroy(self);
    }
    fn fail(self: *Job, comptime format: []const u8, args: anytype) void {
        const text = std.fmt.bufPrintSentinel(&self.message, format, args, 0) catch "Session action failed";
        self.finish(.{ .failure = text });
    }
    /// Runs in the cancelling thread; disconnecting there could deadlock, so finish from the loop.
    fn cancelled(_: *c.GCancellable, ptr: c.gpointer) callconv(.c) void {
        const self: *Job = @ptrCast(@alignCast(ptr));
        if (self.idle != 0) _ = c.g_source_remove(self.idle);
        self.idle = c.g_idle_add(&finishCancelled, self);
    }
    fn finishCancelled(ptr: c.gpointer) callconv(.c) c.gboolean {
        const self: *Job = @ptrCast(@alignCast(ptr));
        self.idle = 0;
        self.finish(.cancelled);
        return 0;
    }
    fn start(ptr: c.gpointer) callconv(.c) c.gboolean {
        const self: *Job = @ptrCast(@alignCast(ptr));
        self.idle = 0;
        self.source = loop.Source.open(self.allocator, .system) catch |err| {
            self.fail("Could not connect to the system bus: {s}", .{@errorName(err)});
            return 0;
        };
        if (self.action == .logout) {
            if (self.session_id) |id| {
                self.stage = .action;
                self.call(path, manager, "TerminateSession", .{@as([]const u8, id)}, 5000);
            } else {
                self.stage = .session;
                self.call(path, manager, "GetSessionByPID", .{@as(u32, @intCast(std.os.linux.getpid()))}, 5000);
            }
        } else {
            self.call(path, manager, switch (self.action) {
                .@"suspend" => "CanSuspend",
                .reboot => "CanReboot",
                .poweroff => "CanPowerOff",
                .logout => unreachable,
            }, .{}, 5000);
        }
        return 0;
    }
    fn call(self: *Job, object: []const u8, interface: []const u8, method: []const u8, args: anytype, timeout: u32) void {
        const connection = self.source.?.connection;
        self.serial = connection.call(.{ .destination = name, .path = object, .interface = interface, .member = method }, args, timeout, &replied, self) catch |err| {
            self.fail("Could not call {s}: {s}", .{ method, @errorName(err) });
            return;
        };
    }
    fn replied(ptr: ?*anyopaque, reply: dbus.Reply) void {
        const self: *Job = @ptrCast(@alignCast(ptr));
        const message = switch (reply) {
            .ok => |value| value,
            .failed => |failure| return self.fail("{s}: {s}", .{ failure.name, failure.text }),
        };
        if (c.g_cancellable_is_cancelled(self.cancel) != 0) return self.finish(.cancelled);
        switch (self.stage) {
            .action => self.finish(.success),
            .session => {
                const session = message.read(struct { dbus.ObjectPath }) catch return self.fail("Unexpected reply to GetSessionByPID", .{});
                self.stage = .action;
                self.call(session[0].value, name ++ ".Session", "Terminate", .{}, 5000);
            },
            .capability => {
                const value = message.read(struct { []const u8 }) catch return self.fail("Unexpected reply to the capability query", .{});
                const capability = value[0];
                if (!std.mem.eql(u8, capability, "yes") and !std.mem.eql(u8, capability, "challenge")) {
                    self.finish(.{ .failure = if (std.mem.eql(u8, capability, "na")) "This power action is not supported" else if (std.mem.eql(u8, capability, "no")) "This power action is not permitted" else "This power action is inhibited or unavailable" });
                    return;
                }
                self.stage = .action;
                self.call(path, manager, switch (self.action) {
                    .@"suspend" => "Suspend",
                    .reboot => "Reboot",
                    .poweroff => "PowerOff",
                    .logout => unreachable,
                }, .{true}, 120000);
            },
        }
    }
};
