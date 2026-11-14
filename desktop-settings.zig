//! Settings windows using native form controls and the existing system services.
const std = @import("std");
pub const c = @import("desktop-gtk.zig");
pub const SoundControl = @import("desktop-sound-view.zig").Control;
pub const Sound = @import("desktop-sound-settings.zig").Sound;
const network = @import("desktop-network.zig");
const editor = @import("desktop-network-editor.zig");
const native = @import("desktop-form.zig");
const auth = @import("desktop-auth-dialog.zig");
const network_view = @import("desktop-network-view.zig");
const raster = @import("desktop-raster.zig");
const a = if (@import("builtin").is_test) std.testing.allocator else std.heap.page_allocator;
const cast = c.__zig.cast;
const eq = c.__zig.eq;
fn z(value: []const u8) [:0]u8 {
    return c.__zig.dupeZ(a, value);
}
pub const Mode = enum { sound, network };
pub const Settings = struct {
    mode: Mode = .network,
    window: *native.host.Window,
    ui: *native.Form,
    message: *native.Item,
    refresh_button: *native.Item,
    network_client: ?*network.Client = null,
    network_operations: usize = 0,
    closed: bool = false,
    audio_cancel: *c.GCancellable,
    ssids: *native.Item,
    manual: *native.Item,
    password: *native.Item,
    hidden: *native.Item,
    profiles: *native.Item,
    devices: *native.Item,
    status: *native.Item,
    view: network_view.View = .{},
    rows: std.ArrayList(network_view.Row) = .empty,
    dynamic_start: usize = 0,
    initial_page: bool = true,
    pub fn create(mode: Mode) *Settings {
        std.debug.assert(mode == .network);
        const self = a.create(Settings) catch @panic("out of memory");
        const ui = native.Form.create("Network", self, &action, &fieldChanged) catch @panic("out of memory");
        self.* = .{ .window = ui.window, .ui = ui, .audio_cancel = c.g_cancellable_new().?, .message = undefined, .refresh_button = undefined, .ssids = undefined, .manual = undefined, .password = undefined, .hidden = undefined, .profiles = undefined, .devices = undefined, .status = undefined };
        self.status = self.add(.label, "Loading network devices…", "", false);
        self.refresh_button = self.add(.button, "Refresh", "", false);
        self.refresh_button.always_enabled = true;
        const wifi_on = self.add(.button, "Enable Wi-Fi", "", false);
        const wifi_off = self.add(.button, "Disable Wi-Fi", "", false);
        ui.pair(wifi_on.id, wifi_off.id);
        self.ssids = self.add(.choice, "Available Wi-Fi networks", "", false);
        self.manual = self.add(.entry, "Wi-Fi network name", "Select a network above or enter its name", false);
        self.password = self.add(.entry, "Password", "Leave empty for a saved or open network", true);
        self.hidden = self.add(.toggle, "Hidden network", "", false);
        const connect_wifi = self.add(.button, "Connect", "", false);
        self.profiles = self.add(.choice, "Saved connections", "", false);
        const activate_profile = self.add(.button, "Connect", "", false);
        const deactivate_profile = self.add(.button, "Disconnect", "", false);
        ui.pair(activate_profile.id, deactivate_profile.id);
        _ = self.add(.button, "Forget…", "", false);
        self.devices = self.add(.choice, "Network devices", "", false);
        _ = self.add(.button, "Disconnect device", "", false);
        const edit_profile = self.add(.button, "Edit connection…", "", false);
        const new_profile = self.add(.button, "New connection…", "", false);
        ui.pair(edit_profile.id, new_profile.id);
        self.message = ui.get(ui.addPinned(.label, "") catch @panic("out of memory"));
        self.view = .{
            .wifi_nav = ui.add(.button, "Wi-Fi", "", false) catch @panic("out of memory"),
            .network_nav = ui.add(.button, "Network", "", false) catch @panic("out of memory"),
            .wifi = ui.add(.toggle, "Wi-Fi", "", false) catch @panic("out of memory"),
            .saved = ui.add(.button, "Saved Networks", "", false) catch @panic("out of memory"),
            .hidden = ui.add(.button, "Connect to Hidden Network…", "", false) catch @panic("out of memory"),
            .hotspot = ui.add(.label, "Turn On Wi-Fi Hotspot…", "", false) catch @panic("out of memory"),
            .back = ui.add(.button, "Back", "", false) catch @panic("out of memory"),
            .close = ui.add(.button, "Close", "", false) catch @panic("out of memory"),
            .search = ui.add(.button, "Search Networks", "", false) catch @panic("out of memory"),
            .query = ui.add(.entry, "Search Networks", "", false) catch @panic("out of memory"),
            .new_connection = new_profile.id,
            .manual = self.manual.id,
            .password = self.password.id,
            .connect = connect_wifi.id,
            .refresh = self.refresh_button.id,
            .message = self.message.id,
        };
        for ([_]usize{ self.view.wifi_nav, self.view.network_nav, self.view.back, self.view.close, self.view.search }) |id| ui.get(id).always_enabled = true;
        self.dynamic_start = ui.items.items.len;
        self.window.setSize(980, 700);
        ui.window.surface.?.options.min_width = 680;
        ui.window.surface.?.options.min_height = 400;
        ui.layout = &layout;
        ui.painter = &paint;
        ui.scrolled = &scroll;
        ui.shortcut = &shortcut;
        ui.reveal = &reveal;
        self.network_client = network.Client.create(&networkChanged, self) catch null;
        ui.close_callback = &destroyed;
        ui.show();
        self.refresh();
        return self;
    }
    fn add(self: *Settings, kind: native.Kind, title: [:0]const u8, hint: [:0]const u8, secret: bool) *native.Item {
        return self.ui.get(self.ui.add(kind, title, hint, secret) catch @panic("out of memory"));
    }
    pub fn setMessage(self: *Settings, message: [:0]const u8) void {
        self.ui.setText(self.message.id, message) catch {};
    }
    fn layout(ui: *native.Form) void {
        cast(Settings, ui.context).view.layout(ui);
    }
    fn paint(ui: *native.Form, target: raster.Buffer, scale: u32) !void {
        try cast(Settings, ui.context).view.paint(ui, target, scale);
    }
    fn scroll(ptr: ?*anyopaque, delta: f64) void {
        const self = cast(Settings, ptr);
        self.view.offset = std.math.clamp(self.view.offset + delta, 0, self.view.maxOffset());
        self.ui.relayout();
    }
    fn reveal(ptr: ?*anyopaque, id: usize) void {
        const self = cast(Settings, ptr);
        const r = self.ui.get(id).bounds;
        if (r.x < self.view.frame.sidebar or r.y == 6 or id == self.view.close) return;
        if (r.y < 54) self.view.offset = @max(0, self.view.offset + r.y - 54);
        if (r.y + r.height > self.view.frame.height - 16) self.view.offset += r.y + r.height - self.view.frame.height + 16;
        self.ui.relayout();
    }
    fn shortcut(ptr: ?*anyopaque, symbol: u32, modifiers: u32) bool {
        const self = cast(Settings, ptr);
        if (symbol == 0xffc2) {
            self.refresh();
            return true;
        }
        if ((symbol == 'f' or symbol == 'F') and modifiers & c.GDK_CONTROL_MASK != 0) {
            self.showSearch();
            return true;
        }
        if (symbol == 0xff1b) {
            if (self.view.searching) {
                self.view.searching = false;
                self.ui.setText(self.view.query, "") catch {};
                self.ui.focus = null;
                self.renderCurrent();
                return true;
            }
            if (self.view.page == .hidden or self.view.page == .saved) {
                self.showPage(.wifi);
                return true;
            }
        }
        return false;
    }
    fn showSearch(self: *Settings) void {
        self.view.searching = true;
        self.ui.relayout();
        self.ui.focusItem(self.view.query);
    }
    pub fn showPage(self: *Settings, page: network_view.Page) void {
        self.initial_page = false;
        self.view.page = page;
        self.view.offset = 0;
        self.password.entry.?.clear();
        self.ui.setChecked(self.hidden.id, page == .hidden);
        if (page == .hidden) _ = self.ui.select(self.ssids.id, null);
        self.ui.focus = null;
        self.renderCurrent();
    }
    fn renderCurrent(self: *Settings) void {
        if (self.network_client) |client| self.renderNetwork(client.state()) else self.ui.relayout();
    }
    fn sensitivity(self: *Settings) void {
        const idle = self.network_operations == 0;
        self.refresh_button.enabled = idle;
        self.view.busy = !idle;
        self.ui.setEnabled(idle and self.network_client != null and self.network_client.?.state().available);
    }
    pub fn destroy(self: *Settings) void {
        std.debug.assert(self.closed and self.network_operations == 0);
        c.g_object_unref(self.audio_cancel);
        self.ui.deinit();
        self.view.deinit();
        self.rows.deinit(a);
        a.destroy(self);
    }
    fn destroyed(ptr: ?*anyopaque) void {
        const self = cast(Settings, ptr);
        self.closed = true;
        c.g_cancellable_cancel(self.audio_cancel);
        if (self.network_client) |client| client.destroy();
        self.network_client = null;
    }
    pub fn refresh(self: *Settings) void {
        if (self.closed or self.network_operations != 0) return;
        if (self.network_client) |client| {
            client.refresh();
            if (client.state().available) self.networkAction(.scan) else self.renderNetwork(client.state());
        } else {
            self.setMessage("NetworkManager unavailable");
            self.sensitivity();
        }
    }
    fn networkChanged(ptr: ?*anyopaque, client: *network.Client) void {
        const self = cast(Settings, ptr);
        if (!self.closed) self.renderNetwork(client.state());
    }
    fn networkAction(self: *Settings, command: network.Action) void {
        if (self.closed or self.network_operations != 0) return;
        const client = self.network_client orelse {
            self.setMessage("NetworkManager unavailable");
            return;
        };
        self.network_operations += 1;
        self.setMessage("Working…");
        self.sensitivity();
        client.perform(command, self.audio_cancel, &networkDone, self);
    }
    fn networkDone(ptr: ?*anyopaque, result: network.Result) void {
        const self = cast(Settings, ptr);
        self.network_operations -= 1;
        if (self.closed) return;
        self.setMessage(if (result == .success) "" else result.failure);
        if (self.network_client) |client| self.renderNetwork(client.state());
        self.sensitivity();
    }
    pub fn renderNetwork(self: *Settings, state: *const network.State) void {
        var focused_path: ?[:0]u8 = null;
        var focused_part: enum { row, details, remove } = .row;
        if (self.ui.focus) |id| for (self.rows.items) |row| {
            if (id != row.item and id != row.details and row.remove != id) continue;
            focused_path = z(row.key);
            focused_part = if (id == row.details) .details else if (row.remove == id) .remove else .row;
            break;
        };
        defer if (focused_path) |path| a.free(path);
        self.view.rows = &.{};
        self.rows.clearRetainingCapacity();
        self.ui.updating = true;
        defer {
            self.ui.updating = false;
            self.view.rows = self.rows.items;
            self.ui.relayout();
            if (focused_path) |path| for (self.rows.items) |row| if (eq(row.key, path)) {
                self.ui.focusItem(switch (focused_part) {
                    .row => row.item,
                    .details => row.details,
                    .remove => row.remove orelse row.item,
                });
                break;
            };
        }
        self.ui.truncate(self.dynamic_start);
        self.view.available = state.available;
        self.view.radio = state.wifi_enabled;
        self.view.hardware = state.hardware_enabled;
        self.view.has_wifi = false;
        for (state.devices.items) |device| if (device.kind == 2) {
            self.view.has_wifi = true;
        };
        if (self.initial_page and state.available and state.devices.items.len > 0) {
            self.view.page = if (self.view.has_wifi) .wifi else .network;
            self.initial_page = false;
        }
        self.ui.get(self.view.wifi).checked = state.wifi_enabled;
        self.ui.get(self.view.wifi).enabled = state.hardware_enabled;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        var options: std.ArrayList(native.Option) = .empty;
        var seen: std.StringHashMap(void) = .init(alloc);
        for (state.access_points.items) |ap| {
            if (ap.ssid.len == 0 or seen.contains(ap.ssid)) continue;
            seen.put(ap.ssid, {}) catch @panic("out of memory");
            options.append(alloc, .{ .id = ap.path, .label = ap.title }) catch @panic("out of memory");
        }
        self.ui.setOptions(self.ssids.id, options.items, false) catch @panic("out of memory");
        if (self.ssids.selectedId()) |key| if (state.ap(key)) |ap| {
            self.ui.setText(self.manual.id, ap.title) catch {};
        };
        options.clearRetainingCapacity();
        for (state.profiles.items) |profile| {
            const title = std.fmt.allocPrintSentinel(alloc, "{s} ({s}){s}", .{ profile.title, profile.kind, if (profile.active) " — connected" else "" }, 0) catch @panic("out of memory");
            options.append(alloc, .{ .id = profile.path, .label = title }) catch @panic("out of memory");
        }
        self.ui.setOptions(self.profiles.id, options.items, true) catch @panic("out of memory");
        options.clearRetainingCapacity();
        var summary: std.ArrayList(u8) = .empty;
        for (state.devices.items) |device| {
            if (device.kind == 32 or eq(device.interface, "lo")) continue;
            const title = std.fmt.allocPrintSentinel(alloc, "{s}: {s} — {s}", .{ device.interface, network.deviceState(device.state), state.connectionName(device.active) }, 0) catch @panic("out of memory");
            options.append(alloc, .{ .id = device.path, .label = title }) catch @panic("out of memory");
            if (summary.items.len != 0) summary.append(alloc, '\n') catch @panic("out of memory");
            summary.appendSlice(alloc, title) catch @panic("out of memory");
        }
        self.ui.setOptions(self.devices.id, options.items, true) catch @panic("out of memory");
        const status = alloc.dupeSentinel(u8, if (!state.available) "NetworkManager unavailable" else if (summary.items.len == 0) "No network devices available" else summary.items, 0) catch @panic("out of memory");
        self.ui.setText(self.status.id, status) catch {};
        self.rebuildRows(state);
        self.sensitivity();
    }
    fn profilePath(self: *Settings, path: []const u8) ?[:0]const u8 {
        for (self.profiles.options.items) |option| if (eq(option.id, path)) return option.id;
        return null;
    }
    fn addNetworkRow(self: *Settings, title: [:0]const u8, row: network_view.Row) void {
        var next = row;
        next.item = self.ui.add(.button, title, "", false) catch @panic("out of memory");
        next.details = self.ui.add(.button, "Network Options", "", false) catch @panic("out of memory");
        if (self.view.page == .saved) next.remove = self.ui.add(.button, "Forget", "", false) catch @panic("out of memory");
        self.rows.append(a, next) catch @panic("out of memory");
    }
    fn rebuildRows(self: *Settings, state: *const network.State) void {
        const query = self.ui.get(self.view.query).value();
        if (self.view.page == .wifi and state.available and state.wifi_enabled and state.hardware_enabled) {
            for (self.ssids.options.items) |option| {
                const ap = state.ap(option.id) orelse continue;
                if (!matches(ap.title, query)) continue;
                var profile: ?[:0]const u8 = null;
                for (state.profiles.items) |saved| if (eq(saved.ssid, ap.ssid) and eq(saved.kind, "802-11-wireless")) {
                    profile = self.profilePath(saved.path);
                    break;
                };
                self.addNetworkRow(ap.title, .{ .item = 0, .details = 0, .key = option.id, .profile = profile, .kind = .access_point, .icon = network.wifiIcon(ap.strength), .subtitle = if (ap.connected) "Connected" else "", .connected = ap.connected, .secure = ap.passwordRequired(), .strength = ap.strength });
            }
        } else if (self.view.page == .saved) {
            for (self.profiles.options.items) |option| {
                const profile = state.profile(option.id) orelse continue;
                if (!eq(profile.kind, "802-11-wireless")) continue;
                if (!matches(profile.title, query)) continue;
                self.addNetworkRow(profile.title, .{ .item = 0, .details = 0, .key = option.id, .profile = option.id, .kind = .profile, .icon = "network-wireless-symbolic", .subtitle = if (profile.active) "Connected" else "", .connected = profile.active });
            }
        } else if (self.view.page == .network) {
            for (self.devices.options.items) |option| for (state.devices.items) |device| if (eq(device.path, option.id) and device.kind != 2) {
                var profile: ?[:0]const u8 = null;
                for (state.profiles.items) |saved| if (eq(saved.kind, "802-3-ethernet")) {
                    profile = self.profilePath(saved.path);
                    break;
                };
                self.addNetworkRow(if (device.kind == 1) "Wired" else device.interface, .{ .item = 0, .details = 0, .key = option.id, .profile = profile, .kind = .device, .icon = "network-wired-symbolic", .subtitle = network.deviceState(device.state), .connected = device.state == 100 });
            };
            for (self.profiles.options.items) |option| {
                const profile = state.profile(option.id) orelse continue;
                if (eq(profile.kind, "802-11-wireless") or eq(profile.kind, "802-3-ethernet")) continue;
                self.addNetworkRow(profile.title, .{ .item = 0, .details = 0, .key = option.id, .profile = option.id, .kind = .profile, .icon = "network-vpn-symbolic", .subtitle = if (profile.active) "Connected" else "Not connected", .connected = profile.active });
            }
        }
        if (self.view.page == .wifi or self.view.page == .saved) std.mem.sort(network_view.Row, self.rows.items, self, lessRow);
    }
    fn matches(title: [:0]const u8, query: [:0]const u8) bool {
        if (query.len == 0) return true;
        const folded_title = c.g_utf8_casefold(title, -1);
        defer c.g_free(folded_title);
        const folded_query = c.g_utf8_casefold(query, -1);
        defer c.g_free(folded_query);
        return std.mem.indexOf(u8, std.mem.span(folded_title), std.mem.span(folded_query)) != null;
    }
    fn lessRow(self: *Settings, left: network_view.Row, right: network_view.Row) bool {
        if (left.connected != right.connected) return left.connected;
        if (left.strength != right.strength) return left.strength > right.strength;
        return std.ascii.lessThanIgnoreCase(self.ui.get(left.item).title, self.ui.get(right.item).title);
    }
    pub fn selectAP(self: *Settings, path: []const u8) bool {
        if (!self.ui.select(self.ssids.id, path)) return false;
        fieldChanged(self, self.ssids.id);
        return true;
    }
    fn fieldChanged(ptr: ?*anyopaque, id: usize) void {
        const self = cast(Settings, ptr);
        if (self.closed) return;
        if (id == self.view.wifi) {
            self.networkAction(.{ .wifi = self.ui.get(id).checked });
            return;
        }
        if (id == self.view.query) {
            self.view.offset = 0;
            self.renderCurrent();
            return;
        }
        if (id == self.manual.id) _ = self.ui.select(self.ssids.id, null);
        if (id == self.ssids.id) {
            const client = self.network_client orelse return;
            const key = self.ssids.selectedId() orelse return;
            const ap = client.state().ap(key) orelse return;
            self.ui.setText(self.manual.id, ap.title) catch {};
        }
    }
    pub fn wifiConnect(_: ?*c.GtkButton, ptr: c.gpointer) callconv(.c) void {
        const self = cast(Settings, ptr);
        const client = self.network_client orelse return;
        const ap = if (self.ssids.selectedId()) |key| client.state().ap(key) else null;
        self.networkAction(.{ .connect = .{ .ssid = if (ap) |value| value.ssid else self.manual.value(), .password = self.password.value(), .hidden = self.hidden.checked, .access_point = if (ap) |value| value.path else null } });
        self.password.entry.?.clear();
    }
    fn profileAction(self: *Settings, command: enum { activate, deactivate, forget }) void {
        const key = self.profiles.selectedId() orelse {
            self.setMessage("Select a saved connection first.");
            return;
        };
        self.networkAction(switch (command) {
            .activate => .{ .activate = key },
            .deactivate => .{ .deactivate = key },
            .forget => .{ .forget = key },
        });
    }
    fn forget(self: *Settings) void {
        const key = self.profiles.selectedId() orelse return;
        const owned_key = z(key);
        defer a.free(owned_key);
        const dialog = auth.Dialog.createWithOptions(.confirm, "Forget the selected connection and its saved credentials?", .{ .title = "Forget Connection", .role = "desktop-network-forget", .accept = "Forget", .cancel = "Cancel", .icon = "network-wireless" }) catch return;
        defer dialog.destroy();
        dialog.window.parent = self.window;
        // Hold the controller across the nested dialog loop, even if its parent closes.
        self.network_operations += 1;
        self.sensitivity();
        dialog.run();
        const accepted = dialog.accepted;
        self.network_operations -= 1;
        if (self.closed) return;
        self.sensitivity();
        if (accepted) self.networkAction(.{ .forget = owned_key });
    }
    fn action(ptr: ?*anyopaque, id: usize) void {
        const self = cast(Settings, ptr);
        if (id == self.view.close) {
            self.ui.close();
            return;
        }
        if (id == self.view.wifi_nav or id == self.view.back) {
            self.showPage(.wifi);
            return;
        }
        if (id == self.view.network_nav) {
            self.showPage(.network);
            return;
        }
        if (id == self.view.saved) {
            self.showPage(.saved);
            return;
        }
        if (id == self.view.hidden) {
            self.showPage(.hidden);
            return;
        }
        if (id == self.view.search) {
            self.showSearch();
            return;
        }
        if (id == self.view.connect) {
            wifiConnect(null, self);
            return;
        }
        for (self.rows.items) |row| {
            if (id == row.details) {
                const client = self.network_client orelse return;
                if (row.profile) |path| {
                    _ = editor.Editor.create(self.window, client.state().profile(path) orelse return);
                } else if (row.kind == .access_point) {
                    self.editAccessPoint(row.key);
                } else {
                    _ = editor.Editor.create(self.window, null);
                }
                return;
            }
            if (row.remove == id) {
                _ = self.ui.select(self.profiles.id, row.key);
                self.forget();
                return;
            }
            if (id != row.item) continue;
            switch (row.kind) {
                .access_point => if (!row.connected) self.connectAccessPoint(row.key),
                .profile => {
                    _ = self.ui.select(self.profiles.id, row.key);
                    self.profileAction(if (row.connected) .deactivate else .activate);
                },
                .device => {
                    if (row.connected) self.networkAction(.{ .disconnect = row.key }) else if (row.profile) |path| self.networkAction(.{ .activate = path }) else {
                        _ = editor.Editor.create(self.window, null);
                    }
                },
            }
            return;
        }
        const title = self.ui.get(id).title;
        if (eq(title, "Refresh")) self.refresh() else if (eq(title, "Enable Wi-Fi")) self.networkAction(.{ .wifi = true }) else if (eq(title, "Disable Wi-Fi")) self.networkAction(.{ .wifi = false }) else if (eq(title, "Connect to Wi-Fi")) wifiConnect(null, self) else if (eq(title, "Connect")) self.profileAction(.activate) else if (eq(title, "Disconnect")) self.profileAction(.deactivate) else if (eq(title, "Forget…")) self.forget() else if (eq(title, "Disconnect device")) {
            if (self.devices.selectedId()) |key| self.networkAction(.{ .disconnect = key });
        } else if (eq(title, "New connection…")) {
            _ = editor.Editor.create(self.window, null);
        } else if (eq(title, "Edit connection…")) {
            const client = self.network_client orelse return;
            const key = self.profiles.selectedId() orelse {
                self.setMessage("Select a saved connection first.");
                return;
            };
            _ = editor.Editor.create(self.window, client.state().profile(key) orelse return);
        }
    }
    fn editAccessPoint(self: *Settings, path: [:0]const u8) void {
        const client = self.network_client orelse return;
        const ap = client.state().ap(path) orelse return;
        _ = editor.Editor.createWireless(self.window, ap);
    }
    fn connectAccessPoint(self: *Settings, path: [:0]const u8) void {
        const client = self.network_client orelse return;
        const ap = client.state().ap(path) orelse return;
        for (client.state().profiles.items) |profile| if (eq(profile.kind, "802-11-wireless") and eq(profile.ssid, ap.ssid)) {
            self.networkAction(.{ .connect = .{ .ssid = ap.ssid, .access_point = ap.path } });
            return;
        };
        if (ap.security == .enterprise) {
            self.editAccessPoint(path);
            return;
        }
        if (!ap.passwordRequired()) {
            self.networkAction(.{ .connect = .{ .ssid = ap.ssid, .access_point = ap.path } });
            return;
        }
        const owned_path = z(path);
        defer a.free(owned_path);
        const dialog = auth.Dialog.createWithOptions(.password, ap.title, .{ .title = "Authentication Required", .role = "desktop-network-auth", .accept = "Connect", .cancel = "Cancel", .icon = "network-wireless-symbolic" }) catch return;
        defer dialog.destroy();
        dialog.window.parent = self.window;
        self.network_operations += 1;
        self.sensitivity();
        while (true) {
            dialog.run();
            if (!dialog.accepted or (dialog.validatePassword() catch false)) break;
        }
        self.network_operations -= 1;
        if (self.closed) return;
        self.sensitivity();
        if (dialog.accepted) if (self.network_client) |current| if (current.state().ap(owned_path)) |point| {
            self.networkAction(.{ .connect = .{ .ssid = point.ssid, .access_point = point.path, .password = dialog.entry.?.buffer.value() } });
        };
    }
};

pub const Service = struct {
    windows: std.ArrayList(*Settings) = .empty,
    sounds: std.ArrayList(*Sound) = .empty,

    pub fn show(self: *Service, app: *c.GtkApplication, mode: Mode) !void {
        self.reap();
        if (mode == .sound) {
            for (self.sounds.items) |sound| {
                if (!sound.closed) {
                    c.gtk_window_present(cast(c.GtkWindow, sound.window));
                    return;
                }
            }
            try self.sounds.ensureUnusedCapacity(a, 1);
            const sound = try Sound.create();
            self.sounds.appendAssumeCapacity(sound);
            c.gtk_application_add_window(app, cast(c.GtkWindow, sound.window));
            return;
        }
        for (self.windows.items) |settings| {
            if (!settings.closed and settings.mode == mode) {
                settings.ui.show();
                return;
            }
        }
        try self.windows.ensureUnusedCapacity(a, 1);
        const settings = Settings.create(mode);
        self.windows.appendAssumeCapacity(settings);
        settings.window.hold(@ptrCast(app));
    }

    pub fn reap(self: *Service) void {
        var sound_index: usize = 0;
        while (sound_index < self.sounds.items.len) {
            const sound = self.sounds.items[sound_index];
            if (sound.closed and sound.operations == 0) {
                _ = self.sounds.orderedRemove(sound_index);
                sound.destroy();
            } else sound_index += 1;
        }
        var i: usize = 0;
        while (i < self.windows.items.len) {
            const settings = self.windows.items[i];
            if (settings.closed and settings.network_operations == 0) {
                _ = self.windows.orderedRemove(i);
                settings.destroy();
            } else i += 1;
        }
    }

    pub fn deinit(self: *Service) void {
        for (self.sounds.items) |sound| if (!sound.closed) c.gtk_widget_destroy(sound.window);
        for (self.windows.items) |settings| if (!settings.closed) settings.ui.close();
        while (self.windows.items.len > 0 or self.sounds.items.len > 0) {
            self.reap();
            if (self.windows.items.len > 0 or self.sounds.items.len > 0) _ = c.g_main_context_iteration(null, 1);
        }
        self.windows.deinit(a);
        self.sounds.deinit(a);
    }
};
