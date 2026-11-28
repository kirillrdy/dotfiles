//! One settings window with Wi-Fi, Network, and Sound pages.
const std = @import("std");
const keyboard = @import("desktop-keyboard.zig");
const mainloop = @import("desktop-loop.zig");
const util = @import("desktop-util.zig");
pub const SoundControl = @import("desktop-sound-view.zig").Control;
pub const Sound = @import("desktop-sound-settings.zig").Sound;
const network = @import("desktop-network.zig");
const editor = @import("desktop-network-editor.zig");
const native = @import("desktop-form.zig");
const auth = @import("desktop-auth-dialog.zig");
const network_view = @import("desktop-network-view.zig");
const wire = native.host.wire;
const input = @import("desktop-input.zig");
const raster = @import("desktop-raster.zig");
fn cast(comptime T: type, ptr: anytype) *T { return @ptrCast(@alignCast(ptr)); }
fn eq(a: []const u8, b: []const u8) bool { return std.mem.eql(u8, a, b); }
fn z(a: std.mem.Allocator, value: []const u8) [:0]u8 {
    return a.dupeSentinel(u8, value, 0) catch @panic("out of memory");
}
pub const Mode = enum { sound, network };
const Page = struct {
    context: ?*anyopaque,
    events: input.Events,
    layout: *const fn (*native.Form) void,
    paint: *const fn (*native.Form, raster.Buffer, u32) anyerror!void,
    deactivate: ?*const fn (?*anyopaque) void = null,
};
pub const Settings = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mode: Mode = .network,
    sound: ?*Sound = null,
    form_input: input.Events = .{},
    page: Page = undefined,
    window: *native.host.Window,
    ui: *native.Form,
    message: *native.Item,
    network_client: ?*network.Client = null,
    network_operations: usize = 0,
    closed: bool = false,
    audio_cancel: *mainloop.Cancellable,
    manual: *native.Item,
    password: *native.Item,
    view: network_view.View = .{},
    rows: std.ArrayList(network_view.Row) = .empty,
    row_arena: std.heap.ArenaAllocator,
    dynamic_start: usize = 0,
    initial_page: bool = true,
    pub fn create(a: std.mem.Allocator, io: std.Io, mode: Mode) *Settings {
        const self = a.create(Settings) catch @panic("out of memory");
        const ui = native.Form.create(a, io, "Settings", self, &action, &fieldChanged) catch @panic("out of memory");
        self.* = .{ .allocator = a, .io = io, .row_arena = .init(a), .window = ui.window, .ui = ui, .audio_cancel = mainloop.Cancellable.create(io), .message = undefined, .manual = undefined, .password = undefined };
        self.manual = self.add(.entry, "Wi-Fi network name", "Enter the hidden network’s name", false);
        self.password = self.add(.entry, "Password", "Leave empty for a saved or open network", true);
        self.message = ui.get(ui.addPinned(.label, "") catch @panic("out of memory"));
        self.view = .{
            .wifi_nav = ui.add(.button, "Wi-Fi", "", false) catch @panic("out of memory"),
            .network_nav = ui.add(.button, "Network", "", false) catch @panic("out of memory"),
            .sound_nav = ui.add(.button, "Sound", "", false) catch @panic("out of memory"),
            .wifi = ui.add(.toggle, "Wi-Fi", "", false) catch @panic("out of memory"),
            .saved = ui.add(.button, "Saved Networks", "", false) catch @panic("out of memory"),
            .hidden = ui.add(.button, "Connect to Hidden Network…", "", false) catch @panic("out of memory"),
            .hotspot = ui.add(.label, "Turn On Wi-Fi Hotspot…", "", false) catch @panic("out of memory"),
            .back = ui.add(.button, "Back", "", false) catch @panic("out of memory"),
            .close = ui.add(.button, "Close", "", false) catch @panic("out of memory"),
            .search = ui.add(.button, "Search Networks", "", false) catch @panic("out of memory"),
            .query = ui.add(.entry, "Search Networks", "", false) catch @panic("out of memory"),
            .new_connection = ui.add(.button, "New connection…", "", false) catch @panic("out of memory"),
            .manual = self.manual.id,
            .password = self.password.id,
            .connect = ui.add(.button, "Connect", "", false) catch @panic("out of memory"),
            .refresh = ui.add(.button, "Refresh", "", false) catch @panic("out of memory"),
            .message = self.message.id,
        };
        for ([_]usize{ self.view.wifi_nav, self.view.network_nav, self.view.sound_nav, self.view.back, self.view.close, self.view.search }) |id| ui.get(id).always_enabled = true;
        ui.get(self.view.refresh).always_enabled = true;
        self.dynamic_start = ui.items.items.len;
        self.window.surface.?.options.namespace = "org.dotfiles.Settings";
        self.window.setSize(980, 700);
        ui.window.surface.?.options.min_width = 680;
        ui.window.surface.?.options.min_height = 400;
        ui.scrolled = &scroll;
        ui.shortcut = &shortcut;
        ui.reveal = &reveal;
        self.network_client = network.Client.create(a, io, &networkChanged, self) catch null;
        ui.close_callback = &destroyed;
        self.form_input = ui.window.surface.?.input;
        self.page = self.networkPage();
        const events = &ui.window.surface.?.input;
        events.button = &button;
        events.motion = &motion;
        events.leave = &leave;
        events.symbol = &symbolEvent;
        events.focus = &focusChanged;
        events.scroll = &scrolled;
        self.selectMode(mode);
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
    fn networkPage(self: *Settings) Page {
        return .{ .context = self.ui, .events = self.form_input, .layout = &layoutNetwork, .paint = &paintNetwork };
    }
    fn layoutNetwork(ui: *native.Form) void {
        const self = cast(Settings, ui.context);
        self.view.layout(ui);
    }
    fn paintNetwork(ui: *native.Form, target: raster.Buffer, scale: u32) !void {
        const self = cast(Settings, ui.context);
        try self.view.paint(ui, target, scale);
    }
    fn paintSound(ui: *native.Form, target: raster.Buffer, _: u32) !void {
        try cast(Settings, ui.context).sound.?.paint(target);
    }
    fn deactivateSound(ptr: ?*anyopaque) void {
        cast(Sound, ptr).deactivate();
    }
    pub fn selectMode(self: *Settings, mode: Mode) void {
        if (self.closed) return;
        if (self.page.deactivate) |callback| callback(self.page.context);
        self.ui.focus = null;
        self.ui.hover = null;
        self.ui.pressed = null;
        self.ui.expanded = null;
        self.mode = mode;
        self.page = switch (mode) {
            .network => self.networkPage(),
            .sound => blk: {
                if (self.sound == null) self.sound = Sound.create(self.allocator, self.window, self, &navigateSound) catch @panic("out of memory");
                break :blk .{
                    .context = self.sound.?,
                    .events = .{ .button = &Sound.button, .motion = &Sound.motion, .leave = &Sound.leave, .focus = &Sound.focusChanged, .scroll = &Sound.scrolled, .symbol = &Sound.key },
                    .layout = &@import("desktop-preferences-view.zig").reset,
                    .paint = &paintSound,
                    .deactivate = &deactivateSound,
                };
            },
        };
        self.ui.layout = self.page.layout;
        self.ui.painter = self.page.paint;
        self.ui.relayout();
    }
    fn navigateSound(ptr: ?*anyopaque, control: SoundControl) void {
        const self = cast(Settings, ptr);
        switch (control) {
            .wifi_nav => self.showPage(.wifi),
            .network_nav => self.showPage(.network),
            .sound_nav => self.sound.?.showPage(.sound),
            else => unreachable,
        }
    }
    fn button(ptr: ?*anyopaque, surface: *wire.Surface, code: u32, pressed: bool, x: f64, y: f64) void {
        const self = owner(ptr);
        if (self.closed or self.window.blocked()) return;
        self.page.events.button.?(self.page.context, surface, code, pressed, x, y);
    }
    fn motion(ptr: ?*anyopaque, surface: *wire.Surface, x: f64, y: f64) void {
        const self = owner(ptr);
        if (self.closed or self.window.blocked()) return;
        self.page.events.motion.?(self.page.context, surface, x, y);
    }
    fn leave(ptr: ?*anyopaque, surface: *wire.Surface) void {
        const self = owner(ptr);
        if (self.closed or self.window.blocked()) return;
        self.page.events.leave.?(self.page.context, surface);
    }
    fn focusChanged(ptr: ?*anyopaque, surface: *wire.Surface, focused: bool) void {
        const self = owner(ptr);
        if (self.closed or self.window.blocked()) return;
        self.page.events.focus.?(self.page.context, surface, focused);
    }
    fn scrolled(ptr: ?*anyopaque, surface: *wire.Surface, axis: u32, delta: f64) void {
        const self = owner(ptr);
        if (self.closed or self.window.blocked()) return;
        self.page.events.scroll.?(self.page.context, surface, axis, delta);
    }
    fn symbolEvent(ptr: ?*anyopaque, surface: *wire.Surface, symbol: u32, modifiers: u32, pressed: bool) bool {
        const self = owner(ptr);
        if (self.closed or self.window.blocked()) return true;
        return self.page.events.symbol.?(self.page.context, surface, symbol, modifiers, pressed);
    }
    fn owner(ptr: ?*anyopaque) *Settings {
        return cast(Settings, cast(native.Form, ptr).context);
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
        if ((symbol == 'f' or symbol == 'F') and modifiers & keyboard.control != 0) {
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
        self.selectMode(.network);
        self.initial_page = false;
        self.view.searching = false;
        self.ui.setText(self.view.query, "") catch {};
        self.view.page = page;
        self.view.offset = 0;
        self.password.entry.?.clear();
        self.ui.focus = null;
        self.renderCurrent();
    }
    fn renderCurrent(self: *Settings) void {
        if (self.network_client) |client| self.renderNetwork(client.state()) else self.ui.relayout();
    }
    fn sensitivity(self: *Settings) void {
        const idle = self.network_operations == 0;
        self.ui.get(self.view.refresh).enabled = idle;
        self.view.busy = !idle;
        self.ui.setEnabled(idle and self.network_client != null and self.network_client.?.state().available);
    }
    pub fn destroy(self: *Settings) void {
        std.debug.assert(self.closed and self.network_operations == 0 and (self.sound == null or self.sound.?.operations == 0));
        self.audio_cancel.unref();
        if (self.sound) |sound| sound.destroy();
        self.ui.deinit();
        self.view.deinit(self.allocator);
        self.rows.deinit(self.allocator);
        self.row_arena.deinit();
        self.allocator.destroy(self);
    }
    fn destroyed(ptr: ?*anyopaque) void {
        const self = cast(Settings, ptr);
        self.closed = true;
        if (self.sound) |sound| sound.shutdown();
        self.audio_cancel.cancel();
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
            focused_path = z(self.allocator, row.key);
            focused_part = if (id == row.details) .details else if (row.remove == id) .remove else .row;
            break;
        };
        defer if (focused_path) |path| self.allocator.free(path);
        self.view.rows = &.{};
        self.rows.clearRetainingCapacity();
        _ = self.row_arena.reset(.retain_capacity);
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
        self.rebuildRows(state);
        self.sensitivity();
    }
    fn addNetworkRow(self: *Settings, title: [:0]const u8, row: network_view.Row) void {
        var next = row;
        // Rows outlive the backend snapshot, including while a dialog runs.
        const allocator = self.row_arena.allocator();
        next.key = allocator.dupeSentinel(u8, row.key, 0) catch @panic("out of memory");
        if (row.profile) |path| next.profile = allocator.dupeSentinel(u8, path, 0) catch @panic("out of memory");
        next.item = self.ui.add(.button, title, "", false) catch @panic("out of memory");
        next.details = self.ui.add(.button, "Network Options", "", false) catch @panic("out of memory");
        if (self.view.page == .saved) next.remove = self.ui.add(.button, "Forget", "", false) catch @panic("out of memory");
        self.rows.append(self.allocator, next) catch @panic("out of memory");
    }
    fn rebuildRows(self: *Settings, state: *const network.State) void {
        const query = self.ui.get(self.view.query).value();
        if (self.view.page == .wifi and state.available and state.wifi_enabled and state.hardware_enabled) {
            var seen: std.StringHashMap(void) = .init(self.row_arena.allocator());
            for (state.access_points.items) |ap| {
                if (ap.ssid.len == 0 or seen.contains(ap.ssid)) continue;
                seen.put(ap.ssid, {}) catch @panic("out of memory");
                if (!matches(ap.title, query)) continue;
                var profile: ?[:0]const u8 = null;
                for (state.profiles.items) |saved| if (eq(saved.ssid, ap.ssid) and eq(saved.kind, "802-11-wireless")) {
                    profile = saved.path;
                    break;
                };
                self.addNetworkRow(ap.title, .{ .item = 0, .details = 0, .key = ap.path, .profile = profile, .kind = .access_point, .icon = network.wifiIcon(ap.strength), .subtitle = if (ap.connected) "Connected" else "", .connected = ap.connected, .secure = ap.passwordRequired(), .strength = ap.strength });
            }
        } else if (self.view.page == .saved) {
            for (state.profiles.items) |profile| {
                if (!eq(profile.kind, "802-11-wireless")) continue;
                if (!matches(profile.title, query)) continue;
                self.addNetworkRow(profile.title, .{ .item = 0, .details = 0, .key = profile.path, .profile = profile.path, .kind = .profile, .icon = "network-wireless-symbolic", .subtitle = if (profile.active) "Connected" else "", .connected = profile.active });
            }
        } else if (self.view.page == .network) {
            for (state.devices.items) |device| {
                if (device.kind == 2 or device.kind == 32 or eq(device.interface, "lo")) continue;
                var profile: ?[:0]const u8 = null;
                for (state.profiles.items) |saved| if (eq(saved.kind, "802-3-ethernet")) {
                    profile = saved.path;
                    break;
                };
                self.addNetworkRow(if (device.kind == 1) "Wired" else device.interface, .{ .item = 0, .details = 0, .key = device.path, .profile = profile, .kind = .device, .icon = "network-wired-symbolic", .subtitle = network.deviceState(device.state), .connected = device.state == 100 });
            }
            for (state.profiles.items) |profile| {
                if (eq(profile.kind, "802-11-wireless") or eq(profile.kind, "802-3-ethernet")) continue;
                self.addNetworkRow(profile.title, .{ .item = 0, .details = 0, .key = profile.path, .profile = profile.path, .kind = .profile, .icon = "network-vpn-symbolic", .subtitle = if (profile.active) "Connected" else "Not connected", .connected = profile.active });
            }
        }
        if (self.view.page == .wifi or self.view.page == .saved) std.mem.sort(network_view.Row, self.rows.items, self, lessRow);
    }
    fn matches(title: [:0]const u8, query: [:0]const u8) bool {
        return @import("desktop-unicode.zig").containsCaseless(title, query);
    }
    fn lessRow(self: *Settings, left: network_view.Row, right: network_view.Row) bool {
        if (left.connected != right.connected) return left.connected;
        if (left.strength != right.strength) return left.strength > right.strength;
        return std.ascii.lessThanIgnoreCase(self.ui.get(left.item).title, self.ui.get(right.item).title);
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
    }
    fn connectHidden(self: *Settings) void {
        self.networkAction(.{ .connect = .{ .ssid = self.manual.value(), .password = self.password.value(), .hidden = true } });
        self.password.entry.?.clear();
    }
    fn forget(self: *Settings, key: [:0]const u8) void {
        const owned_key = z(self.allocator, key);
        defer self.allocator.free(owned_key);
        const dialog = auth.Dialog.createWithOptions(self.allocator, self.io, .confirm, "Forget the selected connection and its saved credentials?", .{ .title = "Forget Connection", .role = "desktop-network-forget", .accept = "Forget", .cancel = "Cancel" }) catch return;
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
        if (id == self.view.sound_nav) {
            self.selectMode(.sound);
            return;
        }
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
            self.connectHidden();
            return;
        }
        for (self.rows.items) |row| {
            if (id == row.details) {
                const client = self.network_client orelse return;
                if (row.profile) |path| {
                    _ = editor.Editor.create(self.window, self.io, client.state().profile(path) orelse return);
                } else if (row.kind == .access_point) {
                    self.editAccessPoint(row.key);
                } else {
                    _ = editor.Editor.create(self.window, self.io, null);
                }
                return;
            }
            if (row.remove == id) {
                self.forget(row.key);
                return;
            }
            if (id != row.item) continue;
            switch (row.kind) {
                .access_point => if (!row.connected) self.connectAccessPoint(row.key),
                .profile => self.networkAction(if (row.connected) .{ .deactivate = row.key } else .{ .activate = row.key }),
                .device => {
                    if (row.connected) self.networkAction(.{ .disconnect = row.key }) else if (row.profile) |path| self.networkAction(.{ .activate = path }) else {
                        _ = editor.Editor.create(self.window, self.io, null);
                    }
                },
            }
            return;
        }
        if (id == self.view.refresh) self.refresh() else if (id == self.view.new_connection) {
            _ = editor.Editor.create(self.window, self.io, null);
        }
    }
    fn editAccessPoint(self: *Settings, path: [:0]const u8) void {
        const client = self.network_client orelse return;
        const ap = client.state().ap(path) orelse return;
        _ = editor.Editor.createWireless(self.window, self.io, ap);
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
        const owned_path = z(self.allocator, path);
        defer self.allocator.free(owned_path);
        const dialog = auth.Dialog.createWithOptions(self.allocator, self.io, .password, ap.title, .{ .title = "Authentication Required", .role = "desktop-network-auth", .accept = "Connect", .cancel = "Cancel" }) catch return;
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
    allocator: std.mem.Allocator,
    io: std.Io,
    windows: std.ArrayList(*Settings) = .empty,
    pub fn show(self: *Service, mode: Mode) !void {
        self.reap();
        for (self.windows.items) |settings| {
            if (!settings.closed) {
                settings.selectMode(mode);
                settings.ui.show();
                return;
            }
        }
        try self.windows.ensureUnusedCapacity(self.allocator, 1);
        const settings = Settings.create(self.allocator, self.io, mode);
        self.windows.appendAssumeCapacity(settings);
    }

    pub fn reap(self: *Service) void {
        var i: usize = 0;
        while (i < self.windows.items.len) {
            const settings = self.windows.items[i];
            if (settings.closed and settings.network_operations == 0 and (settings.sound == null or settings.sound.?.operations == 0)) {
                _ = self.windows.orderedRemove(i);
                settings.destroy();
            } else i += 1;
        }
    }

    pub fn deinit(self: *Service) void {
        for (self.windows.items) |settings| if (!settings.closed) settings.ui.close();
        while (self.windows.items.len > 0) {
            self.reap();
            if (self.windows.items.len > 0) _ = mainloop.iteration(self.io, true);
        }
        self.windows.deinit(self.allocator);
    }
};
