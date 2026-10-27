//! UPower DisplayDevice properties, shared by quick settings and panel reporting.
const std = @import("std");
const c = @import("gtk");
const a = std.heap.page_allocator;
const name = "org.freedesktop.UPower";
const path = "/org/freedesktop/UPower/devices/DisplayDevice";
const interface = "org.freedesktop.UPower.Device";

pub const State = struct {
    present: bool = false,
    percent: f64 = 0,
    state: u32 = 0,
    time_to_empty: i64 = 0,
    time_to_full: i64 = 0,
    charge_threshold: bool = false,

    pub fn visible(self: State) bool {
        return self.present and std.math.isFinite(self.percent) and self.percent >= 0 and self.percent <= 100;
    }
    pub fn icon(self: State, buffer: []u8) ![:0]u8 {
        if (!self.visible()) return std.fmt.bufPrintSentinel(buffer, "battery-missing-symbolic", .{}, 0);
        const level: u32 = @as(u32, @intFromFloat(self.percent)) / 10 * 10;
        const suffix: []const u8 = if (self.state == 4 or (self.state == 1 and level == 100)) "-charged" else if (self.state == 1) "-charging" else if (self.state == 5 and self.charge_threshold) "-plugged-in" else "";
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
fn typed(value: ?*c.GVariant, signature: []const u8) ?*c.GVariant {
    const v = value orelse return null;
    if (std.mem.eql(u8, std.mem.span(c.g_variant_get_type_string(v)), signature)) return v;
    c.g_variant_unref(v);
    return null;
}
fn boolean(value: ?*c.GVariant) bool {
    const v = typed(value, "b") orelse return false;
    defer c.g_variant_unref(v);
    return c.g_variant_get_boolean(v) != 0;
}
fn number(value: ?*c.GVariant) f64 {
    const v = typed(value, "d") orelse return std.math.nan(f64);
    defer c.g_variant_unref(v);
    return c.g_variant_get_double(v);
}
fn integer(value: ?*c.GVariant) i64 {
    const v = typed(value, "x") orelse return 0;
    defer c.g_variant_unref(v);
    return c.g_variant_get_int64(v);
}
fn stateNumber(value: ?*c.GVariant) u32 {
    const v = typed(value, "u") orelse return 0;
    defer c.g_variant_unref(v);
    return c.g_variant_get_uint32(v);
}
fn properties(source: anytype, comptime get: anytype) State {
    return .{
        .present = boolean(get(source, "IsPresent")),
        .percent = number(get(source, "Percentage")),
        .state = stateNumber(get(source, "State")),
        .time_to_empty = integer(get(source, "TimeToEmpty")),
        .time_to_full = integer(get(source, "TimeToFull")),
        .charge_threshold = boolean(get(source, "ChargeThresholdEnabled")),
    };
}
fn cached(proxy: *c.GDBusProxy, key: [*:0]const u8) ?*c.GVariant {
    return c.g_dbus_proxy_get_cached_property(proxy, key);
}
pub const Service = struct {
    callback: *const fn (?*anyopaque, State) void,
    data: ?*anyopaque,
    proxy: ?*c.GDBusProxy = null,
    cancel: *c.GCancellable,
    timer: c.guint = 0,
    pending: bool = false,
    stopped: bool = false,
    refs: usize = 1,
    value: State = .{},

    pub fn create(callback: *const fn (?*anyopaque, State) void, data: ?*anyopaque) !*Service {
        const self = try a.create(Service);
        self.* = .{ .callback = callback, .data = data, .cancel = c.g_cancellable_new().? };
        self.connect();
        self.timer = c.g_timeout_add_seconds(5, &maintain, self);
        return self;
    }
    pub fn destroy(self: *Service) void {
        self.stopped = true;
        _ = c.g_source_remove(self.timer);
        self.clearProxy();
        c.g_cancellable_cancel(self.cancel);
        self.unref();
    }
    fn unref(self: *Service) void {
        self.refs -= 1;
        if (self.refs == 0) {
            c.g_object_unref(self.cancel);
            a.destroy(self);
        }
    }
    fn clearProxy(self: *Service) void {
        if (self.proxy) |proxy| {
            _ = c.g_signal_handlers_disconnect_matched(proxy, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
            c.g_object_unref(proxy);
        }
        self.proxy = null;
    }
    fn maintain(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Service = @ptrCast(@alignCast(data));
        if (self.proxy) |proxy| if (c.g_dbus_connection_is_closed(c.g_dbus_proxy_get_connection(proxy)) != 0) {
            self.clearProxy();
            self.publish(.{});
        };
        if (self.proxy == null) self.connect();
        return 1;
    }
    fn connect(self: *Service) void {
        if (self.pending) return;
        self.pending = true;
        self.refs += 1;
        c.g_bus_get(c.G_BUS_TYPE_SYSTEM, self.cancel, &busConnected, self);
    }
    fn busConnected(_: [*c]c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Service = @ptrCast(@alignCast(data));
        const bus = c.g_bus_get_finish(result, null);
        if (bus == null or self.stopped or c.g_dbus_connection_is_closed(bus) != 0) {
            if (bus) |value| c.g_object_unref(value);
            self.pending = false;
            self.unref();
            return;
        }
        defer c.g_object_unref(bus);
        c.g_dbus_connection_set_exit_on_close(bus, 0);
        // All consumers must release a closed shared bus before GIO can replace it.
        c.g_dbus_proxy_new(bus, c.G_DBUS_PROXY_FLAGS_DO_NOT_AUTO_START | c.G_DBUS_PROXY_FLAGS_GET_INVALIDATED_PROPERTIES, null, name, path, interface, self.cancel, &connected, self);
    }
    fn connected(_: [*c]c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self: *Service = @ptrCast(@alignCast(data));
        defer self.unref();
        self.pending = false;
        const result_proxy = c.g_dbus_proxy_new_finish(result, null);
        if (result_proxy == null) return;
        const proxy: *c.GDBusProxy = @ptrCast(result_proxy);
        if (self.stopped) {
            c.g_object_unref(proxy);
            return;
        }
        self.proxy = proxy;
        c.g_dbus_connection_set_exit_on_close(c.g_dbus_proxy_get_connection(proxy), 0);
        _ = c.g_signal_connect_data(proxy, "g-properties-changed", @ptrCast(&changed), self, null, 0);
        _ = c.g_signal_connect_data(proxy, "notify::g-name-owner", @ptrCast(&ownerChanged), self, null, 0);
        self.refresh();
    }
    fn changed(_: ?*c.GDBusProxy, _: ?*c.GVariant, _: [*c]const [*c]const u8, data: ?*anyopaque) callconv(.c) void {
        const self: *Service = @ptrCast(@alignCast(data));
        self.refresh();
    }
    fn ownerChanged(_: ?*c.GObject, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
        const self: *Service = @ptrCast(@alignCast(data));
        self.refresh();
    }
    fn refresh(self: *Service) void {
        const proxy = self.proxy orelse return;
        const owner = c.g_dbus_proxy_get_name_owner(proxy);
        defer c.g_free(owner);
        self.publish(if (owner != null) properties(proxy, cached) else .{});
    }
    fn publish(self: *Service, value: State) void {
        self.value = value;
        if (!self.stopped) self.callback(self.data, value);
    }
};

test "battery presentation preserves levels, charging states, and exact estimates" {
    var buffer: [100]u8 = undefined;
    const state = State{ .present = true, .percent = 80, .state = 2, .time_to_empty = 9000 };
    try std.testing.expectEqualStrings("battery-level-80-symbolic", try state.icon(&buffer));
    try std.testing.expectEqualStrings("2∶30", try state.duration(&buffer));
    for ([_]u32{ 1, 4, 5 }, [_][]const u8{ "battery-level-80-charging-symbolic", "battery-level-80-charged-symbolic", "battery-level-80-plugged-in-symbolic" }) |kind, icon| {
        try std.testing.expectEqualStrings(icon, try (State{ .present = true, .percent = 85, .state = kind, .charge_threshold = true }).icon(&buffer));
    }
    for ([_]f64{ -1, 101, std.math.nan(f64), std.math.inf(f64) }) |percent| try std.testing.expect(!(State{ .present = true, .percent = percent }).visible());
    try std.testing.expect(!(State{}).visible());
    try std.testing.expectEqualStrings("", try (State{ .state = 4, .time_to_full = 9000 }).duration(&buffer));
}
