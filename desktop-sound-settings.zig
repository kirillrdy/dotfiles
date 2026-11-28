//! Native Wayland sound settings with asynchronous PipeWire controls.
const std = @import("std");
const keyboard = @import("desktop-keyboard.zig");
const mainloop = @import("desktop-loop.zig");
const util = @import("desktop-util.zig");
const audio = @import("desktop-audio.zig");
pub const native = @import("desktop-sound-view.zig");
fn cast(comptime T: type, ptr: anytype) *T { return @ptrCast(@alignCast(ptr)); }
const host = @import("desktop-window.zig");
const wire = host.wire;
const Tooltip = @import("desktop-panel-view.zig").Tooltip;
pub const Sound = struct {
    allocator: std.mem.Allocator,
    window: *host.Window,
    navigation_context: ?*anyopaque,
    navigate: *const fn (?*anyopaque, native.Control) void,
    tooltip: Tooltip = .{},
    view: native.View = .{},
    service: ?*audio.Service = null,
    cancel: *mainloop.Cancellable,
    closed: bool = false,
    operations: usize = 0,
    timer: u32 = 0,
    layout: ?u64 = null,
    message: ?[:0]u8 = null,
    failed: bool = false,
    refreshing: bool = false,
    flushing: bool = false,
    feedback: audio.Feedback,
    // The settings shell owns window lifetime, drawing, and input dispatch.
    pub fn create(a: std.mem.Allocator, window: *host.Window, context: ?*anyopaque, navigate: *const fn (?*anyopaque, native.Control) void) !*Sound {
        const self = try a.create(Sound);
        self.* = .{ .allocator = a, .feedback = .{ .allocator = a, .io = window.io }, .window = window, .navigation_context = context, .navigate = navigate, .cancel = mainloop.Cancellable.create(window.io) };
        self.view.test_enabled = @import("desktop-runtime.zig").sound_file != null;
        self.service = audio.Service.create(a, window.io, &changed, self) catch null;
        self.refresh() catch self.renderFailure();
        return self;
    }
    pub fn deactivate(self: *Sound) void {
        self.tooltip.hide(self.window.io);
        self.flushVolumes();
        self.view.focus = null;
        self.view.hover = null;
        self.view.pressed = null;
        self.view.expanded = null;
    }
    pub fn destroy(self: *Sound) void {
        std.debug.assert(self.closed and self.operations == 0);
        self.tooltip.deinit(self.allocator, self.window.io);
        self.cancel.unref();
        self.view.deinit(self.allocator);
        if (self.message) |message| self.allocator.free(message);
        self.allocator.destroy(self);
    }
    pub fn close(self: *Sound) void {
        self.window.close();
    }
    pub fn shutdown(self: *Sound) void {
        if (self.closed) return;
        self.closed = true;
        self.tooltip.hide(self.window.io);
        self.cancel.cancel();
        if (self.timer != 0) _ = mainloop.remove(self.window.io, self.timer);
        self.timer = 0;
        self.feedback.deinit();
        if (self.service) |service| service.destroy();
        self.service = null;
    }
    fn setMessage(self: *Sound, message: [:0]const u8) !void {
        if (std.mem.eql(u8, self.view.message, message)) return;
        const copy = try self.allocator.dupeSentinel(u8, message, 0);
        if (self.message) |old| self.allocator.free(old);
        self.message = copy;
        self.view.message = copy;
        if (self.view.message_mask) |mask| mask.deinit(self.allocator);
        self.view.message_mask = null;
    }
    fn changed(ptr: ?*anyopaque, _: *audio.Service) void {
        const self = cast(Sound, ptr);
        if (!self.closed) self.refresh() catch self.renderFailure();
    }
    fn renderFailure(self: *Sound) void {
        self.failed = true;
        self.setMessage("Unable to render sound settings") catch {};
        self.window.redraw();
    }
    fn append(self: *Sound, target: audio.Target, title: [:0]const u8, class: ?audio.Class, device: bool) !void {
        const copy = try self.allocator.dupeSentinel(u8, if (std.unicode.utf8ValidateSlice(title)) title else "Unnamed audio device", 0);
        errdefer self.allocator.free(copy);
        try self.view.rows.append(self.allocator, .{ .target = target, .title = copy, .class = class, .device = device });
    }
    pub fn refresh(self: *Sound) !void {
        if (self.closed or self.refreshing or self.flushing) return;
        self.refreshing = true;
        defer self.refreshing = false;
        const service = self.service orelse {
            try self.setMessage("Audio service unavailable");
            self.window.redraw();
            return;
        };
        var hash = std.hash.Wyhash.init(0);
        for (service.nodes.items) |entry| {
            hash.update(std.mem.asBytes(&entry.id));
            hash.update(std.mem.asBytes(&entry.class));
            hash.update(std.mem.sliceTo(&entry.title, 0));
            hash.update(std.mem.sliceTo(&entry.name, 0));
        }
        const layout = hash.final();
        if (self.layout == null or self.layout.? != layout) {
            // Keep debounced writes attached to their old IDs before rebuilding.
            self.flushVolumes();
            self.view.invalidate(self.allocator);
            for (self.view.rows.items) |row| self.allocator.free(row.title);
            self.view.rows.clearRetainingCapacity();
            self.layout = null;
            self.view.focus = null;
            self.view.hover = null;
            self.view.pressed = null;
            self.view.expanded = null;
            try self.append(.output, "Output Volume", null, false);
            try self.append(.input, "Input Volume", null, false);
            for ([_]audio.Class{ .output, .input, .playback, .recording }) |class| {
                for (service.nodes.items) |*entry| {
                    if (entry.class != class) continue;
                    try self.append(.{ .id = entry.id }, std.mem.sliceTo(&entry.title, 0), class, class == .output or class == .input);
                }
            }
            self.layout = layout;
        }
        for (self.view.rows.items) |*row| {
            row.state = service.state(row.target);
            row.is_default = if (service.node(row.target)) |node| node.is_default else false;
        }
        if (!service.ready) try self.setMessage("Audio service unavailable") else if (!self.failed) try self.setMessage("");
        self.view.offset = std.math.clamp(self.view.offset, 0, self.view.maxOffset());
        self.window.redraw();
    }
    pub fn setVolume(self: *Sound, index: usize, value: f64) void {
        const target: native.Target = .{ .row = index };
        if (self.closed or !self.view.active(target) or !std.math.isFinite(value)) return;
        const service = self.service orelse return;
        const node = service.node(self.view.rows.items[index].target) orelse return;
        self.view.rows.items[index].pending_target = .{ .id = node.id };
        self.view.rows.items[index].pending = @round(std.math.clamp(value, 0, 100));
        if (self.timer != 0) _ = mainloop.remove(self.window.io, self.timer);
        self.timer = mainloop.timeout(self.window.io, 150, self, volumeTimeout);
        self.window.redraw();
    }
    fn volumeTimeout(self: *Sound) bool {
        self.timer = 0;
        self.flushVolumes();
        return false;
    }
    fn flushVolumes(self: *Sound) void {
        if (self.timer != 0) _ = mainloop.remove(self.window.io, self.timer);
        self.timer = 0;
        // Rejected writes may complete synchronously; keep row storage stable.
        self.flushing = true;
        defer self.flushing = false;
        for (self.view.rows.items) |*row| if (row.pending) |value| {
            const target = row.pending_target orelse row.target;
            row.pending = null;
            row.pending_target = null;
            self.apply(target, .{ .volume = value });
        };
    }
    pub fn activate(self: *Sound, target: native.Target) void {
        if (self.closed or !self.view.active(target)) return;
        switch (target.control) {
            .wifi_nav, .network_nav, .sound_nav => {
                self.navigate(self.navigation_context, target.control);
                return;
            },
            .close => {
                self.close();
                return;
            },
            .levels => {
                self.showPage(.levels);
                return;
            },
            .back => {
                self.showPage(.sound);
                return;
            },
            .device => {
                self.view.expanded = if (self.view.expanded == target.row) null else target.row;
                self.view.option_cursor = 0;
                while (self.view.optionAt(self.view.option_cursor)) |i| : (self.view.option_cursor += 1) {
                    if (self.view.rows.items[i].is_default) break;
                }
                if (self.view.optionAt(self.view.option_cursor) == null) self.view.option_cursor = 0;
                self.window.redraw();
                return;
            },
            .test_sound => {
                if (@import("desktop-runtime.zig").sound_file) |path| self.feedback.play(path.ptr);
                return;
            },
            else => {},
        }
        const row = self.view.rows.items[target.row];
        switch (target.control) {
            .volume => {},
            .mute => self.apply(row.target, .{ .mute = !row.state.?.muted }),
            .default => {
                self.view.focus = .{ .row = self.view.expanded.?, .control = .device };
                self.view.expanded = null;
                self.apply(row.target, .default);
            },
            else => unreachable,
        }
    }
    pub fn showPage(self: *Sound, page: native.Page) void {
        self.view.page = page;
        self.view.offset = 0;
        self.view.expanded = null;
        self.view.focus = null;
        self.view.pressed = null;
        self.view.hover = null;
        self.window.redraw();
    }
    fn apply(self: *Sound, target: audio.Target, change: audio.Change) void {
        if (self.closed) return;
        const service = self.service orelse return;
        self.failed = false;
        self.operations += 1;
        service.apply(target, change, self.cancel, &done, self);
    }
    fn done(ptr: ?*anyopaque, result: audio.Result) void {
        const self = cast(Sound, ptr);
        self.operations -= 1;
        if (self.closed) return;
        switch (result) {
            .failure => |err| {
                self.failed = true;
                self.setMessage(@errorName(err)) catch {};
            },
            .value => {
                // Panels refresh their device menus from this signal.
                const loop = @import("desktop-dbus-loop.zig");
                if (loop.acquire(self.allocator, self.window.io, .session)) |bus| {
                    defer loop.release(bus);
                    bus.connection.emit("/org/dotfiles/DesktopSettings", "org.dotfiles.DesktopSettings", "DeviceChanged", .{}) catch {};
                } else |_| {}
            },
        }
        self.refresh() catch self.renderFailure();
        self.window.redraw();
    }
    pub fn paint(self: *Sound, target: wire.Pixels) !void {
        const scale = self.window.surface.?.buffer_scale;
        const width = target.width / scale;
        const height = target.height / scale;
        if (self.view.width != width) {
            self.view.invalidate(self.allocator);
            self.view.width = width;
        }
        self.view.viewport_height = height;
        self.view.offset = std.math.clamp(self.view.offset, 0, self.view.maxOffset());
        try self.view.prepare(self.allocator, scale);
        self.view.paint(self.allocator, target);
        try self.tooltip.paint(self.allocator, target, &self.view.renderer, scale);
    }
    fn focus(self: *Sound) void {
        if (self.view.focus) |target| {
            const rect = self.view.rect(target);
            if (target.control != .close and target.control != .back and target.control != .wifi_nav and target.control != .network_nav and target.control != .sound_nav) {
                if (rect.y < 54) self.view.offset = @max(0, self.view.offset + rect.y - 54);
                if (rect.y + rect.height > @as(f64, @floatFromInt(self.view.viewport_height)) - 16) self.view.offset += rect.y + rect.height - @as(f64, @floatFromInt(self.view.viewport_height)) + 16;
                self.view.offset = std.math.clamp(self.view.offset, 0, self.view.maxOffset());
            }
        }
        self.window.redraw();
    }
    pub fn pointerButton(self: *Sound, pressed: bool, x: f64, y: f64) void {
        if (self.closed or self.window.closing) return;
        self.tooltip.hide(self.window.io);
        if (!pressed) {
            const previous = self.view.pressed;
            self.view.pressed = null;
            if (previous) |target| {
                if (target.control == .volume) {
                    self.setVolume(target.row, self.view.percent(target, x));
                    self.flushVolumes();
                } else if (self.view.hit(x, y)) |hit| if (hit.eql(target)) self.activate(target);
            }
            self.window.redraw();
            return;
        }
        const target = self.view.hit(x, y);
        if (self.view.expanded != null and target == null) {
            self.view.expanded = null;
            self.view.pressed = null;
            self.window.redraw();
            return;
        }
        self.view.pressed = target;
        self.view.focus = target;
        self.view.hover = target;
        self.view.keyboard_focus = false;
        if (target) |t| if (t.control == .volume) self.setVolume(t.row, self.view.percent(t, x));
        self.window.redraw();
    }
    pub fn button(ptr: ?*anyopaque, _: *wire.Surface, code: u32, pressed: bool, x: f64, y: f64) void {
        if (code == 272) cast(Sound, ptr).pointerButton(pressed, x, y);
    }
    fn showTooltip(self: *Sound) bool {
        self.tooltip.show();
        self.window.redraw();
        return false;
    }
    pub fn motion(ptr: ?*anyopaque, _: *wire.Surface, x: f64, y: f64) void {
        const self = cast(Sound, ptr);
        if (self.closed or self.window.closing) return;
        self.view.hover = self.view.hit(x, y);
        var value_buffer: [32]u8 = undefined;
        const tooltip: ?[:0]const u8 = if (self.view.hover) |t| switch (t.control) {
            .volume => std.fmt.bufPrintSentinel(&value_buffer, "{d:.0}%", .{self.view.rows.items[t.row].pending orelse self.view.rows.items[t.row].state.?.percent}, 0) catch null,
            .mute => if (self.view.rows.items[t.row].state.?.muted) "Unmute" else "Mute",
            .test_sound => "Play a sound through the selected output device",
            .device => "Select a device",
            .default => self.view.rows.items[t.row].title,
            .levels => "Adjust volume for individual applications",
            .back => "Back",
            .close => "Close",
            .wifi_nav => "Wi-Fi",
            .network_nav => "Network",
            .sound_nav => "Sound",
        } else null;
        self.tooltip.update(self.allocator, self.window.io, x, y, tooltip, self.view.pressed == null, self, showTooltip);
        if (self.view.pressed) |target| if (target.control == .volume) self.setVolume(target.row, self.view.percent(target, x));
        self.window.redraw();
    }
    pub fn leave(ptr: ?*anyopaque, _: *wire.Surface) void {
        const self = cast(Sound, ptr);
        self.view.hover = null;
        self.tooltip.hide(self.window.io);
        self.window.redraw();
    }
    pub fn focusChanged(ptr: ?*anyopaque, _: *wire.Surface, focused: bool) void {
        const self = cast(Sound, ptr);
        if (!focused) {
            self.view.pressed = null;
            self.view.keyboard_focus = false;
            self.tooltip.hide(self.window.io);
            self.window.redraw();
        }
    }
    pub fn key(ptr: ?*anyopaque, _: *wire.Surface, symbol: u32, modifiers: u32, pressed: bool) bool {
        return !pressed or cast(Sound, ptr).handleKey(symbol, modifiers);
    }
    pub fn handleKey(self: *Sound, symbol: u32, modifiers: keyboard.Modifiers) bool {
        if (self.closed or self.window.closing) return false;
        self.tooltip.hide(self.window.io);
        if (self.view.expanded != null) {
            switch (symbol) {
                0xff1b, 0xff09, 0xfe20 => self.view.expanded = null,
                0xff52 => self.view.option_cursor -|= 1,
                0xff54 => if (self.view.optionAt(self.view.option_cursor + 1) != null) {
                    self.view.option_cursor += 1;
                },
                0xff50 => self.view.option_cursor = 0,
                0xff57 => {
                    while (self.view.optionAt(self.view.option_cursor + 1) != null) self.view.option_cursor += 1;
                },
                0x20, 0xff0d, 0xff8d => if (self.view.optionAt(self.view.option_cursor)) |i| self.activate(.{ .row = i, .control = .default }),
                else => return false,
            }
            self.window.redraw();
            return true;
        }
        switch (symbol) {
            0xff1b => if (self.view.page == .levels) self.showPage(.sound) else self.close(),
            0xff09, 0xfe20 => { // Tab / Shift-Tab
                self.view.moveFocus(modifiers & keyboard.shift != 0 or symbol == 0xfe20);
                self.focus();
            },
            0x20, 0xff0d, 0xff8d => if (self.view.focus) |target| self.activate(target),
            0xff51, 0xff53, 0xff52, 0xff54, 0xff50, 0xff57 => {
                const target = self.view.focus orelse return false;
                if (target.control != .volume or !self.view.active(target)) return false;
                const row = self.view.rows.items[target.row];
                const current = row.pending orelse row.state.?.percent;
                const value = switch (symbol) {
                    0xff50 => @as(f64, 0),
                    0xff57 => @as(f64, 100),
                    0xff51, 0xff54 => current - 5,
                    else => current + 5,
                };
                self.view.keyboard_focus = true;
                self.setVolume(target.row, value);
            },
            else => return false,
        }
        return true;
    }
    pub fn scrolled(ptr: ?*anyopaque, _: *wire.Surface, axis: u32, amount: f64) void {
        const self = cast(Sound, ptr);
        if (self.closed or self.window.closing or axis != 0) return;
        self.tooltip.hide(self.window.io);
        const delta = amount * 4;
        if (self.view.expanded != null) {
            if (delta > 0 and self.view.optionAt(self.view.option_cursor + 1) != null) self.view.option_cursor += 1 else if (delta < 0) self.view.option_cursor -|= 1;
        } else self.view.offset = std.math.clamp(self.view.offset + delta, 0, self.view.maxOffset());
        self.window.redraw();
    }
};
