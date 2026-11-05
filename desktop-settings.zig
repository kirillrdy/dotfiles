//! Settings windows using native form controls and the existing system services.
const std = @import("std");
pub const c = @import("desktop-gtk.zig");
pub const SoundControl = @import("desktop-sound-view.zig").Control;
pub const Sound = @import("desktop-sound-settings.zig").Sound;
const network = @import("desktop-network.zig");
const editor = @import("desktop-network-editor.zig");
const native = @import("desktop-form.zig");
const auth = @import("desktop-auth-dialog.zig");
const a = if (@import("builtin").is_test) std.testing.allocator else std.heap.page_allocator;
const cast = c.__zig.cast;
const eq = c.__zig.eq;
fn z(value: []const u8) [:0]u8 {
    return a.dupeSentinel(u8, value, 0) catch @panic("out of memory");
}
pub const Mode = enum { sound, network };
pub const Settings = struct {
    mode: Mode = .network,
    window: *c.GtkWidget,
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
    pub fn create(mode: Mode) *Settings {
        std.debug.assert(mode == .network);
        const self = a.create(Settings) catch @panic("out of memory");
        const ui = native.Form.create("Network", self, &action, &fieldChanged) catch @panic("out of memory");
        self.* = .{ .window = ui.window, .ui = ui, .audio_cancel = c.g_cancellable_new().?, .message = undefined, .refresh_button = undefined, .ssids = undefined, .manual = undefined, .password = undefined, .hidden = undefined, .profiles = undefined, .devices = undefined, .status = undefined };
        c.gtk_window_set_icon_name(cast(c.GtkWindow, self.window), "preferences-system-network");
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
        _ = self.add(.button, "Connect to Wi-Fi", "", false);
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
        self.network_client = network.Client.create(&networkChanged, self) catch null;
        _ = c.g_signal_connect_data(self.window, "destroy", @ptrCast(&destroyed), self, null, 0);
        ui.show();
        self.refresh();
        return self;
    }
    fn add(self: *Settings, kind: native.Kind, title: [:0]const u8, hint: [:0]const u8, secret: bool) *native.Item {
        return self.ui.get(self.ui.add(kind, title, hint, secret) catch @panic("out of memory"));
    }
    pub fn setMessage(self: *Settings, message: [:0]const u8) void {
        self.ui.setText(self.message.id, message) catch {};
        if (message.len != 0) self.ui.focusItem(self.message.id);
    }
    fn sensitivity(self: *Settings) void {
        const idle = self.network_operations == 0;
        self.refresh_button.enabled = idle;
        self.ui.setEnabled(idle and self.network_client != null and self.network_client.?.state().available);
    }
    pub fn destroy(self: *Settings) void {
        std.debug.assert(self.closed and self.network_operations == 0);
        c.g_object_unref(self.audio_cancel);
        self.ui.deinit();
        a.destroy(self);
    }
    fn destroyed(_: *c.GtkWidget, ptr: c.gpointer) callconv(.c) void {
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
        self.sensitivity();
    }
    pub fn selectAP(self: *Settings, path: []const u8) bool {
        if (!self.ui.select(self.ssids.id, path)) return false;
        fieldChanged(self, self.ssids.id);
        return true;
    }
    fn fieldChanged(ptr: ?*anyopaque, id: usize) void {
        const self = cast(Settings, ptr);
        if (self.closed) return;
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
    fn cancelForget(_: *c.GtkWidget, ptr: c.gpointer) callconv(.c) void {
        cast(auth.Dialog, ptr).respond(false);
    }
    fn forget(self: *Settings) void {
        const key = self.profiles.selectedId() orelse return;
        const owned_key = z(key);
        defer a.free(owned_key);
        const dialog = auth.Dialog.createWithOptions(.confirm, "Forget the selected connection and its saved credentials?", .{ .title = "Forget Connection", .role = "desktop-network-forget", .accept = "Forget", .cancel = "Cancel", .icon = "network-wireless" }) catch return;
        defer dialog.destroy();
        c.gtk_window_set_transient_for(cast(c.GtkWindow, dialog.window), cast(c.GtkWindow, self.window));
        const handler = c.g_signal_connect_data(self.window, "destroy", @ptrCast(&cancelForget), dialog, null, 0);
        // Hold the controller across the nested dialog loop, even if its parent closes.
        self.network_operations += 1;
        self.sensitivity();
        dialog.run();
        const accepted = dialog.accepted;
        c.g_signal_handler_disconnect(self.window, handler);
        self.network_operations -= 1;
        if (self.closed) return;
        self.sensitivity();
        if (accepted) self.networkAction(.{ .forget = owned_key });
    }
    fn action(ptr: ?*anyopaque, id: usize) void {
        const self = cast(Settings, ptr);
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
                c.gtk_window_present(cast(c.GtkWindow, settings.window));
                return;
            }
        }
        try self.windows.ensureUnusedCapacity(a, 1);
        const settings = Settings.create(mode);
        self.windows.appendAssumeCapacity(settings);
        c.gtk_application_add_window(app, cast(c.GtkWindow, settings.window));
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
        for (self.windows.items) |settings| if (!settings.closed) c.gtk_widget_destroy(settings.window);
        while (self.windows.items.len > 0 or self.sounds.items.len > 0) {
            self.reap();
            if (self.windows.items.len > 0 or self.sounds.items.len > 0) _ = c.g_main_context_iteration(null, 1);
        }
        self.windows.deinit(a);
        self.sounds.deinit(a);
    }
};
