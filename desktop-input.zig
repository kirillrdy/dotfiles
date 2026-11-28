//! Opt-in Wayland input for native surfaces. Passive clients never bind seats.
const std = @import("std");
const mainloop = @import("desktop-loop.zig");
const util = @import("desktop-util.zig");
const wl = @import("wayland-client");
const native = @import("desktop-surface.zig");
const keyboard = @import("desktop-keyboard.zig");
fn cast(comptime T: type, ptr: anytype) *T { return @ptrCast(@alignCast(ptr)); }

pub const TextState = struct { text: [:0]const u8, cursor: u32, anchor: u32, rect: @import("desktop-raster.zig").IntRect, private: bool = false };

pub const Events = struct {
    leave: ?*const fn (?*anyopaque, *native.Surface) void = null,
    motion: ?*const fn (?*anyopaque, *native.Surface, f64, f64) void = null,
    button: ?*const fn (?*anyopaque, *native.Surface, u32, bool, f64, f64) void = null,
    key: ?*const fn (?*anyopaque, *native.Surface, u32, bool) void = null,
    symbol: ?*const fn (?*anyopaque, *native.Surface, u32, u32, bool) bool = null,
    text: ?*const fn (?*anyopaque, *native.Surface, []const u8) void = null,
    focus: ?*const fn (?*anyopaque, *native.Surface, bool) void = null,
    scroll: ?*const fn (?*anyopaque, *native.Surface, u32, f64) void = null,
    surrounding: ?*const fn (?*anyopaque, *native.Surface) ?TextState = null,
    preedit: ?*const fn (?*anyopaque, *native.Surface, []const u8, i32) void = null,
    commit: ?*const fn (?*anyopaque, *native.Surface, []const u8) void = null,
    delete: ?*const fn (?*anyopaque, *native.Surface, u32, u32) void = null,
};

pub const Seat = struct {
    client: *native.Client,
    name: u32,
    serial: u32 = 0,
    proxy: wl.wl_seat,
    pointer: ?wl.wl_pointer = null,
    keyboard: ?wl.wl_keyboard = null,
    pointer_focus: ?*native.Surface = null,
    keyboard_focus: ?*native.Surface = null,
    cursor: ?wl.wl_surface = null,
    cursor_shape: ?wl.wp_cursor_shape_device_v1 = null,
    x: f64 = 0,
    y: f64 = 0,
    xkb: keyboard.Keyboard = .{},
    repeat_rate: u32 = 0,
    repeat_delay: u32 = 0,
    repeat_code: ?u32 = null,
    repeat_source: u32 = 0,
    text_input: ?*TextInput = null,
    clipboard: ?*@import("desktop-clipboard.zig").Device = null,

    pub fn bindClipboard(self: *Seat) void {
        if (self.clipboard != null) return;
        const manager = self.client.clipboard_manager orelse return;
        self.clipboard = @import("desktop-clipboard.zig").Device.create(self, manager) catch null;
    }
    pub fn bindTextInput(self: *Seat) void {
        if (self.text_input != null) return;
        const manager = self.client.text_manager orelse return;
        self.text_input = TextInput.create(self, manager) catch @panic("text input allocation");
    }
    pub fn bindCursorShape(self: *Seat) void {
        if (self.cursor_shape != null) return;
        const manager = self.client.cursor_manager orelse return;
        const pointer = self.pointer orelse return;
        self.cursor_shape = manager.get_pointer(pointer);
    }

    pub fn create(client: *native.Client, registry: wl.wl_registry, name: u32, version: u32) !*Seat {
        const self = try client.allocator.create(Seat);
        errdefer client.allocator.destroy(self);
        self.* = .{ .client = client, .name = name, .proxy = registry.bind(name, wl.wl_seat, @min(version, 5)) };
        self.proxy.listen(Seat, self, seatEvent);
        return self;
    }
    pub fn destroy(self: *Seat) void {
        if (self.clipboard) |value| value.destroy();
        if (self.text_input) |value| value.destroy();
        self.leaveFocus();
        self.stopRepeat();
        self.xkb.deinit();
        if (self.cursor_shape) |value| value.destroy();
        if (self.cursor) |value| value.destroy();
        if (self.pointer) |value| releasePointer(value);
        if (self.keyboard) |value| releaseKeyboard(value);
        if (self.proxy.version() >= 5) self.proxy.release() else self.proxy.destroy();
        self.client.allocator.destroy(self);
    }
    fn releasePointer(pointer: wl.wl_pointer) void {
        if (pointer.version() >= 3) pointer.release() else pointer.destroy();
    }
    fn releaseKeyboard(value: wl.wl_keyboard) void {
        if (value.version() >= 3) value.release() else value.destroy();
    }
    pub fn forget(self: *Seat, surface: *native.Surface) void {
        if (self.text_input) |value| if (value.surface == surface) value.leaveSurface();
        if (self.pointer_focus == surface) self.pointer_focus = null;
        if (self.keyboard_focus == surface) {
            self.keyboard_focus = null;
            self.stopRepeat();
            self.xkb.reset();
        }
    }
    fn find(self: *Seat, proxy: ?wl.wl_surface) ?*native.Surface {
        for (self.client.surfaces.items) |surface| {
            if (native.same(surface.proxy, proxy) and surface.options.interactive) return surface;
        }
        return null;
    }
    fn seatEvent(self: *Seat, seat: wl.wl_seat, event: wl.wl_seat.Event) void {
        const flags = switch (event) {
            .capabilities => |value| value.capabilities,
            .name => return,
        };
        if (flags & wl.wl_seat.Capability.pointer != 0 and self.pointer == null) {
            const pointer = seat.get_pointer();
            self.pointer = pointer;
            pointer.listen(Seat, self, pointerEvent);
            self.bindCursorShape();
        } else if (flags & wl.wl_seat.Capability.pointer == 0) if (self.pointer) |pointer| {
            self.leaveFocus();
            if (self.cursor_shape) |value| value.destroy();
            self.cursor_shape = null;
            releasePointer(pointer);
            self.pointer = null;
            self.pointer_focus = null;
        };
        if (flags & wl.wl_seat.Capability.keyboard != 0 and self.keyboard == null) {
            const value = seat.get_keyboard();
            self.keyboard = value;
            value.listen(Seat, self, keyboardEvent);
        } else if (flags & wl.wl_seat.Capability.keyboard == 0) if (self.keyboard) |value| {
            self.leaveKeyboard();
            self.xkb.deinit();
            releaseKeyboard(value);
            self.keyboard = null;
            self.keyboard_focus = null;
        };
    }

    fn pointerEvent(self: *Seat, pointer: wl.wl_pointer, event: wl.wl_pointer.Event) void {
        switch (event) {
            .enter => |value| self.enter(pointer, value.serial, value.surface, value.surface_x, value.surface_y),
            .leave => self.leaveFocus(),
            .motion => |value| {
                self.x = value.surface_x;
                self.y = value.surface_y;
                if (self.pointer_focus) |surface| if (surface.input.motion) |callback| callback(surface.data, surface, self.x, self.y);
            },
            .button => |value| {
                self.serial = value.serial;
                if (self.pointer_focus) |surface| if (surface.input.button) |callback| callback(surface.data, surface, value.button, value.state == wl.wl_pointer.ButtonState.pressed, self.x, self.y);
            },
            .axis => |value| if (self.pointer_focus) |surface| if (surface.input.scroll) |callback| callback(surface.data, surface, value.axis, value.value),
            else => {},
        }
    }
    fn enter(self: *Seat, pointer: wl.wl_pointer, serial: u32, proxy: wl.wl_surface, x: f64, y: f64) void {
        self.pointer_focus = self.find(proxy);
        self.x = x;
        self.y = y;
        const surface = self.pointer_focus orelse return;
        if (surface.options.cursor == .arrow and self.cursor_shape != null) {
            self.cursor_shape.?.set_shape(serial, wl.wp_cursor_shape_device_v1.Shape.default);
            self.client.flush();
        } else {
            if (self.cursor == null) self.cursor = self.client.compositor.?.create_surface();
            native.setCursor(surface, self.cursor.?, pointer, serial) catch |err| std.log.warn("native cursor: {s}", .{@errorName(err)});
        }
        if (surface.input.motion) |callback| callback(surface.data, surface, self.x, self.y);
    }
    fn leaveFocus(self: *Seat) void {
        const surface = self.pointer_focus orelse return;
        self.pointer_focus = null;
        if (surface.input.leave) |callback| callback(surface.data, surface);
    }

    fn keyboardEvent(self: *Seat, _: wl.wl_keyboard, event: wl.wl_keyboard.Event) void {
        switch (event) {
            .keymap => |value| {
                self.stopRepeat();
                self.xkb.load(value.fd, value.format, value.size);
            },
            .enter => |value| {
                self.leaveKeyboard();
                self.keyboard_focus = self.find(value.surface);
                if (self.keyboard_focus) |surface| if (surface.input.focus) |callback| callback(surface.data, surface, true);
            },
            .leave => self.leaveKeyboard(),
            .key => |value| self.key(value.serial, value.key, value.state == wl.wl_keyboard.KeyState.pressed),
            .modifiers => |value| self.xkb.update(value.mods_depressed, value.mods_latched, value.mods_locked, value.group),
            .repeat_info => |value| {
                self.stopRepeat();
                self.repeat_rate = @intCast(std.math.clamp(value.rate, 0, 200));
                self.repeat_delay = @intCast(std.math.clamp(value.delay, 1, 10000));
            },
        }
    }
    fn leaveKeyboard(self: *Seat) void {
        self.stopRepeat();
        self.xkb.reset();
        const surface = self.keyboard_focus orelse return;
        self.keyboard_focus = null;
        if (surface.input.focus) |callback| callback(surface.data, surface, false);
    }
    fn key(self: *Seat, serial: u32, code: u32, pressed: bool) void {
        self.serial = serial;
        if (pressed) {
            self.stopRepeat();
            if (self.repeat_rate > 0 and self.xkb.repeats(code)) {
                self.repeat_code = code;
                self.repeat_source = mainloop.timeout(self.client.io, self.repeat_delay, self, repeatBegin);
            }
        } else if (self.repeat_code == code) self.stopRepeat();
        self.dispatchKey(code, pressed);
    }
    fn dispatchKey(self: *Seat, code: u32, pressed: bool) void {
        const surface = self.keyboard_focus orelse return;
        if (surface.input.symbol) |callback| {
            if (callback(surface.data, surface, self.xkb.symbol(code), self.xkb.modifiers(), pressed)) {
                self.xkb.reset();
                return;
            }
        }
        if (pressed) if (surface.input.text) |callback| {
            var buffer: [128]u8 = @splat(0);
            defer std.crypto.secureZero(u8, &buffer);
            const value = self.xkb.text(code, &buffer);
            if (value.len > 0) callback(surface.data, surface, value);
        };
        if (surface.input.key) |callback| callback(surface.data, surface, code, pressed);
    }
    fn stopRepeat(self: *Seat) void {
        if (self.repeat_source != 0) _ = mainloop.remove(self.client.io, self.repeat_source);
        self.repeat_source = 0;
        self.repeat_code = null;
    }
    fn repeatBegin(self: *Seat) bool {
        self.repeat_source = 0;
        const code = self.repeat_code orelse return false;
        self.repeat_source = mainloop.timeout(self.client.io, @max(1, 1000 / self.repeat_rate), self, repeatTick);
        self.dispatchKey(code, true);
        return false;
    }
    fn repeatTick(self: *Seat) bool {
        const code = self.repeat_code orelse return false;
        self.dispatchKey(code, true);
        return self.repeat_source != 0;
    }
};

pub const TextInput = struct {
    seat: *Seat,
    proxy: wl.zwp_text_input_v3,
    surface: ?*native.Surface = null,
    enabled: bool = false,
    serial: u32 = 0,
    enabled_since: u32 = 0,
    applying: bool = false,
    state_blocked: bool = false,
    state_hash: ?u64 = null,
    commit_bytes: [4096:0]u8 = @splat(0),
    commit_len: ?usize = null,
    preedit_bytes: [4096:0]u8 = @splat(0),
    preedit_len: ?usize = null,
    cursor: i32 = 0,
    before: u32 = 0,
    after: u32 = 0,
    fn create(seat: *Seat, manager: wl.zwp_text_input_manager_v3) !*TextInput {
        const self = try seat.client.allocator.create(TextInput);
        self.* = .{ .seat = seat, .proxy = manager.get_text_input(seat.proxy) };
        self.proxy.listen(TextInput, self, textEvent);
        return self;
    }
    fn clear(self: *TextInput) void {
        self.commit_len = null;
        self.preedit_len = null;
        self.before = 0;
        self.after = 0;
    }
    fn leaveSurface(self: *TextInput) void {
        if (self.enabled) {
            self.proxy.disable();
            self.proxy.commit();
            self.serial +%= 1;
        }
        self.enabled = false;
        self.state_blocked = false;
        self.state_hash = null;
        self.clear();
        self.surface = null;
    }
    fn destroy(self: *TextInput) void {
        self.proxy.destroy();
        self.seat.client.allocator.destroy(self);
    }
    pub fn update(self: *TextInput) void {
        if (self.applying) return;
        const surface = self.surface orelse return;
        const state = if (surface.input.surrounding) |callback| callback(surface.data, surface) else null;
        if (state) |value| {
            if (self.state_blocked) return;
            var hash = std.hash.Wyhash.init(0);
            hash.update(value.text);
            hash.update(std.mem.asBytes(&value.private));
            hash.update(std.mem.asBytes(&value.cursor));
            hash.update(std.mem.asBytes(&value.anchor));
            hash.update(std.mem.asBytes(&value.rect));
            const current = hash.final();
            if (self.enabled and self.state_hash == current) return;
            const enabling = !self.enabled;
            if (enabling) self.proxy.enable();
            self.proxy.set_surrounding_text(value.text, @intCast(value.cursor), @intCast(value.anchor));
            self.proxy.set_text_change_cause(0);
            self.proxy.set_content_type(if (value.private) 0xc0 else 0, if (value.private) 8 else 0);
            self.proxy.set_cursor_rectangle(value.rect.x, value.rect.y, value.rect.width, value.rect.height);
            self.proxy.commit();
            self.serial +%= 1;
            if (enabling) self.enabled_since = self.serial;
            self.enabled = true;
            self.state_hash = current;
        } else if (self.enabled) {
            self.proxy.disable();
            self.proxy.commit();
            self.serial +%= 1;
            self.enabled = false;
            self.state_blocked = false;
            self.state_hash = null;
            self.clear();
        }
        self.seat.client.flush();
    }
    fn textEvent(self: *TextInput, _: wl.zwp_text_input_v3, event: wl.zwp_text_input_v3.Event) void {
        switch (event) {
            .enter => |value| {
                self.surface = self.seat.find(value.surface);
                self.state_hash = null;
                self.update();
            },
            .leave => self.leaveSurface(),
            .preedit_string => |value| self.preedit(value.text, value.cursor_begin),
            .commit_string => |value| self.commit(value.text),
            .delete_surrounding_text => |value| self.delete(value.before_length, value.after_length),
            .done => |value| self.done(value.serial),
            else => {},
        }
    }
    fn preedit(self: *TextInput, value: ?[]const u8, cursor: i32) void {
        const bytes = value orelse "";
        if (bytes.len > self.preedit_bytes.len or !std.unicode.utf8ValidateSlice(bytes)) return;
        @memcpy(self.preedit_bytes[0..bytes.len], bytes);
        self.preedit_len = bytes.len;
        self.cursor = cursor;
    }
    fn commit(self: *TextInput, value: ?[]const u8) void {
        const bytes = value orelse {
            self.commit_len = null;
            return;
        };
        if (bytes.len > self.commit_bytes.len or !std.unicode.utf8ValidateSlice(bytes)) return;
        @memcpy(self.commit_bytes[0..bytes.len], bytes);
        self.commit_len = bytes.len;
    }
    fn delete(self: *TextInput, before: u32, after: u32) void {
        self.before = before;
        self.after = after;
    }
    fn done(self: *TextInput, serial: u32) void {
        defer self.clear();
        const surface = self.surface orelse return;
        if (!self.enabled or serial -% self.enabled_since >= 0x80000000) return;
        // In-flight edits still apply, but v3 forbids publishing new state
        // until done acknowledges our latest commit. Focus generations differ.
        self.state_blocked = serial != self.serial;
        self.applying = true;
        if (surface.input.delete) |callback| if (self.before > 0 or self.after > 0) callback(surface.data, surface, self.before, self.after);
        if (self.commit_len) |len| if (surface.input.commit) |callback| callback(surface.data, surface, self.commit_bytes[0..len]);
        if (self.preedit_len) |len| if (surface.input.preedit) |callback| callback(surface.data, surface, self.preedit_bytes[0..len], self.cursor);
        self.applying = false;
        if (surface.input.surrounding != null) self.update();
    }
};

test "native text input applies in-flight edits, rejects old focus and ignores absent commits" {
    const State = struct {
        commits: usize = 0,
        composition: usize = 0,
        deletions: u32 = 0,
        fn paint(_: ?*anyopaque, _: native.Pixels) void {}
        fn commit(data: ?*anyopaque, _: *native.Surface, value: []const u8) void {
            const self = cast(@This(), data);
            self.commits += value.len;
        }
        fn preedit(data: ?*anyopaque, _: *native.Surface, value: []const u8, _: i32) void {
            const self = cast(@This(), data);
            self.composition += value.len;
        }
        fn delete(data: ?*anyopaque, _: *native.Surface, before: u32, after: u32) void {
            cast(@This(), data).deletions += before + after;
        }
    };
    var state: State = .{};
    var surface: native.Surface = .{ .client = undefined, .output = undefined, .options = .{ .namespace = "test" }, .paint = &State.paint, .data = &state, .input = .{ .commit = &State.commit, .preedit = &State.preedit, .delete = &State.delete } };
    var input: TextInput = .{ .seat = undefined, .proxy = undefined, .surface = &surface, .enabled = true, .serial = 2 };
    input.commit("東京");
    input.done(1);
    try std.testing.expectEqual(@as(usize, 6), state.commits);
    try std.testing.expect(input.state_blocked);
    input.enabled_since = 2;
    input.commit("old focus");
    input.done(1);
    try std.testing.expectEqual(@as(usize, 6), state.commits);
    input.commit(null);
    input.preedit("とうきょう", 15);
    input.done(2);
    try std.testing.expectEqual(@as(usize, 6), state.commits);
    try std.testing.expect(!input.state_blocked);
    try std.testing.expectEqual(@as(usize, 15), state.composition);
    input.commit("東京");
    input.delete(3, 0);
    input.done(2);
    try std.testing.expectEqual(@as(usize, 12), state.commits);
    try std.testing.expectEqual(@as(u32, 3), state.deletions);
}
