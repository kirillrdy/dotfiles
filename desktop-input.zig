//! Opt-in Wayland input for native surfaces. Passive clients never bind seats.
const std = @import("std");
const c = @import("desktop-gtk.zig");
const libc = @import("desktop-libc.zig");
const native = @import("desktop-surface.zig");
const keyboard = @import("desktop-keyboard.zig");
const a = std.heap.page_allocator;
const Proxy = c.wl_proxy;
const cast = c.__zig.cast;
extern const wl_seat_interface: c.wl_interface;
extern const wl_pointer_interface: c.wl_interface;
extern const wl_keyboard_interface: c.wl_interface;
extern const wl_surface_interface: c.wl_interface;
const protocols = @import("desktop-protocols.zig");

pub const TextState = struct { text: [:0]const u8, cursor: u32, anchor: u32, rect: c.GdkRectangle };

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

fn releaseProxy(proxy: *Proxy, opcode: u32, since: u32) void {
    if (c.wl_proxy_get_version(proxy) >= since) {
        _ = c.wl_proxy_marshal_flags(proxy, opcode, null, c.wl_proxy_get_version(proxy), 1);
    } else c.wl_proxy_destroy(proxy);
}
fn listen(proxy: *Proxy, listener: anytype, data: *Seat) void {
    if (c.wl_proxy_add_listener(proxy, @ptrCast(@constCast(listener)), data) != 0) @panic("Wayland input listener");
}

pub const Seat = struct {
    client: *native.Client,
    name: u32,
    proxy: *Proxy,
    pointer: ?*Proxy = null,
    keyboard: ?*Proxy = null,
    pointer_focus: ?*native.Surface = null,
    keyboard_focus: ?*native.Surface = null,
    cursor: ?*Proxy = null,
    x: f64 = 0,
    y: f64 = 0,
    xkb: keyboard.Keyboard = .{},
    repeat_rate: u32 = 0,
    repeat_delay: u32 = 0,
    repeat_code: ?u32 = null,
    repeat_source: c.guint = 0,
    text_input: ?*TextInput = null,

    pub fn bindTextInput(self: *Seat) void {
        if (self.text_input != null) return;
        const manager = self.client.text_manager orelse return;
        self.text_input = TextInput.create(self, manager) catch @panic("text input allocation");
    }

    pub fn create(client: *native.Client, registry: *c.wl_registry, name: u32, version: u32) !*Seat {
        const self = try a.create(Seat);
        errdefer a.destroy(self);
        self.* = .{ .client = client, .name = name, .proxy = @ptrCast(c.wl_registry_bind(registry, name, &wl_seat_interface, @min(version, 5))) };
        listen(self.proxy, &seat_listener, self);
        return self;
    }
    pub fn destroy(self: *Seat) void {
        if (self.text_input) |value| value.destroy();
        self.leaveFocus();
        self.stopRepeat();
        self.xkb.deinit();
        if (self.cursor) |proxy| releaseProxy(proxy, 0, 1);
        if (self.pointer) |proxy| releaseProxy(proxy, 1, 3);
        if (self.keyboard) |proxy| releaseProxy(proxy, 0, 3);
        releaseProxy(self.proxy, 3, 5);
        a.destroy(self);
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
    fn find(self: *Seat, proxy: ?*Proxy) ?*native.Surface {
        if (proxy == null) return null;
        for (self.client.surfaces.items) |surface| {
            if (surface.proxy == proxy and surface.options.interactive) return surface;
        }
        return null;
    }
    fn device(self: *Seat, opcode: u32, interface: *const c.wl_interface) *Proxy {
        return c.wl_proxy_marshal_flags(self.proxy, opcode, interface, c.wl_proxy_get_version(self.proxy), 0, @as(?*anyopaque, null)) orelse @panic("Wayland input device");
    }
    fn capabilities(data: ?*anyopaque, _: *Proxy, flags: u32) callconv(.c) void {
        const self = cast(Seat, data);
        if (flags & 1 != 0 and self.pointer == null) {
            self.pointer = self.device(0, &wl_pointer_interface);
            listen(self.pointer.?, &pointer_listener, self);
        } else if (flags & 1 == 0 and self.pointer != null) {
            self.leaveFocus();
            releaseProxy(self.pointer.?, 1, 3);
            self.pointer = null;
            self.pointer_focus = null;
        }
        if (flags & 2 != 0 and self.keyboard == null) {
            self.keyboard = self.device(1, &wl_keyboard_interface);
            listen(self.keyboard.?, &keyboard_listener, self);
        } else if (flags & 2 == 0 and self.keyboard != null) {
            self.leaveKeyboard();
            self.xkb.deinit();
            releaseProxy(self.keyboard.?, 0, 3);
            self.keyboard = null;
            self.keyboard_focus = null;
        }
    }
    fn seatName(_: ?*anyopaque, _: *Proxy, _: [*c]const u8) callconv(.c) void {}
    const seat_listener = extern struct {
        capabilities: *const @TypeOf(capabilities) = &capabilities,
        name: *const @TypeOf(seatName) = &seatName,
    }{};

    fn enter(data: ?*anyopaque, pointer: *Proxy, serial: u32, proxy: ?*Proxy, x: i32, y: i32) callconv(.c) void {
        const self = cast(Seat, data);
        self.pointer_focus = self.find(proxy);
        self.x = @as(f64, @floatFromInt(x)) / 256;
        self.y = @as(f64, @floatFromInt(y)) / 256;
        if (self.pointer_focus) |surface| {
            if (self.cursor == null) {
                const compositor = self.client.compositor.?;
                self.cursor = c.wl_proxy_marshal_flags(compositor, 0, &wl_surface_interface, c.wl_proxy_get_version(compositor), 0, @as(?*anyopaque, null));
            }
            if (self.cursor) |cursor| native.setCursor(surface, cursor, pointer, serial) catch |err| std.log.warn("native cursor: {s}", .{@errorName(err)});
            if (surface.input.motion) |callback| callback(surface.data, surface, self.x, self.y);
        }
    }
    fn leave(data: ?*anyopaque, _: *Proxy, _: u32, _: ?*Proxy) callconv(.c) void {
        cast(Seat, data).leaveFocus();
    }
    fn leaveFocus(self: *Seat) void {
        const surface = self.pointer_focus orelse return;
        self.pointer_focus = null;
        if (surface.input.leave) |callback| callback(surface.data, surface);
    }
    fn motion(data: ?*anyopaque, _: *Proxy, _: u32, x: i32, y: i32) callconv(.c) void {
        const self = cast(Seat, data);
        self.x = @as(f64, @floatFromInt(x)) / 256;
        self.y = @as(f64, @floatFromInt(y)) / 256;
        if (self.pointer_focus) |surface| if (surface.input.motion) |callback| callback(surface.data, surface, self.x, self.y);
    }
    fn button(data: ?*anyopaque, _: *Proxy, _: u32, _: u32, code: u32, state: u32) callconv(.c) void {
        const self = cast(Seat, data);
        if (self.pointer_focus) |surface| if (surface.input.button) |callback| callback(surface.data, surface, code, state == 1, self.x, self.y);
    }
    fn axis(data: ?*anyopaque, _: *Proxy, _: u32, direction: u32, value: i32) callconv(.c) void {
        const self = cast(Seat, data);
        if (self.pointer_focus) |surface| if (surface.input.scroll) |callback| callback(surface.data, surface, direction, @as(f64, @floatFromInt(value)) / 256);
    }
    fn frame(_: ?*anyopaque, _: *Proxy) callconv(.c) void {}
    fn axisSource(_: ?*anyopaque, _: *Proxy, _: u32) callconv(.c) void {}
    fn axisStop(_: ?*anyopaque, _: *Proxy, _: u32, _: u32) callconv(.c) void {}
    fn axisDiscrete(_: ?*anyopaque, _: *Proxy, _: u32, _: i32) callconv(.c) void {}
    const pointer_listener = extern struct {
        enter: *const @TypeOf(enter) = &enter,
        leave: *const @TypeOf(leave) = &leave,
        motion: *const @TypeOf(motion) = &motion,
        button: *const @TypeOf(button) = &button,
        axis: *const @TypeOf(axis) = &axis,
        frame: *const @TypeOf(frame) = &frame,
        source: *const @TypeOf(axisSource) = &axisSource,
        stop: *const @TypeOf(axisStop) = &axisStop,
        discrete: *const @TypeOf(axisDiscrete) = &axisDiscrete,
    }{};

    fn keymap(data: ?*anyopaque, _: *Proxy, format: u32, fd: c_int, size: u32) callconv(.c) void {
        const self = cast(Seat, data);
        self.stopRepeat();
        self.xkb.load(fd, format, size);
    }
    fn keyboardEnter(data: ?*anyopaque, _: *Proxy, _: u32, proxy: ?*Proxy, _: ?*c.wl_array) callconv(.c) void {
        const self = cast(Seat, data);
        self.leaveKeyboard();
        self.keyboard_focus = self.find(proxy);
        if (self.keyboard_focus) |surface| if (surface.input.focus) |callback| callback(surface.data, surface, true);
    }
    fn keyboardLeave(data: ?*anyopaque, _: *Proxy, _: u32, _: ?*Proxy) callconv(.c) void {
        cast(Seat, data).leaveKeyboard();
    }
    fn leaveKeyboard(self: *Seat) void {
        self.stopRepeat();
        self.xkb.reset();
        const surface = self.keyboard_focus orelse return;
        self.keyboard_focus = null;
        if (surface.input.focus) |callback| callback(surface.data, surface, false);
    }
    fn key(data: ?*anyopaque, _: *Proxy, _: u32, _: u32, code: u32, state: u32) callconv(.c) void {
        const self = cast(Seat, data);
        if (state == 1) {
            self.stopRepeat();
            if (self.repeat_rate > 0 and self.xkb.repeats(code)) {
                self.repeat_code = code;
                self.repeat_source = c.g_timeout_add(self.repeat_delay, &repeatBegin, self);
            }
        } else if (self.repeat_code == code) self.stopRepeat();
        self.dispatchKey(code, state == 1);
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
        if (self.repeat_source != 0) _ = c.g_source_remove(self.repeat_source);
        self.repeat_source = 0;
        self.repeat_code = null;
    }
    fn repeatBegin(ptr: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast(Seat, ptr);
        self.repeat_source = 0;
        const code = self.repeat_code orelse return 0;
        self.repeat_source = c.g_timeout_add(@max(1, 1000 / self.repeat_rate), &repeatTick, self);
        self.dispatchKey(code, true);
        return 0;
    }
    fn repeatTick(ptr: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast(Seat, ptr);
        const code = self.repeat_code orelse return 0;
        self.dispatchKey(code, true);
        return @intFromBool(self.repeat_source != 0);
    }
    fn modifiers(data: ?*anyopaque, _: *Proxy, _: u32, depressed: u32, latched: u32, locked: u32, group: u32) callconv(.c) void {
        cast(Seat, data).xkb.update(depressed, latched, locked, group);
    }
    fn repeat(data: ?*anyopaque, _: *Proxy, rate: i32, delay: i32) callconv(.c) void {
        const self = cast(Seat, data);
        self.stopRepeat();
        self.repeat_rate = @intCast(std.math.clamp(rate, 0, 200));
        self.repeat_delay = @intCast(std.math.clamp(delay, 1, 10000));
    }
    const keyboard_listener = extern struct {
        keymap: *const @TypeOf(keymap) = &keymap,
        enter: *const @TypeOf(keyboardEnter) = &keyboardEnter,
        leave: *const @TypeOf(keyboardLeave) = &keyboardLeave,
        key: *const @TypeOf(key) = &key,
        modifiers: *const @TypeOf(modifiers) = &modifiers,
        repeat: *const @TypeOf(repeat) = &repeat,
    }{};
};

pub const TextInput = struct {
    seat: *Seat,
    proxy: *Proxy,
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
    fn create(seat: *Seat, manager: *Proxy) !*TextInput {
        const self = try a.create(TextInput);
        errdefer a.destroy(self);
        const proxy = c.wl_proxy_marshal_flags(manager, 1, &protocols.zwp_text_input_v3_interface, 1, 0, @as(?*anyopaque, null), seat.proxy) orelse return error.TextInput;
        self.* = .{ .seat = seat, .proxy = proxy };
        if (c.wl_proxy_add_listener(proxy, @ptrCast(@constCast(&listener)), self) != 0) return error.TextInput;
        return self;
    }
    fn request(self: *TextInput, opcode: u32, args: anytype) void {
        _ = @call(.auto, c.wl_proxy_marshal_flags, .{ self.proxy, opcode, @as([*c]const c.wl_interface, null), @as(u32, 1), @as(u32, 0) } ++ args);
    }
    fn clear(self: *TextInput) void {
        self.commit_len = null;
        self.preedit_len = null;
        self.before = 0;
        self.after = 0;
    }
    fn leaveSurface(self: *TextInput) void {
        if (self.enabled) {
            self.request(2, .{});
            self.request(7, .{});
            self.serial +%= 1;
        }
        self.enabled = false;
        self.state_blocked = false;
        self.state_hash = null;
        self.clear();
        self.surface = null;
    }
    fn destroy(self: *TextInput) void {
        releaseProxy(self.proxy, 0, 1);
        a.destroy(self);
    }
    pub fn update(self: *TextInput) void {
        if (self.applying) return;
        const surface = self.surface orelse return;
        const state = if (surface.input.surrounding) |callback| callback(surface.data, surface) else null;
        if (state) |value| {
            if (self.state_blocked) return;
            var hash = std.hash.Wyhash.init(0);
            hash.update(value.text);
            hash.update(std.mem.asBytes(&value.cursor));
            hash.update(std.mem.asBytes(&value.anchor));
            hash.update(std.mem.asBytes(&value.rect));
            const current = hash.final();
            if (self.enabled and self.state_hash == current) return;
            const enabling = !self.enabled;
            if (enabling) self.request(1, .{});
            self.request(3, .{ value.text.ptr, value.cursor, value.anchor });
            self.request(4, .{@as(u32, 0)});
            self.request(5, .{ @as(u32, 0), @as(u32, 0) });
            self.request(6, .{ value.rect.x, value.rect.y, value.rect.width, value.rect.height });
            self.request(7, .{});
            self.serial +%= 1;
            if (enabling) self.enabled_since = self.serial;
            self.enabled = true;
            self.state_hash = current;
        } else if (self.enabled) {
            self.request(2, .{});
            self.request(7, .{});
            self.serial +%= 1;
            self.enabled = false;
            self.state_blocked = false;
            self.state_hash = null;
            self.clear();
        }
        self.seat.client.flush();
    }
    fn enter(data: ?*anyopaque, _: *Proxy, surface: ?*Proxy) callconv(.c) void {
        const self = cast(TextInput, data);
        self.surface = self.seat.find(surface);
        self.state_hash = null;
        self.update();
    }
    fn leave(data: ?*anyopaque, _: *Proxy, _: ?*Proxy) callconv(.c) void {
        cast(TextInput, data).leaveSurface();
    }
    fn preedit(data: ?*anyopaque, _: *Proxy, value: [*c]const u8, cursor: i32, _: i32) callconv(.c) void {
        const self = cast(TextInput, data);
        const bytes = if (value == null) "" else std.mem.span(value);
        if (bytes.len > self.preedit_bytes.len or !std.unicode.utf8ValidateSlice(bytes)) return;
        @memcpy(self.preedit_bytes[0..bytes.len], bytes);
        self.preedit_len = bytes.len;
        self.cursor = cursor;
    }
    fn commit(data: ?*anyopaque, _: *Proxy, value: [*c]const u8) callconv(.c) void {
        const self = cast(TextInput, data);
        if (value == null) {
            self.commit_len = null;
            return;
        }
        const bytes = if (value == null) "" else std.mem.span(value);
        if (bytes.len > self.commit_bytes.len or !std.unicode.utf8ValidateSlice(bytes)) return;
        @memcpy(self.commit_bytes[0..bytes.len], bytes);
        self.commit_len = bytes.len;
    }
    fn delete(data: ?*anyopaque, _: *Proxy, before: u32, after: u32) callconv(.c) void {
        const self = cast(TextInput, data);
        self.before = before;
        self.after = after;
    }
    fn done(data: ?*anyopaque, _: *Proxy, serial: u32) callconv(.c) void {
        const self = cast(TextInput, data);
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
    const listener = extern struct {
        enter: *const @TypeOf(enter) = &enter,
        leave: *const @TypeOf(leave) = &leave,
        preedit: *const @TypeOf(preedit) = &preedit,
        commit: *const @TypeOf(commit) = &commit,
        delete: *const @TypeOf(delete) = &delete,
        done: *const @TypeOf(done) = &done,
    }{};
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
    TextInput.commit(&input, undefined, "東京");
    TextInput.done(&input, undefined, 1);
    try std.testing.expectEqual(@as(usize, 6), state.commits);
    try std.testing.expect(input.state_blocked);
    input.enabled_since = 2;
    TextInput.commit(&input, undefined, "old focus");
    TextInput.done(&input, undefined, 1);
    try std.testing.expectEqual(@as(usize, 6), state.commits);
    TextInput.commit(&input, undefined, null);
    TextInput.preedit(&input, undefined, "とうきょう", 15, 15);
    TextInput.done(&input, undefined, 2);
    try std.testing.expectEqual(@as(usize, 6), state.commits);
    try std.testing.expect(!input.state_blocked);
    try std.testing.expectEqual(@as(usize, 15), state.composition);
    TextInput.commit(&input, undefined, "東京");
    TextInput.delete(&input, undefined, 3, 0);
    TextInput.done(&input, undefined, 2);
    try std.testing.expectEqual(@as(usize, 12), state.commits);
    try std.testing.expectEqual(@as(u32, 3), state.deletions);
}
