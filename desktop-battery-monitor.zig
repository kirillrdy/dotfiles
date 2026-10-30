//! System battery policy and core read-only UPower status compatibility.
const std = @import("std");
const c = @import("gtk");
const libc = @import("libc");
const battery = @import("battery");
const name = "org.freedesktop.UPower";
const root = "/org/freedesktop/UPower";
const display = root ++ "/devices/DisplayDevice";
const device = root ++ "/devices/battery_system";
const iface = name ++ ".Device";
const login = "org.freedesktop.login1";
const login_path = "/org/freedesktop/login1";
const login_iface = login ++ ".Manager";
fn cast(comptime T: type, value: anytype) *T {
    return @ptrCast(@alignCast(value));
}
fn eq(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}

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
        const item = std.mem.sliceTo(&entry.*.d_name, 0);
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
    bus: *c.GDBusConnection,
    node: *c.GDBusNodeInfo,
    registrations: [3]c.guint = .{ 0, 0, 0 },
    service: ?*battery.Service = null,
    cancel: *c.GCancellable,
    state: battery.State = .{},
    lid: Lid = .{},
    policy: Policy = .{},
    update_time: u64 = 0,
    jobs: usize = 0,
    stopping: bool = false,
    tick_count: u32 = 0,

    fn property(self: *Server, object: []const u8, key: []const u8) ?*c.GVariant {
        const value = self.state;
        if (eq(object, root)) {
            if (eq(key, "DaemonVersion")) return c.g_variant_new("s", @as([*:0]const u8, "desktop-zig-0.1.0"));
            if (eq(key, "OnBattery")) return c.g_variant_new("b", @as(c_int, @intFromBool(value.on_battery)));
            if (eq(key, "LidIsPresent")) return c.g_variant_new("b", @as(c_int, @intFromBool(self.lid.present)));
            if (eq(key, "LidIsClosed")) return c.g_variant_new("b", @as(c_int, @intFromBool(self.lid.closed)));
            return null;
        }
        if (eq(key, "NativePath")) return c.g_variant_new("s", self.options.source.backend.root.ptr);
        if (eq(key, "Vendor") or eq(key, "Serial")) return c.g_variant_new("s", @as([*:0]const u8, ""));
        if (eq(key, "Model")) return c.g_variant_new("s", @as([*:0]const u8, "System batteries"));
        if (eq(key, "UpdateTime")) return c.g_variant_new("t", self.update_time);
        if (eq(key, "Type")) return c.g_variant_new("u", @as(c_uint, 2));
        if (eq(key, "State")) return c.g_variant_new("u", value.state);
        if (eq(key, "Technology")) return c.g_variant_new("u", @as(c_uint, 0));
        if (eq(key, "WarningLevel")) return c.g_variant_new("u", @as(c_uint, @backingInt(value.warning())));
        if (eq(key, "PowerSupply") or eq(key, "IsRechargeable")) return c.g_variant_new("b", @as(c_int, 1));
        if (eq(key, "HasHistory") or eq(key, "HasStatistics") or eq(key, "Online")) return c.g_variant_new("b", @as(c_int, 0));
        if (eq(key, "IsPresent")) return c.g_variant_new("b", @as(c_int, @intFromBool(if (eq(object, display)) value.visible() else value.present)));
        if (eq(key, "ChargeThresholdEnabled")) return c.g_variant_new("b", @as(c_int, @intFromBool(value.charge_threshold)));
        if (eq(key, "TimeToEmpty")) return c.g_variant_new("x", value.time_to_empty);
        if (eq(key, "TimeToFull")) return c.g_variant_new("x", value.time_to_full);
        if (eq(key, "Energy")) return c.g_variant_new("d", value.energy);
        if (eq(key, "EnergyFull")) return c.g_variant_new("d", value.energy_full);
        if (eq(key, "EnergyRate")) return c.g_variant_new("d", value.energy_rate);
        if (eq(key, "Percentage")) return c.g_variant_new("d", if (value.visible()) value.percent else @as(f64, 0));
        if (eq(key, "EnergyEmpty") or eq(key, "EnergyFullDesign") or eq(key, "Capacity") or eq(key, "Voltage") or eq(key, "Temperature") or eq(key, "Luminosity")) return c.g_variant_new("d", @as(f64, 0));
        if (eq(key, "ChargeCycles")) return c.g_variant_new("i", @as(c_int, -1));
        if (eq(key, "IconName")) {
            var buffer: [100]u8 = undefined;
            const icon = value.icon(&buffer) catch return null;
            return c.g_variant_new("s", icon.ptr);
        }
        return null;
    }
    fn propertiesChanged(self: *Server, object: [:0]const u8, index: usize) void {
        const info: *c.GDBusInterfaceInfo = self.node.interfaces[index];
        const values = c.g_variant_builder_new(@ptrCast(@as([*:0]const u8, "a{sv}")));
        defer c.g_variant_builder_unref(values);
        var i: usize = 0;
        while (info.properties[i] != null) : (i += 1) {
            const key = info.properties[i].*.name;
            if (self.property(object, std.mem.span(key))) |value| c.g_variant_builder_add(values, "{sv}", key, value);
        }
        _ = c.g_dbus_connection_emit_signal(self.bus, null, object, "org.freedesktop.DBus.Properties", "PropertiesChanged", c.g_variant_new("(s@a{sv}@as)", info.name, c.g_variant_builder_end(values), c.g_variant_new_strv(null, 0)), null);
    }
    fn changed(data: ?*anyopaque, value: battery.State) void {
        const self = cast(Server, data);
        if (self.stopping) return;
        const was_present = self.state.present;
        self.state = value;
        self.update_time = @intCast(@divTrunc(c.g_get_real_time(), 1000000));
        _ = self.policy.update(value, c.g_get_monotonic_time(), self.options.action_delay_us);
        self.propertiesChanged(root, 0);
        self.propertiesChanged(display, 1);
        self.propertiesChanged(device, 1);
        if (was_present != value.present) _ = c.g_dbus_connection_emit_signal(self.bus, null, root, name, if (value.present) "DeviceAdded" else "DeviceRemoved", c.g_variant_new("(o)", @as([*:0]const u8, device)), null);
    }
    fn tick(data: ?*anyopaque) callconv(.c) c_int {
        const self = cast(Server, data);
        self.tick_count +%= 1;
        if (self.tick_count % 4 == 0) {
            const lid = lidState(self.options.lid_root);
            if (!std.meta.eql(lid, self.lid)) {
                self.lid = lid;
                self.propertiesChanged(root, 0);
            }
        }
        if (self.policy.update(self.state, c.g_get_monotonic_time(), self.options.action_delay_us)) {
            self.policy.done = true;
            Job.start(self, null) catch {
                self.policy.done = false;
                self.policy.retry_at = c.g_get_monotonic_time() + 60 * 1000000;
            };
        }
        return 1;
    }
    fn deinit(self: *Server) void {
        self.stopping = true;
        c.g_cancellable_cancel(self.cancel);
        if (self.service) |service| {
            service.stop();
            while (service.pending or self.jobs > 0) _ = c.g_main_context_iteration(null, 1);
            service.destroy();
        } else while (self.jobs > 0) _ = c.g_main_context_iteration(null, 1);
        for (self.registrations) |id| if (id != 0) {
            _ = c.g_dbus_connection_unregister_object(self.bus, id);
        };
        c.g_object_unref(self.cancel);
    }
};

const Job = struct {
    server: *Server,
    invocation: ?*c.GDBusMethodInvocation = null,
    generation: u64,
    index: usize = 0,
    stage: enum { capability, action } = .capability,
    fresh: battery.State = .{},
    const capabilities = [_][*:0]const u8{ "CanHybridSleep", "CanHibernate", "CanPowerOff" };
    const actions = [_][*:0]const u8{ "HybridSleep", "Hibernate", "PowerOff" };
    fn start(server: *Server, invocation: ?*c.GDBusMethodInvocation) !void {
        if (invocation != null and server.jobs >= 32) return error.TooManyRequests;
        const self = try server.allocator.create(Job);
        self.* = .{ .server = server, .invocation = invocation, .generation = server.policy.generation };
        if (invocation) |value| _ = c.g_object_ref(value);
        server.jobs += 1;
        self.next();
    }
    fn current(self: *Job) bool {
        return !self.server.stopping and (self.invocation != null or self.generation == self.server.policy.generation);
    }
    fn finish(self: *Job, success: bool) void {
        const server = self.server;
        if (self.invocation) |invocation| {
            if (success) c.g_dbus_method_invocation_return_value(invocation, c.g_variant_new("(s)", actions[self.index])) else c.g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.UPower.Error.NotSupported", "No critical power action is available");
            c.g_object_unref(invocation);
        } else if (!success and self.current()) {
            server.policy.done = false;
            server.policy.retry_at = c.g_get_monotonic_time() + 60 * 1000000;
            std.log.warn("battery: critical power action unavailable; retrying in one minute", .{});
        }
        server.jobs -= 1;
        server.allocator.destroy(self);
    }
    fn next(self: *Job) void {
        if (!self.current() or self.index >= capabilities.len) return self.finish(false);
        self.stage = .capability;
        c.g_dbus_connection_call(self.server.bus, login, login_path, login_iface, capabilities[self.index], null, @ptrCast(@as([*:0]const u8, "(s)")), 0, 3000, self.server.cancel, &completed, self);
    }
    fn completed(_: ?*c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self = cast(Job, data);
        const reply = c.g_dbus_connection_call_finish(self.server.bus, result, null);
        defer if (reply != null) c.g_variant_unref(reply);
        if (!self.current()) return self.finish(false);
        if (reply != null and self.stage == .action) return self.finish(true);
        if (reply != null) {
            const status = c.g_variant_get_child_value(reply, 0);
            defer c.g_variant_unref(status);
            if (eq(std.mem.span(c.g_variant_get_string(status, null)), "yes")) {
                if (self.invocation != null) return self.finish(true);
                // Re-read AC and every battery after capability negotiation, before acting.
                const task = c.g_task_new(null, self.server.cancel, &validated, self);
                c.g_task_set_task_data(task, self, null);
                c.g_task_run_in_thread(task, &validateWork);
                c.g_object_unref(task);
                return;
            }
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
        c.g_dbus_connection_call(self.server.bus, login, login_path, login_iface, actions[self.index], c.g_variant_new("(b)", @as(c_int, 0)), @ptrCast(@as([*:0]const u8, "()")), 0, 60000, self.server.cancel, &completed, self);
    }
};
fn getProperty(_: ?*c.GDBusConnection, _: [*c]const u8, path: [*c]const u8, _: [*c]const u8, property: [*c]const u8, _: [*c][*c]c.GError, data: ?*anyopaque) callconv(.c) ?*c.GVariant {
    return cast(Server, data).property(std.mem.span(path), std.mem.span(property));
}
fn methodCall(_: ?*c.GDBusConnection, _: [*c]const u8, _: [*c]const u8, interface: [*c]const u8, method: [*c]const u8, _: ?*c.GVariant, invocation: ?*c.GDBusMethodInvocation, data: ?*anyopaque) callconv(.c) void {
    const self = cast(Server, data);
    if (eq(std.mem.span(interface), iface)) {
        self.service.?.refresh();
        c.g_dbus_method_invocation_return_value(invocation, null);
    } else if (eq(std.mem.span(method), "GetDisplayDevice")) c.g_dbus_method_invocation_return_value(invocation, c.g_variant_new("(o)", @as([*:0]const u8, display))) else if (eq(std.mem.span(method), "GetCriticalAction")) {
        Job.start(self, invocation) catch c.g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.UPower.Error.LimitsExceeded", "Too many requests");
    } else {
        const objects = c.g_variant_builder_new(@ptrCast(@as([*:0]const u8, "ao")));
        defer c.g_variant_builder_unref(objects);
        if (eq(std.mem.span(method), "EnumerateDevices") and self.state.present) c.g_variant_builder_add(objects, "o", @as([*:0]const u8, device));
        c.g_dbus_method_invocation_return_value(invocation, c.g_variant_new("(@ao)", c.g_variant_builder_end(objects)));
    }
}
const vtable = c.GDBusInterfaceVTable{ .method_call = &methodCall, .get_property = &getProperty };
fn quit(data: ?*anyopaque) callconv(.c) c_int {
    cast(Server, data).stopping = true;
    return 1;
}
pub fn run() !void {
    if (libc.geteuid() != 0) return error.RequiresRoot;
    return runWithOptions(.{}, std.heap.page_allocator);
}
pub fn runWithOptions(options: Options, allocator: std.mem.Allocator) !void {
    const bus = c.g_bus_get_sync(c.G_BUS_TYPE_SYSTEM, null, null) orelse return error.NoSystemBus;
    defer c.g_object_unref(bus);
    const node = c.g_dbus_node_info_new_for_xml(@embedFile("desktop-battery.xml"), null) orelse return error.InvalidXml;
    defer c.g_dbus_node_info_unref(node);
    var server = Server{ .allocator = allocator, .options = options, .bus = bus, .node = node, .cancel = c.g_cancellable_new().?, .lid = lidState(options.lid_root) };
    defer server.deinit();
    for ([_][*:0]const u8{ root, display, device }, 0..) |path, i| {
        server.registrations[i] = c.g_dbus_connection_register_object(bus, path, node.*.interfaces[if (i == 0) @as(usize, 0) else 1], &vtable, &server, null, null);
        if (server.registrations[i] == 0) return error.RegistrationFailed;
    }
    server.service = try battery.Service.createWithOptions(options.source, &Server.changed, &server);
    const reply = c.g_dbus_connection_call_sync(bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName", c.g_variant_new("(su)", @as([*:0]const u8, name), @as(c_uint, 4)), @ptrCast(@as([*:0]const u8, "(u)")), 0, 3000, null, null) orelse return error.NameUnavailable;
    defer c.g_variant_unref(reply);
    const status = c.g_variant_get_child_value(reply, 0);
    defer c.g_variant_unref(status);
    if (c.g_variant_get_uint32(status) != 1) return error.NameUnavailable;
    const timer = c.g_timeout_add(250, &Server.tick, &server);
    const term = c.g_unix_signal_add(c.SIGTERM, &quit, &server);
    const interrupt = c.g_unix_signal_add(c.SIGINT, &quit, &server);
    defer {
        _ = c.g_source_remove(timer);
        _ = c.g_source_remove(term);
        _ = c.g_source_remove(interrupt);
    }
    while (!server.stopping and c.g_dbus_connection_is_closed(bus) == 0) _ = c.g_main_context_iteration(null, 1);
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
