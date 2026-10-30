//! Shared, event-driven NetworkManager state and asynchronous actions on the system bus.
const std = @import("std");
const c = @import("gtk");
const g = @import("network-api");
pub const api = g;
const a = if (@import("builtin").is_test) std.testing.allocator else std.heap.page_allocator;
const name = "org.freedesktop.NetworkManager";
const root = "/org/freedesktop/NetworkManager";
const device_iface = name ++ ".Device";
const wireless_iface = device_iface ++ ".Wireless";
const ap_iface = name ++ ".AccessPoint";
const profile_iface = name ++ ".Settings.Connection";
const active_iface = name ++ ".Connection.Active";
const cast = c.__zig.cast;
fn z(value: []const u8) [:0]u8 {
    return a.dupeSentinel(u8, value, 0) catch @panic("out of memory");
}
const eq = c.__zig.eq;
fn string(value: ?*c.GVariant) []const u8 {
    return if (value) |v| std.mem.span(c.g_variant_get_string(v, null)) else "";
}
fn prop(proxy: *c.GDBusProxy, key: [*:0]const u8) ?*c.GVariant {
    return c.g_dbus_proxy_get_cached_property(proxy, key);
}
fn text(proxy: *c.GDBusProxy, key: [*:0]const u8) [:0]u8 {
    const v = prop(proxy, key);
    defer if (v) |p| c.g_variant_unref(p);
    return z(string(v));
}
fn number(proxy: *c.GDBusProxy, key: [*:0]const u8) u32 {
    const v = prop(proxy, key) orelse return 0;
    defer c.g_variant_unref(v);
    return if (eq(std.mem.span(c.g_variant_get_type_string(v)), "y")) c.g_variant_get_byte(v) else c.g_variant_get_uint32(v);
}
fn boolean(proxy: *c.GDBusProxy, key: [*:0]const u8) bool {
    const v = prop(proxy, key) orelse return false;
    defer c.g_variant_unref(v);
    return c.g_variant_get_boolean(v) != 0;
}
fn bytes(value: ?*c.GVariant) []const u8 {
    const v = value orelse return "";
    var len: usize = 0;
    const data = c.g_variant_get_fixed_array(v, &len, 1) orelse return "";
    return @as([*]const u8, @ptrCast(data))[0..len];
}
fn section(value: *c.GVariant, key: [*:0]const u8) ?*c.GVariant {
    return c.g_variant_lookup_value(value, key, null);
}
fn setting(value: *c.GVariant, group_key: [*:0]const u8, key: [*:0]const u8) ?*c.GVariant {
    const s = section(value, group_key) orelse return null;
    defer c.g_variant_unref(s);
    return section(s, key);
}
fn settingText(value: *c.GVariant, group_key: [*:0]const u8, key: [*:0]const u8) [:0]u8 {
    const v = setting(value, group_key, key);
    defer if (v) |p| c.g_variant_unref(p);
    return z(string(v));
}
pub fn ssidTitle(allocator: std.mem.Allocator, ssid: []const u8) ![:0]u8 {
    if (std.unicode.utf8ValidateSlice(ssid) and std.mem.indexOfScalar(u8, ssid, 0) == null) return allocator.dupeSentinel(u8, ssid, 0);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    for (ssid) |byte| {
        if (byte >= 32 and byte < 127 and byte != '\\') try out.append(allocator, byte) else {
            const hex = "0123456789abcdef";
            try out.appendSlice(allocator, &.{ '\\', 'x', hex[byte >> 4], hex[byte & 15] });
        }
    }
    return allocator.dupeSentinel(u8, out.items, 0);
}
pub const Security = enum { open, wep, personal, sae, enterprise, owe };
pub fn security(flags: u32, wpa: u32, rsn: u32) Security {
    const auth = wpa | rsn;
    if (auth & 0x100 != 0) return .personal;
    if (auth & 0x400 != 0) return .sae;
    if (auth & 0x200 != 0 or auth & 0x2000 != 0) return .enterprise;
    if (auth & 0x1800 != 0) return .owe;
    return if (flags & 1 != 0) .wep else .open;
}
pub const AccessPoint = struct {
    path: [:0]u8,
    device: [:0]u8,
    ssid: []u8,
    title: [:0]u8,
    strength: u8,
    security: Security,
    connected: bool,
    pub fn passwordRequired(self: AccessPoint) bool {
        return self.security != .open and self.security != .owe;
    }
};
pub const Device = struct { path: [:0]u8, interface: [:0]u8, kind: u32, state: u32, managed: bool, active: [:0]u8 };
pub const Profile = struct { path: [:0]u8, uuid: [:0]u8, title: [:0]u8, kind: [:0]u8, ssid: []u8, active: bool, base: *c.GVariant, version: u64 = 0 };
const Active = struct { path: [:0]u8, profile: [:0]u8, title: [:0]u8, kind: [:0]u8, state: u32 };
pub const Indicator = struct { icon: [:0]const u8, title: []const u8, strength: ?u8 = null };
pub const State = struct {
    available: bool = false,
    wifi_enabled: bool = false,
    hardware_enabled: bool = false,
    primary: [:0]u8 = undefined,
    devices: std.ArrayList(Device) = .empty,
    access_points: std.ArrayList(AccessPoint) = .empty,
    profiles: std.ArrayList(Profile) = .empty,
    active: std.ArrayList(Active) = .empty,
    fn clear(self: *State) void {
        if (self.available) a.free(self.primary);
        for (self.devices.items) |d| {
            a.free(d.path);
            a.free(d.interface);
            a.free(d.active);
        }
        for (self.access_points.items) |p| {
            a.free(p.path);
            a.free(p.device);
            a.free(p.ssid);
            a.free(p.title);
        }
        for (self.profiles.items) |p| {
            a.free(p.path);
            a.free(p.uuid);
            a.free(p.title);
            a.free(p.kind);
            a.free(p.ssid);
            c.g_variant_unref(p.base);
        }
        for (self.active.items) |v| {
            a.free(v.path);
            a.free(v.profile);
            a.free(v.title);
            a.free(v.kind);
        }
        self.devices.clearRetainingCapacity();
        self.access_points.clearRetainingCapacity();
        self.profiles.clearRetainingCapacity();
        self.active.clearRetainingCapacity();
        self.available = false;
    }
    fn deinit(self: *State) void {
        self.clear();
        self.devices.deinit(a);
        self.access_points.deinit(a);
        self.profiles.deinit(a);
        self.active.deinit(a);
    }
    pub fn ap(self: *const State, path: []const u8) ?AccessPoint {
        for (self.access_points.items) |p| if (eq(p.path, path)) return p;
        return null;
    }
    pub fn profile(self: *const State, path: []const u8) ?Profile {
        for (self.profiles.items) |p| if (eq(p.path, path)) return p;
        return null;
    }
    pub fn connectionName(self: *const State, active: []const u8) []const u8 {
        for (self.active.items) |v| if (eq(v.path, active)) return v.title;
        return "";
    }
    pub fn indicator(self: *const State) Indicator {
        if (!self.available) return .{ .icon = "network-offline-symbolic", .title = "NetworkManager unavailable" };
        for (self.active.items) |v| if (eq(v.path, self.primary) and eq(v.kind, "802-3-ethernet")) return .{ .icon = "network-wired-symbolic", .title = v.title };
        for (self.access_points.items) |p| if (p.connected) return .{ .icon = wifiIcon(p.strength), .title = p.title, .strength = p.strength };
        for (self.devices.items) |d| if (d.kind == 1 and d.state == 100) return .{ .icon = "network-wired-symbolic", .title = self.connectionName(d.active) };
        return .{ .icon = "network-wireless-offline-symbolic", .title = if (!self.hardware_enabled) "Wi-Fi blocked by hardware switch" else if (!self.wifi_enabled) "Wi-Fi disabled" else "Network disconnected" };
    }
};
pub fn wifiIcon(strength: u8) [:0]const u8 {
    return if (strength >= 80) "network-wireless-signal-excellent-symbolic" else if (strength >= 55) "network-wireless-signal-good-symbolic" else if (strength >= 30) "network-wireless-signal-ok-symbolic" else "network-wireless-signal-weak-symbolic";
}
pub fn deviceState(state: u32) []const u8 {
    return switch (state) {
        10 => "unmanaged",
        20 => "unavailable",
        30 => "disconnected",
        40...90 => "connecting",
        100 => "connected",
        110 => "disconnecting",
        120 => "failed",
        else => "unknown",
    };
}
const Record = struct { path: [:0]u8, settings: ?*c.GVariant = null, dirty: bool = true, loading: bool = false, seen: bool = false, version: u64 = 0 };
const Fetch = struct { service: *Service, path: [:0]u8, epoch: u64, version: u64 };
var shared: ?*Service = null;
pub const Service = struct {
    manager: ?*g.GDBusObjectManager = null,
    cancel: *c.GCancellable,
    clients: std.ArrayList(*Client) = .empty,
    records: std.ArrayList(*Record) = .empty,
    waiting: std.ArrayList(*Call) = .empty,
    state: State = .{},
    refs: usize = 0,
    idle: c.guint = 0,
    timer: c.guint = 0,
    connecting: bool = false,
    stopped: bool = false,
    epoch: u64 = 0,
    fn ref(self: *Service) void {
        self.refs += 1;
    }
    fn unref(self: *Service) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        self.state.deinit();
        self.clearRecords();
        self.records.deinit(a);
        self.waiting.deinit(a);
        self.clients.deinit(a);
        c.g_object_unref(self.cancel);
        a.destroy(self);
    }
    fn clearRecords(self: *Service) void {
        for (self.records.items) |r| {
            if (r.settings) |s| c.g_variant_unref(s);
            a.free(r.path);
            a.destroy(r);
        }
        self.records.clearRetainingCapacity();
    }
    fn start(self: *Service) void {
        self.connectBus();
        self.timer = c.g_timeout_add_seconds(5, &maintain, self);
    }
    fn connectBus(self: *Service) void {
        if (self.stopped or self.connecting) return;
        self.connecting = true;
        self.ref();
        g.g_dbus_object_manager_client_new_for_bus(c.G_BUS_TYPE_SYSTEM, 0, name, "/org/freedesktop", null, null, null, self.cancel, &connected, self);
    }
    fn connected(_: [*c]c.GObject, result: ?*c.GAsyncResult, ptr: c.gpointer) callconv(.c) void {
        const self = cast(Service, ptr);
        defer self.unref();
        self.connecting = false;
        const manager = g.g_dbus_object_manager_client_new_for_bus_finish(result, null);
        if (self.stopped) {
            if (manager) |m| c.g_object_unref(m);
            return;
        }
        self.manager = manager;
        if (manager) |m| {
            g.g_dbus_connection_set_exit_on_close(g.g_dbus_object_manager_client_get_connection(@ptrCast(m)), 0);
            _ = c.g_signal_connect_data(m, "object-added", @ptrCast(&objectsChanged), self, null, 0);
            _ = c.g_signal_connect_data(m, "object-removed", @ptrCast(&objectsChanged), self, null, 0);
            _ = c.g_signal_connect_data(m, "interface-added", @ptrCast(&interfacesChanged), self, null, 0);
            _ = c.g_signal_connect_data(m, "interface-removed", @ptrCast(&interfacesChanged), self, null, 0);
            _ = c.g_signal_connect_data(m, "interface-proxy-properties-changed", @ptrCast(&propertiesChanged), self, null, 0);
            _ = c.g_signal_connect_data(m, "interface-proxy-signal", @ptrCast(&proxySignal), self, null, 0);
            _ = c.g_signal_connect_data(m, "notify::name-owner", @ptrCast(&ownerChanged), self, null, 0);
        }
        self.schedule();
    }
    fn dropManager(self: *Service) void {
        if (self.manager) |m| {
            _ = c.g_signal_handlers_disconnect_matched(m, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
            c.g_object_unref(m);
        }
        self.manager = null;
        self.epoch += 1;
        self.clearRecords();
    }
    fn stop(self: *Service) void {
        self.stopped = true;
        if (shared == self) shared = null;
        if (self.idle != 0) _ = c.g_source_remove(self.idle);
        if (self.timer != 0) _ = c.g_source_remove(self.timer);
        self.idle = 0;
        self.timer = 0;
        c.g_cancellable_cancel(self.cancel);
        self.dropManager();
    }
    fn maintain(ptr: c.gpointer) callconv(.c) c_int {
        const self = cast(Service, ptr);
        if (self.manager) |m| if (c.g_dbus_connection_is_closed(g.g_dbus_object_manager_client_get_connection(@ptrCast(m))) != 0) {
            self.dropManager();
            self.schedule();
        };
        if (self.manager == null) self.connectBus();
        return 1;
    }
    fn objectsChanged(_: ?*anyopaque, _: ?*anyopaque, ptr: c.gpointer) callconv(.c) void {
        cast(Service, ptr).schedule();
    }
    fn interfacesChanged(_: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque, ptr: c.gpointer) callconv(.c) void {
        cast(Service, ptr).schedule();
    }
    fn propertiesChanged(_: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque, _: ?*c.GVariant, _: ?*anyopaque, ptr: c.gpointer) callconv(.c) void {
        cast(Service, ptr).schedule();
    }
    fn ownerChanged(_: ?*anyopaque, _: ?*anyopaque, ptr: c.gpointer) callconv(.c) void {
        const self = cast(Service, ptr);
        self.epoch += 1;
        self.clearRecords();
        self.schedule();
    }
    fn proxySignal(_: ?*anyopaque, object: *g.GDBusObject, _: ?*anyopaque, _: ?*anyopaque, signal_name: [*:0]const u8, _: ?*c.GVariant, ptr: c.gpointer) callconv(.c) void {
        const self = cast(Service, ptr);
        if (eq(std.mem.span(signal_name), "Updated")) if (self.record(std.mem.span(g.g_dbus_object_get_object_path(object)))) |r| {
            r.dirty = true;
        };
        self.schedule();
    }
    fn schedule(self: *Service) void {
        if (!self.stopped and self.idle == 0) self.idle = c.g_timeout_add(0, &updated, self);
    }
    fn updated(ptr: c.gpointer) callconv(.c) c_int {
        const self = cast(Service, ptr);
        self.idle = 0;
        self.ref();
        defer self.unref();
        self.rebuild();
        var waiting_index: usize = 0;
        while (waiting_index < self.waiting.items.len) {
            const call = self.waiting.items[waiting_index];
            call.checkActivation();
            if (waiting_index < self.waiting.items.len and self.waiting.items[waiting_index] == call) waiting_index += 1;
        }
        var i: usize = 0;
        while (!self.stopped and i < self.clients.items.len) {
            const client = self.clients.items[i];
            client.refs += 1;
            client.callback(client.data, client);
            client.unref();
            if (i < self.clients.items.len and self.clients.items[i] == client) i += 1;
        }
        return 0;
    }
    fn interface(self: *Service, path: [*:0]const u8, iface: [*:0]const u8) ?*c.GDBusProxy {
        const object = g.g_dbus_object_manager_get_object(self.manager orelse return null, path) orelse return null;
        defer c.g_object_unref(object);
        return @ptrCast(g.g_dbus_object_get_interface(object, iface));
    }
    fn record(self: *Service, path: []const u8) ?*Record {
        for (self.records.items) |r| if (eq(r.path, path)) return r;
        return null;
    }
    fn fetch(self: *Service, r: *Record, proxy: *c.GDBusProxy) void {
        if (r.loading or !r.dirty) return;
        r.dirty = false;
        r.loading = true;
        const fetch_data = a.create(Fetch) catch @panic("out of memory");
        const version = prop(proxy, "VersionId");
        defer if (version) |v| c.g_variant_unref(v);
        fetch_data.* = .{ .service = self, .path = z(r.path), .epoch = self.epoch, .version = if (version) |v| c.g_variant_get_uint64(v) else 0 };
        self.ref();
        g.g_dbus_proxy_call(proxy, "GetSettings", null, c.G_DBUS_CALL_FLAGS_NONE, 10000, self.cancel, &fetched, fetch_data);
    }
    fn fetched(source: [*c]c.GObject, result: ?*c.GAsyncResult, ptr: c.gpointer) callconv(.c) void {
        const task = cast(Fetch, ptr);
        const self = task.service;
        defer {
            a.free(task.path);
            a.destroy(task);
            self.unref();
        }
        const reply = g.g_dbus_proxy_call_finish(@ptrCast(source), result, null);
        defer if (reply) |v| c.g_variant_unref(v);
        if (self.stopped or task.epoch != self.epoch) return;
        const r = self.record(task.path) orelse return;
        r.loading = false;
        if (reply) |v| {
            if (r.settings) |old| c.g_variant_unref(old);
            r.settings = c.g_variant_get_child_value(v, 0);
            r.version = task.version;
        }
        self.schedule();
    }
    fn rebuild(self: *Service) void {
        self.state.clear();
        const m = self.manager orelse return;
        const owner = g.g_dbus_object_manager_client_get_name_owner(@ptrCast(m));
        if (owner == null) return;
        c.g_free(owner);
        const main = self.interface(root, name) orelse return;
        defer c.g_object_unref(main);
        self.state.available = true;
        self.state.primary = text(main, "PrimaryConnection");
        self.state.wifi_enabled = boolean(main, "WirelessEnabled");
        self.state.hardware_enabled = boolean(main, "WirelessHardwareEnabled");
        for (self.records.items) |r| r.seen = false;
        const objects = g.g_dbus_object_manager_get_objects(m);
        defer {
            var node = objects;
            while (node != null) : (node = node.*.next) c.g_object_unref(node.*.data);
            c.g_list_free(objects);
        }
        var node = objects;
        while (node != null) : (node = node.*.next) {
            const object = cast(g.GDBusObject, node.*.data);
            const path = g.g_dbus_object_get_object_path(object);
            if (g.g_dbus_object_get_interface(object, device_iface)) |iface| {
                defer c.g_object_unref(iface);
                const proxy: *c.GDBusProxy = @ptrCast(iface);
                const d = Device{ .path = z(std.mem.span(path)), .interface = text(proxy, "Interface"), .kind = number(proxy, "DeviceType"), .state = number(proxy, "State"), .managed = boolean(proxy, "Managed"), .active = text(proxy, "ActiveConnection") };
                self.state.devices.append(a, d) catch @panic("out of memory");
                if (d.kind == 2) self.readAccessPoints(d);
            }
            if (g.g_dbus_object_get_interface(object, active_iface)) |iface| {
                defer c.g_object_unref(iface);
                const proxy: *c.GDBusProxy = @ptrCast(iface);
                self.state.active.append(a, .{ .path = z(std.mem.span(path)), .profile = text(proxy, "Connection"), .title = text(proxy, "Id"), .kind = text(proxy, "Type"), .state = number(proxy, "State") }) catch @panic("out of memory");
            }
            if (g.g_dbus_object_get_interface(object, profile_iface)) |iface| {
                defer c.g_object_unref(iface);
                const r = self.record(std.mem.span(path)) orelse blk: {
                    const item = a.create(Record) catch @panic("out of memory");
                    item.* = .{ .path = z(std.mem.span(path)) };
                    self.records.append(a, item) catch @panic("out of memory");
                    break :blk item;
                };
                r.seen = true;
                self.fetch(r, @ptrCast(iface));
            }
        }
        var index: usize = 0;
        while (index < self.records.items.len) {
            const r = self.records.items[index];
            if (!r.seen) {
                if (r.settings) |v| c.g_variant_unref(v);
                a.free(r.path);
                a.destroy(r);
                _ = self.records.swapRemove(index);
                continue;
            }
            if (r.settings) |base| {
                const ssid = setting(base, "802-11-wireless", "ssid");
                defer if (ssid) |v| c.g_variant_unref(v);
                var active = false;
                for (self.state.active.items) |v| {
                    if (eq(v.profile, r.path)) active = true;
                }
                self.state.profiles.append(a, .{ .path = z(r.path), .uuid = settingText(base, "connection", "uuid"), .title = settingText(base, "connection", "id"), .kind = settingText(base, "connection", "type"), .ssid = a.dupe(u8, bytes(ssid)) catch @panic("out of memory"), .active = active, .base = g.g_variant_ref(base).?, .version = r.version }) catch @panic("out of memory");
            }
            index += 1;
        }
        std.mem.sort(AccessPoint, self.state.access_points.items, {}, struct {
            fn less(_: void, x: AccessPoint, y: AccessPoint) bool {
                if (x.connected != y.connected) return x.connected;
                if (x.strength != y.strength) return x.strength > y.strength;
                return std.mem.order(u8, x.ssid, y.ssid) == .lt;
            }
        }.less);
    }
    fn readAccessPoints(self: *Service, device: Device) void {
        const wireless = self.interface(device.path, wireless_iface) orelse return;
        defer c.g_object_unref(wireless);
        const current = text(wireless, "ActiveAccessPoint");
        defer a.free(current);
        const paths = prop(wireless, "AccessPoints") orelse return;
        defer c.g_variant_unref(paths);
        for (0..c.g_variant_n_children(paths)) |i| {
            const child = c.g_variant_get_child_value(paths, i).?;
            defer c.g_variant_unref(child);
            const path = c.g_variant_get_string(child, null);
            const proxy = self.interface(path, ap_iface) orelse continue;
            defer c.g_object_unref(proxy);
            const ssid = prop(proxy, "Ssid");
            defer if (ssid) |v| c.g_variant_unref(v);
            const raw = a.dupe(u8, bytes(ssid)) catch @panic("out of memory");
            self.state.access_points.append(a, .{ .path = z(std.mem.span(path)), .device = z(device.path), .ssid = raw, .title = ssidTitle(a, raw) catch @panic("out of memory"), .strength = @intCast(@min(100, number(proxy, "Strength"))), .security = security(number(proxy, "Flags"), number(proxy, "WpaFlags"), number(proxy, "RsnFlags")), .connected = device.state == 100 and eq(current, std.mem.span(path)) }) catch @panic("out of memory");
        }
    }
};
pub const Connect = struct { ssid: []const u8, password: []const u8 = "", hidden: bool = false, access_point: ?[]const u8 = null };
pub const Save = struct { path: ?[]const u8, settings: *c.GVariant, version: u64 = 0 };
pub const Action = union(enum) { save: Save, wifi: bool, scan, connect: Connect, activate: []const u8, deactivate: []const u8, forget: []const u8, disconnect: []const u8 };
pub const Result = union(enum) { success, failure: [:0]const u8 };
pub const Completion = *const fn (?*anyopaque, Result) void;
pub const Client = struct {
    service: *Service,
    callback: *const fn (?*anyopaque, *Client) void,
    data: ?*anyopaque,
    cancel: *c.GCancellable,
    refs: usize = 1,
    dead: bool = false,
    pub fn create(callback: *const fn (?*anyopaque, *Client) void, data: ?*anyopaque) !*Client {
        const self = try a.create(Client);
        errdefer a.destroy(self);
        const service = shared orelse blk: {
            const value = try a.create(Service);
            value.* = .{ .cancel = c.g_cancellable_new().? };
            break :blk value;
        };
        service.ref();
        errdefer service.unref();
        self.* = .{ .service = service, .callback = callback, .data = data, .cancel = c.g_cancellable_new().? };
        errdefer c.g_object_unref(self.cancel);
        try service.clients.append(a, self);
        if (shared == null) {
            shared = service;
            service.start();
        }
        service.schedule();
        return self;
    }
    pub fn state(self: *Client) *const State {
        return &self.service.state;
    }
    pub fn refresh(self: *Client) void {
        for (self.service.records.items) |r| r.dirty = true;
        self.service.schedule();
    }
    pub fn destroy(self: *Client) void {
        self.dead = true;
        c.g_cancellable_cancel(self.cancel);
        for (self.service.clients.items, 0..) |value, i| if (value == self) {
            _ = self.service.clients.orderedRemove(i);
            break;
        };
        if (self.service.clients.items.len == 0) self.service.stop();
        self.unref();
    }
    fn unref(self: *Client) void {
        self.refs -= 1;
        if (self.refs == 0) {
            const service = self.service;
            c.g_object_unref(self.cancel);
            a.destroy(self);
            service.unref();
        }
    }
    pub fn perform(self: *Client, action: Action, cancel: *c.GCancellable, callback: Completion, data: ?*anyopaque) void {
        if (self.dead or !self.state().available) {
            callback(data, .{ .failure = "NetworkManager unavailable" });
            return;
        }
        if (c.g_cancellable_is_cancelled(cancel) != 0) {
            callback(data, .{ .failure = "Cancelled" });
            return;
        }
        const call = a.create(Call) catch @panic("out of memory");
        self.refs += 1;
        call.* = .{ .client = self, .callback = callback, .data = data, .cancel = c.g_cancellable_new().?, .parent = cast(c.GCancellable, c.g_object_ref(cancel)) };
        call.parent_signal = c.g_signal_connect_data(cancel, "cancelled", @ptrCast(&Call.cancelled), call, null, 0);
        call.client_signal = c.g_signal_connect_data(self.cancel, "cancelled", @ptrCast(&Call.cancelled), call, null, 0);
        call.begin(action) catch |err| {
            call.finish(.{ .failure = @errorName(err) });
            return;
        };
        if (call.pending == 0) call.finish(.success);
    }
};
fn builder(kind: [*:0]const u8) *g.GVariantBuilder {
    return g.g_variant_builder_new(@ptrCast(kind));
}
fn add(b: *g.GVariantBuilder, key: [*:0]const u8, value: ?*c.GVariant) void {
    g.g_variant_builder_add(b, "{sv}", key, value);
}
fn group(b: *g.GVariantBuilder, key: [*:0]const u8, inner: *g.GVariantBuilder) void {
    g.g_variant_builder_add(b, "{s@a{sv}}", key, g.g_variant_builder_end(inner));
    g.g_variant_builder_unref(inner);
}
pub const secret_groups = [_][:0]const u8{ "802-11-wireless-security", "802-1x", "vpn", "gsm", "cdma", "pppoe", "wireguard", "macsec" };
pub fn secretProperty(key: []const u8) bool {
    return std.mem.indexOf(u8, key, "password") != null or std.mem.indexOf(u8, key, "private-key") != null or eq(key, "psk") or std.mem.startsWith(u8, key, "wep-key") or eq(key, "secrets") or eq(key, "pin") or eq(key, "peers") or eq(key, "mka-cak");
}
fn hasSecrets(settings: *c.GVariant) bool {
    for (secret_groups) |group_key| {
        const dict = section(settings, group_key) orelse continue;
        defer c.g_variant_unref(dict);
        for (0..c.g_variant_n_children(dict)) |i| {
            const pair = c.g_variant_get_child_value(dict, i).?;
            defer c.g_variant_unref(pair);
            const key = c.g_variant_get_child_value(pair, 0).?;
            defer c.g_variant_unref(key);
            const key_text = string(key);
            if (secretProperty(key_text) and !std.mem.endsWith(u8, key_text, "-flags")) return true;
        }
    }
    return false;
}
fn overlayDictionary(base: *c.GVariant, patch: *c.GVariant) *c.GVariant {
    const out = builder(c.g_variant_get_type_string(patch));
    defer g.g_variant_builder_unref(out);
    for ([_]*c.GVariant{ base, patch }, 0..) |source, pass| for (0..c.g_variant_n_children(source)) |i| {
        const pair = c.g_variant_get_child_value(source, i).?;
        defer c.g_variant_unref(pair);
        if (pass == 0) {
            const key = c.g_variant_get_child_value(pair, 0).?;
            defer c.g_variant_unref(key);
            if (section(patch, c.g_variant_get_string(key, null))) |replacement| {
                c.g_variant_unref(replacement);
                continue;
            }
        }
        g.g_variant_builder_add_value(out, pair);
    };
    return g.g_variant_ref_sink(g.g_variant_builder_end(out)).?;
}
fn mergePeers(base: *c.GVariant, patch: *c.GVariant) *c.GVariant {
    const out = builder("aa{sv}");
    defer g.g_variant_builder_unref(out);
    for (0..c.g_variant_n_children(patch)) |i| {
        const peer = c.g_variant_get_child_value(patch, i).?;
        defer c.g_variant_unref(peer);
        var combined = g.g_variant_ref(peer).?;
        defer c.g_variant_unref(combined);
        const key = section(peer, "public-key");
        defer if (key) |v| c.g_variant_unref(v);
        if (key) |public_key| {
            for (0..c.g_variant_n_children(base)) |j| {
                const old = c.g_variant_get_child_value(base, j).?;
                defer c.g_variant_unref(old);
                const old_key = section(old, "public-key") orelse continue;
                defer c.g_variant_unref(old_key);
                if (eq(std.mem.span(c.g_variant_get_type_string(old_key)), "s") and eq(std.mem.span(c.g_variant_get_type_string(public_key)), "s") and eq(string(old_key), string(public_key))) {
                    c.g_variant_unref(combined);
                    combined = overlayDictionary(old, peer);
                    break;
                }
            }
        }
        g.g_variant_builder_add_value(out, combined);
    }
    return g.g_variant_ref_sink(g.g_variant_builder_end(out)).?;
}
/// Overlay complete setting groups without losing unedited or unknown keys.
pub fn mergeSettings(base: *c.GVariant, patch: *c.GVariant) *c.GVariant {
    const out = builder("a{sa{sv}}");
    defer g.g_variant_builder_unref(out);
    for ([_]*c.GVariant{ base, patch }, 0..) |source, pass| {
        for (0..c.g_variant_n_children(source)) |i| {
            const pair = c.g_variant_get_child_value(source, i).?;
            defer c.g_variant_unref(pair);
            const key = c.g_variant_get_child_value(pair, 0).?;
            defer c.g_variant_unref(key);
            const key_text = c.g_variant_get_string(key, null);
            const old = section(base, key_text);
            defer if (old) |v| c.g_variant_unref(v);
            const fresh = section(patch, key_text);
            defer if (fresh) |v| c.g_variant_unref(v);
            if (pass == 1 and old != null) continue;
            const inner = builder("a{sv}");
            if (old) |dict| for (0..c.g_variant_n_children(dict)) |j| {
                const property = c.g_variant_get_child_value(dict, j).?;
                defer c.g_variant_unref(property);
                const property_key = c.g_variant_get_child_value(property, 0).?;
                defer c.g_variant_unref(property_key);
                const replacement = if (fresh) |f| section(f, c.g_variant_get_string(property_key, null)) else null;
                if (replacement) |v| {
                    c.g_variant_unref(v);
                    continue;
                }
                g.g_variant_builder_add(inner, "@{sv}", property);
            };
            if (fresh) |dict| for (0..c.g_variant_n_children(dict)) |j| {
                const property = c.g_variant_get_child_value(dict, j).?;
                defer c.g_variant_unref(property);
                const property_key = c.g_variant_get_child_value(property, 0).?;
                defer c.g_variant_unref(property_key);
                const key_name = c.g_variant_get_string(property_key, null);
                const previous = if (old) |v| section(v, key_name) else null;
                defer if (previous) |v| c.g_variant_unref(v);
                const next = section(dict, key_name).?;
                defer c.g_variant_unref(next);
                if (previous) |v| {
                    const kind = std.mem.span(c.g_variant_get_type_string(next));
                    if (eq(kind, std.mem.span(c.g_variant_get_type_string(v)))) {
                        if (eq(std.mem.span(key_name), "secrets") and eq(kind, "a{ss}")) {
                            const merged = overlayDictionary(v, next);
                            defer c.g_variant_unref(merged);
                            add(inner, key_name, merged);
                            continue;
                        }
                        if (eq(std.mem.span(key_text), "wireguard") and eq(std.mem.span(key_name), "peers") and eq(kind, "aa{sv}")) {
                            const merged = mergePeers(v, next);
                            defer c.g_variant_unref(merged);
                            add(inner, key_name, merged);
                            continue;
                        }
                    }
                }
                g.g_variant_builder_add(inner, "@{sv}", property);
            };
            group(out, key_text, inner);
        }
    }
    return g.g_variant_ref_sink(g.g_variant_builder_end(out)).?;
}
const Call = struct {
    client: *Client,
    callback: Completion,
    data: ?*anyopaque,
    cancel: *c.GCancellable,
    parent: *c.GCancellable,
    parent_signal: c.gulong = 0,
    client_signal: c.gulong = 0,
    pending: usize = 0,
    failed: bool = false,
    message: [512:0]u8 = @splat(0),
    activation: bool = false,
    active_seen: bool = false,
    active_index: usize = 0,
    active: ?[:0]u8 = null,
    activation_timer: c.guint = 0,
    next_profile: ?[:0]u8 = null,
    next_device: ?[:0]u8 = null,
    next_ap: ?[:0]u8 = null,
    save_settings: ?*c.GVariant = null,
    save_path: ?[:0]u8 = null,
    save_version: u64 = 0,
    secret_next: usize = 0,
    reading_secrets: bool = false,
    fn cancelled(_: ?*c.GCancellable, ptr: c.gpointer) callconv(.c) void {
        const self = cast(Call, ptr);
        c.g_cancellable_cancel(self.cancel);
        if (self.active != null) self.finish(.{ .failure = "Cancelled" });
    }
    fn send(self: *Call, path: [*:0]const u8, iface: [*:0]const u8, method: [*:0]const u8, params: ?*c.GVariant) void {
        self.pending += 1;
        const manager = self.client.service.manager.?;
        c.g_dbus_connection_call(g.g_dbus_object_manager_client_get_connection(@ptrCast(manager)), name, path, iface, method, params, null, c.G_DBUS_CALL_FLAGS_NONE, 30000, self.cancel, &done, self);
    }
    fn done(source: [*c]c.GObject, result: ?*c.GAsyncResult, ptr: c.gpointer) callconv(.c) void {
        const self = cast(Call, ptr);
        self.pending -= 1;
        var err: [*c]c.GError = null;
        const reply = c.g_dbus_connection_call_finish(@ptrCast(source), result, &err);
        defer if (reply) |v| c.g_variant_unref(v);
        defer c.g_clear_error(&err);
        if (reply == null and self.reading_secrets and err != null) {
            const remote = c.g_dbus_error_get_remote_error(err);
            defer c.g_free(remote);
            if (remote != null and std.mem.endsWith(u8, std.mem.span(remote), ".NoSecrets")) {
                self.nextSecret();
                return;
            }
        }
        if (reply == null) {
            self.failed = true;
            if (err != null) {
                const msg = std.mem.span(err.*.message);
                @memset(&self.message, 0);
                @memcpy(self.message[0..@min(msg.len, self.message.len - 1)], msg[0..@min(msg.len, self.message.len - 1)]);
            }
        }
        if (self.pending != 0) return;
        if (self.failed) {
            self.finish(.{ .failure = std.mem.sliceTo(&self.message, 0) });
            return;
        }
        if (self.reading_secrets) {
            const secrets = c.g_variant_get_child_value(reply.?, 0).?;
            defer c.g_variant_unref(secrets);
            const combined = mergeSettings(secrets, self.save_settings.?);
            c.g_variant_unref(self.save_settings.?);
            self.save_settings = combined;
            self.nextSecret();
            return;
        }
        if (self.next_profile) |profile| {
            if (self.client.dead or c.g_cancellable_is_cancelled(self.cancel) != 0 or !self.client.state().available) {
                self.finish(.{ .failure = "Cancelled" });
                return;
            }
            self.activation = true;
            self.send(root, name, "ActivateConnection", c.g_variant_new("(ooo)", profile.ptr, self.next_device.?.ptr, self.next_ap.?.ptr));
            a.free(profile);
            self.next_profile = null;
            a.free(self.next_device.?);
            self.next_device = null;
            a.free(self.next_ap.?);
            self.next_ap = null;
            return;
        }
        if (self.activation) {
            if (self.client.dead or c.g_cancellable_is_cancelled(self.cancel) != 0) {
                self.finish(.{ .failure = "Cancelled" });
                return;
            }
            const value = c.g_variant_get_child_value(reply.?, self.active_index).?;
            defer c.g_variant_unref(value);
            self.active = z(string(value));
            self.client.service.waiting.append(a, self) catch @panic("out of memory");
            self.activation_timer = c.g_timeout_add(30000, &activationTimeout, self);
            self.client.service.schedule();
            return;
        }
        self.finish(.success);
    }
    fn activationTimeout(ptr: c.gpointer) callconv(.c) c_int {
        const self = cast(Call, ptr);
        self.activation_timer = 0;
        self.finish(.{ .failure = "Connection activation timed out" });
        return 0;
    }
    fn checkActivation(self: *Call) void {
        if (!self.client.state().available) {
            self.finish(.{ .failure = "NetworkManager disconnected" });
            return;
        }
        for (self.client.state().active.items) |v| if (eq(v.path, self.active.?)) {
            self.active_seen = true;
            if (v.state == 2) self.finish(.success) else if (v.state == 4) self.finish(.{ .failure = "Connection failed. Check credentials and network availability." });
            return;
        };
        if (self.active_seen) self.finish(.{ .failure = "Connection was deactivated before activation completed" });
    }
    fn finish(self: *Call, result: Result) void {
        const client = self.client;
        if (self.activation_timer != 0) _ = c.g_source_remove(self.activation_timer);
        if (self.active) |path| {
            for (client.service.waiting.items, 0..) |value, i| if (value == self) {
                _ = client.service.waiting.orderedRemove(i);
                break;
            };
            a.free(path);
        }
        c.g_signal_handler_disconnect(self.parent, self.parent_signal);
        c.g_signal_handler_disconnect(client.cancel, self.client_signal);
        self.callback(self.data, result);
        c.g_object_unref(self.cancel);
        c.g_object_unref(self.parent);
        if (self.next_profile) |s| a.free(s);
        if (self.next_device) |s| a.free(s);
        if (self.next_ap) |s| a.free(s);
        if (self.save_settings) |v| c.g_variant_unref(v);
        if (self.save_path) |v| a.free(v);
        a.destroy(self);
        client.unref();
    }
    fn nextSecret(self: *Call) void {
        if (self.client.dead or c.g_cancellable_is_cancelled(self.cancel) != 0 or !self.client.state().available) {
            self.finish(.{ .failure = "Cancelled" });
            return;
        }
        const profile = self.client.state().profile(self.save_path.?) orelse {
            self.finish(.{ .failure = "NetworkProfileUnavailable" });
            return;
        };
        while (self.secret_next < secret_groups.len) {
            const key = secret_groups[self.secret_next];
            self.secret_next += 1;
            const dict = section(profile.base, key) orelse continue;
            c.g_variant_unref(dict);
            const retained = section(self.save_settings.?, key) orelse continue;
            c.g_variant_unref(retained);
            self.reading_secrets = true;
            self.send(self.save_path.?, profile_iface, "GetSecrets", c.g_variant_new("(s)", key.ptr));
            return;
        }
        self.reading_secrets = false;
        self.writeSettings();
    }
    fn writeSettings(self: *Call) void {
        if (self.save_path) |path| {
            const options = builder("a{sv}");
            defer g.g_variant_builder_unref(options);
            add(options, "version-id", c.g_variant_new("t", self.save_version));
            self.send(path, profile_iface, "Update2", c.g_variant_new("(@a{sa{sv}}u@a{sv})", self.save_settings.?, @as(c_uint, 1), g.g_variant_builder_end(options)));
        } else self.send(root ++ "/Settings", name ++ ".Settings", "AddConnection", c.g_variant_new("(@a{sa{sv}})", self.save_settings.?));
    }
    fn device(self: *Call, kind: u32, wanted: ?[]const u8) !Device {
        for (self.client.state().devices.items) |d| if (d.kind == kind and d.managed and (wanted == null or eq(d.path, wanted.?))) return d;
        return error.NoCompatibleNetworkDevice;
    }
    fn begin(self: *Call, action: Action) !void {
        const state = self.client.state();
        switch (action) {
            .save => |request| {
                if (!eq(std.mem.span(c.g_variant_get_type_string(request.settings)), "a{sa{sv}}")) return error.InvalidConnectionSettings;
                if (request.path) |path| {
                    const p = state.profile(path) orelse return error.NetworkProfileUnavailable;
                    if (request.version == 0 or p.version != request.version) return error.NetworkProfileChanged;
                }
                self.save_path = if (request.path) |path| z(path) else null;
                self.save_version = request.version;
                self.save_settings = g.g_variant_ref(request.settings);
                if (request.path != null and hasSecrets(request.settings)) self.nextSecret() else self.writeSettings();
            },
            .wifi => |enabled| self.send(root, "org.freedesktop.DBus.Properties", "Set", c.g_variant_new("(ssv)", @as([*:0]const u8, name), @as([*:0]const u8, "WirelessEnabled"), c.g_variant_new("b", @as(c_int, @intFromBool(enabled))))),
            .scan => {
                self.client.refresh();
                var count: usize = 0;
                for (state.devices.items) |d| if (d.kind == 2 and d.managed) {
                    const options = builder("a{sv}");
                    self.send(d.path, wireless_iface, "RequestScan", c.g_variant_new("(@a{sv})", g.g_variant_builder_end(options)));
                    g.g_variant_builder_unref(options);
                    count += 1;
                };
                if (count == 0) return error.NoCompatibleNetworkDevice;
            },
            .disconnect => |path| {
                const p = z(path);
                defer a.free(p);
                self.send(p, device_iface, "Disconnect", null);
            },
            .forget => |path| {
                const p = state.profile(path) orelse return error.NetworkProfileUnavailable;
                self.send(p.path, profile_iface, "Delete", null);
            },
            .deactivate => |path| {
                for (state.active.items) |v| if (eq(v.profile, path)) self.send(root, name, "DeactivateConnection", c.g_variant_new("(o)", v.path.ptr));
            },
            .activate => |path| {
                const p = state.profile(path) orelse return error.NetworkProfileUnavailable;
                const device_path: [*:0]const u8 = if (eq(p.kind, "802-11-wireless")) (try self.device(2, null)).path else if (eq(p.kind, "802-3-ethernet")) (try self.device(1, null)).path else "/";
                self.activation = true;
                self.send(root, name, "ActivateConnection", c.g_variant_new("(ooo)", p.path.ptr, device_path, @as([*:0]const u8, "/")));
            },
            .connect => |request| {
                if (request.ssid.len == 0 or request.ssid.len > 32) return error.InvalidSSIDLength;
                var ap: ?AccessPoint = if (request.access_point) |path| state.ap(path) else null;
                if (ap == null) for (state.access_points.items) |candidate| if (eq(candidate.ssid, request.ssid)) {
                    ap = candidate;
                    break;
                };
                const d = try self.device(2, if (ap) |p| p.device else null);
                const specific: [*:0]const u8 = if (ap) |p| p.path else "/";
                var profile: ?Profile = null;
                for (state.profiles.items) |p| if (eq(p.kind, "802-11-wireless") and eq(p.ssid, request.ssid)) {
                    profile = p;
                    break;
                };
                if (profile != null and request.password.len == 0) {
                    self.activation = true;
                    self.send(root, name, "ActivateConnection", c.g_variant_new("(ooo)", profile.?.path.ptr, d.path.ptr, specific));
                    return;
                }
                const mode = if (ap) |p| p.security else if (request.password.len != 0) Security.personal else Security.open;
                if (profile == null and mode == .enterprise) return error.CreateEnterpriseProfileInConnectionEditor;
                if (profile == null and mode != .open and mode != .owe and request.password.len == 0) return error.PasswordRequired;
                const values = try connectionSettings(request, mode, profile);
                if (profile) |p| {
                    self.next_profile = z(p.path);
                    self.next_device = z(d.path);
                    self.next_ap = z(std.mem.span(specific));
                    self.send(p.path, profile_iface, "Update", c.g_variant_new("(@a{sa{sv}})", values));
                } else {
                    self.activation = true;
                    self.active_index = 1;
                    self.send(root, name, "AddAndActivateConnection", c.g_variant_new("(@a{sa{sv}}oo)", values, d.path.ptr, specific));
                }
            },
        }
    }
};
fn connectionSettings(request: Connect, mode: Security, profile: ?Profile) !*c.GVariant {
    const out = builder("a{sa{sv}}");
    defer g.g_variant_builder_unref(out);
    const pass = z(request.password);
    defer {
        @memset(pass, 0);
        a.free(pass);
    }
    if (profile) |p| {
        const km = settingText(p.base, "802-11-wireless-security", "key-mgmt");
        defer a.free(km);
        const enterprise = eq(km, "wpa-eap") or eq(km, "wpa-eap-suite-b-192") or eq(km, "ieee8021x");
        const target: [:0]const u8 = if (enterprise) "802-1x" else "802-11-wireless-security";
        var found = false;
        for (0..c.g_variant_n_children(p.base)) |i| {
            const entry = c.g_variant_get_child_value(p.base, i).?;
            defer c.g_variant_unref(entry);
            const key = c.g_variant_get_child_value(entry, 0).?;
            defer c.g_variant_unref(key);
            const dict = c.g_variant_get_child_value(entry, 1).?;
            defer c.g_variant_unref(dict);
            const group_name = c.g_variant_get_string(key, null);
            if (!eq(std.mem.span(group_name), target)) {
                g.g_variant_builder_add(out, "{s@a{sv}}", group_name, dict);
                continue;
            }
            found = true;
            const inner = builder("a{sv}");
            const secret: [*:0]const u8 = if (enterprise) "password" else if (eq(km, "none")) "wep-key0" else "psk";
            for (0..c.g_variant_n_children(dict)) |j| {
                const pair = c.g_variant_get_child_value(dict, j).?;
                defer c.g_variant_unref(pair);
                const k = c.g_variant_get_child_value(pair, 0).?;
                defer c.g_variant_unref(k);
                const k_text = c.g_variant_get_string(k, null);
                if (eq(std.mem.span(k_text), std.mem.span(secret))) continue;
                g.g_variant_builder_add(inner, "@{sv}", pair);
            }
            add(inner, secret, c.g_variant_new("s", pass.ptr));
            group(out, group_name, inner);
        }
        if (!found) return error.NetworkProfileSecurityUnavailable;
    } else {
        const conn = builder("a{sv}");
        const title = try ssidTitle(a, request.ssid);
        defer a.free(title);
        add(conn, "id", c.g_variant_new("s", title.ptr));
        add(conn, "type", c.g_variant_new("s", @as([*:0]const u8, "802-11-wireless")));
        group(out, "connection", conn);
        const wifi = builder("a{sv}");
        add(wifi, "ssid", g.g_variant_new_fixed_array(@ptrCast(@as([*:0]const u8, "y")), request.ssid.ptr, request.ssid.len, 1));
        add(wifi, "mode", c.g_variant_new("s", @as([*:0]const u8, "infrastructure")));
        add(wifi, "hidden", c.g_variant_new("b", @as(c_int, @intFromBool(request.hidden))));
        if (mode != .open) add(wifi, "security", c.g_variant_new("s", @as([*:0]const u8, "802-11-wireless-security")));
        group(out, "802-11-wireless", wifi);
        if (mode != .open) {
            const auth = builder("a{sv}");
            const key: [*:0]const u8 = switch (mode) {
                .wep => "none",
                .personal => "wpa-psk",
                .sae => "sae",
                .owe => "owe",
                else => unreachable,
            };
            add(auth, "key-mgmt", c.g_variant_new("s", key));
            if (mode != .owe) add(auth, if (mode == .wep) "wep-key0" else "psk", c.g_variant_new("s", pass.ptr));
            group(out, "802-11-wireless-security", auth);
        }
        for ([_][*:0]const u8{ "ipv4", "ipv6" }) |key| {
            const ip = builder("a{sv}");
            add(ip, "method", c.g_variant_new("s", @as([*:0]const u8, "auto")));
            group(out, key, ip);
        }
    }
    return g.g_variant_builder_end(out).?;
}

test "network security and byte-exact SSID display" {
    try std.testing.expectEqual(Security.personal, security(1, 0, 0x500));
    try std.testing.expectEqual(Security.sae, security(1, 0, 0x400));
    try std.testing.expectEqual(Security.owe, security(1, 0, 0x800));
    try std.testing.expectEqual(Security.enterprise, security(1, 0, 0x200));
    try std.testing.expectEqual(Security.wep, security(1, 0, 0));
    const title = try ssidTitle(std.testing.allocator, &.{ 'A', 0, 255 });
    defer std.testing.allocator.free(title);
    try std.testing.expectEqualStrings("A\\x00\\xff", title);
}

test "network profiles retain binary SSIDs and select security settings" {
    const modes = [_]Security{ .open, .personal, .sae, .wep, .owe };
    const keys = [_][]const u8{ "", "wpa-psk", "sae", "none", "owe" };
    for (modes, keys) |mode, key| {
        const raw = "\xff\x00Cafe";
        const values = try connectionSettings(.{ .ssid = raw, .password = "secret:$()\\", .hidden = true }, mode, null);
        defer c.g_variant_unref(values);
        const ssid = setting(values, "802-11-wireless", "ssid").?;
        defer c.g_variant_unref(ssid);
        try std.testing.expectEqualSlices(u8, raw, bytes(ssid));
        const hidden = setting(values, "802-11-wireless", "hidden").?;
        defer c.g_variant_unref(hidden);
        try std.testing.expect(c.g_variant_get_boolean(hidden) != 0);
        const auth = settingText(values, "802-11-wireless-security", "key-mgmt");
        defer a.free(auth);
        try std.testing.expectEqualStrings(key, auth);
    }
}

test "network snapshot cleanup and connected presentation" {
    var state = State{};
    defer state.deinit();
    state.available = true;
    state.wifi_enabled = true;
    state.hardware_enabled = true;
    state.primary = z("/");
    try state.access_points.append(a, .{ .path = z("/ap"), .device = z("/device"), .ssid = try a.dupe(u8, "Cafe"), .title = z("Cafe"), .strength = 72, .security = .personal, .connected = true });
    try std.testing.expectEqualStrings("network-wireless-signal-good-symbolic", state.indicator().icon);
    try std.testing.expectEqualStrings("Cafe", state.indicator().title);
    state.access_points.items[0].connected = false;
    state.hardware_enabled = false;
    try std.testing.expectEqualStrings("Wi-Fi blocked by hardware switch", state.indicator().title);
    state.clear();
    try std.testing.expectEqualStrings("NetworkManager unavailable", state.indicator().title);
}

test "connection edits preserve VPN credentials and WireGuard peer secrets" {
    const signature: [*:0]const u8 = "a{sa{sv}}";
    const original = c.g_variant_parse(@ptrCast(signature), "{'vpn': {'secrets': <@a{ss} {'password': 'old', 'otp': 'keep'}>}, 'wireguard': {'peers': <@aa{sv} [{'public-key': <'peer-a'>, 'preshared-key': <'keep-peer-key'>}, {'public-key': <'removed-peer'>, 'preshared-key': <'discard'>}]>}}", null, null, null).?;
    defer c.g_variant_unref(original);
    const patch = c.g_variant_parse(@ptrCast(signature), "{'vpn': {'secrets': <@a{ss} {'password': 'new'}>}, 'wireguard': {'peers': <@aa{sv} [{'public-key': <'peer-a'>, 'endpoint': <'host:51820'>}]>}}", null, null, null).?;
    defer c.g_variant_unref(patch);
    const combined = mergeSettings(original, patch);
    defer c.g_variant_unref(combined);
    const secrets = setting(combined, "vpn", "secrets").?;
    defer c.g_variant_unref(secrets);
    const password = section(secrets, "password").?;
    defer c.g_variant_unref(password);
    const otp = section(secrets, "otp").?;
    defer c.g_variant_unref(otp);
    try std.testing.expectEqualStrings("new", string(password));
    try std.testing.expectEqualStrings("keep", string(otp));
    const peers = setting(combined, "wireguard", "peers").?;
    defer c.g_variant_unref(peers);
    try std.testing.expectEqual(@as(usize, 1), c.g_variant_n_children(peers));
    const peer = c.g_variant_get_child_value(peers, 0).?;
    defer c.g_variant_unref(peer);
    const secret = section(peer, "preshared-key").?;
    defer c.g_variant_unref(secret);
    try std.testing.expectEqualStrings("keep-peer-key", string(secret));
}
