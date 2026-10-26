//! Small GTK settings clients using the desktop's existing system services.
const std = @import("std");
pub const c = @import("gtk");
const a = std.heap.page_allocator;
fn cast(comptime T: type, p: anytype) *T {
    return @ptrCast(@alignCast(p));
}
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

/// nmcli's terse format escapes both colons and backslashes. Never split it
/// with a plain ':' tokenizer: SSIDs and connection names may contain either.
pub fn fields(comptime count: usize, allocator: std.mem.Allocator, line: []const u8) ![count][]const u8 {
    var result: [count][]const u8 = undefined;
    var field: std.ArrayList(u8) = .empty;
    defer field.deinit(allocator);
    var index: usize = 0;
    var pos: usize = 0;
    while (pos < line.len) : (pos += 1) {
        if (line[pos] == '\\') {
            pos += 1;
            if (pos == line.len or (line[pos] != ':' and line[pos] != '\\')) return error.InvalidEscape;
        } else if (line[pos] == ':') {
            if (index >= count - 1) return error.InvalidFields;
            result[index] = try allocator.dupe(u8, field.items);
            index += 1;
            field.clearRetainingCapacity();
            continue;
        }
        try field.append(allocator, line[pos]);
    }
    if (index != count - 1) return error.InvalidFields;
    result[index] = try allocator.dupe(u8, field.items);
    return result;
}
pub const Volume = struct { percent: f64, muted: bool };
pub fn volume(text: []const u8) !Volume {
    var words = std.mem.tokenizeAny(u8, text, " \t\r\n");
    if (!std.mem.eql(u8, words.next() orelse "", "Volume:")) return error.InvalidVolume;
    const amount = try std.fmt.parseFloat(f64, words.next() orelse return error.InvalidVolume);
    if (!std.math.isFinite(amount) or amount < 0) return error.InvalidVolume;
    return .{ .percent = @min(amount * 100, 100), .muted = std.mem.indexOf(u8, text, "[MUTED]") != null };
}

pub const Mode = enum { sound, network };
const Kind = enum { snapshot, volume, wifi, profiles, devices, action, audio_action };
const Job = struct {
    owner: *Settings,
    process: *c.GSubprocess,
    next: ?*Job,
    kind: Kind,
    generation: usize,
    index: usize,
    input: ?[:0]u8,
};
pub const AudioRow = struct {
    owner: *Settings,
    id: [:0]u8,
    box: *c.GtkWidget,
    scale: *c.GtkWidget,
    mute: *c.GtkWidget,
    setting: bool = false,
    timer: c.guint = 0,
};
pub const Settings = struct {
    mode: Mode,
    window: *c.GtkWidget,
    body: *c.GtkWidget,
    message: *c.GtkWidget,
    refresh_button: *c.GtkWidget,
    rows: std.ArrayList(*AudioRow) = .empty,
    jobs: ?*Job = null,
    closed: bool = false,
    generation: usize = 0,
    queries: usize = 0,
    mutating: bool = false,
    failed: bool = false,
    ssids: ?*c.GtkWidget = null,
    password: ?*c.GtkWidget = null,
    hidden: ?*c.GtkWidget = null,
    profiles: ?*c.GtkWidget = null,
    devices: ?*c.GtkWidget = null,
    status: ?*c.GtkWidget = null,

    pub fn create(mode: Mode) *Settings {
        const self = a.create(Settings) catch @panic("out of memory");
        const window = c.gtk_window_new(c.GTK_WINDOW_TOPLEVEL);
        self.* = .{ .mode = mode, .window = window, .body = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 14), .message = label(""), .refresh_button = c.gtk_button_new_with_label("Refresh") };
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
        if (mode == .network) self.makeNetwork();
        c.gtk_widget_show_all(window);
        self.refresh();
        return self;
    }
    pub fn setMessage(self: *Settings, text: [*c]const u8) void {
        c.gtk_label_set_text(cast(c.GtkLabel, self.message), text);
    }
    fn sensitivity(self: *Settings) void {
        c.gtk_widget_set_sensitive(self.refresh_button, @intFromBool(self.queries == 0 and !self.mutating));
        c.gtk_widget_set_sensitive(self.body, @intFromBool(!self.mutating and (self.mode == .sound or self.queries == 0)));
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
        std.debug.assert(self.closed and self.jobs == null);
        self.clearRows();
        self.rows.deinit(a);
        a.destroy(self);
    }
    fn destroyed(_: *c.GtkWidget, data: c.gpointer) callconv(.c) void {
        const self: *Settings = @ptrCast(@alignCast(data));
        self.closed = true;
        for (self.rows.items) |row| {
            if (row.timer != 0) _ = c.g_source_remove(row.timer);
            row.timer = 0;
        }
        var job = self.jobs;
        // timeout forwards TERM to the backend; killing only the supervisor
        // would leave nmcli/pw-dump running after the window closes.
        while (job) |j| : (job = j.next) c.g_subprocess_send_signal(j.process, c.SIGTERM);
    }
    fn refreshClicked(_: *c.GtkButton, data: c.gpointer) callconv(.c) void {
        const self: *Settings = @ptrCast(@alignCast(data));
        self.refresh();
    }
    pub fn refresh(self: *Settings) void {
        if (self.closed or self.mutating or self.queries != 0) return;
        self.generation += 1;
        self.failed = false;
        self.setMessage("Refreshing…");
        if (self.mode == .sound) {
            self.run(&.{"pw-dump"}, .snapshot, 0, null);
        } else {
            self.run(&.{ "nmcli", "-t", "-e", "yes", "-f", "IN-USE,SSID,SIGNAL,SECURITY", "device", "wifi", "list", "--rescan", "auto" }, .wifi, 0, null);
            self.run(&.{ "nmcli", "-t", "-e", "yes", "-f", "UUID,NAME,TYPE,DEVICE", "connection", "show" }, .profiles, 0, null);
            self.run(&.{ "nmcli", "-t", "-e", "yes", "-f", "DEVICE,TYPE,STATE,CONNECTION", "device", "status" }, .devices, 0, null);
        }
    }
    pub fn run(self: *Settings, args: []const [:0]const u8, kind: Kind, index: usize, input: ?[:0]const u8) void {
        if (self.closed) return;
        var argv: [40:null]?[*:0]const u8 = @splat(null);
        std.debug.assert(args.len + 2 < argv.len);
        // Bound queries and interactive authentication; never block GTK's loop.
        argv[0] = "timeout";
        argv[1] = "40";
        for (args, 2..) |arg, i| argv[i] = arg.ptr;
        const flags: c.GSubprocessFlags = @intCast(c.G_SUBPROCESS_FLAGS_STDOUT_PIPE | c.G_SUBPROCESS_FLAGS_STDERR_PIPE | if (input != null) c.G_SUBPROCESS_FLAGS_STDIN_PIPE else @as(c_int, 0));
        const launcher = c.g_subprocess_launcher_new(flags);
        defer c.g_object_unref(launcher);
        c.g_subprocess_launcher_setenv(launcher, "LC_ALL", "C", 1);
        var err: [*c]c.GError = null;
        const process = c.g_subprocess_launcher_spawnv(launcher, @ptrCast(&argv), &err);
        if (process == null) {
            self.failed = true;
            self.setMessage(err.*.message);
            c.g_clear_error(&err);
            if (kind == .action) self.mutating = false;
            self.sensitivity();
            return;
        }
        const job = a.create(Job) catch @panic("out of memory");
        job.* = .{ .owner = self, .process = process.?, .next = self.jobs, .kind = kind, .generation = self.generation, .index = index, .input = if (input) |s| z(s) else null };
        self.jobs = job;
        if (kind != .action and kind != .audio_action) self.queries += 1;
        self.sensitivity();
        c.g_subprocess_communicate_utf8_async(process, if (job.input) |s| s.ptr else null, null, &completed, job);
    }
    fn completed(_: ?*c.GObject, result: ?*c.GAsyncResult, data: c.gpointer) callconv(.c) void {
        const job: *Job = @ptrCast(@alignCast(data));
        const self = job.owner;
        var out: [*c]u8 = null;
        var errors: [*c]u8 = null;
        var err: [*c]c.GError = null;
        const communicated = c.g_subprocess_communicate_utf8_finish(job.process, result, &out, &errors, &err) != 0;
        const ok = communicated and c.g_subprocess_get_successful(job.process) != 0;
        if (job.kind != .action and job.kind != .audio_action) self.queries -= 1;
        var link = &self.jobs;
        while (link.* != job) link = &link.*.?.next;
        link.* = job.next;
        if (!self.closed and job.generation == self.generation) {
            if (job.kind == .action) self.mutating = false;
            if (!ok) {
                self.failed = true;
                self.setMessage(if (err != null) err.*.message else if (errors != null and errors[0] != 0) errors else "The operation failed or timed out. Refresh and try again.");
            } else {
                const text = if (out != null) std.mem.span(out) else "";
                self.accept(job.kind, job.index, text) catch |failure| {
                    self.failed = true;
                    const message = z(@errorName(failure));
                    defer a.free(message);
                    self.setMessage(message);
                };
            }
            self.sensitivity();
        }
        c.g_free(out);
        c.g_free(errors);
        c.g_clear_error(&err);
        c.g_object_unref(job.process);
        if (job.input) |s| {
            @memset(s, 0);
            a.free(s);
        }
        a.destroy(job);
    }
    fn accept(self: *Settings, kind: Kind, index: usize, text: []const u8) !void {
        switch (kind) {
            .snapshot => try self.renderSound(text),
            .volume => {
                if (index < self.rows.items.len) {
                    const row = self.rows.items[index];
                    const value = try volume(text);
                    row.setting = true;
                    c.gtk_range_set_value(cast(c.GtkRange, row.scale), value.percent);
                    c.gtk_toggle_button_set_active(cast(c.GtkToggleButton, row.mute), @intFromBool(value.muted));
                    row.setting = false;
                    c.gtk_widget_set_sensitive(row.box, 1);
                }
            },
            .wifi => try self.renderWifi(text),
            .profiles => try self.renderProfiles(text),
            .devices => try self.renderDevices(text),
            .action => {
                self.notifyDevices();
                self.refresh();
                return;
            },
            .audio_action => {
                // Re-read to reflect server clamping and concurrent media keys.
                if (index < self.rows.items.len) self.run(&.{ "wpctl", "get-volume", self.rows.items[index].id }, .volume, index, null);
                self.notifyDevices();
            },
        }
        if (self.queries == 0 and !self.failed) self.setMessage("");
    }
    fn notifyDevices(_: *Settings) void {
        const app = c.g_application_get_default() orelse return;
        const bus = c.g_application_get_dbus_connection(app) orelse return;
        _ = c.g_dbus_connection_emit_signal(bus, null, "/org/dotfiles/DesktopSettings", "org.dotfiles.DesktopSettings", "DeviceChanged", null, null);
    }
    pub fn renderSound(self: *Settings, text: []const u8) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, a, text, .{});
        defer parsed.deinit();
        if (parsed.value != .array) return error.InvalidAudioSnapshot;
        const children = c.gtk_container_get_children(cast(c.GtkContainer, self.body));
        var child = children;
        while (child != null) : (child = child.*.next) c.gtk_widget_destroy(cast(c.GtkWidget, child.*.data));
        c.g_list_free(children);
        self.clearRows();
        self.audioRow("@DEFAULT_AUDIO_SINK@", "Output volume", false);
        self.audioRow("@DEFAULT_AUDIO_SOURCE@", "Microphone volume", false);
        for ([_][]const u8{ "Audio/Sink", "Audio/Source", "Stream/Output/Audio", "Stream/Input/Audio" }, [_][*:0]const u8{ "Output devices", "Input devices", "Playback applications", "Recording applications" }) |class, heading| {
            pack(self.body, label(heading));
            var count: usize = 0;
            for (parsed.value.array.items) |node| {
                if (node != .object) continue;
                const info = node.object.get("info") orelse continue;
                if (info != .object) continue;
                const props = info.object.get("props") orelse continue;
                if (props != .object) continue;
                const media = props.object.get("media.class") orelse continue;
                if (media != .string or !std.mem.eql(u8, media.string, class)) continue;
                const id = node.object.get("id") orelse continue;
                if (id != .integer or id.integer <= 0) continue;
                const name = props.object.get("node.description") orelse props.object.get("application.name") orelse props.object.get("node.nick") orelse props.object.get("node.name") orelse continue;
                if (name != .string) continue;
                const id_text = try std.fmt.allocPrintSentinel(a, "{d}", .{id.integer}, 0);
                defer a.free(id_text);
                const title = z(name.string);
                defer a.free(title);
                self.audioRow(id_text, title, std.mem.startsWith(u8, class, "Audio/"));
                count += 1;
            }
            if (count == 0) pack(self.body, label("None available"));
        }
        c.gtk_widget_show_all(self.body);
        for (self.rows.items, 0..) |row, i| self.run(&.{ "wpctl", "get-volume", row.id }, .volume, i, null);
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
        if (device) _ = button(controls, "Use by default", &defaultClicked, row);
        connect(row.scale, "value-changed", &volumeChanged, row);
        connect(row.mute, "toggled", &muteChanged, row);
        c.gtk_widget_set_sensitive(box, 0);
        pack(self.body, box);
    }
    fn rowIndex(row: *AudioRow) usize {
        for (row.owner.rows.items, 0..) |item, i| if (item == row) return i;
        unreachable;
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
        const value = std.fmt.allocPrintSentinel(a, "{d:.0}%", .{c.gtk_range_get_value(cast(c.GtkRange, row.scale))}, 0) catch @panic("out of memory");
        defer a.free(value);
        row.owner.run(&.{ "wpctl", "set-volume", "-l", "1.0", row.id, value }, .audio_action, rowIndex(row), null);
        return 0;
    }
    fn muteChanged(toggle: *c.GtkToggleButton, data: c.gpointer) callconv(.c) void {
        const row: *AudioRow = @ptrCast(@alignCast(data));
        if (row.setting) return;
        row.owner.run(&.{ "wpctl", "set-mute", row.id, if (c.gtk_toggle_button_get_active(toggle) != 0) "1" else "0" }, .audio_action, rowIndex(row), null);
    }
    fn defaultClicked(_: *c.GtkButton, data: c.gpointer) callconv(.c) void {
        const row: *AudioRow = @ptrCast(@alignCast(data));
        row.owner.action(&.{ "wpctl", "set-default", row.id }, null);
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
        _ = button(self.body, "Edit connections…", &editConnections, self);
    }
    pub fn renderWifi(self: *Settings, text: []const u8) !void {
        // Keep a manually entered SSID while refreshing the access-point list.
        const entry = cast(c.GtkEntry, c.gtk_bin_get_child(cast(c.GtkBin, self.ssids.?)));
        const selected = z(std.mem.span(c.gtk_entry_get_text(entry)));
        defer a.free(selected);
        c.gtk_combo_box_text_remove_all(cast(c.GtkComboBoxText, self.ssids.?));
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        var seen: std.StringHashMap(void) = .init(arena.allocator());
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const values = try fields(4, arena.allocator(), line);
            if (values[1].len == 0 or seen.contains(values[1])) continue;
            try seen.put(values[1], {});
            const ssid = try arena.allocator().dupeSentinel(u8, values[1], 0);
            c.gtk_combo_box_text_append(cast(c.GtkComboBoxText, self.ssids.?), ssid, ssid);
        }
        c.gtk_entry_set_text(entry, selected);
    }
    pub fn renderProfiles(self: *Settings, text: []const u8) !void {
        const combo = cast(c.GtkComboBox, self.profiles.?);
        const current = c.gtk_combo_box_get_active_id(combo);
        const selected = if (current != null) z(std.mem.span(current)) else null;
        defer if (selected) |s| a.free(s);
        c.gtk_combo_box_text_remove_all(cast(c.GtkComboBoxText, self.profiles.?));
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const values = try fields(4, arena.allocator(), line);
            const id = try arena.allocator().dupeSentinel(u8, values[0], 0);
            const name = try std.fmt.allocPrintSentinel(arena.allocator(), "{s} ({s}){s}", .{ values[1], values[2], if (values[3].len > 0 and !std.mem.eql(u8, values[3], "--")) " — connected" else "" }, 0);
            c.gtk_combo_box_text_append(cast(c.GtkComboBoxText, self.profiles.?), id, name);
        }
        if (selected == null or c.gtk_combo_box_set_active_id(combo, selected.?) == 0) c.gtk_combo_box_set_active(combo, 0);
    }
    pub fn renderDevices(self: *Settings, text: []const u8) !void {
        const combo = cast(c.GtkComboBox, self.devices.?);
        const current = c.gtk_combo_box_get_active_id(combo);
        const selected = if (current != null) z(std.mem.span(current)) else null;
        defer if (selected) |s| a.free(s);
        c.gtk_combo_box_text_remove_all(cast(c.GtkComboBoxText, self.devices.?));
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        var summary: std.ArrayList(u8) = .empty;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const values = try fields(4, arena.allocator(), line);
            if (std.mem.eql(u8, values[1], "loopback")) continue;
            const id = try arena.allocator().dupeSentinel(u8, values[0], 0);
            const name = try std.fmt.allocPrintSentinel(arena.allocator(), "{s}: {s} — {s}", .{ values[0], values[2], values[3] }, 0);
            c.gtk_combo_box_text_append(cast(c.GtkComboBoxText, self.devices.?), id, name);
            if (summary.items.len != 0) try summary.append(arena.allocator(), '\n');
            try summary.appendSlice(arena.allocator(), name);
        }
        if (selected == null or c.gtk_combo_box_set_active_id(combo, selected.?) == 0) c.gtk_combo_box_set_active(combo, 0);
        const status = try arena.allocator().dupeSentinel(u8, if (summary.items.len == 0) "No network devices available" else summary.items, 0);
        c.gtk_label_set_text(cast(c.GtkLabel, self.status.?), status);
    }
    fn action(self: *Settings, args: []const [:0]const u8, input: ?[:0]const u8) void {
        if (self.mutating or self.queries != 0) return;
        self.mutating = true;
        self.setMessage("Applying…");
        self.run(args, .action, 0, input);
    }
    fn wifiOn(_: *c.GtkButton, data: c.gpointer) callconv(.c) void {
        const self: *Settings = @ptrCast(@alignCast(data));
        self.action(&.{ "nmcli", "radio", "wifi", "on" }, null);
    }
    fn wifiOff(_: *c.GtkButton, data: c.gpointer) callconv(.c) void {
        const self: *Settings = @ptrCast(@alignCast(data));
        self.action(&.{ "nmcli", "radio", "wifi", "off" }, null);
    }
    pub fn wifiConnect(_: ?*c.GtkButton, data: c.gpointer) callconv(.c) void {
        const self: *Settings = @ptrCast(@alignCast(data));
        const ssid = c.gtk_entry_get_text(cast(c.GtkEntry, c.gtk_bin_get_child(cast(c.GtkBin, self.ssids.?))));
        if (ssid[0] == 0) {
            self.setMessage("Select a Wi-Fi network or enter its name.");
            return;
        }
        const password = c.gtk_entry_get_text(cast(c.GtkEntry, self.password.?));
        // --ask reads a missing secret from stdin. Keep it out of argv, the
        // process list and temporary files; EOF terminates additional prompts.
        const input = std.fmt.allocPrintSentinel(a, "{s}\n", .{std.mem.span(password)}, 0) catch @panic("out of memory");
        defer {
            @memset(input, 0);
            a.free(input);
        }
        self.action(&.{ "nmcli", "--wait", "30", "--ask", "device", "wifi", "connect", std.mem.span(ssid), "hidden", if (c.gtk_toggle_button_get_active(cast(c.GtkToggleButton, self.hidden.?)) != 0) "yes" else "no" }, input);
        c.gtk_entry_set_text(cast(c.GtkEntry, self.password.?), "");
    }
    fn profileAction(self: *Settings, verb: [:0]const u8) void {
        const id = c.gtk_combo_box_get_active_id(cast(c.GtkComboBox, self.profiles.?));
        if (id == null) {
            self.setMessage("Select a saved connection first.");
            return;
        }
        self.action(&.{ "nmcli", "--wait", "30", "connection", verb, "uuid", std.mem.span(id) }, null);
    }
    fn profileConnect(_: *c.GtkButton, data: c.gpointer) callconv(.c) void {
        const self: *Settings = @ptrCast(@alignCast(data));
        self.profileAction("up");
    }
    fn profileDisconnect(_: *c.GtkButton, data: c.gpointer) callconv(.c) void {
        const self: *Settings = @ptrCast(@alignCast(data));
        self.profileAction("down");
    }
    fn profileForget(_: *c.GtkButton, data: c.gpointer) callconv(.c) void {
        const self: *Settings = @ptrCast(@alignCast(data));
        if (c.gtk_combo_box_get_active_id(cast(c.GtkComboBox, self.profiles.?)) == null) return;
        const dialog = c.gtk_message_dialog_new(cast(c.GtkWindow, self.window), c.GTK_DIALOG_MODAL | c.GTK_DIALOG_DESTROY_WITH_PARENT, c.GTK_MESSAGE_QUESTION, c.GTK_BUTTONS_OK_CANCEL, "%s", @as([*:0]const u8, "Forget the selected connection and its saved credentials?"));
        const response = c.gtk_dialog_run(cast(c.GtkDialog, dialog));
        c.gtk_widget_destroy(dialog);
        if (!self.closed and response == c.GTK_RESPONSE_OK) self.profileAction("delete");
    }
    fn deviceDisconnect(_: *c.GtkButton, data: c.gpointer) callconv(.c) void {
        const self: *Settings = @ptrCast(@alignCast(data));
        const id = c.gtk_combo_box_get_active_id(cast(c.GtkComboBox, self.devices.?));
        if (id != null) self.action(&.{ "nmcli", "--wait", "30", "device", "disconnect", std.mem.span(id) }, null);
    }
    fn editConnections(_: *c.GtkButton, data: c.gpointer) callconv(.c) void {
        const self: *Settings = @ptrCast(@alignCast(data));
        var err: [*c]c.GError = null;
        // nmtui is part of the NetworkManager package already in the closure.
        const process = c.g_subprocess_new(c.G_SUBPROCESS_FLAGS_NONE, &err, @as([*:0]const u8, "ghostty"), @as([*:0]const u8, "-e"), @as([*:0]const u8, "nmtui-edit"), @as(?*anyopaque, null));
        if (process) |p| c.g_object_unref(p);
        if (err != null) self.setMessage(err.*.message);
        c.g_clear_error(&err);
    }
};

const Application = struct {
    mode: Mode,
    settings: ?*Settings = null,
    fn activate(app: *c.GtkApplication, data: c.gpointer) callconv(.c) void {
        const self: *Application = @ptrCast(@alignCast(data));
        if (self.settings == null) {
            self.settings = Settings.create(self.mode);
            c.gtk_application_add_window(app, cast(c.GtkWindow, self.settings.?.window));
        }
        c.gtk_window_present(cast(c.GtkWindow, self.settings.?.window));
    }
};
pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const args = try init.minimal.args.toSlice(arena.allocator());
    if (args.len != 2) return error.ExpectedSoundOrNetwork;
    const mode = std.meta.stringToEnum(Mode, args[1]) orelse return error.ExpectedSoundOrNetwork;
    var state = Application{ .mode = mode };
    const app = c.gtk_application_new(if (mode == .sound) "org.dotfiles.DesktopSound" else "org.dotfiles.DesktopNetwork", c.G_APPLICATION_FLAGS_NONE);
    defer c.g_object_unref(app);
    connect(app, "activate", &Application.activate, &state);
    var argv = [_:null]?[*:0]u8{try arena.allocator().dupeSentinel(u8, args[0], 0)};
    const status = c.g_application_run(cast(c.GApplication, app), 1, @ptrCast(&argv));
    if (state.settings) |settings| {
        if (!settings.closed) c.gtk_widget_destroy(settings.window);
        while (settings.jobs != null) _ = c.g_main_context_iteration(null, 1);
        settings.destroy();
    }
    if (status != 0) return error.ApplicationFailed;
}

test "escaped nmcli fields and malformed records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const values = try fields(4, arena.allocator(), "*:Cafe\\: Tokyo\\\\5G:83:WPA2 WPA3");
    try std.testing.expectEqualStrings("Cafe: Tokyo\\5G", values[1]);
    try std.testing.expectEqualStrings("", (try fields(4, arena.allocator(), "uuid:Name:wifi:"))[3]);
    try std.testing.expectError(error.InvalidFields, fields(4, arena.allocator(), "one:two"));
    try std.testing.expectError(error.InvalidEscape, fields(4, arena.allocator(), "a:b:c:bad\\"));
}
test "volume rejects invalid data and clamps amplification" {
    const muted = try volume("Volume: 0.42 [MUTED]\n");
    try std.testing.expect(muted.muted);
    try std.testing.expectApproxEqAbs(@as(f64, 42), muted.percent, 0.01);
    try std.testing.expectEqual(@as(f64, 100), (try volume("Volume: 1.5")).percent);
    try std.testing.expectError(error.InvalidVolume, volume("Volume: nan"));
    try std.testing.expectError(error.InvalidVolume, volume("Volume: -1"));
    try std.testing.expectError(error.InvalidVolume, volume("unavailable"));
}

/// Keep dialog states alive until their asynchronous jobs have completed.
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
            if (settings.closed and settings.jobs == null) {
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
