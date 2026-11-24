//! System battery policy and core read-only UPower status compatibility.
const std = @import("std");
const c = @import("desktop-glib.zig");
const dbus = @import("dbus");
const loop = @import("desktop-dbus-loop.zig");
const libc = @import("desktop-libc.zig");
const battery = @import("desktop-battery.zig");
const name = "org.freedesktop.UPower";
const root = "/org/freedesktop/UPower";
const display = root ++ "/devices/DisplayDevice";
const device = root ++ "/devices/battery_system";
const iface = name ++ ".Device";
const login = "org.freedesktop.login1";
const login_path = "/org/freedesktop/login1";
const login_iface = login ++ ".Manager";
const cast = c.__zig.cast;
const eq = c.__zig.eq;

pub const Policy = struct {
    since: ?i64 = null,
    done: bool = false,
    retry_at: i64 = 0,
    generation: u64 = 0,
    pub fn update(self: *Policy, value: battery.State, now: i64, delay: i64) bool {
        if (value.warning() != .action) {
            if (self.since != null) self.generation +%= 1;
            self.since = null;
            self.done = false;
            self.retry_at = 0;
            return false;
        }
        if (self.since == null) self.since = now;
        return !self.done and now >= self.retry_at and now - self.since.? >= delay;
    }
};
pub const Options = struct {
    source: battery.Options = .{},
    lid_root: [:0]const u8 = "/proc/acpi/button/lid",
    // Fixtures supply their own tree and private logind; production has no overrides.
    action_delay_us: i64 = 20 * 1000000,
};
const Lid = struct { present: bool = false, closed: bool = false };
fn lidState(directory: [:0]const u8) Lid {
    const dir = libc.opendir(directory) orelse return .{};
    defer _ = libc.closedir(dir);
    var result = Lid{};
    while (libc.readdir(dir)) |entry| {
        const item = entry.*.name();
        if (item.len == 0 or item[0] == '.') continue;
        var path: [4096]u8 = undefined;
        const file = std.fmt.bufPrintSentinel(&path, "{s}/{s}/state", .{ directory, item }, 0) catch continue;
        const fd = libc.open(file, libc.O_RDONLY | libc.O_CLOEXEC | libc.O_NOFOLLOW);
        if (fd < 0) continue;
        var buffer: [64]u8 = undefined;
        const count = libc.read(fd, &buffer, buffer.len);
        _ = libc.close(fd);
        if (count <= 0 or count == buffer.len) continue;
        const text = buffer[0..@intCast(count)];
        if (std.mem.indexOf(u8, text, "open") != null) result.present = true;
        if (std.mem.indexOf(u8, text, "closed") != null) result = .{ .present = true, .closed = true };
    }
    return result;
}
const Server = struct {
    allocator: std.mem.Allocator,
    options: Options,
    connection: *dbus.Connection,
    service: ?*battery.Service = null,
    cancel: *c.GCancellable,
    state: battery.State = .{},
    lid: Lid = .{},
    policy: Policy = .{},
    update_time: u64 = 0,
    jobs: std.ArrayList(*Job) = .empty,
    stopping: bool = false,
    tick_count: u32 = 0,

    fn property(self: *Server, object: []const u8, key: []const u8, arena: std.mem.Allocator) ?dbus.Value {
        const value = self.state;
        if (eq(object, root)) {
            if (eq(key, "DaemonVersion")) return .{ .string = "desktop-zig-0.1.0" };
            if (eq(key, "OnBattery")) return .{ .boolean = value.on_battery };
            if (eq(key, "LidIsPresent")) return .{ .boolean = self.lid.present };
            if (eq(key, "LidIsClosed")) return .{ .boolean = self.lid.closed };
            return null;
        }
        if (eq(key, "NativePath")) return .{ .string = self.options.source.backend.root };
        if (eq(key, "Vendor") or eq(key, "Serial")) return .{ .string = "" };
        if (eq(key, "Model")) return .{ .string = "System batteries" };
        if (eq(key, "UpdateTime")) return .{ .uint64 = self.update_time };
        if (eq(key, "Type")) return .{ .uint32 = 2 };
        if (eq(key, "State")) return .{ .uint32 = value.state };
        if (eq(key, "Technology")) return .{ .uint32 = 0 };
        if (eq(key, "WarningLevel")) return .{ .uint32 = @backingInt(value.warning()) };
        if (eq(key, "PowerSupply") or eq(key, "IsRechargeable")) return .{ .boolean = true };
        if (eq(key, "HasHistory") or eq(key, "HasStatistics") or eq(key, "Online")) return .{ .boolean = false };
        if (eq(key, "IsPresent")) return .{ .boolean = if (eq(object, display)) value.visible() else value.present };
        if (eq(key, "ChargeThresholdEnabled")) return .{ .boolean = value.charge_threshold };
        if (eq(key, "TimeToEmpty")) return .{ .int64 = value.time_to_empty };
        if (eq(key, "TimeToFull")) return .{ .int64 = value.time_to_full };
        if (eq(key, "Energy")) return .{ .double = value.energy };
        if (eq(key, "EnergyFull")) return .{ .double = value.energy_full };
        if (eq(key, "EnergyFullDesign")) return .{ .double = value.energy_full_design };
        if (eq(key, "Capacity")) return .{ .double = value.capacity };
        if (eq(key, "EnergyRate")) return .{ .double = value.energy_rate };
        if (eq(key, "Percentage")) return .{ .double = if (value.visible()) value.percent else 0 };
        if (eq(key, "EnergyEmpty") or eq(key, "Voltage") or eq(key, "Temperature") or eq(key, "Luminosity")) return .{ .double = 0 };
        if (eq(key, "ChargeCycles")) return .{ .int32 = -1 };
        if (eq(key, "IconName")) {
            var buffer: [100]u8 = undefined;
            const icon = value.icon(&buffer) catch return null;
            return .{ .string = arena.dupe(u8, icon) catch return null };
        }
        return null;
    }
    fn getProperty(context: ?*anyopaque, path: []const u8, _: []const u8, key: []const u8, arena: std.mem.Allocator) ?dbus.Value {
        return cast(Server, context).property(path, key, arena);
    }
    fn methodCall(context: ?*anyopaque, message: *const dbus.Message) void {
        const self = cast(Server, context);
        const member = message.member orelse "";
        const connection = self.connection;
        if (eq(member, "Refresh")) {
            self.service.?.refresh();
            connection.reply(message, .{}) catch {};
        } else if (eq(member, "GetDisplayDevice")) {
            connection.reply(message, .{dbus.ObjectPath{ .value = display }}) catch {};
        } else if (eq(member, "GetCriticalAction")) {
            Job.start(self, message) catch connection.replyError(message, "org.freedesktop.UPower.Error.LimitsExceeded", "Too many requests") catch {};
        } else {
            const devices: []const dbus.ObjectPath = if (eq(member, "EnumerateDevices") and self.state.present) &.{.{ .value = device }} else &.{};
            connection.reply(message, .{devices}) catch {};
        }
    }
    fn changed(data: ?*anyopaque, value: battery.State) void {
        const self = cast(Server, data);
        if (self.stopping) return;
        const was_present = self.state.present;
        self.state = value;
        self.update_time = @intCast(@divTrunc(c.__zig.realTime(), 1000000));
        _ = self.policy.update(value, c.__zig.monotonicTime(), self.options.action_delay_us);
        self.connection.emitPropertiesChanged(root, name) catch {};
        self.connection.emitPropertiesChanged(display, iface) catch {};
        self.connection.emitPropertiesChanged(device, iface) catch {};
        if (was_present != value.present) self.connection.emit(root, name, if (value.present) "DeviceAdded" else "DeviceRemoved", .{dbus.ObjectPath{ .value = device }}) catch {};
    }
    fn tick(data: ?*anyopaque) callconv(.c) c_int {
        const self = cast(Server, data);
        self.tick_count +%= 1;
        if (self.tick_count % 4 == 0) {
            const lid = lidState(self.options.lid_root);
            if (!std.meta.eql(lid, self.lid)) {
                self.lid = lid;
                self.connection.emitPropertiesChanged(root, name) catch {};
            }
        }
        if (self.policy.update(self.state, c.__zig.monotonicTime(), self.options.action_delay_us)) {
            self.policy.done = true;
            Job.start(self, null) catch {
                self.policy.done = false;
                self.policy.retry_at = c.__zig.monotonicTime() + 60 * 1000000;
            };
        }
        return 1;
    }
    fn deinit(self: *Server) void {
        self.stopping = true;
        c.g_cancellable_cancel(self.cancel);
        // Calls still waiting on logind are dropped; jobs re-reading sysfs finish on cancellation.
        var index: usize = 0;
        while (index < self.jobs.items.len) {
            const job = self.jobs.items[index];
            if (job.serial == 0) {
                index += 1;
                continue;
            }
            self.connection.cancel(job.serial);
            job.serial = 0;
            job.finish(false);
            index = 0;
        }
        if (self.service) |service| {
            service.stop();
            while (service.pending or self.jobs.items.len > 0) _ = c.g_main_context_iteration(null, 1);
            service.destroy();
        } else while (self.jobs.items.len > 0) _ = c.g_main_context_iteration(null, 1);
        self.jobs.deinit(self.allocator);
        c.g_object_unref(self.cancel);
    }
};

const Job = struct {
    server: *Server,
    invocation: ?dbus.Invocation = null,
    generation: u64,
    index: usize = 0,
    stage: enum { capability, action } = .capability,
    serial: u32 = 0,
    fresh: battery.State = .{},
    const capabilities = [_][]const u8{ "CanHybridSleep", "CanHibernate", "CanPowerOff" };
    const actions = [_][]const u8{ "HybridSleep", "Hibernate", "PowerOff" };
    fn start(server: *Server, message: ?*const dbus.Message) !void {
        if (message != null and server.jobs.items.len >= 32) return error.TooManyRequests;
        const self = try server.allocator.create(Job);
        errdefer server.allocator.destroy(self);
        self.* = .{ .server = server, .generation = server.policy.generation };
        if (message) |value| self.invocation = try server.connection.hold(value);
        errdefer if (self.invocation) |*invocation| invocation.release(server.allocator);
        try server.jobs.append(server.allocator, self);
        self.next();
    }
    fn current(self: *Job) bool {
        return !self.server.stopping and (self.invocation != null or self.generation == self.server.policy.generation);
    }
    fn finish(self: *Job, success: bool) void {
        const server = self.server;
        if (self.invocation) |*invocation| {
            if (success) server.connection.answer(invocation, .{actions[self.index]}) catch {} else server.connection.answerError(invocation, "org.freedesktop.UPower.Error.NotSupported", "No critical power action is available") catch {};
        } else if (!success and self.current()) {
            server.policy.done = false;
            server.policy.retry_at = c.__zig.monotonicTime() + 60 * 1000000;
            std.log.warn("battery: critical power action unavailable; retrying in one minute", .{});
        }
        for (server.jobs.items, 0..) |job, i| if (job == self) {
            _ = server.jobs.orderedRemove(i);
            break;
        };
        server.allocator.destroy(self);
    }
    fn call(self: *Job, member: []const u8, args: anytype, timeout: u32) void {
        self.serial = self.server.connection.call(.{ .destination = login, .path = login_path, .interface = login_iface, .member = member }, args, timeout, &completed, self) catch return self.finish(false);
    }
    fn next(self: *Job) void {
        if (!self.current() or self.index >= capabilities.len) return self.finish(false);
        self.stage = .capability;
        self.call(capabilities[self.index], .{}, 3000);
    }
    fn completed(data: ?*anyopaque, reply: dbus.Reply) void {
        const self = cast(Job, data);
        self.serial = 0;
        if (!self.current()) return self.finish(false);
        const message = switch (reply) {
            .ok => |value| value,
            // A refused capability or a failed action falls back to the next action.
            .failed => {
                self.index += 1;
                return self.next();
            },
        };
        if (self.stage == .action) return self.finish(true);
        const status = message.read(struct { []const u8 }) catch .{""};
        if (eq(status[0], "yes")) {
            if (self.invocation != null) return self.finish(true);
            // Re-read AC and every battery after capability negotiation, before acting.
            const task = c.g_task_new(null, self.server.cancel, &validated, self);
            c.g_task_set_task_data(task, self, null);
            c.g_task_run_in_thread(task, &validateWork);
            c.g_object_unref(task);
            return;
        }
        self.index += 1;
        self.next();
    }
    fn validateWork(task: ?*c.GTask, _: ?*anyopaque, data: ?*anyopaque, _: [*c]c.GCancellable) callconv(.c) void {
        const self = cast(Job, data);
        self.fresh = self.server.options.source.backend.read();
        c.g_task_return_boolean(task, 1);
    }
    fn validated(_: ?*c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self = cast(Job, data);
        if (c.g_task_propagate_boolean(@ptrCast(result), null) == 0 or !self.current()) return self.finish(false);
        Server.changed(self.server, self.fresh);
        if (!self.current() or self.fresh.warning() != .action) return self.finish(false);
        self.stage = .action;
        std.log.warn("battery: critical battery level; requesting {s}", .{actions[self.index]});
        self.call(actions[self.index], .{false}, 60000);
    }
};
fn quit(data: ?*anyopaque) callconv(.c) c_int {
    cast(Server, data).stopping = true;
    return 1;
}
pub fn run(allocator: std.mem.Allocator) !void {
    if (libc.geteuid() != 0) return error.RequiresRoot;
    return runWithOptions(.{}, allocator);
}
pub fn runWithOptions(options: Options, allocator: std.mem.Allocator) !void {
    var introspection = try dbus.Introspection.parse(allocator, @embedFile("desktop-battery.xml"));
    defer introspection.deinit();
    const source = loop.Source.open(allocator, .system) catch return error.NoSystemBus;
    defer source.destroy();
    const connection = source.connection;
    var server = Server{ .allocator = allocator, .options = options, .connection = connection, .cancel = c.g_cancellable_new().?, .lid = lidState(options.lid_root) };
    defer server.deinit();
    const manager = introspection.find(name) orelse return error.InvalidXml;
    const device_info = introspection.find(iface) orelse return error.InvalidXml;
    _ = try connection.exportObject(root, manager, &Server.methodCall, &Server.getProperty, &server);
    _ = try connection.exportObject(display, device_info, &Server.methodCall, &Server.getProperty, &server);
    _ = try connection.exportObject(device, device_info, &Server.methodCall, &Server.getProperty, &server);
    server.service = try battery.Service.createWithOptions(allocator, options.source, &Server.changed, &server);
    if ((connection.requestName(name, 4) catch return error.NameUnavailable) != 1) return error.NameUnavailable;
    const timer = c.g_timeout_add(250, &Server.tick, &server);
    const term = c.g_unix_signal_add(c.SIGTERM, &quit, &server);
    const interrupt = c.g_unix_signal_add(c.SIGINT, &quit, &server);
    defer {
        _ = c.g_source_remove(timer);
        _ = c.g_source_remove(term);
        _ = c.g_source_remove(interrupt);
    }
    while (!server.stopping and !connection.closed) _ = c.g_main_context_iteration(null, 1);
    if (!server.stopping) return error.SystemBusDisconnected;
}

test "critical battery policy cancels on AC or invalid data and acts once after the grace period" {
    var policy = Policy{};
    var state = battery.State{ .present = true, .percent = 2, .state = 2, .on_battery = true };
    try std.testing.expect(!policy.update(state, 100, 20));
    try std.testing.expect(!policy.update(state, 119, 20));
    try std.testing.expect(policy.update(state, 120, 20));
    policy.done = true;
    try std.testing.expect(!policy.update(state, 140, 20));
    state.on_battery = false;
    try std.testing.expect(!policy.update(state, 145, 20));
    const generation = policy.generation;
    state.on_battery = true;
    try std.testing.expect(!policy.update(state, 150, 20));
    try std.testing.expect(policy.update(state, 170, 20));
    state.percent = std.math.nan(f64);
    try std.testing.expect(!policy.update(state, 171, 20));
    try std.testing.expect(policy.generation > generation);
    state.percent = 1;
    try std.testing.expect(!policy.update(state, 180, 20));
    policy.retry_at = 250;
    try std.testing.expect(!policy.update(state, 230, 20));
    try std.testing.expect(policy.update(state, 250, 20));
}
