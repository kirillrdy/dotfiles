//! Native Linux power-supply monitoring, shared by the panel and system power policy.
const std = @import("std");
const c = @import("desktop-gtk.zig");
const libc = @import("desktop-libc.zig");
// Test builds account for service state and asynchronous callback allocations.
const a = if (@import("builtin").is_test) std.testing.allocator else std.heap.page_allocator;

pub const State = struct {
    present: bool = false,
    on_battery: bool = false,
    energy: f64 = 0,
    energy_full: f64 = 0,
    energy_rate: f64 = 0,
    percent: f64 = 0,
    state: u32 = 0,
    time_to_empty: i64 = 0,
    time_to_full: i64 = 0,
    charge_threshold: bool = false,

    pub fn warning(self: State) Warning {
        if (!self.visible() or !self.on_battery or (self.state != 2 and self.state != 3 and self.state != 6)) return .none;
        if (self.percent <= 2) return .action;
        if (self.percent <= 5) return .critical;
        if (self.percent <= 20) return .low;
        return .discharging;
    }
    pub fn visible(self: State) bool {
        return self.present and std.math.isFinite(self.percent) and self.percent >= 0 and self.percent <= 100;
    }
    pub fn icon(self: State, buffer: []u8) ![:0]u8 {
        if (!self.visible()) return std.fmt.bufPrintSentinel(buffer, "battery-missing-symbolic", .{}, 0);
        // Full batteries can report slightly less than 100%; Adwaita only
        // provides the charged icon at level 100.
        if (self.state == 4 or (self.state == 1 and self.percent >= 100)) return std.fmt.bufPrintSentinel(buffer, "battery-level-100-charged-symbolic", .{}, 0);
        const level: u32 = @as(u32, @intFromFloat(self.percent)) / 10 * 10;
        const suffix: []const u8 = if (self.state == 1) "-charging" else if (self.state == 5 and self.charge_threshold) "-plugged-in" else "";
        return std.fmt.bufPrintSentinel(buffer, "battery-level-{d}{s}-symbolic", .{ level, suffix }, 0);
    }
    pub fn duration(self: State, buffer: []u8) ![]const u8 {
        const seconds = if (self.state == 1 or self.state == 5) self.time_to_full else if (self.state == 2 or self.state == 6) self.time_to_empty else 0;
        if (seconds <= 0) return "";
        const minutes: u64 = @intCast(@divTrunc(seconds +| 30, 60));
        return std.fmt.bufPrint(buffer, "{d}∶{d:0>2}", .{ @divTrunc(minutes, 60), @mod(minutes, 60) });
    }
    pub fn description(self: State) []const u8 {
        return switch (self.state) {
            1 => "charging",
            2 => "discharging",
            3 => "empty",
            4 => "fully-charged",
            5 => "pending-charge",
            6 => "pending-discharge",
            else => "unknown",
        };
    }
};
test "battery presentation preserves levels, charging states, and exact estimates" {
    var buffer: [100]u8 = undefined;
    const state = State{ .present = true, .percent = 80, .state = 2, .time_to_empty = 9000 };
    try std.testing.expectEqualStrings("battery-level-80-symbolic", try state.icon(&buffer));
    try std.testing.expectEqualStrings("2∶30", try state.duration(&buffer));
    for ([_]u32{ 1, 4, 5 }, [_][]const u8{ "battery-level-80-charging-symbolic", "battery-level-100-charged-symbolic", "battery-level-80-plugged-in-symbolic" }) |kind, icon| {
        try std.testing.expectEqualStrings(icon, try (State{ .present = true, .percent = 85, .state = kind, .charge_threshold = true }).icon(&buffer));
    }
    try std.testing.expectEqualStrings("battery-level-100-charged-symbolic", try (State{ .present = true, .percent = 99.88, .state = 4 }).icon(&buffer));
    try std.testing.expectEqualStrings("battery-level-100-charged-symbolic", try (State{ .present = true, .percent = 100, .state = 1 }).icon(&buffer));
    for ([_]f64{ -1, 101, std.math.nan(f64), std.math.inf(f64) }) |percent| try std.testing.expect(!(State{ .present = true, .percent = percent }).visible());
    try std.testing.expect(!(State{}).visible());
    try std.testing.expectEqualStrings("", try (State{ .state = 4, .time_to_full = 9000 }).duration(&buffer));
}

pub const Warning = enum(u32) { none = 1, discharging = 2, low = 3, critical = 4, action = 5 };
pub const Alerts = struct {
    last: Warning = .none,
    /// Notify once per severity per discharge, with hysteresis when recovering.
    pub fn update(self: *Alerts, value: State) ?Warning {
        if (!value.visible() or !value.on_battery or value.percent > 22) self.last = .none;
        const level = value.warning();
        if (@backingInt(level) < @backingInt(Warning.low) or @backingInt(level) <= @backingInt(self.last)) return null;
        self.last = level;
        return level;
    }
};

pub const Device = struct {
    percent: f64 = std.math.nan(f64),
    state: u32 = 0,
    energy: ?f64 = null,
    full: ?f64 = null,
    rate: ?f64 = null,
    time_empty: i64 = 0,
    time_full: i64 = 0,
    threshold: bool = false,
};
const eq = c.__zig.eq;
fn validName(name: []const u8) bool {
    return name.len > 0 and name.len < 256 and name[0] != '.' and std.mem.indexOfAny(u8, name, "/\x00") == null;
}
fn estimateSeconds(amount: f64, rate: f64) i64 {
    if (amount <= 0 or rate <= 0) return 0;
    const value = amount / rate * 3600;
    if (!std.math.isFinite(value) or value < 0 or value > 365 * 24 * 3600) return 0;
    return @intFromFloat(value);
}

pub const Backend = struct {
    root: [:0]const u8 = "/sys/class/power_supply",

    fn attribute(self: Backend, name: []const u8, key: []const u8, buffer: []u8) ?[]const u8 {
        if (!validName(name)) return null;
        var path: [4096]u8 = undefined;
        const file = std.fmt.bufPrintSentinel(&path, "{s}/{s}/{s}", .{ self.root, name, key }, 0) catch return null;
        const fd = libc.open(file, libc.O_RDONLY | libc.O_CLOEXEC | libc.O_NOFOLLOW);
        if (fd < 0) return null;
        defer _ = libc.close(fd);
        var count: isize = undefined;
        while (true) {
            count = libc.read(fd, buffer.ptr, buffer.len);
            if (count >= 0 or libc.__errno_location().* != libc.EINTR) break;
        }
        if (count < 0 or count == buffer.len) return null;
        return std.mem.trim(u8, buffer[0..@intCast(count)], " \t\r\n");
    }
    fn number(self: Backend, name: []const u8, key: []const u8) ?f64 {
        var buffer: [128]u8 = undefined;
        const value = std.fmt.parseFloat(f64, self.attribute(name, key, &buffer) orelse return null) catch return null;
        if (!std.math.isFinite(value) or @abs(value) > 1e15) return null;
        return value;
    }
    fn nonnegative(self: Backend, name: []const u8, key: []const u8) ?f64 {
        const value = self.number(name, key) orelse return null;
        return if (value >= 0) value else null;
    }
    fn positive(self: Backend, name: []const u8, key: []const u8) ?f64 {
        const value = self.number(name, key) orelse return null;
        return if (value > 0) value else null;
    }
    fn time(self: Backend, name: []const u8, key: []const u8) i64 {
        const value = self.nonnegative(name, key) orelse return 0;
        return if (value <= 365 * 24 * 3600) @intFromFloat(value) else 0;
    }
    pub fn readDevice(self: Backend, name: []const u8) ?Device {
        var buffer: [128]u8 = undefined;
        if (!eq(self.attribute(name, "type", &buffer) orelse "", "Battery")) return null;
        if (eq(self.attribute(name, "scope", &buffer) orelse "", "Device")) return null;
        if (self.attribute(name, "present", &buffer)) |present| {
            if (eq(present, "0")) return null;
            if (!eq(present, "1")) return Device{};
        }
        var result = Device{};
        const status = self.attribute(name, "status", &buffer) orelse "";
        result.state = if (eq(status, "Charging")) 1 else if (eq(status, "Discharging")) 2 else if (eq(status, "Full")) 4 else if (eq(status, "Not charging")) 5 else 0;
        const voltage = self.positive(name, "voltage_min_design") orelse self.positive(name, "voltage_now");
        const voltage_now = self.positive(name, "voltage_now") orelse voltage;
        const current = self.number(name, "current_now") orelse self.number(name, "current_avg");
        const charge = self.nonnegative(name, "charge_now");
        const charge_full = self.positive(name, "charge_full") orelse self.positive(name, "charge_full_design");
        result.energy = self.nonnegative(name, "energy_now");
        result.full = self.positive(name, "energy_full") orelse self.positive(name, "energy_full_design");
        if ((result.energy == null or result.full == null) and charge != null and charge_full != null and voltage != null) {
            result.energy = charge.? * voltage.? / 1e6;
            result.full = charge_full.? * voltage.? / 1e6;
        }
        if (result.energy != null and result.full != null) {
            result.percent = std.math.clamp(result.energy.? / result.full.? * 100, 0, 100);
        } else if (self.number(name, "capacity")) |capacity| {
            if (capacity >= 0 and capacity <= 100) result.percent = capacity;
        } else if (charge != null and charge_full != null) {
            result.percent = std.math.clamp(charge.? / charge_full.? * 100, 0, 100);
        }
        if (self.number(name, "power_now") orelse self.number(name, "power_avg")) |power| result.rate = @abs(power) else if (current) |amps| {
            if (voltage_now) |v| result.rate = @abs(amps) * v / 1e6;
        }
        result.time_empty = self.time(name, "time_to_empty_now");
        result.time_full = self.time(name, "time_to_full_now");
        if (result.energy != null and result.full != null and result.rate != null) {
            if (result.time_empty == 0) result.time_empty = estimateSeconds(result.energy.?, result.rate.?);
            if (result.time_full == 0) result.time_full = estimateSeconds(@max(0, result.full.? - result.energy.?), result.rate.?);
        } else if (charge != null and charge_full != null) {
            if (current) |amps| {
                if (result.time_empty == 0) result.time_empty = estimateSeconds(charge.?, @abs(amps));
                if (result.time_full == 0) result.time_full = estimateSeconds(@max(0, charge_full.? - charge.?), @abs(amps));
            }
        }
        if (self.positive(name, "charge_control_end_threshold")) |threshold| result.threshold = threshold < 100;
        return result;
    }
    pub fn read(self: Backend) State {
        const dir = libc.opendir(self.root) orelse return .{};
        defer _ = libc.closedir(dir);
        var total = Aggregate{};
        var online: ?bool = null;
        while (libc.readdir(dir)) |entry| {
            const name = std.mem.sliceTo(&entry.*.d_name, 0);
            if (!validName(name)) continue;
            var buffer: [128]u8 = undefined;
            const kind = self.attribute(name, "type", &buffer) orelse continue;
            if (eq(kind, "Battery")) {
                if (self.readDevice(name)) |device| total.add(device);
            } else {
                if (eq(self.attribute(name, "scope", &buffer) orelse "", "Device")) continue;
                if (self.number(name, "online")) |value| {
                    if (value == 1) online = true else if (value == 0 and online == null) online = false;
                }
            }
        }
        return total.finish(online);
    }
};

pub const Aggregate = struct {
    count: usize = 0,
    valid: bool = true,
    energy_known: bool = true,
    rate_known: bool = true,
    energy: f64 = 0,
    full: f64 = 0,
    rate: f64 = 0,
    percent: f64 = 0,
    charging: bool = false,
    discharging: bool = false,
    all_full: bool = true,
    threshold: bool = false,
    single: Device = .{},
    pub fn add(self: *Aggregate, value: Device) void {
        self.count += 1;
        self.single = value;
        self.valid = self.valid and std.math.isFinite(value.percent) and value.percent >= 0 and value.percent <= 100;
        self.percent += value.percent;
        self.threshold = self.threshold or value.threshold;
        self.charging = self.charging or value.state == 1;
        self.discharging = self.discharging or value.state == 2;
        self.all_full = self.all_full and value.state == 4;
        if (value.energy != null and value.full != null) {
            self.energy += value.energy.?;
            self.full += value.full.?;
        } else self.energy_known = false;
        if (value.state == 0) self.rate_known = false;
        if (value.state == 1 or value.state == 2) {
            if (value.rate) |rate| self.rate += if (value.state == 1) -rate else rate else self.rate_known = false;
        }
    }
    pub fn finish(self: Aggregate, online: ?bool) State {
        if (self.count == 0) return .{};
        const weighted = self.energy_known and self.full > 0;
        var result = State{
            .present = true,
            .percent = if (!self.valid) std.math.nan(f64) else if (weighted) std.math.clamp(self.energy / self.full * 100, 0, 100) else self.percent / @as(f64, @floatFromInt(self.count)),
            .charge_threshold = self.threshold,
            .energy = if (weighted) self.energy / 1e6 else 0,
            .energy_full = if (weighted) self.full / 1e6 else 0,
            .energy_rate = if (self.rate_known) @abs(self.rate) / 1e6 else 0,
        };
        if (self.charging and self.discharging and self.rate_known and self.rate != 0) {
            result.state = if (self.rate > 0) 2 else 1;
        } else result.state = if (self.discharging) 2 else if (self.charging) 1 else if (self.all_full) 4 else if (online == true) 5 else if (online == false) 6 else 0;
        result.on_battery = online == false or (online == null and (result.state == 2 or result.state == 6));
        if (weighted and self.rate_known and self.rate != 0) {
            if (result.state == 2) result.time_to_empty = estimateSeconds(self.energy, self.rate);
            if (result.state == 1) result.time_to_full = estimateSeconds(@max(0, self.full - self.energy), -self.rate);
        }
        if (self.count == 1) {
            if (result.state == 2) result.time_to_empty = self.single.time_empty;
            if (result.state == 1) result.time_to_full = self.single.time_full;
        }
        return result;
    }
};

pub const Options = struct {
    backend: Backend = .{},
    poll_ms: u32 = 5000,
    events: bool = true,
};

pub fn powerSupplyEvent(payload: []const u8, sender_pid: u32) bool {
    if (sender_pid != 0 or payload.len == 0 or payload[payload.len - 1] != 0) return false;
    var fields = std.mem.splitScalar(u8, payload, 0);
    while (fields.next()) |field| if (eq(field, "SUBSYSTEM=power_supply")) return true;
    return false;
}

pub const Service = struct {
    callback: *const fn (?*anyopaque, State) void,
    data: ?*anyopaque,
    backend: Backend,
    root: [:0]u8,
    cancel: *c.GCancellable,
    timer: c.guint = 0,
    event_source: c.guint = 0,
    debounce: c.guint = 0,
    event_fd: c_int = -1,
    events: bool,
    pending: bool = false,
    again: bool = false,
    stopped: bool = false,
    refs: usize = 1,
    value: State = .{},
    next: State = .{},
    sent: bool = false,

    pub fn create(callback: *const fn (?*anyopaque, State) void, data: ?*anyopaque) !*Service {
        return createWithOptions(.{}, callback, data);
    }
    pub fn createWithOptions(options: Options, callback: *const fn (?*anyopaque, State) void, data: ?*anyopaque) !*Service {
        if (options.poll_ms == 0) return error.InvalidPollInterval;
        const self = try a.create(Service);
        errdefer a.destroy(self);
        const root = try a.dupeSentinel(u8, options.backend.root, 0);
        self.* = .{ .callback = callback, .data = data, .backend = .{ .root = root }, .root = root, .cancel = c.g_cancellable_new().?, .events = options.events };
        if (self.events) self.connectEvents();
        self.timer = c.g_timeout_add(options.poll_ms, &poll, self);
        self.refresh();
        return self;
    }
    pub fn destroy(self: *Service) void {
        self.stop();
        self.unref();
    }
    pub fn stop(self: *Service) void {
        self.stopped = true;
        if (self.timer != 0) _ = c.g_source_remove(self.timer);
        if (self.debounce != 0) _ = c.g_source_remove(self.debounce);
        self.disconnectEvents();
        self.timer = 0;
        self.debounce = 0;
        c.g_cancellable_cancel(self.cancel);
    }
    fn unref(self: *Service) void {
        self.refs -= 1;
        if (self.refs == 0) {
            c.g_object_unref(self.cancel);
            a.free(self.root);
            a.destroy(self);
        }
    }
    pub fn refresh(self: *Service) void {
        if (self.stopped) return;
        if (self.pending) {
            self.again = true;
            return;
        }
        self.pending = true;
        self.refs += 1;
        const task = c.g_task_new(null, self.cancel, &readDone, self);
        c.g_task_set_task_data(task, self, null);
        c.g_task_run_in_thread(task, &readWork);
        c.g_object_unref(task);
    }
    fn readWork(task: ?*c.GTask, _: ?*anyopaque, data: ?*anyopaque, _: [*c]c.GCancellable) callconv(.c) void {
        const self: *Service = @ptrCast(@alignCast(data));
        self.next = self.backend.read();
        c.g_task_return_boolean(task, 1);
    }
    fn readDone(_: [*c]c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Service = @ptrCast(@alignCast(data));
        defer self.unref();
        self.pending = false;
        const ok = c.g_task_propagate_boolean(@ptrCast(result), null) != 0;
        if (self.stopped) return;
        if (ok and (!self.sent or !std.meta.eql(self.value, self.next))) {
            self.value = self.next;
            self.sent = true;
            self.callback(self.data, self.value);
        }
        if (!self.stopped and self.again) {
            self.again = false;
            self.refresh();
        }
    }
    fn poll(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Service = @ptrCast(@alignCast(data));
        if (self.events and self.event_fd < 0) self.connectEvents();
        self.refresh();
        return 1;
    }
    fn connectEvents(self: *Service) void {
        const fd = libc.socket(libc.AF_NETLINK, libc.SOCK_DGRAM | libc.SOCK_NONBLOCK | libc.SOCK_CLOEXEC, libc.NETLINK_KOBJECT_UEVENT);
        if (fd < 0) return;
        var address = libc.struct_sockaddr_nl{ .nl_family = @intCast(libc.AF_NETLINK), .nl_groups = 1 };
        if (libc.bind(fd, @ptrCast(&address), @sizeOf(@TypeOf(address))) != 0) {
            _ = libc.close(fd);
            return;
        }
        self.event_fd = fd;
        self.event_source = c.g_unix_fd_add(fd, c.G_IO_IN | c.G_IO_ERR | c.G_IO_HUP, &eventReady, self);
    }
    fn disconnectEvents(self: *Service) void {
        if (self.event_source != 0) _ = c.g_source_remove(self.event_source);
        self.event_source = 0;
        if (self.event_fd >= 0) _ = libc.close(self.event_fd);
        self.event_fd = -1;
    }
    fn eventReady(_: c_int, condition: c.GIOCondition, data: ?*anyopaque) callconv(.c) c_int {
        const self: *Service = @ptrCast(@alignCast(data));
        if (condition & (c.G_IO_ERR | c.G_IO_HUP) != 0) {
            self.event_source = 0;
            self.disconnectEvents();
            self.refresh();
            return 0;
        }
        var buffer: [8192]u8 = undefined;
        while (true) {
            var sender = libc.struct_sockaddr_nl{};
            var size: libc.socklen_t = @sizeOf(@TypeOf(sender));
            const count = libc.recvfrom(self.event_fd, &buffer, buffer.len, 0, @ptrCast(&sender), &size);
            if (count < 0) {
                if (libc.__errno_location().* == libc.EINTR) continue;
                if (libc.__errno_location().* == 105) self.refresh(); // ENOBUFS: recover a lost event by reading sysfs.
                break;
            }
            if (size >= @sizeOf(@TypeOf(sender)) and count < buffer.len and powerSupplyEvent(buffer[0..@intCast(count)], sender.nl_pid) and self.debounce == 0) self.debounce = c.g_timeout_add(100, &eventRefresh, self);
        }
        return 1;
    }
    fn eventRefresh(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Service = @ptrCast(@alignCast(data));
        self.debounce = 0;
        self.refresh();
        return 0;
    }
};

test "aggregation weights energy, nets charging rates and never mixes charge with energy" {
    var aggregate = Aggregate{};
    aggregate.add(.{ .percent = 50, .state = 2, .energy = 10e6, .full = 20e6, .rate = 5e6 });
    aggregate.add(.{ .percent = 90, .state = 2, .energy = 72e6, .full = 80e6, .rate = 3e6 });
    const state = aggregate.finish(false);
    try std.testing.expectApproxEqAbs(@as(f64, 82), state.percent, 0.00001);
    try std.testing.expectEqual(@as(i64, 36900), state.time_to_empty);
    try std.testing.expect(state.on_battery);
    try std.testing.expect(!aggregate.finish(true).on_battery);
    aggregate = .{};
    aggregate.add(.{ .percent = 50, .state = 1, .energy = 10e6, .full = 20e6, .rate = 3e6 });
    aggregate.add(.{ .percent = 90, .state = 2, .energy = 72e6, .full = 80e6, .rate = 5e6 });
    try std.testing.expectEqual(@as(u32, 2), aggregate.finish(false).state);
    try std.testing.expectEqual(@as(i64, 147600), aggregate.finish(false).time_to_empty);
    aggregate.add(.{ .percent = 20, .state = 2 });
    try std.testing.expectApproxEqAbs(@as(f64, 160.0 / 3.0), aggregate.finish(false).percent, 0.00001);
    try std.testing.expectEqual(@as(i64, 0), aggregate.finish(false).time_to_empty);
    aggregate.add(.{ .state = 2 });
    try std.testing.expect(!aggregate.finish(false).visible());
}
test "warnings honor AC, reject invalid readings and suppress repeated alerts" {
    var alerts = Alerts{};
    var state = State{ .present = true, .percent = 20, .state = 2, .on_battery = true };
    try std.testing.expectEqual(Warning.low, alerts.update(state).?);
    try std.testing.expectEqual(@as(?Warning, null), alerts.update(state));
    state.percent = 5;
    try std.testing.expectEqual(Warning.critical, alerts.update(state).?);
    state.percent = 6;
    try std.testing.expectEqual(@as(?Warning, null), alerts.update(state));
    state.percent = 2;
    try std.testing.expectEqual(Warning.action, alerts.update(state).?);
    state.on_battery = false;
    try std.testing.expectEqual(Warning.none, state.warning());
    try std.testing.expectEqual(@as(?Warning, null), alerts.update(state));
    state.on_battery = true;
    try std.testing.expectEqual(Warning.action, alerts.update(state).?);
    state.state = 1;
    try std.testing.expectEqual(Warning.none, state.warning());
    state.state = 4;
    try std.testing.expectEqual(Warning.none, state.warning());
    state.state = 2;
    state.percent = std.math.nan(f64);
    try std.testing.expectEqual(Warning.none, state.warning());
}
test "only complete kernel power-supply events trigger a scan" {
    try std.testing.expect(powerSupplyEvent("change@/devices/BAT0\x00SUBSYSTEM=power_supply\x00", 0));
    try std.testing.expect(!powerSupplyEvent("SUBSYSTEM=power_supply\x00", 100));
    try std.testing.expect(!powerSupplyEvent("SUBSYSTEM=power_supply", 0));
    try std.testing.expect(!powerSupplyEvent("SUBSYSTEM=backlight\x00", 0));
    try std.testing.expect(!powerSupplyEvent("NOT_SUBSYSTEM=power_supply\x00", 0));
}

/// Session-only warnings; the system monitor never connects to a user bus.
pub fn notifyWarning(level: Warning) void {
    const bus = c.g_bus_get_sync(c.G_BUS_TYPE_SESSION, null, null) orelse return;
    defer c.g_object_unref(bus);
    const hints = c.g_variant_builder_new(@ptrCast(@as([*:0]const u8, "a{sv}")));
    defer c.g_variant_builder_unref(hints);
    c.g_variant_builder_add(hints, "{sv}", @as([*:0]const u8, "urgency"), c.g_variant_new("y", @as(c_int, if (level == .low) 1 else 2)));
    const title: [*:0]const u8 = switch (level) {
        .low => "Battery Low",
        .critical => "Battery Critically Low",
        .action => "Battery Almost Empty",
        else => return,
    };
    c.g_dbus_connection_call(bus, "org.freedesktop.Notifications", "/org/freedesktop/Notifications", "org.freedesktop.Notifications", "Notify", c.g_variant_new("(susss@as@a{sv}i)", @as([*:0]const u8, "desktop-zig"), @as(c_uint, 0), @as([*:0]const u8, "battery-caution-symbolic"), title, @as([*:0]const u8, "Connect a power source."), c.g_variant_new_strv(null, 0), c.g_variant_builder_end(hints), @as(c_int, -1)), null, 0, 3000, null, null, null);
}

test "disposing an in-flight sysfs scan releases ownership without publishing after destruction" {
    const Callback = struct {
        fn changed(data: ?*anyopaque, _: State) void {
            @as(*bool, @ptrCast(@alignCast(data))).* = true;
        }
    };
    var delivered = false;
    const service = try Service.createWithOptions(.{ .backend = .{ .root = "/nonexistent/desktop-battery-test" }, .events = false }, &Callback.changed, &delivered);
    // Retain one observer reference while the worker's cancellation callback drains.
    service.refs += 1;
    service.refresh();
    service.destroy();
    const deadline = c.g_get_monotonic_time() + 5000000;
    while (service.pending and c.g_get_monotonic_time() < deadline) {
        while (c.g_main_context_iteration(null, 0) != 0) {}
        c.g_usleep(1000);
    }
    const pending = service.pending;
    service.unref();
    try std.testing.expect(!pending);
    try std.testing.expect(!delivered);
}
