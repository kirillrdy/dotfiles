//! Independent ext-session-lock client. Only successful PAM authentication sends unlock.
const std = @import("std");
const c = @import("gtk");
const libc = @import("libc");
const p = @import("protocols");
const auth = @import("lock-auth");
const a = std.heap.page_allocator;
const Proxy = c.wl_proxy;
extern const wl_compositor_interface: c.wl_interface;
extern const wl_surface_interface: c.wl_interface;
extern const wl_keyboard_interface: c.wl_interface;
const XkbContext = opaque {};
const XkbKeymap = opaque {};
const XkbState = opaque {};
extern fn xkb_context_new(c_int) ?*XkbContext;
extern fn xkb_context_unref(?*XkbContext) void;
extern fn xkb_keymap_new_from_string(*XkbContext, [*:0]const u8, c_int, c_int) ?*XkbKeymap;
extern fn xkb_keymap_unref(?*XkbKeymap) void;
extern fn xkb_state_new(*XkbKeymap) ?*XkbState;
extern fn xkb_state_unref(?*XkbState) void;
extern fn xkb_state_update_mask(*XkbState, u32, u32, u32, u32, u32, u32) c_int;
extern fn xkb_state_key_get_one_sym(*XkbState, u32) u32;
extern fn xkb_state_key_get_utf8(*XkbState, u32, [*]u8, usize) c_int;
extern fn mlock(*const anyopaque, usize) c_int;
extern fn munlock(*const anyopaque, usize) c_int;
extern fn signal(c_int, ?*const fn (c_int) callconv(.c) void) ?*const fn (c_int) callconv(.c) void;
extern fn setsid() c_int;

fn cast(comptime T: type, ptr: anytype) *T {
    return @ptrCast(@alignCast(ptr));
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
    next: ?*Output = null,
    fn lock(self: *Output) void {
        if (self.lock_surface != null) return;
        const s = self.state;
        self.surface = create(s.compositor.?, 0, &wl_surface_interface);
        self.lock_surface = c.wl_proxy_marshal_flags(s.lock.?, 1, &p.ext_session_lock_surface_v1_interface, 1, 0, @as(?*anyopaque, null), self.surface.?, self.proxy) orelse std.process.exit(1);
        listen(self.lock_surface.?, &surface_listener, self);
    }
    fn render(self: *Output) void {
        if (self.width == 0 or self.height == 0) return;
        const width = self.width;
        const height = self.height;
        if (width > 16384 or height > 16384 or @as(u64, width) * height > 32 * 1024 * 1024) std.process.exit(1);
        const size: usize = @as(usize, width) * height * 4;
        const fd = libc.memfd_create("desktop-lock", libc.MFD_CLOEXEC);
        if (fd < 0) std.process.exit(1);
        defer _ = libc.close(fd);
        if (libc.ftruncate(fd, @intCast(size)) != 0) std.process.exit(1);
        const memory = libc.mmap(null, size, libc.PROT_READ | libc.PROT_WRITE, libc.MAP_SHARED, fd, 0);
        if (memory == libc.MAP_FAILED or memory == null) std.process.exit(1);
        const image = c.cairo_image_surface_create_for_data(@ptrCast(memory), c.CAIRO_FORMAT_RGB24, @intCast(width), @intCast(height), @intCast(width * 4));
        const cr = c.cairo_create(image);
        c.cairo_set_source_rgb(cr, 0.118, 0.118, 0.18);
        c.cairo_paint(cr);
        c.cairo_set_source_rgb(cr, 1, 1, 1);
        c.cairo_select_font_face(cr, "Adwaita Sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_NORMAL);
        c.cairo_set_font_size(cr, 26);
        c.cairo_move_to(cr, @as(f64, @floatFromInt(width)) / 2 - 105, @as(f64, @floatFromInt(height)) / 2 - 35);
        c.cairo_show_text(cr, "Session locked");
        c.cairo_set_font_size(cr, 17);
        c.cairo_move_to(cr, @as(f64, @floatFromInt(width)) / 2 - 105, @as(f64, @floatFromInt(height)) / 2 + 5);
        const s = self.state;
        c.cairo_show_text(cr, if (s.failed) "Try again" else if (s.busy) "Authenticating…" else "Password, then Enter");
        // Never render password length or password contents.
        c.cairo_destroy(cr);
        c.cairo_surface_flush(image);
        c.cairo_surface_destroy(image);
        const pool = c.wl_shm_create_pool(s.shm, fd, @intCast(size));
        const buffer = c.wl_shm_pool_create_buffer(pool, 0, @intCast(width), @intCast(height), @intCast(width * 4), c.WL_SHM_FORMAT_XRGB8888) orelse std.process.exit(1);
        c.wl_shm_pool_destroy(pool);
        const storage = a.create(Buffer) catch std.process.exit(1);
        storage.* = .{ .proxy = buffer, .memory = memory.?, .size = size };
        listen(cast(Proxy, buffer), &buffer_listener, storage);
        _ = c.wl_proxy_marshal_flags(self.surface.?, 1, null, 1, 0, buffer, @as(i32, 0), @as(i32, 0));
        _ = c.wl_proxy_marshal_flags(self.surface.?, 2, null, 1, 0, @as(i32, 0), @as(i32, 0), @as(i32, @intCast(width)), @as(i32, @intCast(height)));
        request(self.surface.?, 6);
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
        c.wl_output_destroy(self.proxy);
        a.destroy(self);
    }
};
const surface_listener = extern struct { configure: *const @TypeOf(Output.configure) }{ .configure = Output.configure };
const Seat = struct {
    state: *State,
    name: u32,
    proxy: *Proxy,
    keyboard: ?*Proxy = null,
    xkb: ?*XkbState = null,
    next: ?*Seat = null,
    fn capabilities(data: ?*anyopaque, _: ?*Proxy, flags: u32) callconv(.c) void {
        const self = cast(Seat, data);
        if (flags & 2 != 0 and self.keyboard == null) {
            self.keyboard = create(self.proxy, 1, &wl_keyboard_interface);
            listen(self.keyboard.?, &keyboard_listener, self);
        } else if (flags & 2 == 0 and self.keyboard != null) {
            c.wl_proxy_destroy(self.keyboard);
            self.keyboard = null;
            xkb_state_unref(self.xkb);
            self.xkb = null;
        }
    }
    fn seatName(_: ?*anyopaque, _: ?*Proxy, _: [*c]const u8) callconv(.c) void {}
    fn keymap(data: ?*anyopaque, _: ?*Proxy, format: u32, fd: c_int, size: u32) callconv(.c) void {
        defer _ = libc.close(fd);
        const self = cast(Seat, data);
        xkb_state_unref(self.xkb);
        self.xkb = null;
        if (format != 1 or size == 0 or size > 16 * 1024 * 1024) return;
        const memory = libc.mmap(null, size, libc.PROT_READ, libc.MAP_SHARED, fd, 0);
        if (memory == libc.MAP_FAILED or memory == null) return;
        defer _ = libc.munmap(memory, size);
        const bytes: [*]const u8 = @ptrCast(memory);
        if (bytes[size - 1] != 0) return;
        const context = xkb_context_new(0) orelse return;
        defer xkb_context_unref(context);
        const map = xkb_keymap_new_from_string(context, @ptrCast(bytes), 1, 0) orelse return;
        defer xkb_keymap_unref(map);
        self.xkb = xkb_state_new(map);
    }
    fn enter(_: ?*anyopaque, _: ?*Proxy, _: u32, _: ?*Proxy, _: ?*c.wl_array) callconv(.c) void {}
    fn leave(data: ?*anyopaque, _: ?*Proxy, _: u32, _: ?*Proxy) callconv(.c) void {
        const self = cast(Seat, data);
        if (!self.state.busy) self.state.password.clear();
    }
    fn key(data: ?*anyopaque, _: ?*Proxy, _: u32, _: u32, code: u32, pressed: u32) callconv(.c) void {
        const self = cast(Seat, data);
        const s = self.state;
        if (pressed != 1 or self.xkb == null or s.busy or !s.locked or s.done) return;
        const symbol = xkb_state_key_get_one_sym(self.xkb.?, code + 8);
        switch (symbol) {
            0xff0d, 0xff8d => s.authenticate(),
            0xff1b => {
                s.password.clear();
                s.failed = false;
                s.render();
            },
            0xff08 => s.password.backspace(),
            else => {
                var bytes: [64]u8 = @splat(0);
                defer std.crypto.secureZero(u8, &bytes);
                const len = xkb_state_key_get_utf8(self.xkb.?, code + 8, &bytes, bytes.len);
                if (len > 0 and len < bytes.len and bytes[0] >= 32 and bytes[0] != 127) s.password.append(bytes[0..@intCast(len)]);
            },
        }
    }
    fn modifiers(data: ?*anyopaque, _: ?*Proxy, _: u32, depressed: u32, latched: u32, locked: u32, group: u32) callconv(.c) void {
        if (cast(Seat, data).xkb) |state| _ = xkb_state_update_mask(state, depressed, latched, locked, 0, 0, group);
    }
    fn deinit(self: *Seat) void {
        if (self.keyboard) |keyboard| c.wl_proxy_destroy(keyboard);
        xkb_state_unref(self.xkb);
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
const State = struct {
    display: *c.wl_display,
    compositor: ?*Proxy = null,
    shm: ?*c.wl_shm = null,
    manager: ?*Proxy = null,
    lock: ?*Proxy = null,
    outputs: ?*Output = null,
    seats: ?*Seat = null,
    password: *Password,
    user: [*:0]const u8,
    ready_fd: c_int = -1,
    locked: bool = false,
    done: bool = false,
    unlocked: bool = false,
    busy: bool = false,
    failed: bool = false,
    fn render(self: *State) void {
        var output = self.outputs;
        while (output) |o| : (output = o.next) o.render();
    }
    fn authenticate(self: *State) void {
        if (self.password.len == 0) return;
        self.busy = true;
        self.failed = false;
        self.render();
        const task = c.g_task_new(null, null, &authDone, self);
        c.g_task_set_task_data(task, self, null);
        c.g_task_run_in_thread(task, &authWork);
        c.g_object_unref(task);
    }
    fn authWork(task: ?*c.GTask, _: ?*anyopaque, data: ?*anyopaque, _: [*c]c.GCancellable) callconv(.c) void {
        const self = cast(State, data);
        const success = auth.authenticate(self.user, &self.password.bytes);
        self.password.clear();
        c.g_task_return_boolean(task, @intFromBool(success));
    }
    fn authDone(_: [*c]c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self = cast(State, data);
        self.busy = false;
        if (c.g_task_propagate_boolean(@ptrCast(result), null) != 0 and self.locked and !self.done) {
            self.done = true;
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
        if (self.ready_fd >= 0) {
            if (libc.write(self.ready_fd, "1", 1) != 1) std.process.exit(1);
            _ = libc.close(self.ready_fd);
            self.ready_fd = -1;
        }
    }
    fn finished(data: ?*anyopaque, _: ?*Proxy) callconv(.c) void {
        const self = cast(State, data);
        // Never send unlock on rejection or compositor termination.
        self.done = true;
    }
    fn global(data: ?*anyopaque, registry: ?*c.wl_registry, name: u32, interface: [*c]const u8, _: u32) callconv(.c) void {
        const self = cast(State, data);
        const kind = std.mem.span(interface);
        if (std.mem.eql(u8, kind, "wl_compositor")) {
            self.compositor = cast(Proxy, c.wl_registry_bind(registry, name, &wl_compositor_interface, 1));
        } else if (std.mem.eql(u8, kind, "wl_shm")) {
            self.shm = cast(c.wl_shm, c.wl_registry_bind(registry, name, &c.wl_shm_interface, 1));
        } else if (std.mem.eql(u8, kind, "ext_session_lock_manager_v1")) {
            self.manager = cast(Proxy, c.wl_registry_bind(registry, name, &p.ext_session_lock_manager_v1_interface, 1));
        } else if (std.mem.eql(u8, kind, "wl_output")) {
            const output = a.create(Output) catch std.process.exit(1);
            output.* = .{ .state = self, .name = name, .proxy = cast(c.wl_output, c.wl_registry_bind(registry, name, &c.wl_output_interface, 1)), .next = self.outputs };
            self.outputs = output;
            if (self.lock != null) output.lock();
        } else if (std.mem.eql(u8, kind, "wl_seat")) {
            const seat = a.create(Seat) catch std.process.exit(1);
            seat.* = .{ .state = self, .name = name, .proxy = cast(Proxy, c.wl_registry_bind(registry, name, &c.wl_seat_interface, 1)), .next = self.seats };
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
        if (condition & (c.G_IO_ERR | c.G_IO_HUP) != 0 or c.wl_display_dispatch(self.display) < 0) std.process.exit(1);
        return 1;
    }
};
const registry_listener = c.wl_registry_listener{ .global = State.global, .global_remove = State.remove };
const lock_listener = extern struct { locked: *const @TypeOf(State.lockedEvent), finished: *const @TypeOf(State.finished) }{ .locked = State.lockedEvent, .finished = State.finished };

pub fn run(args: []const []const u8) !void {
    var daemonize = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--daemonize") or std.mem.eql(u8, arg, "-f")) daemonize = true else return error.InvalidLockArguments;
    }
    var ready_fd: c_int = -1;
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
        _ = setsid();
    }
    defer {
        if (ready_fd >= 0) _ = libc.close(ready_fd);
    }
    if (libc.prctl(libc.PR_SET_DUMPABLE, @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0)) != 0) return error.PrctlFailed;
    // Terminating the client leaves the compositor locked; ignore ordinary logout signals.
    _ = signal(libc.SIGTERM, @ptrFromInt(1));
    _ = signal(libc.SIGHUP, @ptrFromInt(1));
    _ = signal(@intCast(@backingInt(std.posix.SIG.INT)), @ptrFromInt(1));
    const password = try a.create(Password);
    password.* = .{};
    defer a.destroy(password);
    if (mlock(password, @sizeOf(Password)) != 0) return error.SecretMemoryLockFailed;
    defer {
        password.clear();
        _ = munlock(password, @sizeOf(Password));
    }
    const user = libc.getpwuid(libc.getuid());
    if (user == null) return error.UnknownUser;
    const username = try a.dupeSentinel(u8, std.mem.span(user.*.pw_name), 0);
    defer a.free(username);
    const display = c.wl_display_connect(null) orelse return error.NoWaylandDisplay;
    defer c.wl_display_disconnect(display);
    var state = State{ .display = display, .password = password, .user = username.ptr, .ready_fd = ready_fd };
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
