//! Native Wayland quick-settings popup with asynchronous desktop service controls.
const std = @import("std");
const gsettings = @import("desktop-gsettings.zig");
const keyboard = @import("desktop-keyboard.zig");
const mainloop = @import("desktop-loop.zig");
const util = @import("desktop-util.zig");
const wire = @import("desktop-surface.zig");
const popup = @import("desktop-popup.zig");
const Tooltip = @import("desktop-panel-view.zig").Tooltip;
const devices = @import("desktop-devices.zig");
const audio = @import("desktop-audio.zig");
const battery_backend = @import("desktop-battery.zig");
const backlight = @import("desktop-backlight.zig");
const network_backend = @import("desktop-network.zig");
const session = @import("desktop-session.zig");
const auth = @import("desktop-auth-dialog.zig");
const native = @import("desktop-quick-settings-view.zig");
pub const Target = native.Target;
const power_backend = @import("desktop-power.zig");
// Test builds account for service state and asynchronous callback allocations.
const cast = util.cast;
const Settings = @import("desktop-gsettings.zig").Settings;
fn settings(a: std.mem.Allocator, io: std.Io, schema: []const u8) ?*Settings {
    return gsettings.Settings.open(a, io, schema, null);
}
pub fn bannersEnabled(a: std.mem.Allocator, io: std.Io) bool {
    const prefs = settings(a, io, "org.gnome.desktop.notifications") orelse return true;
    defer prefs.close();
    return prefs.boolean("show-banners");
}
/// When a timed Do Not Disturb ends, as Unix seconds in a small state file so
/// that a restarted shell still turns banners back on.
fn dndDeadlinePath(buffer: []u8) ?[]const u8 {
    return std.fmt.bufPrint(buffer, "{s}/desktop/dnd-until", .{@import("desktop-paths.zig").dataHome()}) catch null;
}
fn loadDndDeadline(a: std.mem.Allocator) i64 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = dndDeadlinePath(&buffer) orelse return 0;
    const bytes = @import("desktop-paths.zig").readFile(a, path, 64) catch return 0;
    defer a.free(bytes);
    return @max(0, std.fmt.parseInt(i64, std.mem.trim(u8, bytes, " \t\r\n"), 10) catch 0);
}
fn saveDndDeadline(a: std.mem.Allocator, deadline: i64) void {
    const paths = @import("desktop-paths.zig");
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = dndDeadlinePath(&buffer) orelse return;
    if (deadline == 0 and !paths.exists(path)) return;
    paths.makeDirectories(std.fs.path.dirname(path).?, 0o700) catch |err| return std.log.warn("do not disturb: {s}", .{@errorName(err)});
    var digits: [24]u8 = undefined;
    paths.writeFileAtomic(a, path, std.fmt.bufPrint(&digits, "{d}\n", .{deadline}) catch unreachable, 0o600) catch |err| std.log.warn("do not disturb: {s}", .{@errorName(err)});
}
/// "Until 14:30", with the weekday when the deadline is not today.
fn dndSubtitle(buffer: []u8, deadline: i64, now: i64) []const u8 {
    const DateTime = @import("desktop-datetime.zig").DateTime;
    const end = DateTime.fromUnix(deadline) catch return "";
    const today = DateTime.fromUnix(now) catch return "";
    return end.format(buffer, if (end.sameDay(today)) "Until %H:%M" else "Until %a %H:%M") catch "";
}
fn unixNow(io: std.Io) i64 {
    return @divFloor(util.realTime(io), std.time.us_per_s);
}
pub const Controls = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    popup: popup.Host = undefined,
    tooltip: Tooltip = .{},
    view: native.View = .{},
    network_paths: [8]?[:0]u8 = @splat(null),
    profile_context: ?*anyopaque = null,
    profile_selected: ?*const fn (?*anyopaque, usize) void = null,
    battery_service: ?*battery_backend.Service = null,
    devices: *devices.Service,
    owns_devices: bool = false,
    subscription: devices.Subscriber = undefined,
    network_settings: [:0]u8,
    sound_settings: [:0]u8,
    interface: ?*Settings,
    notifications: ?*Settings,
    /// Unix seconds when Do Not Disturb turns itself off; 0 when untimed.
    dnd_until: i64 = 0,
    timer: u32 = 0,
    volume_timer: u32 = 0,
    brightness_timer: u32 = 0,
    backlight_backend: backlight.Backend = .{},
    brightness_busy: bool = false,
    brightness_writing: bool = false,
    brightness_wanted: ?f64 = null,
    dead: bool = false,
    refs: usize = 1,
    session_busy: bool = false,
    cancel: *mainloop.Cancellable,
    dialog: ?*auth.Dialog = null,
    dialog_power: bool = false,
    dialog_value: ?[:0]u8 = null,
    end_session: ?session.Action = null,
    end_session_seconds: u32 = 0,
    end_session_timer: u32 = 0,
    power_choices: [3]auth.native.Choice = .{
        .{ .label = "Performance" }, .{ .label = "Balanced" }, .{ .label = "Power Saver" },
    },

    pub fn redraw(self: *Controls) void {
        if (self.dead) return;
        self.view.layout();
        self.popup.redraw();
    }
    pub fn setMessage(self: *Controls, message: []const u8) void {
        self.view.model.message.set(message);
        self.redraw();
    }
    pub fn setPowerState(self: *Controls, state: power_backend.State, pending: bool) void {
        self.view.model.power_state = state;
        self.view.model.power_pending = pending;
        self.syncPowerDialog();
        self.redraw();
    }
    fn selectProfile(self: *Controls, index: usize) void {
        if (self.dead or self.view.model.power_pending or !self.view.model.power_state.available[index]) return;
        if (self.profile_selected) |callback| callback(self.profile_context, index);
    }
    pub fn activate(self: *Controls, target: native.Target) void {
        if (self.dead or !self.view.enabled(target)) return;
        switch (target) {
            .battery, .profiles => self.view.submenu = if (self.view.submenu == .profiles) .none else .profiles,
            .network => {
                self.view.submenu = if (self.view.submenu == .network) .none else .network;
                if (self.view.submenu == .network) self.networkAction(.scan);
            },
            .power => self.view.submenu = if (self.view.submenu == .power) .none else .power,
            .wifi => self.networkAction(.{ .wifi = !self.view.model.wifi_enabled }),
            .profile_toggle => self.selectProfile(if (self.view.model.power_state.active == .balanced) 2 else 1),
            .profile0, .profile1, .profile2 => self.selectProfile(@backingInt(target) - @backingInt(native.Target.profile0)),
            .dark => if (self.interface) |prefs| {
                prefs.setString("color-scheme", if (self.view.model.dark) "default" else "prefer-dark") catch {};
                self.syncPreferences();
            },
            .dnd => self.setDnd(!self.view.model.dnd, null),
            .dnd_menu => self.view.submenu = if (self.view.submenu == .dnd) .none else .dnd,
            .dnd0, .dnd1, .dnd2, .dnd3, .dnd_forever => {
                self.setDnd(true, if (target == .dnd_forever) null else native.dnd_durations[@backingInt(target) - @backingInt(native.Target.dnd0)]);
                self.view.submenu = .none;
                if (self.view.keyboard_focus) self.view.focus = .dnd_menu;
            },
            .mute => self.audioAction(.toggle),
            .sound => self.launch(self.sound_settings),
            .settings, .network_settings => self.launch(self.network_settings),
            .lock => self.launch("desktop-zig lock --daemonize"),
            .screenshot => {
                self.hide();
                self.refs += 1;
                _ = mainloop.timeout(self.io, 200, self, screenshot);
            },
            .power_settings => self.powerSettings(),
            .network0, .network1, .network2, .network3, .network4, .network5, .network6, .network7 => self.connectNetwork(@backingInt(target) - @backingInt(native.Target.network0)),
            .suspend_action => {
                self.hide();
                self.sessionAction(.@"suspend");
            },
            .reboot => self.confirmAction(.reboot),
            .poweroff => self.confirmAction(.poweroff),
            .logout => self.confirmAction(.logout),
            else => {},
        }
        self.redraw();
        if (self.view.keyboard_focus and (target == .network or target == .profiles or target == .power or target == .battery or target == .dnd_menu) and self.view.submenu != .none) {
            for (self.view.items[0..self.view.item_count]) |entry| if (entry.row and entry.enabled) {
                self.view.focus = entry.target;
                break;
            };
        }
    }
    pub fn setSlider(self: *Controls, target: native.Target, value: f64) void {
        if (self.dead or !self.view.enabled(target) or !std.math.isFinite(value)) return;
        const percent = std.math.clamp(value, if (target == .brightness) @as(f64, 1) else @as(f64, 0), 100);
        if ((target == .volume and self.view.model.volume == percent) or (target == .brightness and self.view.model.brightness == percent)) return;
        switch (target) {
            .volume => {
                self.view.model.volume = percent;
                if (self.volume_timer != 0) _ = mainloop.remove(self.io, self.volume_timer);
                self.volume_timer = mainloop.timeout(self.io, 75, self, writeVolume);
            },
            .brightness => {
                self.view.model.brightness = percent;
                if (self.brightness_timer != 0) _ = mainloop.remove(self.io, self.brightness_timer);
                self.brightness_timer = mainloop.timeout(self.io, 75, self, writeBrightness);
            },
            else => return,
        }
        self.redraw();
    }
    fn showTooltip(self: *Controls) bool {
        self.tooltip.show();
        self.redraw();
        return false;
    }
    fn draw(ptr: ?*anyopaque, target: wire.Pixels) void {
        const self = cast(Controls, ptr);
        if (self.dead) return;
        self.paint(target) catch |err| std.log.err("quick-settings render: {s}", .{@errorName(err)});
    }
    fn paint(self: *Controls, target: wire.Pixels) !void {
        const factor = self.popup.surface.?.buffer_scale;
        self.view.layout();
        try self.view.paint(self.allocator, try self.popup.canvas(self.view.width, self.view.height), factor);
        try self.popup.blit(target);
        try self.tooltip.paint(self.allocator, target, &self.view.renderer, factor);
    }
    pub fn pointerButton(self: *Controls, pressed: bool, x: f64, y: f64) void {
        if (self.dead) return;
        self.tooltip.hide(self.io);
        if (pressed) {
            self.view.keyboard_focus = false;
            self.view.hover = self.view.hit(x, y);
            self.view.pressed = self.view.hover;
            self.view.focus = self.view.hover;
            if (native.View.slider(self.view.pressed)) self.setSlider(self.view.pressed, self.view.sliderValue(self.view.pressed, x));
        } else {
            const target = self.view.pressed;
            self.view.pressed = .none;
            if (native.View.slider(target) and self.view.enabled(target)) self.setSlider(target, self.view.sliderValue(target, x)) else if (target != .none and target == self.view.hit(x, y)) self.activate(target);
        }
        self.redraw();
    }
    fn button(ptr: ?*anyopaque, _: *wire.Surface, code: u32, pressed: bool, x: f64, y: f64) void {
        if (code != 272) return;
        const self = cast(Controls, ptr);
        if (!self.popup.visible or self.popup.close_idle != 0) return;
        if (pressed and !self.popup.contains(x, y)) {
            self.requestHide();
            return;
        }
        const local = self.popup.point(x, y);
        self.pointerButton(pressed, local.x, local.y);
    }
    pub fn pointerMotion(self: *Controls, x: f64, y: f64) void {
        if (self.dead) return;
        const previous = self.view.hover;
        self.view.hover = self.view.hit(x, y);
        if (native.View.slider(self.view.pressed)) {
            self.setSlider(self.view.pressed, self.view.sliderValue(self.view.pressed, x));
        } else if (previous != self.view.hover) {
            self.redraw();
        }
    }
    fn motion(ptr: ?*anyopaque, _: *wire.Surface, x: f64, y: f64) void {
        const self = cast(Controls, ptr);
        if (!self.popup.visible or self.popup.close_idle != 0) return;
        const previous_hover = self.view.hover;
        const tooltip_was_visible = self.tooltip.visible;
        // Pointer motion can repaint synchronously when the hovered control changes.
        self.tooltip.hide(self.io);
        const local = self.popup.point(x, y);
        if (self.popup.contains(x, y) or native.View.slider(self.view.pressed)) {
            self.pointerMotion(local.x, local.y);
        } else if (self.view.hover != .none) {
            self.view.hover = .none;
            self.redraw();
        }
        const tooltip: ?[:0]const u8 = switch (self.view.hover) {
            .battery, .profiles, .profile_toggle => "Power Mode",
            .screenshot => "Take Screenshot",
            .settings => "Settings",
            .lock => "Lock Screen",
            .power => "Power Off Menu",
            .mute => if (self.view.model.muted) "Unmute" else "Mute",
            .volume => "Volume",
            .sound => "Sound Settings",
            .brightness => "Brightness",
            .network => "Wi-Fi Networks",
            .wifi => "Wi-Fi",
            .dark => "Dark Style",
            .dnd => "Do Not Disturb",
            .dnd_menu => "Pause Notifications",
            else => null,
        };
        self.tooltip.update(self.allocator, self.io, x, y, tooltip, !native.View.slider(self.view.pressed), self, showTooltip);
        if (tooltip_was_visible and previous_hover == self.view.hover) self.redraw();
    }
    fn leave(ptr: ?*anyopaque, _: *wire.Surface) void {
        const self = cast(Controls, ptr);
        self.view.hover = .none;
        self.tooltip.hide(self.io);
        self.redraw();
    }
    fn key(ptr: ?*anyopaque, _: *wire.Surface, symbol: u32, modifiers: u32, pressed: bool) bool {
        return !pressed or cast(Controls, ptr).handleKey(symbol, modifiers);
    }
    pub fn handleKey(self: *Controls, symbol: u32, modifiers: u32) bool {
        if (self.dead or self.popup.close_idle != 0) return false;
        self.tooltip.hide(self.io);
        self.view.pressed = .none;
        if (symbol == 0xff1b) {
            if (self.view.submenu != .none) {
                self.view.focus = switch (self.view.submenu) {
                    .network => .network,
                    .profiles => .profiles,
                    .power => .power,
                    .dnd => .dnd_menu,
                    .none => unreachable,
                };
                self.view.submenu = .none;
            } else {
                self.requestHide();
                return true;
            }
        } else if (symbol == 0xff09 or symbol == 0xfe20 or symbol == 0xff52 or symbol == 0xff54) {
            self.view.stepFocus(symbol == 0xfe20 or symbol == 0xff52 or (symbol == 0xff09 and modifiers & keyboard.shift != 0));
        } else if (native.View.slider(self.view.focus) and (symbol == 0xff51 or symbol == 0xff53 or symbol == 0xff50 or symbol == 0xff57)) {
            const value = if (self.view.focus == .volume) self.view.model.volume.? else self.view.model.brightness.?;
            self.setSlider(self.view.focus, if (symbol == 0xff50) 0 else if (symbol == 0xff57) 100 else value + (if (symbol == 0xff51) @as(f64, -5) else @as(f64, 5)));
        } else if (symbol == 0x20 or symbol == 0xff0d or symbol == 0xff8d) self.activate(self.view.focus) else return false;
        self.view.keyboard_focus = true;
        self.redraw();
        return true;
    }
    fn scroll(ptr: ?*anyopaque, _: *wire.Surface, axis: u32, amount: f64) void {
        const self = cast(Controls, ptr);
        if (!self.popup.visible or self.popup.close_idle != 0 or axis != 0 or !self.popup.contains(self.tooltip.x, self.tooltip.y)) return;
        const local = self.popup.point(self.tooltip.x, self.tooltip.y);
        const target = self.view.hit(local.x, local.y);
        if (!native.View.slider(target)) return;
        const value = if (target == .volume) self.view.model.volume.? else self.view.model.brightness.?;
        self.setSlider(target, value - (amount / 12) * 5);
    }

    pub fn create(a: std.mem.Allocator, io: std.Io, network_command: [*:0]const u8, sound_command: [*:0]const u8) *Controls {
        return createWithDevices(a, io, network_command, sound_command, null);
    }
    pub fn createWithDevices(a: std.mem.Allocator, io: std.Io, network_command: [*:0]const u8, sound_command: [*:0]const u8, shared: ?*devices.Service) *Controls {
        const self = a.create(Controls) catch @panic("out of memory");
        self.* = .{ .allocator = a, .io = io, .devices = shared orelse (devices.Service.create(a, io) catch @panic("out of memory")), .owns_devices = shared == null, .network_settings = a.dupeSentinel(u8, std.mem.span(network_command), 0) catch @panic("out of memory"), .sound_settings = a.dupeSentinel(u8, std.mem.span(sound_command), 0) catch @panic("out of memory"), .interface = settings(a, io, "org.gnome.desktop.interface"), .notifications = settings(a, io, "org.gnome.desktop.notifications"), .cancel = mainloop.Cancellable.create(io) };
        self.popup = .{
            .allocator = a,
            .io = io,
            .context = self,
            .namespace = "desktop-quick-settings",
            .paint = &draw,
            .input = .{ .motion = &motion, .button = &button, .leave = &leave, .symbol = &key, .scroll = &scroll },
            .resized = &resized,
            .dismiss = &dismiss,
        };
        if (self.interface) |prefs| prefs.watch(&preferencesChanged, self) catch {};
        if (self.notifications) |prefs| prefs.watch(&preferencesChanged, self) catch {};
        if (self.notifications != null) self.dnd_until = loadDndDeadline(a);
        self.syncPreferences();
        self.expireDnd();
        self.subscription = .{ .context = self, .changed = &deviceChanged };
        self.devices.subscribe(&self.subscription);
        self.timer = mainloop.timeoutSeconds(io, 5, self, refreshTimer);
        self.redraw();
        return self;
    }
    fn syncPreferences(self: *Controls) void {
        if (self.interface) |prefs| {
            var buffer: [256]u8 = undefined;
            var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
            self.view.model.dark = std.mem.eql(u8, prefs.string(fixed.allocator(), "color-scheme"), "prefer-dark");
        }
        if (self.notifications) |prefs| self.view.model.dnd = !prefs.boolean("show-banners");
        // Banners turned back on elsewhere cancel a pending timed pause.
        if (!self.view.model.dnd and self.dnd_until != 0) {
            self.dnd_until = 0;
            saveDndDeadline(self.allocator, 0);
        }
        var buffer: [64]u8 = undefined;
        self.view.model.dnd_subtitle.set(if (self.dnd_until != 0) dndSubtitle(&buffer, self.dnd_until, unixNow(self.io)) else "");
        self.view.model.dark_sensitive = self.interface != null;
        self.view.model.dnd_sensitive = self.notifications != null;
        self.redraw();
    }
    /// Turns Do Not Disturb on for `duration` seconds (null: until turned off) or off.
    fn setDnd(self: *Controls, enabled: bool, duration: ?i64) void {
        const prefs = self.notifications orelse return;
        self.dnd_until = if (enabled) if (duration) |seconds| unixNow(self.io) + seconds else 0 else 0;
        saveDndDeadline(self.allocator, self.dnd_until);
        prefs.setBoolean("show-banners", !enabled) catch {};
        self.syncPreferences();
    }
    /// Checked against the wall clock, so time spent suspended counts.
    fn expireDnd(self: *Controls) void {
        if (self.dnd_until != 0 and unixNow(self.io) >= self.dnd_until) self.setDnd(false, null);
    }
    fn preferencesChanged(ptr: ?*anyopaque, _: []const u8) void {
        const self = cast(Controls, ptr);
        if (!self.dead) self.syncPreferences();
    }

    fn dialogError(self: *Controls, err: anyerror) void {
        std.log.err("quick-settings dialog: {s}", .{@errorName(err)});
        self.setMessage("Could not open dialog. Please try again.");
    }
    fn syncPowerDialog(self: *Controls) void {
        for (&self.power_choices, 0..) |*choice, i| {
            choice.enabled = self.view.model.power_state.available[i] and !self.view.model.power_pending;
            choice.selected = if (self.view.model.power_state.active) |active| @backingInt(active) == i else false;
        }
        if (self.dialog_power) if (self.dialog) |dialog| {
            if (dialog.view.focus != .accept and !dialog.view.choiceEnabled(dialog.view.focus)) dialog.focus(.accept);
            dialog.window.redraw();
        };
    }
    fn powerSettings(self: *Controls) void {
        if (self.dialog) |dialog| {
            dialog.window.show() catch {};
            return;
        }
        self.syncPowerDialog();
        self.hide();
        const dialog = auth.Dialog.createWithOptions(self.allocator, self.io, .information, "Choose a power mode.", .{
            .title = "Power Mode",
            .role = "desktop-power-settings",
            .choices = &self.power_choices,
        }) catch |err| {
            self.dialogError(err);
            return;
        };
        self.dialog = dialog;
        self.dialog_power = true;
        dialog.choice_context = self;
        dialog.choice_selected = &dialogProfile;
        self.refs += 1;
        dialog.responded = &powerSettingsClosed;
        dialog.response_context = self;
    }
    fn dialogProfile(ptr: ?*anyopaque, index: usize) void {
        const self = cast(Controls, ptr);
        self.selectProfile(index);
    }
    fn closeDialog(self: *Controls) void {
        const dialog = self.dialog orelse return;
        self.dialog = null;
        self.dialog_power = false;
        self.end_session = null;
        if (self.end_session_timer != 0) _ = mainloop.remove(self.io, self.end_session_timer);
        self.end_session_timer = 0;
        dialog.destroy();
        if (self.dialog_value) |value| self.allocator.free(value);
        self.dialog_value = null;
        self.release();
    }
    fn powerSettingsClosed(ptr: ?*anyopaque, _: bool) void {
        cast(Controls, ptr).closeDialog();
    }

    fn launch(self: *Controls, command: [:0]const u8) void {
        self.hide();
        spawnCommandLine(self.allocator, command);
    }
    pub fn show(self: *Controls, global_x: i32, global_y: i32) !void {
        if (self.dead) return;
        try self.popup.prepare(global_x, global_y);
        self.refresh();
        self.view.layout();
        self.view.focus = .none;
        self.view.stepFocus(false);
        self.popup.place(self.view.width, self.view.height);
        try self.popup.show();
    }
    pub fn hide(self: *Controls) void {
        self.tooltip.hide(self.io);
        self.view.submenu = .none;
        self.view.pressed = .none;
        self.view.hover = .none;
        self.view.focus = .none;
        self.popup.hide();
        self.redraw();
    }
    fn requestHide(self: *Controls) void {
        self.popup.requestHide();
    }
    fn dismiss(ptr: ?*anyopaque) void {
        cast(Controls, ptr).hide();
    }
    fn resized(ptr: ?*anyopaque) void {
        const self = cast(Controls, ptr);
        self.popup.place(self.view.width, self.view.height);
        self.redraw();
    }
    fn refreshTimer(self: *Controls) bool {
        if (!self.dead) self.expireDnd();
        if (self.popup.visible) self.refresh();
        return true;
    }
    pub fn refresh(self: *Controls) void {
        if (self.dead) return;
        self.syncPreferences();
        self.refreshBrightness();
        if (self.devices.network_client) |client| self.renderNetwork(client.state());
    }

    fn writeVolume(self: *Controls) bool {
        self.volume_timer = 0;
        if (self.view.model.volume) |value| self.audioAction(.{ .volume = value });
        return false;
    }
    fn writeBrightness(self: *Controls) bool {
        self.brightness_timer = 0;
        self.brightness_wanted = @max(1, self.view.model.brightness orelse return false);
        self.refreshBrightness();
        return false;
    }
    fn refreshBrightness(self: *Controls) void {
        if (self.dead or self.brightness_busy) return;
        const wanted = self.brightness_wanted;
        self.brightness_wanted = null;
        self.brightness_busy = true;
        self.brightness_writing = wanted != null;
        self.refs += 1;
        self.backlight_backend.start(self.allocator, if (wanted) |value| .{ .set = value } else .read, self.cancel, &brightnessDone, self);
    }
    fn brightnessDone(ptr: ?*anyopaque, result: backlight.Result) void {
        const self = cast(Controls, ptr);
        self.brightness_busy = false;
        if (!self.dead) {
            var reread = false;
            switch (result) {
                .value => |device| {
                    if (self.brightness_writing) self.setMessage("");
                    if (self.brightness_wanted == null and self.brightness_timer == 0) {
                        if (self.view.pressed != .brightness) self.view.model.brightness = device.percent();
                    }
                    if (self.view.model.brightness == null) self.view.model.brightness = device.percent();
                },
                .failure => |err| {
                    if (err == error.NoBacklight or err == error.BacklightUnavailable) self.view.model.brightness = null else if (err != error.Cancelled) self.setMessage(if (self.brightness_writing) "Brightness change failed" else "Brightness unavailable");
                    reread = self.brightness_writing and err != error.Cancelled and err != error.NoBacklight and err != error.BacklightUnavailable;
                },
            }
            self.redraw();
            if (self.brightness_wanted != null or reread) self.refreshBrightness();
        }
        self.release();
    }
    pub fn sessionAction(self: *Controls, action: session.Action) void {
        if (self.dead or self.session_busy) return;
        self.session_busy = true;
        self.view.model.session_busy = true;
        self.redraw();
        self.refs += 1;
        session.perform(self.allocator, action, self.cancel, &sessionDone, self);
    }
    fn sessionDone(ptr: ?*anyopaque, result: session.Result) void {
        const self = cast(Controls, ptr);
        defer self.release();
        self.session_busy = false;
        if (self.dead) return;
        self.view.model.session_busy = false;
        self.redraw();
        switch (result) {
            .success => self.setMessage(""),
            .failure => |message| self.setMessage(message),
            .cancelled => {},
        }
    }
    fn deviceChanged(ptr: ?*anyopaque, service: *devices.Service, event: devices.Event) void {
        const self = cast(Controls, ptr);
        if (self.dead) return;
        switch (event) {
            .audio => if (service.audio_service) |backend| audioChanged(self, backend),
            .network => if (service.network_client) |client| self.renderNetwork(client.state()),
            .battery => if (self.battery_service == null) batteryChanged(self, service.battery_state),
        }
    }
    fn networkAction(self: *Controls, action: network_backend.Action) void {
        if (self.dead) return;
        const client = self.devices.network_client orelse return;
        self.refs += 1;
        client.perform(action, self.cancel, &networkDone, self);
    }
    fn networkDone(ptr: ?*anyopaque, result: network_backend.Result) void {
        const self = cast(Controls, ptr);
        defer self.release();
        if (self.dead) return;
        switch (result) {
            .success => self.setMessage(""),
            .failure => |message| self.setMessage(message),
        }
    }
    pub fn renderNetwork(self: *Controls, state: *const network_backend.State) void {
        const focused_path = if (@backingInt(self.view.focus) >= @backingInt(Target.network0) and @backingInt(self.view.focus) <= @backingInt(Target.network7)) self.network_paths[@backingInt(self.view.focus) - @backingInt(Target.network0)] else null;
        const restore_focus = if (focused_path) |path| self.allocator.dupeSentinel(u8, path, 0) catch @panic("out of memory") else null;
        defer if (restore_focus) |path| self.allocator.free(path);
        if (restore_focus != null) self.view.focus = .none;
        const model = &self.view.model;
        model.wifi_enabled = state.wifi_enabled;
        model.wifi_sensitive = state.available and state.hardware_enabled;
        model.network_title.set(if (!state.available) "Unavailable" else if (!state.hardware_enabled) "Hardware Blocked" else if (!state.wifi_enabled) "Off" else "Not Connected");
        // Never activate a different AP if discovery reorders rows mid-click.
        if (@backingInt(self.view.pressed) >= @backingInt(native.Target.network0) and @backingInt(self.view.pressed) <= @backingInt(native.Target.network7)) self.view.pressed = .none;
        self.clearNetworks();
        for (state.access_points.items, 0..) |ap, index| {
            if (ap.connected) model.network_title.set(ap.title);
            if (model.network_count == 8 or ap.ssid.len == 0) continue;
            var duplicate = false;
            for (state.access_points.items[0..index]) |previous| if (std.mem.eql(u8, previous.ssid, ap.ssid)) {
                duplicate = true;
            };
            if (duplicate) continue;
            const i = model.network_count;
            self.network_paths[i] = self.allocator.dupeSentinel(u8, ap.path, 0) catch @panic("out of memory");
            if (restore_focus) |path| if (std.mem.eql(u8, path, ap.path)) {
                self.view.focus = @fromBackingInt(@intCast(@backingInt(Target.network0) + i));
            };
            model.networks[i] = .{ .connected = ap.connected, .secure = ap.passwordRequired(), .icon = network_backend.wifiIcon(ap.strength) };
            model.networks[i].title.set(ap.title);
            model.network_count += 1;
        }
        self.redraw();
    }
    fn clearNetworks(self: *Controls) void {
        for (&self.network_paths) |*path| {
            if (path.*) |value| self.allocator.free(value);
            path.* = null;
        }
        self.view.model.network_count = 0;
    }
    fn audioChanged(ptr: ?*anyopaque, service: *audio.Service) void {
        const self = cast(Controls, ptr);
        if (self.dead) return;
        if (service.state(.output)) |state| {
            if (self.volume_timer == 0 and self.view.pressed != .volume) self.view.model.volume = state.percent;
            self.view.model.muted = state.muted;
        } else self.view.model.volume = null;
        self.redraw();
    }
    fn audioAction(self: *Controls, change: audio.Change) void {
        if (self.dead) return;
        const service = self.devices.audio_service orelse return;
        self.refs += 1;
        service.apply(.output, change, self.cancel, &audioDone, self);
    }
    fn audioDone(ptr: ?*anyopaque, result: audio.Result) void {
        const self = cast(Controls, ptr);
        defer self.release();
        if (self.dead) return;
        switch (result) {
            .value => if (self.devices.audio_service) |service| audioChanged(self, service),
            .failure => |err| self.setMessage(@errorName(err)),
        }
    }
    pub fn monitorBattery(self: *Controls, options: battery_backend.Options) void {
        if (self.battery_service) |service| service.destroy();
        self.battery_service = battery_backend.Service.createWithOptions(self.allocator, self.io, options, &batteryChanged, self) catch null;
    }
    fn batteryChanged(ptr: ?*anyopaque, state: battery_backend.State) void {
        const self = cast(Controls, ptr);
        if (self.dead) return;
        if (state.visible()) {
            var buffer: [100]u8 = undefined;
            self.view.model.battery.set(std.fmt.bufPrint(&buffer, "{d:.0}%", .{state.percent}) catch "");
            self.view.model.battery_icon.set(state.icon(&buffer) catch "battery-symbolic");
        } else self.view.model.battery.set("");
        self.redraw();
    }
    fn connectNetwork(self: *Controls, index: usize) void {
        const path = self.network_paths[index] orelse return;
        const ssid = path.ptr;
        const client = self.devices.network_client orelse return;
        const ap = client.state().ap(std.mem.span(ssid)) orelse return;
        if (!ap.passwordRequired()) {
            self.networkAction(.{ .connect = .{ .ssid = ap.ssid, .access_point = ap.path } });
            return;
        }
        if (self.dialog) |dialog| {
            dialog.window.show() catch {};
            return;
        }
        self.hide();
        const dialog = auth.Dialog.createWithOptions(self.allocator, self.io, .password, ap.title, .{
            .title = "Authentication Required",
            .role = "desktop-network-auth",
            .accept = "Connect",
        }) catch |err| {
            self.dialogError(err);
            return;
        };
        self.dialog = dialog;
        self.dialog_value = self.allocator.dupeSentinel(u8, std.mem.span(ssid), 0) catch @panic("out of memory");
        self.refs += 1;
        dialog.responded = &networkConfirmed;
        dialog.response_context = self;
    }
    fn networkConfirmed(ptr: ?*anyopaque, accepted: bool) void {
        const self = cast(Controls, ptr);
        const dialog = self.dialog.?;
        const ssid = self.dialog_value.?;
        if (!self.dead and accepted) {
            if (!(dialog.validatePassword() catch {
                self.closeDialog();
                return;
            })) return;
            if (self.devices.network_client) |client| if (client.state().ap(ssid)) |ap| {
                self.networkAction(.{ .connect = .{ .ssid = ap.ssid, .access_point = ap.path, .password = dialog.entry.?.buffer.value() } });
            };
        }
        self.closeDialog();
    }

    fn screenshot(self: *Controls) bool {
        if (!self.dead) {
            @import("desktop-command.zig").launch(self.allocator, self.io, "Screenshot", &.{ @import("desktop-runtime.zig").executable, "screenshot" });
        }
        self.release();
        return false;
    }
    /// Mirrors GNOME Shell's end-session dialog: the action runs on its own
    /// when the countdown expires unless it is cancelled.
    const end_session_timeout = 60;
    fn endSessionTitle(action: session.Action) [:0]const u8 {
        return switch (action) {
            .reboot => "Restart",
            .poweroff => "Power Off",
            .logout => "Log Out",
            .@"suspend" => "Suspend",
        };
    }
    fn endSessionDescription(buffer: []u8, action: session.Action, seconds: u32) [:0]const u8 {
        const unit = if (seconds == 1) "second" else "seconds";
        return (switch (action) {
            .reboot => std.fmt.bufPrintSentinel(buffer, "The system will restart automatically in {d} {s}.", .{ seconds, unit }, 0),
            .poweroff => std.fmt.bufPrintSentinel(buffer, "The system will power off automatically in {d} {s}.", .{ seconds, unit }, 0),
            .logout => std.fmt.bufPrintSentinel(buffer, "You will be logged out automatically in {d} {s}.", .{ seconds, unit }, 0),
            .@"suspend" => std.fmt.bufPrintSentinel(buffer, "The system will suspend automatically in {d} {s}.", .{ seconds, unit }, 0),
        }) catch unreachable;
    }
    fn confirmAction(self: *Controls, action: session.Action) void {
        if (self.session_busy) return;
        if (self.dialog) |dialog| {
            dialog.window.show() catch {};
            return;
        }
        self.hide();
        var buffer: [96]u8 = undefined;
        const title = endSessionTitle(action);
        const dialog = auth.Dialog.createWithOptions(self.allocator, self.io, .confirm, endSessionDescription(&buffer, action, end_session_timeout), .{
            .title = title,
            .role = "desktop-session-confirm",
            .accept = title,
            .cancel = "Cancel",
        }) catch |err| {
            self.dialogError(err);
            return;
        };
        self.dialog = dialog;
        self.end_session = action;
        self.end_session_seconds = end_session_timeout;
        self.end_session_timer = mainloop.timeout(self.io, 1000, self, endSessionTick);
        self.refs += 1;
        // GNOME focuses the action button so Enter confirms.
        dialog.focus(.accept);
        dialog.responded = &confirmed;
        dialog.response_context = self;
    }
    fn endSessionTick(self: *Controls) bool {
        const dialog = self.dialog orelse {
            self.end_session_timer = 0;
            return false;
        };
        self.end_session_seconds -|= 1;
        if (self.end_session_seconds == 0) {
            self.end_session_timer = 0;
            dialog.respond(true);
            return false;
        }
        var buffer: [96]u8 = undefined;
        dialog.setPrompt(endSessionDescription(&buffer, self.end_session.?, self.end_session_seconds)) catch {};
        return true;
    }
    fn confirmed(ptr: ?*anyopaque, accepted: bool) void {
        const self = cast(Controls, ptr);
        if (accepted and !self.dead) if (self.end_session) |action| self.sessionAction(action);
        self.closeDialog();
    }
    pub fn deinit(self: *Controls) void {
        self.dead = true;
        self.popup.deinit();
        self.tooltip.hide(self.io);
        if (self.battery_service) |service| service.destroy();
        self.devices.unsubscribe(&self.subscription);
        if (self.owns_devices) self.devices.destroy();
        if (self.dialog) |dialog| dialog.respond(false);
        _ = mainloop.remove(self.io, self.timer);
        if (self.volume_timer != 0) _ = mainloop.remove(self.io, self.volume_timer);
        if (self.brightness_timer != 0) _ = mainloop.remove(self.io, self.brightness_timer);
        self.cancel.cancel();
        if (self.interface) |prefs| prefs.close();
        if (self.notifications) |prefs| prefs.close();
        self.release();
    }
    fn release(self: *Controls) void {
        self.refs -= 1;
        if (self.refs == 0) {
            self.clearNetworks();
            self.tooltip.deinit(self.allocator, self.io);
            self.view.deinit(self.allocator);
            self.cancel.unref();
            self.allocator.free(self.network_settings);
            self.allocator.free(self.sound_settings);
            self.allocator.destroy(self);
        }
    }
};

/// Starts a command line detached, as g_spawn_command_line_async; failures are logged.
pub fn spawnCommandLine(a: std.mem.Allocator, command: []const u8) void {
    const process = @import("desktop-process.zig");
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const argv = process.shellParse(arena.allocator(), command) catch |err| return std.log.warn("{s}: {s}", .{ command, @errorName(err) });
    process.spawnDetached(a, argv, .{}) catch |err| std.log.warn("{s}: {s}", .{ command, @errorName(err) });
}

test "timed Do Not Disturb subtitles name the weekday only past today" {
    const DateTime = @import("desktop-datetime.zig").DateTime;
    var buffer: [64]u8 = undefined;
    // Local noon keeps both instants on one day in any time zone.
    const noon = try DateTime.now();
    const start = unixNow(std.testing.io) - @as(i64, noon.second) + 12 * 3600;
    try std.testing.expectEqualStrings("Until 13:30", dndSubtitle(&buffer, start + 90 * 60, start));
    const later = dndSubtitle(&buffer, start + 24 * 3600, start);
    try std.testing.expect(std.mem.startsWith(u8, later, "Until ") and later.len > "Until 12:00".len);
}
