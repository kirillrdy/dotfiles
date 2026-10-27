//! Shared backlight discovery and asynchronous, session-authorized brightness changes.
const std = @import("std");
const c = @import("gtk");
const libc = @import("libc");
// Test builds account for service state and asynchronous callback allocations.
const a = if (@import("builtin").is_test) std.testing.allocator else std.heap.page_allocator;

pub const Device = struct {
    name: [256:0]u8 = @splat(0),
    current: u32,
    maximum: u32,
    priority: u8 = 0,
    pub fn percent(self: Device) f64 {
        return @as(f64, @floatFromInt(self.current)) / @as(f64, @floatFromInt(self.maximum)) * 100;
    }
    pub fn level(self: Device, percent_value: f64) !u32 {
        if (!std.math.isFinite(percent_value)) return error.InvalidBrightness;
        const percent_clamped = std.math.clamp(percent_value, 1, 100);
        return @max(1, @as(u32, @intFromFloat(@round(percent_clamped * @as(f64, @floatFromInt(self.maximum)) / 100))));
    }
};
pub const Action = union(enum) { read, set: f64, step: i16 };
pub const Result = union(enum) { value: Device, failure: anyerror };
pub const Callback = *const fn (?*anyopaque, Result) void;

pub const Backend = struct {
    // Tests supply an isolated sysfs tree. Writes always go through logind, never this path.
    root: [:0]const u8 = "/sys/class/backlight",
    fn attribute(self: Backend, name: []const u8, field: []const u8, buffer: []u8) ![]const u8 {
        var path: [4096]u8 = undefined;
        const file = try std.fmt.bufPrintSentinel(&path, "{s}/{s}/{s}", .{ self.root, name, field }, 0);
        const fd = libc.open(file, libc.O_RDONLY | libc.O_CLOEXEC | libc.O_NOFOLLOW);
        if (fd < 0) return error.BacklightUnavailable;
        defer _ = libc.close(fd);
        var size: isize = undefined;
        while (true) {
            size = libc.read(fd, buffer.ptr, buffer.len);
            if (size >= 0 or libc.__errno_location().* != 4) break;
        }
        if (size < 0 or size == buffer.len) return error.InvalidBacklight;
        return std.mem.trim(u8, buffer[0..@intCast(size)], " \t\r\n");
    }
    pub fn readDevice(self: Backend, name: []const u8) !Device {
        if (!validName(name)) return error.InvalidDeviceName;
        var buffer: [64]u8 = undefined;
        const maximum = std.fmt.parseInt(u32, try self.attribute(name, "max_brightness", &buffer), 10) catch return error.InvalidBacklight;
        const current = std.fmt.parseInt(u32, try self.attribute(name, "brightness", &buffer), 10) catch return error.InvalidBacklight;
        if (maximum == 0 or current > maximum) return error.InvalidBacklight;
        const kind = self.attribute(name, "type", &buffer) catch "";
        var device = Device{ .current = current, .maximum = maximum, .priority = if (std.mem.eql(u8, kind, "firmware")) 3 else if (std.mem.eql(u8, kind, "platform")) 2 else if (std.mem.eql(u8, kind, "raw")) 1 else 0 };
        @memcpy(device.name[0..name.len], name);
        return device;
    }
    pub fn discover(self: Backend) !Device {
        const dir = libc.opendir(self.root) orelse return error.NoBacklight;
        defer _ = libc.closedir(dir);
        var selected: ?Device = null;
        while (true) {
            const entry = libc.readdir(dir);
            if (entry == null) break;
            const name = std.mem.sliceTo(&entry.*.d_name, 0);
            if (!validName(name)) continue;
            const device = self.readDevice(name) catch continue;
            if (selected == null or device.priority > selected.?.priority or (device.priority == selected.?.priority and std.mem.order(u8, name, std.mem.sliceTo(&selected.?.name, 0)) == .lt)) selected = device;
        }
        return selected orelse error.NoBacklight;
    }
    pub fn start(self: Backend, action: Action, cancel: *c.GCancellable, callback: Callback, context: ?*anyopaque) void {
        const job = a.create(Job) catch @panic("out of memory");
        job.* = .{ .backend = self, .action = action, .cancel = cancel, .callback = callback, .context = context };
        _ = c.g_object_ref(cancel);
        job.read();
    }
};
fn validName(name: []const u8) bool {
    return name.len > 0 and name.len < 256 and name[0] != '.' and std.mem.indexOfScalar(u8, name, '/') == null and std.mem.indexOfScalar(u8, name, 0) == null and std.unicode.utf8ValidateSlice(name);
}
const Job = struct {
    backend: Backend,
    action: Action,
    cancel: *c.GCancellable,
    callback: Callback,
    context: ?*anyopaque,
    device: Device = undefined,
    failure: ?anyerror = null,
    written: bool = false,
    bus: ?*c.GDBusConnection = null,
    fn read(self: *Job) void {
        const task = c.g_task_new(null, self.cancel, &readDone, self);
        c.g_task_set_task_data(task, self, null);
        c.g_task_run_in_thread(task, &readWork);
        c.g_object_unref(task);
    }
    fn readWork(task: ?*c.GTask, _: ?*anyopaque, data: ?*anyopaque, _: [*c]c.GCancellable) callconv(.c) void {
        const self: *Job = @ptrCast(@alignCast(data));
        self.device = (if (self.written) self.backend.readDevice(std.mem.sliceTo(&self.device.name, 0)) else self.backend.discover()) catch |err| {
            self.failure = err;
            c.g_task_return_boolean(task, 1);
            return;
        };
        c.g_task_return_boolean(task, 1);
    }
    fn readDone(_: [*c]c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Job = @ptrCast(@alignCast(data));
        if (c.g_task_propagate_boolean(@ptrCast(result), null) == 0) return self.finish(.{ .failure = error.Cancelled });
        if (self.failure) |err| return self.finish(.{ .failure = err });
        if (self.written or self.action == .read) return self.finish(.{ .value = self.device });
        c.g_bus_get(c.G_BUS_TYPE_SYSTEM, self.cancel, &busConnected, self);
    }
    fn busConnected(_: [*c]c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Job = @ptrCast(@alignCast(data));
        self.bus = c.g_bus_get_finish(result, null) orelse return self.finish(.{ .failure = if (c.g_cancellable_is_cancelled(self.cancel) != 0) error.Cancelled else error.NoSystemBus });
        c.g_dbus_connection_set_exit_on_close(self.bus, 0);
        const percent = switch (self.action) {
            .read => unreachable,
            .set => |value| value,
            .step => |delta| std.math.clamp(self.device.percent() + @as(f64, @floatFromInt(delta)), 5, 100),
        };
        const level = self.device.level(percent) catch |err| return self.finish(.{ .failure = err });
        c.g_dbus_connection_call(self.bus, "org.freedesktop.login1", "/org/freedesktop/login1/session/auto", "org.freedesktop.login1.Session", "SetBrightness", c.g_variant_new("(ssu)", @as([*:0]const u8, "backlight"), @as([*:0]const u8, &self.device.name), level), null, c.G_DBUS_CALL_FLAGS_NONE, 2000, self.cancel, &writeDone, self);
    }
    fn writeDone(source: [*c]c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Job = @ptrCast(@alignCast(data));
        var err: [*c]c.GError = null;
        const reply = c.g_dbus_connection_call_finish(@ptrCast(source), result, &err);
        if (reply == null) {
            const cancelled = c.g_cancellable_is_cancelled(self.cancel) != 0;
            if (!cancelled and err != null) std.log.warn("backlight: {s}", .{err.*.message});
            c.g_clear_error(&err);
            return self.finish(.{ .failure = if (cancelled) error.Cancelled else error.SetBrightnessFailed });
        }
        c.g_variant_unref(reply);
        self.written = true;
        self.read();
    }
    fn finish(self: *Job, result: Result) void {
        self.callback(self.context, result);
        if (self.bus) |bus| c.g_object_unref(bus);
        c.g_object_unref(self.cancel);
        a.destroy(self);
    }
};

test "brightness rounding, limits and invalid numbers" {
    const device = Device{ .current = 80, .maximum = 400 };
    try std.testing.expectEqual(@as(f64, 20), device.percent());
    try std.testing.expectEqual(@as(u32, 4), try device.level(0));
    try std.testing.expectEqual(@as(u32, 400), try device.level(1000));
    try std.testing.expectEqual(@as(u32, 134), try device.level(33.5));
    try std.testing.expectEqual(@as(u32, 1), try (Device{ .current = 1, .maximum = 2 }).level(1));
    try std.testing.expectError(error.InvalidBrightness, device.level(std.math.nan(f64)));
    try std.testing.expectError(error.InvalidBrightness, device.level(std.math.inf(f64)));
    for ([_][]const u8{ "", "..", "../intel", "intel/brightness", ".hidden" }) |name| try std.testing.expect(!validName(name));
}
