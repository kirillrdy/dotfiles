//! Shared, event-driven NetworkManager state and asynchronous actions on the system bus.
const std = @import("std");
const c = @import("desktop-glib.zig");
const dbus = @import("dbus");
const loop = @import("desktop-dbus-loop.zig");
const objects = @import("desktop-dbus-objects.zig");
const name = "org.freedesktop.NetworkManager";
const root = "/org/freedesktop/NetworkManager";
const device_iface = name ++ ".Device";
const wireless_iface = device_iface ++ ".Wireless";
const ap_iface = name ++ ".AccessPoint";
const profile_iface = name ++ ".Settings.Connection";
const active_iface = name ++ ".Connection.Active";
const cast = c.__zig.cast;
fn z(a: std.mem.Allocator, value: []const u8) [:0]u8 {
    return c.__zig.dupeZ(a, value);
}
const eq = c.__zig.eq;
/// An interface's cached properties, as mirrored from NetworkManager's ObjectManager.
const Proxy = objects.Interface;
fn text(a: std.mem.Allocator, proxy: *const Proxy, key: []const u8) [:0]u8 {
    return z(a, switch (proxy.property(key) orelse return z(a, "")) {
        .string, .object_path => |value| value,
        else => "",
    });
}
fn number(proxy: *const Proxy, key: []const u8) u32 {
    return switch (proxy.property(key) orelse return 0) {
        .byte => |value| value,
        .uint32 => |value| value,
        else => 0,
    };
}
fn boolean(proxy: *const Proxy, key: []const u8) bool {
    return switch (proxy.property(key) orelse return false) {
        .boolean => |value| value,
        else => false,
    };
}
pub const Settings = @import("desktop-network-settings.zig").Settings;
const Wire = @import("desktop-network-settings.zig").Wire;
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
pub const Profile = struct { path: [:0]u8, uuid: [:0]u8, title: [:0]u8, kind: [:0]u8, ssid: []u8, active: bool, base: *Settings, version: u64 = 0 };
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
    fn clear(self: *State, a: std.mem.Allocator) void {
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
            p.base.unref();
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
    fn deinit(self: *State, a: std.mem.Allocator) void {
        self.clear(a);
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
pub fn deviceState(state: u32) [:0]const u8 {
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
const Record = struct { path: [:0]u8, settings: ?*Settings = null, dirty: bool = true, loading: bool = false, seen: bool = false, version: u64 = 0 };
const Fetch = struct { service: *Service, path: [:0]u8, epoch: u64, version: u64, serial: u32 = 0 };
var shared: ?*Service = null;
/// Services not yet freed, so lifetime tests can wait for teardown.
pub var live_services: usize = 0;
pub const Service = struct {
    allocator: std.mem.Allocator,
    source: ?*loop.Source = null,
    manager: ?*objects.Manager = null,
    /// GetSettings calls awaiting replies; each holds a reference on the service.
    fetches: std.ArrayList(*Fetch) = .empty,
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
        self.state.deinit(self.allocator);
        self.clearRecords();
        self.records.deinit(self.allocator);
        self.waiting.deinit(self.allocator);
        self.fetches.deinit(self.allocator);
        self.clients.deinit(self.allocator);
        self.allocator.destroy(self);
        live_services -= 1;
    }
    fn clearRecords(self: *Service) void {
        for (self.records.items) |r| {
            if (r.settings) |s| s.unref();
            self.allocator.free(r.path);
            self.allocator.destroy(r);
        }
        self.records.clearRetainingCapacity();
    }
    fn start(self: *Service) void {
        self.connectBus();
        self.timer = c.g_timeout_add_seconds(5, &maintain, self);
    }
    fn connectBus(self: *Service) void {
        if (self.stopped or self.manager != null) return;
        const source = loop.acquire(self.allocator, .system) catch return;
        self.source = source;
        self.manager = objects.Manager.create(self.allocator, source.connection, name, "/org/freedesktop", &event, self) catch {
            self.dropManager();
            return;
        };
        // Profiles announce edits with Updated; their settings are fetched again.
        self.manager.?.forward(profile_iface) catch {};
        self.schedule();
    }
    fn dropManager(self: *Service) void {
        if (self.manager) |m| m.destroy();
        self.manager = null;
        self.cancelFetches();
        if (self.source) |source| loop.release(source);
        self.source = null;
        self.epoch += 1;
        self.clearRecords();
    }
    fn cancelFetches(self: *Service) void {
        while (self.fetches.pop()) |task| {
            if (self.source) |source| source.connection.cancel(task.serial);
            self.allocator.free(task.path);
            self.allocator.destroy(task);
            self.unref();
        }
    }
    fn stop(self: *Service) void {
        self.stopped = true;
        if (shared == self) shared = null;
        if (self.idle != 0) _ = c.g_source_remove(self.idle);
        if (self.timer != 0) _ = c.g_source_remove(self.timer);
        self.idle = 0;
        self.timer = 0;
        self.ref();
        defer self.unref();
        self.dropManager();
    }
    fn maintain(ptr: c.gpointer) callconv(.c) c_int {
        const self = cast(Service, ptr);
        if (self.source) |source| if (source.connection.closed) {
            self.dropManager();
            self.schedule();
        };
        if (self.manager == null) self.connectBus();
        return 1;
    }
    fn event(ptr: ?*anyopaque, change: objects.Event) void {
        const self = cast(Service, ptr);
        switch (change) {
            .owner => {
                self.epoch += 1;
                self.clearRecords();
            },
            .objects, .properties => {},
            .signal => |signal| if (eq(signal.member, "Updated")) if (self.record(signal.path)) |r| {
                r.dirty = true;
            },
        }
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
    fn interface(self: *Service, path: []const u8, iface: []const u8) ?*const Proxy {
        return (self.manager orelse return null).interface(path, iface);
    }
    fn record(self: *Service, path: []const u8) ?*Record {
        for (self.records.items) |r| if (eq(r.path, path)) return r;
        return null;
    }
    fn fetch(self: *Service, r: *Record, proxy: *const Proxy) void {
        if (r.loading or !r.dirty) return;
        const source = self.source orelse return;
        r.dirty = false;
        r.loading = true;
        const fetch_data = self.allocator.create(Fetch) catch @panic("out of memory");
        const version: u64 = switch (proxy.property("VersionId") orelse dbus.Value{ .uint64 = 0 }) {
            .uint64 => |value| value,
            else => 0,
        };
        fetch_data.* = .{ .service = self, .path = z(self.allocator, r.path), .epoch = self.epoch, .version = version };
        self.fetches.append(self.allocator, fetch_data) catch @panic("out of memory");
        self.ref();
        fetch_data.serial = source.connection.call(.{ .destination = name, .path = r.path, .interface = profile_iface, .member = "GetSettings" }, .{}, 10000, &fetched, fetch_data) catch {
            _ = self.fetches.pop();
            self.allocator.free(fetch_data.path);
            self.allocator.destroy(fetch_data);
            r.loading = false;
            self.unref();
            return;
        };
    }
    fn fetched(ptr: ?*anyopaque, reply: dbus.Reply) void {
        const task = cast(Fetch, ptr);
        const self = task.service;
        for (self.fetches.items, 0..) |item, i| if (item == task) {
            _ = self.fetches.swapRemove(i);
            break;
        };
        defer {
            self.allocator.free(task.path);
            self.allocator.destroy(task);
            self.unref();
        }
        if (self.stopped or task.epoch != self.epoch) return;
        const r = self.record(task.path) orelse return;
        r.loading = false;
        switch (reply) {
            .ok => |message| if (message.read(struct { Wire })) |args| {
                if (Settings.fromWire(self.allocator, args[0])) |fresh| {
                    if (r.settings) |old| old.unref();
                    r.settings = fresh;
                    r.version = task.version;
                } else |_| {}
            } else |_| {},
            .failed => {},
        }
        self.schedule();
    }
    fn rebuild(self: *Service) void {
        self.state.clear(self.allocator);
        const m = self.manager orelse return;
        if (m.owner == null) return;
        const main = self.interface(root, name) orelse return;
        self.state.available = true;
        self.state.primary = text(self.allocator, main, "PrimaryConnection");
        self.state.wifi_enabled = boolean(main, "WirelessEnabled");
        self.state.hardware_enabled = boolean(main, "WirelessHardwareEnabled");
        for (self.records.items) |r| r.seen = false;
        for (m.objects.items) |object| {
            const path = object.path;
            if (object.interface(device_iface)) |proxy| {
                const d = Device{ .path = z(self.allocator, path), .interface = text(self.allocator, proxy, "Interface"), .kind = number(proxy, "DeviceType"), .state = number(proxy, "State"), .managed = boolean(proxy, "Managed"), .active = text(self.allocator, proxy, "ActiveConnection") };
                self.state.devices.append(self.allocator, d) catch @panic("out of memory");
                if (d.kind == 2) self.readAccessPoints(d);
            }
            if (object.interface(active_iface)) |proxy| {
                self.state.active.append(self.allocator, .{ .path = z(self.allocator, path), .profile = text(self.allocator, proxy, "Connection"), .title = text(self.allocator, proxy, "Id"), .kind = text(self.allocator, proxy, "Type"), .state = number(proxy, "State") }) catch @panic("out of memory");
            }
            if (object.interface(profile_iface)) |proxy| {
                const r = self.record(path) orelse blk: {
                    const item = self.allocator.create(Record) catch @panic("out of memory");
                    item.* = .{ .path = z(self.allocator, path) };
                    self.records.append(self.allocator, item) catch @panic("out of memory");
                    break :blk item;
                };
                r.seen = true;
                self.fetch(r, proxy);
            }
        }
        var index: usize = 0;
        while (index < self.records.items.len) {
            const r = self.records.items[index];
            if (!r.seen) {
                if (r.settings) |v| v.unref();
                self.allocator.free(r.path);
                self.allocator.destroy(r);
                _ = self.records.swapRemove(index);
                continue;
            }
            if (r.settings) |base| {
                var active = false;
                for (self.state.active.items) |v| {
                    if (eq(v.profile, r.path)) active = true;
                }
                self.state.profiles.append(self.allocator, .{ .path = z(self.allocator, r.path), .uuid = z(self.allocator, base.text("connection", "uuid")), .title = z(self.allocator, base.text("connection", "id")), .kind = z(self.allocator, base.text("connection", "type")), .ssid = self.allocator.dupe(u8, base.bytes("802-11-wireless", "ssid")) catch @panic("out of memory"), .active = active, .base = base.ref(), .version = r.version }) catch @panic("out of memory");
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
        const current = text(self.allocator, wireless, "ActiveAccessPoint");
        defer self.allocator.free(current);
        const paths = switch (wireless.property("AccessPoints") orelse return) {
            .array => |array| array.items,
            else => return,
        };
        for (paths) |item| {
            const path = switch (item) {
                .object_path => |value| value,
                else => continue,
            };
            const proxy = self.interface(path, ap_iface) orelse continue;
            const ssid: []const u8 = switch (proxy.property("Ssid") orelse dbus.Value{ .bytes = "" }) {
                .bytes => |value| value,
                else => "",
            };
            const raw = self.allocator.dupe(u8, ssid) catch @panic("out of memory");
            self.state.access_points.append(self.allocator, .{ .path = z(self.allocator, path), .device = z(self.allocator, device.path), .ssid = raw, .title = ssidTitle(self.allocator, raw) catch @panic("out of memory"), .strength = @intCast(@min(100, number(proxy, "Strength"))), .security = security(number(proxy, "Flags"), number(proxy, "WpaFlags"), number(proxy, "RsnFlags")), .connected = device.state == 100 and eq(current, path) }) catch @panic("out of memory");
        }
    }
};
pub const Connect = struct { ssid: []const u8, password: []const u8 = "", hidden: bool = false, access_point: ?[]const u8 = null };
pub const Save = struct { path: ?[]const u8, settings: *Settings, version: u64 = 0 };
pub const Action = union(enum) { save: Save, wifi: bool, scan, connect: Connect, activate: []const u8, deactivate: []const u8, forget: []const u8, disconnect: []const u8 };
pub const Result = union(enum) { success, failure: [:0]const u8 };
pub const Completion = *const fn (?*anyopaque, Result) void;
pub const Client = struct {
    allocator: std.mem.Allocator,
    service: *Service,
    callback: *const fn (?*anyopaque, *Client) void,
    data: ?*anyopaque,
    cancel: *c.GCancellable,
    refs: usize = 1,
    dead: bool = false,
    pub fn create(a: std.mem.Allocator, callback: *const fn (?*anyopaque, *Client) void, data: ?*anyopaque) !*Client {
        const self = try a.create(Client);
        errdefer a.destroy(self);
        const service = shared orelse blk: {
            const value = try a.create(Service);
            value.* = .{ .allocator = a };
            live_services += 1;
            break :blk value;
        };
        service.ref();
        errdefer service.unref();
        self.* = .{ .allocator = a, .service = service, .callback = callback, .data = data, .cancel = c.g_cancellable_new().? };
        errdefer c.g_object_unref(self.cancel);
        try service.clients.append(service.allocator, self);
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
            self.allocator.destroy(self);
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
        const call = self.allocator.create(Call) catch @panic("out of memory");
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
pub const secret_groups = [_][:0]const u8{ "802-11-wireless-security", "802-1x", "vpn", "gsm", "cdma", "pppoe", "wireguard", "macsec" };
pub fn secretProperty(key: []const u8) bool {
    return std.mem.indexOf(u8, key, "password") != null or std.mem.indexOf(u8, key, "private-key") != null or eq(key, "psk") or std.mem.startsWith(u8, key, "wep-key") or eq(key, "secrets") or eq(key, "pin") or eq(key, "peers") or eq(key, "mka-cak");
}
fn hasSecrets(settings: *Settings) bool {
    for (secret_groups) |group_key| {
        const entries = settings.group(group_key) orelse continue;
        for (entries.properties.items) |property| {
            if (secretProperty(property.key) and !std.mem.endsWith(u8, property.key, "-flags")) return true;
        }
    }
    return false;
}
/// The string key of a dictionary entry, if it has one.
fn entryKey(item: dbus.Value) ?[]const u8 {
    return switch (item) {
        .dict_entry => |entry| switch (entry[0]) {
            .string => |key| key,
            else => null,
        },
        else => null,
    };
}
fn dictionaryHas(items: []const dbus.Value, key: []const u8) bool {
    for (items) |item| if (entryKey(item)) |found| if (eq(found, key)) return true;
    return false;
}
/// `patch`'s entries over `base`'s, for dictionaries with string keys.
fn overlayDictionary(arena: std.mem.Allocator, base: dbus.Value, patch: dbus.Value) !dbus.Value {
    var items: std.ArrayList(dbus.Value) = .empty;
    for (base.array.items) |item| {
        if (!dictionaryHas(patch.array.items, entryKey(item) orelse "")) try items.append(arena, item);
    }
    try items.appendSlice(arena, patch.array.items);
    return .{ .array = .{ .element = patch.array.element, .items = items.items } };
}
fn publicKey(peer: dbus.Value) ?[]const u8 {
    return switch (peer.lookup("public-key") orelse return null) {
        .string => |key| key,
        else => null,
    };
}
/// WireGuard peers from `patch`, each keeping the secrets of the `base` peer with its key.
fn mergePeers(arena: std.mem.Allocator, base: dbus.Value, patch: dbus.Value) !dbus.Value {
    const items = try arena.alloc(dbus.Value, patch.array.items.len);
    for (items, patch.array.items) |*out, peer| {
        out.* = peer;
        const key = publicKey(peer) orelse continue;
        for (base.array.items) |old| if (publicKey(old)) |old_key| if (eq(old_key, key)) {
            out.* = try overlayDictionary(arena, old, peer);
            break;
        };
    }
    return .{ .array = .{ .element = patch.array.element, .items = items } };
}
fn sameType(x: dbus.Value, y: dbus.Value, signature: []const u8) bool {
    var x_buffer: [256]u8 = undefined;
    var y_buffer: [256]u8 = undefined;
    const x_signature = x.signatureInto(&x_buffer) catch return false;
    const y_signature = y.signatureInto(&y_buffer) catch return false;
    return eq(x_signature, y_signature) and eq(x_signature, signature);
}
/// Overlay complete setting groups without losing unedited or unknown keys.
pub fn mergeSettings(a: std.mem.Allocator, base: *Settings, patch: *Settings) !*Settings {
    const out = try Settings.create(a);
    errdefer out.unref();
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    for (base.groups.items) |old| {
        _ = try out.ensureGroup(old.name);
        const fresh = patch.group(old.name);
        for (old.properties.items) |property| {
            if (fresh) |f| if (f.get(property.key) != null) continue;
            try out.put(old.name, property.key, property.value);
        }
    }
    for (patch.groups.items) |fresh| {
        _ = try out.ensureGroup(fresh.name);
        const old = base.group(fresh.name);
        for (fresh.properties.items) |property| {
            var value = property.value;
            if (old) |o| if (o.get(property.key)) |previous| {
                if (eq(property.key, "secrets") and sameType(previous, value, "a{ss}")) value = try overlayDictionary(scratch.allocator(), previous, value);
                if (eq(fresh.name, "wireguard") and eq(property.key, "peers") and sameType(previous, value, "aa{sv}")) value = try mergePeers(scratch.allocator(), previous, value);
            };
            try out.put(fresh.name, property.key, value);
        }
    }
    return out;
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
    save_settings: ?*Settings = null,
    save_path: ?[:0]u8 = null,
    save_version: u64 = 0,
    secret_next: usize = 0,
    reading_secrets: bool = false,
    fn cancelled(_: ?*c.GCancellable, ptr: c.gpointer) callconv(.c) void {
        const self = cast(Call, ptr);
        c.g_cancellable_cancel(self.cancel);
        if (self.active != null) self.finish(.{ .failure = "Cancelled" });
    }
    /// Calls NetworkManager on a request connection, so cancelling still completes the call once.
    fn send(self: *Call, path: []const u8, iface: []const u8, method: []const u8, args: anytype) void {
        self.pending += 1;
        loop.request(self.client.allocator, .system, .{ .destination = name, .path = path, .interface = iface, .member = method }, args, 30000, self.cancel, &done, self);
    }
    /// Sends settings, which are encoded before this returns.
    fn sendSettings(self: *Call, path: []const u8, iface: []const u8, method: []const u8, settings: *Settings, rest: anytype) void {
        var arena = std.heap.ArenaAllocator.init(self.client.allocator);
        defer arena.deinit();
        const wire = settings.wire(arena.allocator()) catch {
            self.pending += 1;
            return done(self, .{ .failed = .{ .name = "org.freedesktop.DBus.Error.NoMemory", .text = "Out of memory" } });
        };
        self.send(path, iface, method, .{wire} ++ rest);
    }
    fn done(ptr: ?*anyopaque, result: dbus.Reply) void {
        const self = cast(Call, ptr);
        self.pending -= 1;
        const message = switch (result) {
            .ok => |message| message,
            .failed => |failure| {
                if (self.reading_secrets and std.mem.endsWith(u8, failure.name, ".NoSecrets")) {
                    self.nextSecret();
                    return;
                }
                @memset(&self.message, 0);
                const text_value = if (failure.text.len > 0) failure.text else failure.name;
                const count = @min(text_value.len, self.message.len - 1);
                @memcpy(self.message[0..count], text_value[0..count]);
                self.failed = true;
                if (self.pending == 0) self.finish(.{ .failure = std.mem.sliceTo(&self.message, 0) });
                return;
            },
        };
        if (self.pending != 0) return;
        if (self.failed) {
            self.finish(.{ .failure = std.mem.sliceTo(&self.message, 0) });
            return;
        }
        if (self.reading_secrets) {
            const wire = (message.read(struct { Wire }) catch return self.finish(.{ .failure = "InvalidSecrets" }))[0];
            const secrets = Settings.fromWire(self.client.allocator, wire) catch return self.finish(.{ .failure = "OutOfMemory" });
            defer secrets.unref();
            const combined = mergeSettings(self.client.allocator, secrets, self.save_settings.?) catch return self.finish(.{ .failure = "OutOfMemory" });
            self.save_settings.?.unref();
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
            self.send(root, name, "ActivateConnection", .{ dbus.ObjectPath{ .value = profile }, dbus.ObjectPath{ .value = self.next_device.? }, dbus.ObjectPath{ .value = self.next_ap.? } });
            self.client.allocator.free(profile);
            self.next_profile = null;
            self.client.allocator.free(self.next_device.?);
            self.next_device = null;
            self.client.allocator.free(self.next_ap.?);
            self.next_ap = null;
            return;
        }
        if (self.activation) {
            if (self.client.dead or c.g_cancellable_is_cancelled(self.cancel) != 0) {
                self.finish(.{ .failure = "Cancelled" });
                return;
            }
            const values = message.values() catch return self.finish(.{ .failure = "InvalidReply" });
            if (self.active_index >= values.len) return self.finish(.{ .failure = "InvalidReply" });
            self.active = z(self.client.allocator, switch (values[self.active_index]) {
                .object_path => |path| path,
                else => return self.finish(.{ .failure = "InvalidReply" }),
            });
            self.client.service.waiting.append(self.client.service.allocator, self) catch @panic("out of memory");
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
            self.client.allocator.free(path);
        }
        c.g_signal_handler_disconnect(self.parent, self.parent_signal);
        c.g_signal_handler_disconnect(client.cancel, self.client_signal);
        self.callback(self.data, result);
        c.g_object_unref(self.cancel);
        c.g_object_unref(self.parent);
        if (self.next_profile) |s| self.client.allocator.free(s);
        if (self.next_device) |s| self.client.allocator.free(s);
        if (self.next_ap) |s| self.client.allocator.free(s);
        if (self.save_settings) |v| v.unref();
        if (self.save_path) |v| self.client.allocator.free(v);
        self.client.allocator.destroy(self);
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
            if (profile.base.group(key) == null or self.save_settings.?.group(key) == null) continue;
            self.reading_secrets = true;
            self.send(self.save_path.?, profile_iface, "GetSecrets", .{@as([]const u8, key)});
            return;
        }
        self.reading_secrets = false;
        self.writeSettings();
    }
    fn writeSettings(self: *Call) void {
        if (self.save_path) |path| {
            const options = [_]dbus.Dict([]const u8, dbus.Value).Entry{.{ .key = "version-id", .value = .{ .uint64 = self.save_version } }};
            self.sendSettings(path, profile_iface, "Update2", self.save_settings.?, .{ @as(u32, 1), dbus.Dict([]const u8, dbus.Value){ .entries = &options } });
        } else self.sendSettings(root ++ "/Settings", name ++ ".Settings", "AddConnection", self.save_settings.?, .{});
    }
    fn device(self: *Call, kind: u32, wanted: ?[]const u8) !Device {
        for (self.client.state().devices.items) |d| if (d.kind == kind and d.managed and (wanted == null or eq(d.path, wanted.?))) return d;
        return error.NoCompatibleNetworkDevice;
    }
    fn begin(self: *Call, action: Action) !void {
        const state = self.client.state();
        switch (action) {
            .save => |request| {
                if (request.path) |path| {
                    const p = state.profile(path) orelse return error.NetworkProfileUnavailable;
                    if (request.version == 0 or p.version != request.version) return error.NetworkProfileChanged;
                }
                self.save_path = if (request.path) |path| z(self.client.allocator, path) else null;
                self.save_version = request.version;
                self.save_settings = request.settings.ref();
                if (request.path != null and hasSecrets(request.settings)) self.nextSecret() else self.writeSettings();
            },
            .wifi => |enabled| self.send(root, "org.freedesktop.DBus.Properties", "Set", .{ @as([]const u8, name), "WirelessEnabled", dbus.Value{ .boolean = enabled } }),
            .scan => {
                self.client.refresh();
                var count: usize = 0;
                for (state.devices.items) |d| if (d.kind == 2 and d.managed) {
                    self.send(d.path, wireless_iface, "RequestScan", .{dbus.Dict([]const u8, dbus.Value){ .entries = &.{} }});
                    count += 1;
                };
                if (count == 0) return error.NoCompatibleNetworkDevice;
            },
            .disconnect => |path| {
                const p = z(self.client.allocator, path);
                defer self.client.allocator.free(p);
                self.send(p, device_iface, "Disconnect", .{});
            },
            .forget => |path| {
                const p = state.profile(path) orelse return error.NetworkProfileUnavailable;
                self.send(p.path, profile_iface, "Delete", .{});
            },
            .deactivate => |path| {
                for (state.active.items) |v| if (eq(v.profile, path)) self.send(root, name, "DeactivateConnection", .{dbus.ObjectPath{ .value = v.path }});
            },
            .activate => |path| {
                const p = state.profile(path) orelse return error.NetworkProfileUnavailable;
                const device_path: []const u8 = if (eq(p.kind, "802-11-wireless")) (try self.device(2, null)).path else if (eq(p.kind, "802-3-ethernet")) (try self.device(1, null)).path else "/";
                self.activation = true;
                self.send(root, name, "ActivateConnection", .{ dbus.ObjectPath{ .value = p.path }, dbus.ObjectPath{ .value = device_path }, dbus.ObjectPath{ .value = "/" } });
            },
            .connect => |request| {
                if (request.ssid.len == 0 or request.ssid.len > 32) return error.InvalidSSIDLength;
                var ap: ?AccessPoint = if (request.access_point) |path| state.ap(path) else null;
                if (ap == null) for (state.access_points.items) |candidate| if (eq(candidate.ssid, request.ssid)) {
                    ap = candidate;
                    break;
                };
                const d = try self.device(2, if (ap) |p| p.device else null);
                const specific: []const u8 = if (ap) |p| p.path else "/";
                var profile: ?Profile = null;
                for (state.profiles.items) |p| if (eq(p.kind, "802-11-wireless") and eq(p.ssid, request.ssid)) {
                    profile = p;
                    break;
                };
                if (profile != null and request.password.len == 0) {
                    self.activation = true;
                    self.send(root, name, "ActivateConnection", .{ dbus.ObjectPath{ .value = profile.?.path }, dbus.ObjectPath{ .value = d.path }, dbus.ObjectPath{ .value = specific } });
                    return;
                }
                const mode = if (ap) |p| p.security else if (request.password.len != 0) Security.personal else Security.open;
                if (profile == null and mode == .enterprise) return error.CreateEnterpriseProfileInConnectionEditor;
                if (profile == null and mode != .open and mode != .owe and request.password.len == 0) return error.PasswordRequired;
                const values = try connectionSettings(self.client.allocator, request, mode, profile);
                defer values.unref();
                if (profile) |p| {
                    self.next_profile = z(self.client.allocator, p.path);
                    self.next_device = z(self.client.allocator, d.path);
                    self.next_ap = z(self.client.allocator, specific);
                    self.sendSettings(p.path, profile_iface, "Update", values, .{});
                } else {
                    self.activation = true;
                    self.active_index = 1;
                    self.sendSettings(root, name, "AddAndActivateConnection", values, .{ dbus.ObjectPath{ .value = d.path }, dbus.ObjectPath{ .value = specific } });
                }
            },
        }
    }
};
fn connectionSettings(a: std.mem.Allocator, request: Connect, mode: Security, profile: ?Profile) !*Settings {
    const out = try Settings.create(a);
    errdefer out.unref();
    if (profile) |p| {
        const km = p.base.text("802-11-wireless-security", "key-mgmt");
        const enterprise = eq(km, "wpa-eap") or eq(km, "wpa-eap-suite-b-192") or eq(km, "ieee8021x");
        const target = if (enterprise) "802-1x" else "802-11-wireless-security";
        if (p.base.group(target) == null) return error.NetworkProfileSecurityUnavailable;
        const secret = if (enterprise) "password" else if (eq(km, "none")) "wep-key0" else "psk";
        // The profile's own settings, with the entered secret replacing the stored one.
        for (p.base.groups.items) |item| {
            _ = try out.ensureGroup(item.name);
            for (item.properties.items) |property| {
                if (eq(item.name, target) and eq(property.key, secret)) continue;
                try out.put(item.name, property.key, property.value);
            }
        }
        try out.put(target, secret, .{ .string = request.password });
    } else {
        const title = try ssidTitle(a, request.ssid);
        defer a.free(title);
        try out.put("connection", "id", .{ .string = title });
        try out.put("connection", "type", .{ .string = "802-11-wireless" });
        try out.put("802-11-wireless", "ssid", .{ .bytes = request.ssid });
        try out.put("802-11-wireless", "mode", .{ .string = "infrastructure" });
        try out.put("802-11-wireless", "hidden", .{ .boolean = request.hidden });
        if (mode != .open) try out.put("802-11-wireless", "security", .{ .string = "802-11-wireless-security" });
        if (mode != .open) {
            const key = switch (mode) {
                .wep => "none",
                .personal => "wpa-psk",
                .sae => "sae",
                .owe => "owe",
                else => unreachable,
            };
            try out.put("802-11-wireless-security", "key-mgmt", .{ .string = key });
            if (mode != .owe) try out.put("802-11-wireless-security", if (mode == .wep) "wep-key0" else "psk", .{ .string = request.password });
        }
        for ([_][]const u8{ "ipv4", "ipv6" }) |key| try out.put(key, "method", .{ .string = "auto" });
    }
    return out;
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
        const values = try connectionSettings(std.testing.allocator, .{ .ssid = raw, .password = "secret:$()\\", .hidden = true }, mode, null);
        defer values.unref();
        try std.testing.expectEqualSlices(u8, raw, values.bytes("802-11-wireless", "ssid"));
        try std.testing.expect(values.get("802-11-wireless", "hidden").?.boolean);
        try std.testing.expectEqualStrings(key, values.text("802-11-wireless-security", "key-mgmt"));
    }
}

test "network snapshot cleanup and connected presentation" {
    const a = std.testing.allocator;
    var state = State{};
    defer state.deinit(a);
    state.available = true;
    state.wifi_enabled = true;
    state.hardware_enabled = true;
    state.primary = z(a, "/");
    try state.access_points.append(a, .{ .path = z(a, "/ap"), .device = z(a, "/device"), .ssid = try a.dupe(u8, "Cafe"), .title = z(a, "Cafe"), .strength = 72, .security = .personal, .connected = true });
    try std.testing.expectEqualStrings("network-wireless-signal-good-symbolic", state.indicator().icon);
    try std.testing.expectEqualStrings("Cafe", state.indicator().title);
    state.access_points.items[0].connected = false;
    state.hardware_enabled = false;
    try std.testing.expectEqualStrings("Wi-Fi blocked by hardware switch", state.indicator().title);
    state.clear(a);
    try std.testing.expectEqualStrings("NetworkManager unavailable", state.indicator().title);
}

test "connection edits preserve VPN credentials and WireGuard peer secrets" {
    const text_format = @import("desktop-dbus-text.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parse = struct {
        fn settings(allocator: std.mem.Allocator, text_value: []const u8) !*Settings {
            const value = try text_format.parse(allocator, "a{sa{sv}}", text_value);
            const out = try Settings.create(std.testing.allocator);
            errdefer out.unref();
            for (value.array.items) |group_entry| {
                const group_name = group_entry.dict_entry[0].string;
                _ = try out.ensureGroup(group_name);
                for (group_entry.dict_entry[1].array.items) |property| try out.put(group_name, property.dict_entry[0].string, property.dict_entry[1].variant.*);
            }
            return out;
        }
    };
    const original = try parse.settings(arena.allocator(), "{'vpn': {'secrets': <@a{ss} {'password': 'old', 'otp': 'keep'}>}, 'wireguard': {'peers': <@aa{sv} [{'public-key': <'peer-a'>, 'preshared-key': <'keep-peer-key'>}, {'public-key': <'removed-peer'>, 'preshared-key': <'discard'>}]>}}");
    defer original.unref();
    const patch = try parse.settings(arena.allocator(), "{'vpn': {'secrets': <@a{ss} {'password': 'new'}>}, 'wireguard': {'peers': <@aa{sv} [{'public-key': <'peer-a'>, 'endpoint': <'host:51820'>}]>}}");
    defer patch.unref();
    const combined = try mergeSettings(std.testing.allocator, original, patch);
    defer combined.unref();
    const secrets = combined.get("vpn", "secrets").?;
    const lookup = struct {
        fn string(dictionary: dbus.Value, key: []const u8) []const u8 {
            for (dictionary.array.items) |item| if (eq(item.dict_entry[0].string, key)) return item.dict_entry[1].string;
            return "";
        }
    };
    try std.testing.expectEqualStrings("new", lookup.string(secrets, "password"));
    try std.testing.expectEqualStrings("keep", lookup.string(secrets, "otp"));
    const peers = combined.get("wireguard", "peers").?;
    try std.testing.expectEqual(@as(usize, 1), peers.array.items.len);
    try std.testing.expectEqualStrings("keep-peer-key", peers.array.items[0].lookup("preshared-key").?.string);
}
