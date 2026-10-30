//! Small GTK settings clients using the desktop's existing system services.
const std = @import("std");
pub const c = @import("gtk");
const audio = @import("audio");
const network = @import("network");
const editor = @import("desktop-network-editor.zig");
// Test builds account for service state and asynchronous callback allocations.
const a = if (@import("builtin").is_test) std.testing.allocator else std.heap.page_allocator;
const cast = c.__zig.cast;
fn z(text: []const u8) [:0]u8 {
    return a.dupeSentinel(u8, text, 0) catch @panic("out of memory");
}
fn connect(widget: anytype, signal: [*:0]const u8, callback: anytype, data: anytype) void {
    _ = c.g_signal_connect_data(widget, signal, @ptrCast(callback), data, null, 0);
}
fn pack(box: *c.GtkWidget, child: *c.GtkWidget) void {
    c.gtk_box_pack_start(cast(c.GtkBox, box), child, 0, 0, 0);
}
fn label(text: [*:0]const u8) *c.GtkWidget {
    const widget = c.gtk_label_new(text);
    c.gtk_label_set_xalign(cast(c.GtkLabel, widget), 0);
    c.gtk_label_set_line_wrap(cast(c.GtkLabel, widget), 1);
    return widget;
}
fn button(box: *c.GtkWidget, text: [*:0]const u8, callback: anytype, data: anytype) *c.GtkWidget {
    const widget = c.gtk_button_new_with_label(text);
    connect(widget, "clicked", callback, data);
    pack(box, widget);
    return widget;
}

pub const Mode = enum { sound, network };
pub const AudioRow = struct {
    owner: *Settings,
    id: [:0]u8,
    box: *c.GtkWidget,
    scale: *c.GtkWidget,
    mute: *c.GtkWidget,
    setting: bool = false,
    timer: c.guint = 0,
    default_button: ?*c.GtkWidget = null,
};
pub const Settings = struct {
    mode: Mode,
    window: *c.GtkWidget,
    body: *c.GtkWidget,
    message: *c.GtkWidget,
    refresh_button: *c.GtkWidget,
    rows: std.ArrayList(*AudioRow) = .empty,
    network_client: ?*network.Client = null,
    network_operations: usize = 0,
    closed: bool = false,
    failed: bool = false,
    audio_service: ?*audio.Service = null,
    audio_cancel: *c.GCancellable,
    audio_operations: usize = 0,
    audio_layout: ?u64 = null,
    ssids: ?*c.GtkWidget = null,
    password: ?*c.GtkWidget = null,
    hidden: ?*c.GtkWidget = null,
    profiles: ?*c.GtkWidget = null,
    devices: ?*c.GtkWidget = null,
    status: ?*c.GtkWidget = null,

    pub fn create(mode: Mode) *Settings {
        const self = a.create(Settings) catch @panic("out of memory");
        const window = c.gtk_window_new(c.GTK_WINDOW_TOPLEVEL);
        self.* = .{ .mode = mode, .window = window, .body = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 14), .message = label(""), .refresh_button = c.gtk_button_new_with_label("Refresh"), .audio_cancel = c.g_cancellable_new().? };
        c.gtk_window_set_title(cast(c.GtkWindow, window), if (mode == .sound) "Sound" else "Network");
        c.gtk_window_set_default_size(cast(c.GtkWindow, window), 560, 600);
        c.gtk_window_set_icon_name(cast(c.GtkWindow, window), if (mode == .sound) "preferences-desktop-sound" else "preferences-system-network");
        const layout = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 12);
        c.gtk_container_set_border_width(cast(c.GtkContainer, layout), 18);
        c.gtk_container_add(cast(c.GtkContainer, window), layout);
        const toolbar = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8);
        pack(layout, toolbar);
        const title = label(if (mode == .sound) "Sound" else "Network");
        c.gtk_box_pack_start(cast(c.GtkBox, toolbar), title, 1, 1, 0);
        pack(toolbar, self.refresh_button);
        connect(self.refresh_button, "clicked", &refreshClicked, self);
        const scroll = c.gtk_scrolled_window_new(null, null);
        c.gtk_scrolled_window_set_policy(cast(c.GtkScrolledWindow, scroll), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
        c.gtk_container_add(cast(c.GtkContainer, scroll), self.body);
        c.gtk_box_pack_start(cast(c.GtkBox, layout), scroll, 1, 1, 0);
        pack(layout, self.message);
        c.gtk_label_set_max_width_chars(cast(c.GtkLabel, self.message), 60);
        c.gtk_label_set_selectable(cast(c.GtkLabel, self.message), 1);
        connect(window, "destroy", &destroyed, self);
        if (mode == .network) {
            self.makeNetwork();
            self.network_client = network.Client.create(&networkChanged, self) catch null;
        } else self.audio_service = audio.Service.create(&audioChanged, self) catch null;
        c.gtk_widget_show_all(window);
        self.refresh();
        return self;
    }
    pub fn setMessage(self: *Settings, text: [*c]const u8) void {
        c.gtk_label_set_text(cast(c.GtkLabel, self.message), text);
    }
    fn sensitivity(self: *Settings) void {
        const idle = self.audio_operations == 0 and self.network_operations == 0;
        c.gtk_widget_set_sensitive(self.refresh_button, @intFromBool(idle));
        const available = self.mode == .sound or (self.network_client != null and self.network_client.?.state().available);
        c.gtk_widget_set_sensitive(self.body, @intFromBool(idle and available));
    }
    fn clearRows(self: *Settings) void {
        for (self.rows.items) |row| {
            if (row.timer != 0) _ = c.g_source_remove(row.timer);
            a.free(row.id);
            a.destroy(row);
        }
        self.rows.clearRetainingCapacity();
    }
    /// The caller frees the state after asynchronous completions have drained.
    pub fn destroy(self: *Settings) void {
        std.debug.assert(self.closed and self.network_operations == 0 and self.audio_operations == 0);
        c.g_object_unref(self.audio_cancel);
        self.clearRows();
        self.rows.deinit(a);
        a.destroy(self);
    }
    fn destroyed(_: *c.GtkWidget, data: c.gpointer) callconv(.c) void {
        const self: *Settings = @ptrCast(@alignCast(data));
        self.closed = true;
        c.g_cancellable_cancel(self.audio_cancel);
        if (self.audio_service) |service| service.destroy();
        self.audio_service = null;
        for (self.rows.items) |row| {
            if (row.timer != 0) _ = c.g_source_remove(row.timer);
            row.timer = 0;
        }
        if (self.network_client) |client| client.destroy();
        self.network_client = null;
    }
    fn refreshClicked(_: *c.GtkButton, data: c.gpointer) callconv(.c) void {
        const self: *Settings = @ptrCast(@alignCast(data));
        self.refresh();
    }
    pub fn refresh(self: *Settings) void {
        if (self.closed or self.network_operations != 0 or self.audio_operations != 0) return;
        self.failed = false;
        if (self.mode == .sound) {
            self.audio_layout = null;
            if (self.audio_service) |service| self.renderSound(service) else self.setMessage("Audio service unavailable");
        } else if (self.network_client) |client| {
            client.refresh();
            if (client.state().available) self.networkAction(.scan) else self.renderNetwork(client.state());
        } else self.setMessage("NetworkManager unavailable");
    }
    fn networkChanged(ptr: ?*anyopaque, client: *network.Client) void {
        const self = cast(Settings, ptr);
        if (!self.closed) self.renderNetwork(client.state());
    }
    fn networkAction(self: *Settings, action: network.Action) void {
        if (self.closed or self.network_operations != 0) return;
        const client = self.network_client orelse {
            self.setMessage("NetworkManager unavailable");
            return;
        };
        self.failed = false;
        self.network_operations += 1;
        self.setMessage("Working…");
        self.sensitivity();
        client.perform(action, self.audio_cancel, &networkDone, self);
    }
    fn networkDone(ptr: ?*anyopaque, result: network.Result) void {
        const self = cast(Settings, ptr);
        self.network_operations -= 1;
        if (self.closed) return;
        switch (result) {
            .success => self.setMessage(""),
            .failure => |message| {
                self.failed = true;
                self.setMessage(message);
            },
        }
        if (self.network_client) |client| self.renderNetwork(client.state());
        self.sensitivity();
    }
    fn notifyDevices(_: *Settings) void {
        const app = c.g_application_get_default() orelse return;
        const bus = c.g_application_get_dbus_connection(app) orelse return;
        _ = c.g_dbus_connection_emit_signal(bus, null, "/org/dotfiles/DesktopSettings", "org.dotfiles.DesktopSettings", "DeviceChanged", null, null);
    }
    fn audioChanged(ptr: ?*anyopaque, service: *audio.Service) void {
        const self = cast(Settings, ptr);
        if (!self.closed) self.renderSound(service);
    }
    pub fn renderSound(self: *Settings, service: *audio.Service) void {
        var hash = std.hash.Wyhash.init(0);
        for (service.nodes.items) |entry| {
            hash.update(std.mem.asBytes(&entry.id));
            hash.update(std.mem.asBytes(&entry.class));
            hash.update(std.mem.sliceTo(&entry.title, 0));
            hash.update(std.mem.sliceTo(&entry.name, 0));
        }
        const layout = hash.final();
        if (self.audio_layout == null or self.audio_layout.? != layout) {
            const children = c.gtk_container_get_children(cast(c.GtkContainer, self.body));
            var child = children;
            while (child != null) : (child = child.*.next) c.gtk_widget_destroy(cast(c.GtkWidget, child.*.data));
            c.g_list_free(children);
            self.clearRows();
            self.audio_layout = layout;
            self.audioRow("@DEFAULT_AUDIO_SINK@", "Output volume", false);
            self.audioRow("@DEFAULT_AUDIO_SOURCE@", "Microphone volume", false);
            for ([_]audio.Class{ .output, .input, .playback, .recording }, [_][*:0]const u8{ "Output devices", "Input devices", "Playback applications", "Recording applications" }) |class, heading| {
                pack(self.body, label(heading));
                var count: usize = 0;
                for (service.nodes.items) |entry| {
                    if (entry.class != class) continue;
                    var buffer: [32]u8 = undefined;
                    const id = std.fmt.bufPrintSentinel(&buffer, "{d}", .{entry.id}, 0) catch unreachable;
                    self.audioRow(id, &entry.title, class == .output or class == .input);
                    count += 1;
                }
                if (count == 0) pack(self.body, label("None available"));
            }
            c.gtk_widget_show_all(self.body);
        }
        for (self.rows.items) |row| {
            const wanted = audio.target(row.id) catch continue;
            const state = service.state(wanted);
            row.setting = true;
            if (state) |value| {
                // Keep a slider being dragged until its debounced write is sent.
                if (row.timer == 0) c.gtk_range_set_value(cast(c.GtkRange, row.scale), value.percent);
                c.gtk_toggle_button_set_active(cast(c.GtkToggleButton, row.mute), @intFromBool(value.muted));
            }
            row.setting = false;
            c.gtk_widget_set_sensitive(row.box, @intFromBool(state != null));
            if (row.default_button) |button_widget| {
                const entry = service.node(wanted);
                c.gtk_widget_set_sensitive(button_widget, @intFromBool(entry != null and !entry.?.is_default));
            }
        }
        if (!service.ready) self.setMessage("Audio service unavailable") else if (!self.failed) self.setMessage("");
        self.sensitivity();
    }
    fn audioRow(self: *Settings, id: [:0]const u8, title: [*:0]const u8, device: bool) void {
        const row = a.create(AudioRow) catch @panic("out of memory");
        const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 6);
        row.* = .{ .owner = self, .id = z(id), .box = box, .scale = c.gtk_scale_new_with_range(c.GTK_ORIENTATION_HORIZONTAL, 0, 100, 1), .mute = c.gtk_check_button_new_with_label("Mute") };
        self.rows.append(a, row) catch @panic("out of memory");
        pack(box, label(title));
        const controls = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8);
        pack(box, controls);
        c.gtk_scale_set_digits(cast(c.GtkScale, row.scale), 0);
        c.gtk_scale_set_value_pos(cast(c.GtkScale, row.scale), c.GTK_POS_RIGHT);
        c.gtk_box_pack_start(cast(c.GtkBox, controls), row.scale, 1, 1, 0);
        pack(controls, row.mute);
        if (device) row.default_button = button(controls, "Use by default", &defaultClicked, row);
        connect(row.scale, "value-changed", &volumeChanged, row);
        connect(row.mute, "toggled", &muteChanged, row);
        c.gtk_widget_set_sensitive(box, 0);
        pack(self.body, box);
    }
    fn volumeChanged(_: *c.GtkRange, data: c.gpointer) callconv(.c) void {
        const row: *AudioRow = @ptrCast(@alignCast(data));
        if (row.setting or row.owner.closed) return;
        if (row.timer != 0) _ = c.g_source_remove(row.timer);
        row.timer = c.g_timeout_add(150, &setVolume, row);
    }
    fn setVolume(data: c.gpointer) callconv(.c) c.gboolean {
        const row: *AudioRow = @ptrCast(@alignCast(data));
        row.timer = 0;
        row.owner.audioAction(row.id, .{ .volume = c.gtk_range_get_value(cast(c.GtkRange, row.scale)) });
        return 0;
    }
    fn muteChanged(toggle: *c.GtkToggleButton, data: c.gpointer) callconv(.c) void {
        const row: *AudioRow = @ptrCast(@alignCast(data));
        if (row.setting) return;
        row.owner.audioAction(row.id, .{ .mute = c.gtk_toggle_button_get_active(toggle) != 0 });
    }
    fn defaultClicked(_: *c.GtkButton, data: c.gpointer) callconv(.c) void {
        const row: *AudioRow = @ptrCast(@alignCast(data));
        row.owner.audioAction(row.id, .default);
    }
    fn audioAction(self: *Settings, id: []const u8, change: audio.Change) void {
        if (self.closed) return;
        const service = self.audio_service orelse return;
        const wanted = audio.target(id) catch return;
        self.audio_operations += 1;
        self.sensitivity();
        service.apply(wanted, change, self.audio_cancel, &audioDone, self);
    }
    fn audioDone(ptr: ?*anyopaque, result: audio.Result) void {
        const self = cast(Settings, ptr);
        self.audio_operations -= 1;
        if (self.closed) return;
        switch (result) {
            .failure => |err| {
                self.failed = true;
                self.setMessage(@errorName(err).ptr);
            },
            .value => {
                self.notifyDevices();
                if (self.audio_service) |service| self.renderSound(service);
            },
        }
        self.sensitivity();
    }
    fn makeNetwork(self: *Settings) void {
        self.status = label("Loading network devices…");
        pack(self.body, self.status.?);
        const radio = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8);
        pack(self.body, radio);
        _ = button(radio, "Enable Wi-Fi", &wifiOn, self);
        _ = button(radio, "Disable Wi-Fi", &wifiOff, self);
        pack(self.body, label("Wi-Fi network"));
        self.ssids = c.gtk_combo_box_text_new_with_entry();
        pack(self.body, self.ssids.?);
        c.gtk_entry_set_placeholder_text(cast(c.GtkEntry, c.gtk_bin_get_child(cast(c.GtkBin, self.ssids.?))), "Select a network or enter its name");
        self.password = c.gtk_entry_new();
        c.gtk_entry_set_visibility(cast(c.GtkEntry, self.password.?), 0);
        c.gtk_entry_set_input_purpose(cast(c.GtkEntry, self.password.?), c.GTK_INPUT_PURPOSE_PASSWORD);
        c.gtk_entry_set_placeholder_text(cast(c.GtkEntry, self.password.?), "Password (leave empty for a saved or open network)");
        pack(self.body, self.password.?);
        self.hidden = c.gtk_check_button_new_with_label("Hidden network");
        pack(self.body, self.hidden.?);
        _ = button(self.body, "Connect to Wi-Fi", &wifiConnect, self);
        pack(self.body, label("Saved connections"));
        self.profiles = c.gtk_combo_box_text_new();
        pack(self.body, self.profiles.?);
        const profiles = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8);
        pack(self.body, profiles);
        _ = button(profiles, "Connect", &profileConnect, self);
        _ = button(profiles, "Disconnect", &profileDisconnect, self);
        _ = button(profiles, "Forget…", &profileForget, self);
        pack(self.body, label("Disconnect a device"));
        self.devices = c.gtk_combo_box_text_new();
        pack(self.body, self.devices.?);
        _ = button(self.body, "Disconnect device", &deviceDisconnect, self);
        _ = button(self.body, "Edit connection…", &editConnections, self);
        _ = button(self.body, "New connection…", &newConnection, self);
    }
    pub fn renderNetwork(self: *Settings, state: *const network.State) void {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const alloc = arena.allocator();
        const entry = cast(c.GtkEntry, c.gtk_bin_get_child(cast(c.GtkBin, self.ssids.?)));
        const manual = alloc.dupeSentinel(u8, std.mem.span(c.gtk_entry_get_text(entry)), 0) catch @panic("out of memory");
        const selected_ap = c.gtk_combo_box_get_active_id(cast(c.GtkComboBox, self.ssids.?));
        const ap_id = if (selected_ap != null) alloc.dupeSentinel(u8, std.mem.span(selected_ap), 0) catch @panic("out of memory") else null;
        c.gtk_combo_box_text_remove_all(cast(c.GtkComboBoxText, self.ssids.?));
        var seen: std.StringHashMap(void) = .init(alloc);
        for (state.access_points.items) |ap| {
            if (ap.ssid.len == 0 or seen.contains(ap.ssid)) continue;
            seen.put(ap.ssid, {}) catch @panic("out of memory");
            c.gtk_combo_box_text_append(cast(c.GtkComboBoxText, self.ssids.?), ap.path, ap.title);
        }
        if (ap_id == null or c.gtk_combo_box_set_active_id(cast(c.GtkComboBox, self.ssids.?), ap_id.?) == 0) c.gtk_entry_set_text(entry, manual);
        const profile_combo = cast(c.GtkComboBox, self.profiles.?);
        const current_profile = c.gtk_combo_box_get_active_id(profile_combo);
        const profile_id = if (current_profile != null) alloc.dupeSentinel(u8, std.mem.span(current_profile), 0) catch @panic("out of memory") else null;
        c.gtk_combo_box_text_remove_all(cast(c.GtkComboBoxText, self.profiles.?));
        for (state.profiles.items) |p| {
            const title = std.fmt.allocPrintSentinel(alloc, "{s} ({s}){s}", .{ p.title, p.kind, if (p.active) " — connected" else "" }, 0) catch @panic("out of memory");
            c.gtk_combo_box_text_append(cast(c.GtkComboBoxText, self.profiles.?), p.path, title);
        }
        if (profile_id == null or c.gtk_combo_box_set_active_id(profile_combo, profile_id.?) == 0) c.gtk_combo_box_set_active(profile_combo, 0);
        const device_combo = cast(c.GtkComboBox, self.devices.?);
        const current_device = c.gtk_combo_box_get_active_id(device_combo);
        const device_id = if (current_device != null) alloc.dupeSentinel(u8, std.mem.span(current_device), 0) catch @panic("out of memory") else null;
        c.gtk_combo_box_text_remove_all(cast(c.GtkComboBoxText, self.devices.?));
        var summary: std.ArrayList(u8) = .empty;
        for (state.devices.items) |d| {
            if (d.kind == 32 or std.mem.eql(u8, d.interface, "lo")) continue;
            const title = std.fmt.allocPrintSentinel(alloc, "{s}: {s} — {s}", .{ d.interface, network.deviceState(d.state), state.connectionName(d.active) }, 0) catch @panic("out of memory");
            c.gtk_combo_box_text_append(cast(c.GtkComboBoxText, self.devices.?), d.path, title);
            if (summary.items.len != 0) summary.append(alloc, '\n') catch @panic("out of memory");
            summary.appendSlice(alloc, title) catch @panic("out of memory");
        }
        if (device_id == null or c.gtk_combo_box_set_active_id(device_combo, device_id.?) == 0) c.gtk_combo_box_set_active(device_combo, 0);
        const status = alloc.dupeSentinel(u8, if (!state.available) "NetworkManager unavailable" else if (summary.items.len == 0) "No network devices available" else summary.items, 0) catch @panic("out of memory");
        c.gtk_label_set_text(cast(c.GtkLabel, self.status.?), status);
        self.sensitivity();
    }
    fn wifiOn(_: *c.GtkButton, ptr: c.gpointer) callconv(.c) void {
        cast(Settings, ptr).networkAction(.{ .wifi = true });
    }
    fn wifiOff(_: *c.GtkButton, ptr: c.gpointer) callconv(.c) void {
        cast(Settings, ptr).networkAction(.{ .wifi = false });
    }
    pub fn wifiConnect(_: ?*c.GtkButton, ptr: c.gpointer) callconv(.c) void {
        const self = cast(Settings, ptr);
        const client = self.network_client orelse return;
        const entered = std.mem.span(c.gtk_entry_get_text(cast(c.GtkEntry, c.gtk_bin_get_child(cast(c.GtkBin, self.ssids.?)))));
        const selected = c.gtk_combo_box_get_active_id(cast(c.GtkComboBox, self.ssids.?));
        const ap = if (selected != null) client.state().ap(std.mem.span(selected)) else null;
        const password = c.gtk_entry_get_text(cast(c.GtkEntry, self.password.?));
        self.networkAction(.{ .connect = .{ .ssid = if (ap) |p| p.ssid else entered, .password = std.mem.span(password), .hidden = c.gtk_toggle_button_get_active(cast(c.GtkToggleButton, self.hidden.?)) != 0, .access_point = if (ap) |p| p.path else null } });
        c.gtk_entry_set_text(cast(c.GtkEntry, self.password.?), "");
    }
    fn profileAction(self: *Settings, action: enum { activate, deactivate, forget }) void {
        const id = c.gtk_combo_box_get_active_id(cast(c.GtkComboBox, self.profiles.?));
        if (id == null) {
            self.setMessage("Select a saved connection first.");
            return;
        }
        self.networkAction(switch (action) {
            .activate => .{ .activate = std.mem.span(id) },
            .deactivate => .{ .deactivate = std.mem.span(id) },
            .forget => .{ .forget = std.mem.span(id) },
        });
    }
    fn profileConnect(_: *c.GtkButton, ptr: c.gpointer) callconv(.c) void {
        cast(Settings, ptr).profileAction(.activate);
    }
    fn profileDisconnect(_: *c.GtkButton, ptr: c.gpointer) callconv(.c) void {
        cast(Settings, ptr).profileAction(.deactivate);
    }
    fn profileForget(_: *c.GtkButton, ptr: c.gpointer) callconv(.c) void {
        const self = cast(Settings, ptr);
        if (c.gtk_combo_box_get_active_id(cast(c.GtkComboBox, self.profiles.?)) == null) return;
        const dialog = c.gtk_message_dialog_new(cast(c.GtkWindow, self.window), c.GTK_DIALOG_MODAL | c.GTK_DIALOG_DESTROY_WITH_PARENT, c.GTK_MESSAGE_QUESTION, c.GTK_BUTTONS_OK_CANCEL, "%s", @as([*:0]const u8, "Forget the selected connection and its saved credentials?"));
        const response = c.gtk_dialog_run(cast(c.GtkDialog, dialog));
        c.gtk_widget_destroy(dialog);
        if (!self.closed and response == c.GTK_RESPONSE_OK) self.profileAction(.forget);
    }
    fn deviceDisconnect(_: *c.GtkButton, ptr: c.gpointer) callconv(.c) void {
        const self = cast(Settings, ptr);
        if (c.gtk_combo_box_get_active_id(cast(c.GtkComboBox, self.devices.?))) |id| self.networkAction(.{ .disconnect = std.mem.span(id) });
    }
    fn editConnections(_: *c.GtkButton, data: c.gpointer) callconv(.c) void {
        const self = cast(Settings, data);
        const client = self.network_client orelse return;
        const id = c.gtk_combo_box_get_active_id(cast(c.GtkComboBox, self.profiles.?));
        if (id == null) {
            self.setMessage("Select a saved connection first.");
            return;
        }
        const profile = client.state().profile(std.mem.span(id)) orelse return;
        _ = editor.Editor.create(self.window, profile);
    }
    fn newConnection(_: *c.GtkButton, data: c.gpointer) callconv(.c) void {
        const self = cast(Settings, data);
        _ = editor.Editor.create(self.window, null);
    }
};

pub const Service = struct {
    windows: std.ArrayList(*Settings) = .empty,

    pub fn show(self: *Service, app: *c.GtkApplication, mode: Mode) !void {
        self.reap();
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
        var i: usize = 0;
        while (i < self.windows.items.len) {
            const settings = self.windows.items[i];
            if (settings.closed and settings.network_operations == 0 and settings.audio_operations == 0) {
                _ = self.windows.orderedRemove(i);
                settings.destroy();
            } else i += 1;
        }
    }

    pub fn deinit(self: *Service) void {
        for (self.windows.items) |settings| if (!settings.closed) c.gtk_widget_destroy(settings.window);
        while (self.windows.items.len > 0) {
            self.reap();
            if (self.windows.items.len > 0) _ = c.g_main_context_iteration(null, 1);
        }
        self.windows.deinit(a);
    }
};
