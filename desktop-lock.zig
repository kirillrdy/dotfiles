//! Independent ext-session-lock client. Only successful PAM authentication sends unlock.
const std = @import("std");
const wayland = @import("desktop-wayland.zig");
const c = @import("desktop-glib.zig");
const libc = @import("desktop-libc.zig");
const p = @import("desktop-protocols.zig");
const auth = @import("desktop-lock-auth.zig");
const view = @import("desktop-lock-view.zig");
const raster = @import("desktop-raster.zig");
const a = std.heap.page_allocator;
const kb = @import("desktop-keyboard.zig");
const u = @import("desktop-util.zig");
const Proxy = c.wl_proxy;

const cast = c.__zig.cast;

fn screenLocked(locked: bool) void {
    const bus = c.g_bus_get_sync(c.G_BUS_TYPE_SESSION, null, null) orelse return;
    defer c.g_object_unref(bus);
    const reply = c.g_dbus_connection_call_sync(bus, "org.freedesktop.secrets", "/org/freedesktop/secrets", "org.dotfiles.Desktop.Secrets", "SetScreenLocked", c.g_variant_new("(b)", @as(c_int, @intFromBool(locked))), null, c.G_DBUS_CALL_FLAGS_NO_AUTO_START, 3000, null, null) orelse return;
    c.g_variant_unref(reply);
}
fn unlockSecrets(password: []const u8) void {
    const bus = c.g_bus_get_sync(c.G_BUS_TYPE_SESSION, null, null) orelse return;
    defer c.g_object_unref(bus);
    const bytes = c.g_variant_new_fixed_array(@ptrCast(@as([*:0]const u8, "y")), password.ptr, password.len, 1);
    const reply = c.g_dbus_connection_call_sync(bus, "org.freedesktop.secrets", "/org/freedesktop/secrets", "org.dotfiles.Desktop.Secrets", "LoginUnlock", c.g_variant_new("(@ay)", bytes), null, c.G_DBUS_CALL_FLAGS_NO_AUTO_START, 30000, null, null) orelse return;
    c.g_variant_unref(reply);
}
fn request(proxy: *Proxy, opcode: u32) void {
    _ = c.wl_proxy_marshal_flags(proxy, opcode, null, c.wl_proxy_get_version(proxy), 0);
}
fn destroy(proxy: *Proxy, opcode: u32) void {
    _ = c.wl_proxy_marshal_flags(proxy, opcode, null, c.wl_proxy_get_version(proxy), 1);
}
fn listen(proxy: *Proxy, listener: anytype, data: anytype) void {
    if (c.wl_proxy_add_listener(proxy, @ptrCast(@constCast(listener)), data) != 0) std.process.exit(1);
}
fn create(proxy: *Proxy, opcode: u32, interface: *const c.wl_interface) *Proxy {
    return c.wl_proxy_marshal_flags(proxy, opcode, interface, 1, 0, @as(?*anyopaque, null)) orelse std.process.exit(1);
}
const Password = struct {
    bytes: [1024:0]u8 = @splat(0),
    len: usize = 0,
    fn clear(self: *Password) void {
        std.crypto.secureZero(u8, &self.bytes);
        self.len = 0;
    }
    fn backspace(self: *Password) void {
        if (self.len == 0) return;
        self.len -= 1;
        while (self.len > 0 and self.bytes[self.len] & 0xc0 == 0x80) self.len -= 1;
        std.crypto.secureZero(u8, self.bytes[self.len..]);
    }
    fn append(self: *Password, value: []const u8) void {
        if (value.len > self.bytes.len - self.len - 1) return;
        @memcpy(self.bytes[self.len..][0..value.len], value);
        self.len += value.len;
        self.bytes[self.len] = 0;
    }
};
const Buffer = struct {
    proxy: *c.wl_buffer,
    memory: *anyopaque,
    size: usize,
    fn release(data: ?*anyopaque, _: ?*c.wl_buffer) callconv(.c) void {
        const self = cast(Buffer, data);
        c.wl_buffer_destroy(self.proxy);
        _ = libc.munmap(self.memory, self.size);
        a.destroy(self);
    }
};
const buffer_listener = extern struct { release: *const @TypeOf(Buffer.release) }{ .release = Buffer.release };
const Output = struct {
    state: *State,
    name: u32,
    proxy: *c.wl_output,
    surface: ?*Proxy = null,
    lock_surface: ?*Proxy = null,
    width: u32 = 0,
    height: u32 = 0,
    scale: u32 = 1,
    /// The blurred wallpaper at the current buffer size, painted once per size.
    backdrop: []u32 = &.{},
    backdrop_width: u32 = 0,
    backdrop_height: u32 = 0,
    next: ?*Output = null,
    fn lock(self: *Output) void {
        if (self.lock_surface != null) return;
        const s = self.state;
        // Surfaces inherit the compositor's version so buffer scale is available.
        self.surface = c.wl_proxy_marshal_flags(s.compositor.?, 0, &wayland.wl_surface_interface, c.wl_proxy_get_version(s.compositor.?), 0, @as(?*anyopaque, null)) orelse std.process.exit(1);
        self.lock_surface = c.wl_proxy_marshal_flags(s.lock.?, 1, &p.ext_session_lock_surface_v1_interface, 1, 0, @as(?*anyopaque, null), self.surface.?, self.proxy) orelse std.process.exit(1);
        listen(self.lock_surface.?, &surface_listener, self);
    }
    fn render(self: *Output) void {
        if (self.width == 0 or self.height == 0 or self.surface == null) return;
        const s = self.state;
        // Integer buffer scale, as the shell's own surfaces use, needs wl_surface v3.
        const versioned = c.wl_proxy_get_version(self.surface.?) >= 3;
        const scale: u32 = if (versioned) self.scale else 1;
        const width = self.width * scale;
        const height = self.height * scale;
        if (width > 16384 or height > 16384 or @as(u64, width) * height > 64 * 1024 * 1024) std.process.exit(1);
        const size: usize = @as(usize, width) * height * 4;
        const shm = c.__zig.createShmBuffer(s.shm, "desktop-lock", size, width, height, width * 4, c.WL_SHM_FORMAT_XRGB8888) catch std.process.exit(1);
        const pixels: [*]u32 = @ptrCast(@alignCast(shm.memory));
        const target: raster.Buffer = .{ .pixels = pixels[0 .. size / 4], .width = width, .height = height };
        if (self.backdrop_width != width or self.backdrop_height != height) {
            a.free(self.backdrop);
            self.backdrop = &.{};
            self.backdrop_width = 0;
            self.backdrop_height = 0;
            if (a.alloc(u32, size / 4)) |memory| {
                s.view.background(.{ .pixels = memory, .width = width, .height = height });
                self.backdrop = memory;
                self.backdrop_width = width;
                self.backdrop_height = height;
            } else |_| {}
        }
        if (self.backdrop.len == size / 4) @memcpy(target.pixels, self.backdrop) else s.view.background(target);
        s.view.paint(target, scale, s.frame());
        const buffer = shm.proxy;
        const storage = a.create(Buffer) catch std.process.exit(1);
        storage.* = .{ .proxy = buffer, .memory = shm.memory, .size = size };
        listen(cast(Proxy, buffer), &buffer_listener, storage);
        if (versioned) _ = c.wl_proxy_marshal_flags(self.surface.?, 8, null, c.wl_proxy_get_version(self.surface.?), 0, @as(i32, @intCast(scale)));
        _ = c.wl_proxy_marshal_flags(self.surface.?, 1, null, 1, 0, buffer, @as(i32, 0), @as(i32, 0));
        _ = c.wl_proxy_marshal_flags(self.surface.?, 2, null, 1, 0, @as(i32, 0), @as(i32, 0), @as(i32, @intCast(self.width)), @as(i32, @intCast(self.height)));
        request(self.surface.?, 6);
    }
    fn geometry(_: ?*anyopaque, _: ?*Proxy, _: i32, _: i32, _: i32, _: i32, _: i32, _: [*c]const u8, _: [*c]const u8, _: i32) callconv(.c) void {}
    fn mode(_: ?*anyopaque, _: ?*Proxy, _: u32, _: i32, _: i32, _: i32) callconv(.c) void {}
    fn done(_: ?*anyopaque, _: ?*Proxy) callconv(.c) void {}
    fn scaled(data: ?*anyopaque, _: ?*Proxy, factor: i32) callconv(.c) void {
        const self = cast(Output, data);
        const scale: u32 = @intCast(std.math.clamp(factor, 1, 8));
        if (scale == self.scale) return;
        self.scale = scale;
        self.render();
    }
    fn configure(data: ?*anyopaque, surface: ?*Proxy, serial: u32, width: u32, height: u32) callconv(.c) void {
        const self = cast(Output, data);
        _ = c.wl_proxy_marshal_flags(surface, 1, null, 1, 0, serial);
        self.width = width;
        self.height = height;
        self.render();
    }
    fn deinit(self: *Output) void {
        if (self.lock_surface) |proxy| destroy(proxy, 0);
        if (self.surface) |proxy| destroy(proxy, 0);
        if (self.state.pointer_output == self) self.state.pointer_output = null;
        c.wl_output_destroy(self.proxy);
        a.free(self.backdrop);
        a.destroy(self);
    }
};
const surface_listener = extern struct { configure: *const @TypeOf(Output.configure) }{ .configure = Output.configure };
const output_listener = extern struct {
    geometry: *const @TypeOf(Output.geometry),
    mode: *const @TypeOf(Output.mode),
    done: *const @TypeOf(Output.done),
    scale: *const @TypeOf(Output.scaled),
}{ .geometry = Output.geometry, .mode = Output.mode, .done = Output.done, .scale = Output.scaled };
const Seat = struct {
    state: *State,
    name: u32,
    proxy: *Proxy,
    keyboard: ?*Proxy = null,
    pointer: ?*Proxy = null,
    xkb: ?*kb.State = null,
    next: ?*Seat = null,
    fn capabilities(data: ?*anyopaque, _: ?*Proxy, flags: u32) callconv(.c) void {
        const self = cast(Seat, data);
        if (flags & 2 != 0 and self.keyboard == null) {
            self.keyboard = create(self.proxy, 1, &wayland.wl_keyboard_interface);
            listen(self.keyboard.?, &keyboard_listener, self);
        } else if (flags & 2 == 0 and self.keyboard != null) {
            c.wl_proxy_destroy(self.keyboard);
            self.keyboard = null;
            kb.xkb_state_unref(self.xkb);
            self.xkb = null;
        }
        if (flags & 1 != 0 and self.pointer == null) {
            self.pointer = create(self.proxy, 0, &wayland.wl_pointer_interface);
            listen(self.pointer.?, &pointer_listener, self);
        } else if (flags & 1 == 0 and self.pointer != null) {
            c.wl_proxy_destroy(self.pointer);
            self.pointer = null;
        }
    }
    fn pointerEnter(data: ?*anyopaque, _: ?*Proxy, _: u32, surface: ?*Proxy, x: i32, y: i32) callconv(.c) void {
        const s = cast(Seat, data).state;
        s.pointer_output = null;
        var output = s.outputs;
        while (output) |o| : (output = o.next) if (o.surface == surface) {
            s.pointer_output = o;
        };
        s.pointerMoved(x, y);
    }
    fn pointerLeave(data: ?*anyopaque, _: ?*Proxy, _: u32, _: ?*Proxy) callconv(.c) void {
        cast(Seat, data).state.pointer_output = null;
    }
    fn pointerMotion(data: ?*anyopaque, _: ?*Proxy, _: u32, x: i32, y: i32) callconv(.c) void {
        cast(Seat, data).state.pointerMoved(x, y);
    }
    fn pointerButton(data: ?*anyopaque, _: ?*Proxy, _: u32, _: u32, _: u32, pressed: u32) callconv(.c) void {
        if (pressed == 1) cast(Seat, data).state.click();
    }
    fn pointerAxis(_: ?*anyopaque, _: ?*Proxy, _: u32, _: u32, _: i32) callconv(.c) void {}
    fn seatName(_: ?*anyopaque, _: ?*Proxy, _: [*c]const u8) callconv(.c) void {}
    fn keymap(data: ?*anyopaque, _: ?*Proxy, format: u32, fd: c_int, size: u32) callconv(.c) void {
        defer _ = libc.close(fd);
        const self = cast(Seat, data);
        kb.xkb_state_unref(self.xkb);
        self.xkb = null;
        if (format != 1 or size == 0 or size > 16 * 1024 * 1024) return;
        const memory = libc.mmap(null, size, libc.PROT_READ, libc.MAP_SHARED, fd, 0);
        if (memory == libc.MAP_FAILED or memory == null) return;
        defer _ = libc.munmap(memory, size);
        const bytes: [*]const u8 = @ptrCast(memory);
        if (bytes[size - 1] != 0) return;
        const context = kb.xkb_context_new(0) orelse return;
        defer kb.xkb_context_unref(context);
        const map = kb.xkb_keymap_new_from_string(context, @ptrCast(bytes), 1, 0) orelse return;
        defer kb.xkb_keymap_unref(map);
        self.xkb = kb.xkb_state_new(map);
    }
    fn enter(_: ?*anyopaque, _: ?*Proxy, _: u32, _: ?*Proxy, _: ?*c.wl_array) callconv(.c) void {}
    fn leave(data: ?*anyopaque, _: ?*Proxy, _: u32, _: ?*Proxy) callconv(.c) void {
        const self = cast(Seat, data);
        if (!self.state.busy) {
            self.state.password.clear();
            self.state.changed();
        }
    }
    fn key(data: ?*anyopaque, _: ?*Proxy, _: u32, _: u32, code: u32, pressed: u32) callconv(.c) void {
        const self = cast(Seat, data);
        const s = self.state;
        if (pressed != 1 or self.xkb == null or s.busy or !s.locked or s.done) return;
        const symbol = kb.xkb_state_key_get_one_sym(self.xkb.?, code + 8);
        // Modifiers alone, including Caps Lock, neither reveal nor edit the prompt.
        if (symbol >= 0xffe1 and symbol <= 0xffee) return;
        s.last_activity = u.monotonicTime();
        if (s.stage == .clock) {
            // Like GNOME, any key raises the prompt and a printable one starts the password.
            s.stage = .prompt;
            if (symbol != 0xff0d and symbol != 0xff8d and symbol != 0xff1b and symbol != 0xff08) self.typeKey(code);
            _ = s.recount();
            s.render();
            return;
        }
        switch (symbol) {
            0xff0d, 0xff8d => s.authenticate(),
            0xff1b => s.showClock(),
            0xff08 => {
                s.password.backspace();
                s.changed();
            },
            else => {
                self.typeKey(code);
                s.changed();
            },
        }
    }
    fn typeKey(self: *Seat, code: u32) void {
        var bytes: [64]u8 = @splat(0);
        defer std.crypto.secureZero(u8, &bytes);
        const len = kb.xkb_state_key_get_utf8(self.xkb.?, code + 8, &bytes, bytes.len);
        if (len > 0 and len < bytes.len and bytes[0] >= 32 and bytes[0] != 127) self.state.password.append(bytes[0..@intCast(len)]);
    }
    fn modifiers(data: ?*anyopaque, _: ?*Proxy, _: u32, depressed: u32, latched: u32, locked: u32, group: u32) callconv(.c) void {
        const state = cast(Seat, data).xkb orelse return;
        _ = kb.xkb_state_update_mask(state, depressed, latched, locked, 0, 0, group);
        const s = cast(Seat, data).state;
        const caps = kb.xkb_state_mod_name_is_active(state, "Lock", 1 << 3) > 0;
        if (caps == s.caps_lock) return;
        s.caps_lock = caps;
        if (s.stage == .prompt) s.render();
    }
    fn deinit(self: *Seat) void {
        if (self.keyboard) |keyboard| c.wl_proxy_destroy(keyboard);
        if (self.pointer) |pointer| c.wl_proxy_destroy(pointer);
        kb.xkb_state_unref(self.xkb);
        c.wl_proxy_destroy(self.proxy);
        a.destroy(self);
    }
};
const seat_listener = extern struct { capabilities: *const @TypeOf(Seat.capabilities), name: *const @TypeOf(Seat.seatName) }{ .capabilities = Seat.capabilities, .name = Seat.seatName };
const keyboard_listener = extern struct {
    keymap: *const @TypeOf(Seat.keymap),
    enter: *const @TypeOf(Seat.enter),
    leave: *const @TypeOf(Seat.leave),
    key: *const @TypeOf(Seat.key),
    modifiers: *const @TypeOf(Seat.modifiers),
}{ .keymap = Seat.keymap, .enter = Seat.enter, .leave = Seat.leave, .key = Seat.key, .modifiers = Seat.modifiers };
const pointer_listener = extern struct {
    enter: *const @TypeOf(Seat.pointerEnter),
    leave: *const @TypeOf(Seat.pointerLeave),
    motion: *const @TypeOf(Seat.pointerMotion),
    button: *const @TypeOf(Seat.pointerButton),
    axis: *const @TypeOf(Seat.pointerAxis),
}{ .enter = Seat.pointerEnter, .leave = Seat.pointerLeave, .motion = Seat.pointerMotion, .button = Seat.pointerButton, .axis = Seat.pointerAxis };
/// GNOME returns an unattended prompt to the clock after two minutes.
const prompt_timeout_us = 120 * std.time.us_per_s;
const State = struct {
    display: *c.wl_display,
    compositor: ?*Proxy = null,
    shm: ?*c.wl_shm = null,
    manager: ?*Proxy = null,
    lock: ?*Proxy = null,
    outputs: ?*Output = null,
    seats: ?*Seat = null,
    view: *view.View,
    password: *Password,
    stage: view.Stage = .clock,
    caps_lock: bool = false,
    last_activity: i64 = 0,
    spinner: c.guint = 0,
    pointer_output: ?*Output = null,
    pointer_x: f64 = 0,
    pointer_y: f64 = 0,
    user: [*:0]const u8,
    authenticator: *const fn ([*:0]const u8, [*:0]const u8) bool = auth.authenticate,
    ready_fd: c_int = -1,
    managed_readiness: bool = false,
    locked: bool = false,
    done: bool = false,
    unlocked: bool = false,
    busy: bool = false,
    failed: bool = false,
    /// Characters shown as dots, tracked on the main thread so rendering never
    /// reads the password while the authentication thread may be clearing it.
    typed: usize = 0,
    fn render(self: *State) void {
        var output = self.outputs;
        while (output) |o| : (output = o.next) o.render();
    }
    fn frame(self: *const State) view.Frame {
        const period = 800 * std.time.us_per_ms;
        const phase: f64 = @floatFromInt(@mod(u.monotonicTime(), period));
        return .{
            .stage = self.stage,
            .status = if (self.failed) .failed else if (self.busy) .authenticating else .ready,
            .typed = self.typed,
            .caps_lock = self.caps_lock,
            .spin = phase / period * 2 * std.math.pi,
        };
    }
    /// Recounts typed characters; returns whether the count changed.
    fn recount(self: *State) bool {
        var count: usize = 0;
        for (self.password.bytes[0..self.password.len]) |byte| count += @intFromBool(byte & 0xc0 != 0x80);
        if (count == self.typed) return false;
        self.typed = count;
        // Typing again after a rejection returns to the normal prompt.
        if (count > 0) self.failed = false;
        return true;
    }
    fn changed(self: *State) void {
        if (self.recount()) self.render();
    }
    fn showClock(self: *State) void {
        // The worker thread owns the password while PAM runs.
        if (self.busy) return;
        self.password.clear();
        self.typed = 0;
        self.failed = false;
        self.stage = .clock;
        self.render();
    }
    fn pointerMoved(self: *State, x: i32, y: i32) void {
        self.pointer_x = @as(f64, @floatFromInt(x)) / 256;
        self.pointer_y = @as(f64, @floatFromInt(y)) / 256;
    }
    fn click(self: *State) void {
        if (self.busy or !self.locked or self.done) return;
        self.last_activity = u.monotonicTime();
        if (self.stage == .clock) {
            self.stage = .prompt;
            self.render();
            return;
        }
        const output = self.pointer_output orelse return;
        const layout = view.Layout.compute(@floatFromInt(output.width), @floatFromInt(output.height));
        if (layout.back.contains(self.pointer_x, self.pointer_y)) self.showClock();
    }
    /// Once a second: advance the clock and retire an unattended prompt.
    fn tick(data: ?*anyopaque) callconv(.c) c_int {
        const self = cast(State, data);
        if (self.stage == .prompt and !self.busy and u.monotonicTime() - self.last_activity > prompt_timeout_us) {
            _ = self.view.tick();
            self.showClock();
        } else if (self.view.tick() and self.stage == .clock) self.render();
        return 1;
    }
    fn spin(data: ?*anyopaque) callconv(.c) c_int {
        const self = cast(State, data);
        if (!self.busy or self.failed or self.done) {
            self.spinner = 0;
            return 0;
        }
        self.render();
        return 1;
    }
    fn authenticate(self: *State) void {
        if (self.password.len == 0) return;
        self.busy = true;
        self.failed = false;
        self.render();
        if (self.spinner == 0) self.spinner = c.g_timeout_add(50, &spin, self);
        const task = c.g_task_new(null, null, &authDone, self);
        c.g_task_set_task_data(task, self, null);
        c.g_task_run_in_thread(task, &authWork);
        c.g_object_unref(task);
    }
    fn authWork(task: ?*c.GTask, _: ?*anyopaque, data: ?*anyopaque, _: [*c]c.GCancellable) callconv(.c) void {
        const self = cast(State, data);
        const success = self.authenticator(self.user, &self.password.bytes);
        if (success) {
            screenLocked(false);
            unlockSecrets(self.password.bytes[0..self.password.len]);
        }
        self.password.clear();
        c.g_task_return_boolean(task, @intFromBool(success));
    }
    fn authDone(_: [*c]c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self = cast(State, data);
        self.busy = false;
        self.typed = 0;
        if (c.g_task_propagate_boolean(@ptrCast(result), null) != 0 and self.locked and !self.done) {
            self.done = true;
            // Revoke managed readiness before the compositor processes unlock.
            if (self.ready_fd >= 0) {
                _ = libc.close(self.ready_fd);
                self.ready_fd = -1;
            }
            destroy(self.lock.?, 2);
            self.lock = null;
            if (c.wl_display_roundtrip(self.display) < 0) std.process.exit(1);
            self.unlocked = true;
            self.done = true;
        } else {
            self.failed = true;
            if (!self.done) {
                self.busy = true;
                _ = c.g_timeout_add(1500, &retry, self);
                self.render();
            }
        }
    }
    fn retry(data: ?*anyopaque) callconv(.c) c_int {
        cast(State, data).busy = false;
        return 0;
    }
    fn lockedEvent(data: ?*anyopaque, _: ?*Proxy) callconv(.c) void {
        const self = cast(State, data);
        self.locked = true;
        screenLocked(true);
        if (self.ready_fd >= 0) {
            // Keep protecting the session if the requesting shell has exited.
            if (libc.write(self.ready_fd, "1", 1) != 1) std.log.warn("lock readiness receiver disconnected", .{});
            if (!self.managed_readiness) {
                _ = libc.close(self.ready_fd);
                self.ready_fd = -1;
            }
        }
    }
    fn finished(data: ?*anyopaque, _: ?*Proxy) callconv(.c) void {
        const self = cast(State, data);
        // Never send unlock on rejection or compositor termination.
        self.done = true;
    }
    fn global(data: ?*anyopaque, registry: ?*c.wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
        const self = cast(State, data);
        const kind = std.mem.span(interface);
        if (std.mem.eql(u8, kind, "wl_compositor")) {
            self.compositor = cast(Proxy, c.wl_registry_bind(registry, name, &wayland.wl_compositor_interface, @min(version, 4)));
        } else if (std.mem.eql(u8, kind, "wl_shm")) {
            self.shm = cast(c.wl_shm, c.wl_registry_bind(registry, name, &wayland.wl_shm_interface, 1));
        } else if (std.mem.eql(u8, kind, "ext_session_lock_manager_v1")) {
            self.manager = cast(Proxy, c.wl_registry_bind(registry, name, &p.ext_session_lock_manager_v1_interface, 1));
        } else if (std.mem.eql(u8, kind, "wl_output")) {
            const output = a.create(Output) catch std.process.exit(1);
            output.* = .{ .state = self, .name = name, .proxy = cast(c.wl_output, c.wl_registry_bind(registry, name, &wayland.wl_output_interface, @min(version, 2))), .next = self.outputs };
            listen(cast(Proxy, output.proxy), &output_listener, output);
            self.outputs = output;
            if (self.lock != null) output.lock();
        } else if (std.mem.eql(u8, kind, "wl_seat")) {
            const seat = a.create(Seat) catch std.process.exit(1);
            seat.* = .{ .state = self, .name = name, .proxy = cast(Proxy, c.wl_registry_bind(registry, name, &wayland.wl_seat_interface, 1)), .next = self.seats };
            self.seats = seat;
            listen(seat.proxy, &seat_listener, seat);
        }
    }
    fn remove(data: ?*anyopaque, _: ?*c.wl_registry, name: u32) callconv(.c) void {
        const self = cast(State, data);
        var output = &self.outputs;
        while (output.*) |o| {
            if (o.name == name) {
                output.* = o.next;
                o.deinit();
                break;
            }
            output = &o.next;
        }
        var seat = &self.seats;
        while (seat.*) |s| {
            if (s.name == name) {
                seat.* = s.next;
                s.deinit();
                break;
            }
            seat = &s.next;
        }
    }
    fn readable(_: c_int, condition: c.GIOCondition, data: ?*anyopaque) callconv(.c) c_int {
        const self = cast(State, data);
        if (condition & (c.G_IO_ERR | c.G_IO_HUP) != 0 or !c.__zig.dispatchWayland(self.display)) std.process.exit(1);
        return 1;
    }
};
const registry_listener = c.wl_registry_listener{ .global = State.global, .global_remove = State.remove };
const lock_listener = extern struct { locked: *const @TypeOf(State.lockedEvent), finished: *const @TypeOf(State.finished) }{ .locked = State.lockedEvent, .finished = State.finished };

pub fn run(args: []const []const u8) !void {
    return runWithAuthenticator(args, auth.authenticate);
}

/// Isolated protocol tests supply an authenticator without changing the module graph.
pub fn runWithAuthenticator(args: []const []const u8, authenticator: *const fn ([*:0]const u8, [*:0]const u8) bool) !void {
    var daemonize = false;
    var ready_fd: c_int = -1;
    var wallpaper: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--daemonize") or std.mem.eql(u8, arg, "-f")) {
            daemonize = true;
        } else if (std.mem.eql(u8, arg, "--wallpaper") and index + 1 < args.len and wallpaper == null) {
            index += 1;
            wallpaper = args[index];
        } else if (std.mem.eql(u8, arg, "--ready-fd") and index + 1 < args.len and ready_fd < 0) {
            index += 1;
            ready_fd = std.fmt.parseInt(c_int, args[index], 10) catch return error.InvalidReadyFd;
            if (ready_fd < 3) return error.InvalidReadyFd;
        } else return error.InvalidLockArguments;
    }
    if (daemonize and ready_fd >= 0) return error.InvalidLockArguments;
    if (daemonize) {
        var fds: [2]c_int = undefined;
        if (libc.pipe2(&fds, libc.O_CLOEXEC) != 0) return error.PipeFailed;
        const pid = libc.fork();
        if (pid < 0) {
            _ = libc.close(fds[0]);
            _ = libc.close(fds[1]);
            return error.ForkFailed;
        }
        if (pid > 0) {
            _ = libc.close(fds[1]);
            defer _ = libc.close(fds[0]);
            var byte: u8 = 0;
            var got: isize = undefined;
            while (true) {
                got = libc.read(fds[0], &byte, 1);
                if (got >= 0 or libc.__errno_location().* != 4) break;
            }
            if (got != 1 or byte != '1') {
                _ = libc.waitpid(pid, null, 0);
                return error.LockNotAcquired;
            }
            return;
        }
        _ = libc.close(fds[0]);
        ready_fd = fds[1];
        _ = libc.setsid();
    }
    defer {
        if (ready_fd >= 0) _ = libc.close(ready_fd);
    }
    if (libc.prctl(libc.PR_SET_DUMPABLE, @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0)) != 0) return error.PrctlFailed;
    // Terminating the client leaves the compositor locked; ignore ordinary logout signals.
    _ = libc.signal(libc.SIGTERM, @ptrFromInt(1));
    _ = libc.signal(libc.SIGHUP, @ptrFromInt(1));
    _ = libc.signal(@intCast(@backingInt(std.posix.SIG.PIPE)), @ptrFromInt(1));
    _ = libc.signal(@intCast(@backingInt(std.posix.SIG.INT)), @ptrFromInt(1));
    const password = try a.create(Password);
    password.* = .{};
    defer a.destroy(password);
    if (libc.mlock(password, @sizeOf(Password)) != 0) return error.SecretMemoryLockFailed;
    defer {
        password.clear();
        _ = libc.munlock(password, @sizeOf(Password));
    }
    const user = libc.getpwuid(libc.getuid());
    if (user == null) return error.UnknownUser;
    const username = try a.dupeSentinel(u8, std.mem.span(user.*.pw_name), 0);
    defer a.free(username);
    const display = c.wl_display_connect(null) orelse return error.NoWaylandDisplay;
    defer c.wl_display_disconnect(display);
    // Prepare public labels and the blurred wallpaper before requesting the session lock.
    const wallpaper_path = if (wallpaper) |path| try a.dupeSentinel(u8, path, 0) else null;
    defer if (wallpaper_path) |path| a.free(path);
    const avatar_path = try std.fmt.allocPrintSentinel(a, "/var/lib/AccountsService/icons/{s}", .{username}, 0);
    defer a.free(avatar_path);
    // GECOS starts with the full name, as GNOME's user widget shows it.
    const gecos: []const u8 = if (user.*.pw_gecos) |field| std.mem.sliceTo(std.mem.span(field), ',') else "";
    var lock_view = try view.View.init(a, .{
        .wallpaper = if (wallpaper_path) |path| path.ptr else null,
        .avatar = avatar_path.ptr,
        .name = if (gecos.len > 0 and std.unicode.utf8ValidateSlice(gecos)) gecos else username,
    });
    defer lock_view.deinit();
    var state = State{ .view = &lock_view, .display = display, .password = password, .user = username.ptr, .authenticator = authenticator, .ready_fd = ready_fd, .managed_readiness = !daemonize and ready_fd >= 0 };
    const registry = c.wl_display_get_registry(display);
    _ = c.wl_registry_add_listener(registry, &registry_listener, &state);
    if (c.wl_display_roundtrip(display) < 0) return error.WaylandDisconnected;
    if (state.manager == null or state.compositor == null or state.shm == null) return error.SessionLockUnavailable;
    state.lock = create(state.manager.?, 1, &p.ext_session_lock_v1_interface);
    listen(state.lock.?, &lock_listener, &state);
    var output = state.outputs;
    while (output) |o| : (output = o.next) o.lock();
    const source = c.g_unix_fd_add(c.wl_display_get_fd(display), c.G_IO_IN | c.G_IO_ERR | c.G_IO_HUP, &State.readable, &state);
    defer _ = c.g_source_remove(source);
    const clock = c.g_timeout_add_seconds(1, &State.tick, &state);
    defer _ = c.g_source_remove(clock);
    defer if (state.spinner != 0) {
        _ = c.g_source_remove(state.spinner);
    };
    while (!state.done) {
        _ = c.wl_display_flush(display);
        _ = c.g_main_context_iteration(null, 1);
    }
    // Keep the worker and its secrets alive until its completion callback has run.
    while (state.busy) _ = c.g_main_context_iteration(null, 1);
    ready_fd = state.ready_fd;
    if (!state.unlocked) return error.LockNotAcquired;
}

test "password handles Unicode backspace, capacity, and complete erasure" {
    var password = Password{};
    password.append("a日本");
    password.backspace();
    try std.testing.expectEqualStrings("a日", password.bytes[0..password.len]);
    password.backspace();
    password.backspace();
    password.backspace();
    try std.testing.expectEqual(@as(usize, 0), password.len);
    var too_long: [1024]u8 = @splat('a');
    password.append(&too_long);
    try std.testing.expectEqual(@as(usize, 0), password.len);
    password.append("secret");
    password.clear();
    for (password.bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}
