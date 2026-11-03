//! Opt-in Wayland input for native surfaces. Passive clients never bind seats.
const std = @import("std");
const c = @import("desktop-gtk.zig");
const libc = @import("desktop-libc.zig");
const native = @import("desktop-surface.zig");
const a = std.heap.page_allocator;
const Proxy = c.wl_proxy;
const cast = c.__zig.cast;
extern const wl_seat_interface: c.wl_interface;
extern const wl_pointer_interface: c.wl_interface;
extern const wl_keyboard_interface: c.wl_interface;
extern const wl_surface_interface: c.wl_interface;

pub const Events = struct {
    motion: ?*const fn (?*anyopaque, *native.Surface, f64, f64) void = null,
    button: ?*const fn (?*anyopaque, *native.Surface, u32, bool, f64, f64) void = null,
    key: ?*const fn (?*anyopaque, *native.Surface, u32, bool) void = null,
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

    pub fn create(client: *native.Client, registry: *c.wl_registry, name: u32, version: u32) !*Seat {
        const self = try a.create(Seat);
        errdefer a.destroy(self);
        self.* = .{ .client = client, .name = name, .proxy = @ptrCast(c.wl_registry_bind(registry, name, &wl_seat_interface, @min(version, 5))) };
        listen(self.proxy, &seat_listener, self);
        return self;
    }
    pub fn destroy(self: *Seat) void {
        if (self.cursor) |proxy| releaseProxy(proxy, 0, 1);
        if (self.pointer) |proxy| releaseProxy(proxy, 1, 3);
        if (self.keyboard) |proxy| releaseProxy(proxy, 0, 3);
        releaseProxy(self.proxy, 3, 5);
        a.destroy(self);
    }
    pub fn forget(self: *Seat, surface: *native.Surface) void {
        if (self.pointer_focus == surface) self.pointer_focus = null;
        if (self.keyboard_focus == surface) self.keyboard_focus = null;
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
            releaseProxy(self.pointer.?, 1, 3);
            self.pointer = null;
            self.pointer_focus = null;
        }
        if (flags & 2 != 0 and self.keyboard == null) {
            self.keyboard = self.device(1, &wl_keyboard_interface);
            listen(self.keyboard.?, &keyboard_listener, self);
        } else if (flags & 2 == 0 and self.keyboard != null) {
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
            if (self.cursor) |cursor| native.crosshair(surface, cursor, pointer, serial) catch |err| std.log.warn("selection cursor: {s}", .{@errorName(err)});
            if (surface.input.motion) |callback| callback(surface.data, surface, self.x, self.y);
        }
    }
    fn leave(data: ?*anyopaque, _: *Proxy, _: u32, _: ?*Proxy) callconv(.c) void {
        cast(Seat, data).pointer_focus = null;
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
    fn axis(_: ?*anyopaque, _: *Proxy, _: u32, _: u32, _: i32) callconv(.c) void {}
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

    fn keymap(_: ?*anyopaque, _: *Proxy, _: u32, fd: c_int, _: u32) callconv(.c) void {
        // Escape uses its evdev key code; text clients will need an XKB state.
        _ = libc.close(fd);
    }
    fn keyboardEnter(data: ?*anyopaque, _: *Proxy, _: u32, proxy: ?*Proxy, _: ?*c.wl_array) callconv(.c) void {
        const self = cast(Seat, data);
        self.keyboard_focus = self.find(proxy);
    }
    fn keyboardLeave(data: ?*anyopaque, _: *Proxy, _: u32, _: ?*Proxy) callconv(.c) void {
        cast(Seat, data).keyboard_focus = null;
    }
    fn key(data: ?*anyopaque, _: *Proxy, _: u32, _: u32, code: u32, state: u32) callconv(.c) void {
        const self = cast(Seat, data);
        if (self.keyboard_focus) |surface| if (surface.input.key) |callback| callback(surface.data, surface, code, state == 1);
    }
    fn modifiers(_: ?*anyopaque, _: *Proxy, _: u32, _: u32, _: u32, _: u32, _: u32) callconv(.c) void {}
    fn repeat(_: ?*anyopaque, _: *Proxy, _: i32, _: i32) callconv(.c) void {}
    const keyboard_listener = extern struct {
        keymap: *const @TypeOf(keymap) = &keymap,
        enter: *const @TypeOf(keyboardEnter) = &keyboardEnter,
        leave: *const @TypeOf(keyboardLeave) = &keyboardLeave,
        key: *const @TypeOf(key) = &key,
        modifiers: *const @TypeOf(modifiers) = &modifiers,
        repeat: *const @TypeOf(repeat) = &repeat,
    }{};
};
