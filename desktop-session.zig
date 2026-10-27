//! Asynchronous logind actions. Result messages are valid for the callback only.
const std = @import("std");
const c = @import("gtk");
const a = if (@import("builtin").is_test) std.testing.allocator else std.heap.page_allocator;
const name = "org.freedesktop.login1";
const path = "/org/freedesktop/login1";
const manager = name ++ ".Manager";

pub const Action = enum { @"suspend", reboot, poweroff, logout };
pub const Result = union(enum) { success, cancelled, failure: [:0]const u8 };
pub const Callback = *const fn (?*anyopaque, Result) void;

pub fn perform(action: Action, cancel: *c.GCancellable, callback: Callback, data: ?*anyopaque) void {
    const job = a.create(Job) catch {
        callback(data, .{ .failure = "Could not allocate session action" });
        return;
    };
    job.* = .{ .action = action, .cancel = cancel, .callback = callback, .data = data };
    if (action == .logout) {
        if (c.g_getenv("XDG_SESSION_ID")) |id| {
            if (id[0] != 0) job.session_id = a.dupeSentinel(u8, std.mem.span(id), 0) catch {
                a.destroy(job);
                callback(data, .{ .failure = "Could not allocate session ID" });
                return;
            };
        }
    }
    _ = c.g_object_ref(cancel);
    c.g_bus_get(c.G_BUS_TYPE_SYSTEM, cancel, &Job.connected, job);
}

const Job = struct {
    action: Action,
    cancel: *c.GCancellable,
    callback: Callback,
    data: ?*anyopaque,
    bus: ?*c.GDBusConnection = null,
    session_id: ?[:0]u8 = null,
    stage: enum { capability, session, action } = .capability,

    fn finish(self: *Job, result: Result) void {
        self.callback(self.data, result);
        if (self.bus) |bus| c.g_object_unref(bus);
        c.g_object_unref(self.cancel);
        if (self.session_id) |id| a.free(id);
        a.destroy(self);
    }
    fn failed(self: *Job, err: [*c]c.GError) void {
        defer if (err != null) c.g_error_free(err);
        self.finish(if (c.g_cancellable_is_cancelled(self.cancel) != 0) .cancelled else .{ .failure = if (err != null) std.mem.span(err.*.message) else "Session action failed" });
    }
    fn connected(_: ?*c.GObject, result: ?*c.GAsyncResult, ptr: c.gpointer) callconv(.c) void {
        const self: *Job = @ptrCast(@alignCast(ptr));
        var err: [*c]c.GError = null;
        self.bus = c.g_bus_get_finish(result, &err) orelse {
            self.failed(err);
            return;
        };
        if (self.action == .logout) {
            if (self.session_id) |id| {
                self.stage = .action;
                self.call(path, manager, "TerminateSession", c.g_variant_new("(s)", id.ptr), "()", 5000);
            } else {
                self.stage = .session;
                self.call(path, manager, "GetSessionByPID", c.g_variant_new("(u)", @as(c_uint, @intCast(c.getpid()))), "(o)", 5000);
            }
        } else {
            self.call(path, manager, switch (self.action) {
                .@"suspend" => "CanSuspend",
                .reboot => "CanReboot",
                .poweroff => "CanPowerOff",
                .logout => unreachable,
            }, null, "(s)", 5000);
        }
    }
    fn call(self: *Job, object: [*:0]const u8, interface: [*:0]const u8, method: [*:0]const u8, parameters: ?*c.GVariant, reply: [*:0]const u8, timeout: c_int) void {
        c.g_dbus_connection_call(self.bus, name, object, interface, method, parameters, @ptrCast(reply), c.G_DBUS_CALL_FLAGS_NONE, timeout, self.cancel, &completed, self);
    }
    fn completed(_: ?*c.GObject, result: ?*c.GAsyncResult, ptr: c.gpointer) callconv(.c) void {
        const self: *Job = @ptrCast(@alignCast(ptr));
        var err: [*c]c.GError = null;
        const reply = c.g_dbus_connection_call_finish(self.bus, result, &err) orelse {
            self.failed(err);
            return;
        };
        defer c.g_variant_unref(reply);
        if (c.g_cancellable_is_cancelled(self.cancel) != 0) {
            self.finish(.cancelled);
            return;
        }
        switch (self.stage) {
            .action => self.finish(.success),
            .session => {
                const value = c.g_variant_get_child_value(reply, 0).?;
                defer c.g_variant_unref(value);
                self.stage = .action;
                self.call(c.g_variant_get_string(value, null), name ++ ".Session", "Terminate", null, "()", 5000);
            },
            .capability => {
                const value = c.g_variant_get_child_value(reply, 0).?;
                defer c.g_variant_unref(value);
                const capability = std.mem.span(c.g_variant_get_string(value, null));
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
                }, c.g_variant_new("(b)", @as(c_int, 1)), "()", 120000);
            },
        }
    }
};
