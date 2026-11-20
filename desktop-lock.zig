//! Independent ext-session-lock client. Only successful PAM authentication sends unlock.
const std = @import("std");
const wl = @import("wayland-client");
const wire = @import("wayland-wire");
const helpers = @import("desktop-wayland-client.zig");
const c = @import("desktop-glib.zig");
const libc = @import("desktop-libc.zig");
const auth = @import("desktop-lock-auth.zig");
const view = @import("desktop-lock-view.zig");
const raster = @import("desktop-raster.zig");
const a = std.heap.page_allocator;
const kb = @import("desktop-keyboard.zig");
const u = @import("desktop-util.zig");

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
/// One shared-memory frame, freed when the compositor releases it.
const Buffer = struct {
    shm: helpers.ShmBuffer,
    fn create(shm: wl.wl_shm, width: u32, height: u32) !*Buffer {
        const frame = try helpers.shmBuffer(shm, "desktop-lock", width, height, wl.wl_shm.Format.xrgb8888);
        errdefer {
            frame.buffer.destroy();
            frame.unmap();
        }
        const self = try a.create(Buffer);
        self.* = .{ .shm = frame };
        frame.buffer.listen(Buffer, self, released);
        return self;
    }
    fn released(self: *Buffer, buffer: wl.wl_buffer, _: wl.wl_buffer.Event) void {
        buffer.destroy();
        self.shm.unmap();
        a.destroy(self);
    }
};
const Output = struct {
    state: *State,
    name: u32,
    output: wl.wl_output,
    surface: ?wl.wl_surface = null,
    lock_surface: ?wl.ext_session_lock_surface_v1 = null,
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
        const surface = s.compositor.?.create_surface();
        self.surface = surface;
        const lock_surface = s.lock.?.get_lock_surface(surface, self.output);
        self.lock_surface = lock_surface;
        lock_surface.listen(Output, self, configured);
    }
    fn render(self: *Output) void {
        if (self.width == 0 or self.height == 0) return;
        const surface = self.surface orelse return;
        const s = self.state;
        // Integer buffer scale, as the shell's own surfaces use, needs wl_surface v3.
        const versioned = surface.version() >= 3;
        const scale: u32 = if (versioned) self.scale else 1;
        const width = self.width * scale;
        const height = self.height * scale;
        if (width > 16384 or height > 16384 or @as(u64, width) * height > 64 * 1024 * 1024) std.process.exit(1);
        const frame = Buffer.create(s.shm.?, width, height) catch std.process.exit(1);
        const pixels: [*]u32 = @ptrCast(@alignCast(frame.shm.memory));
        const target: raster.Buffer = .{ .pixels = pixels[0 .. frame.shm.size / 4], .width = width, .height = height };
        if (self.backdrop_width != width or self.backdrop_height != height) {
            a.free(self.backdrop);
            self.backdrop = &.{};
            self.backdrop_width = 0;
            self.backdrop_height = 0;
            if (a.alloc(u32, frame.shm.size / 4)) |memory| {
                s.view.background(.{ .pixels = memory, .width = width, .height = height });
                self.backdrop = memory;
                self.backdrop_width = width;
                self.backdrop_height = height;
            } else |_| {}
        }
        if (self.backdrop.len == target.pixels.len) @memcpy(target.pixels, self.backdrop) else s.view.background(target);
        s.view.paint(target, scale, s.frame());
        if (versioned) surface.set_buffer_scale(@intCast(scale));
        surface.attach(frame.shm.buffer, 0, 0);
        surface.damage(0, 0, @intCast(self.width), @intCast(self.height));
        surface.commit();
    }
    fn outputEvent(self: *Output, _: wl.wl_output, event: wl.wl_output.Event) void {
        switch (event) {
            .scale => |value| {
                const scale: u32 = @intCast(std.math.clamp(value.factor, 1, 8));
                if (scale == self.scale) return;
                self.scale = scale;
                self.render();
            },
            else => {},
        }
    }
    fn configured(self: *Output, lock_surface: wl.ext_session_lock_surface_v1, event: wl.ext_session_lock_surface_v1.Event) void {
        const value = event.configure;
        lock_surface.ack_configure(value.serial);
        self.width = value.width;
        self.height = value.height;
        self.render();
    }
    fn deinit(self: *Output) void {
        if (self.lock_surface) |value| value.destroy();
        if (self.surface) |value| value.destroy();
        if (self.state.pointer_output == self) self.state.pointer_output = null;
        if (self.output.version() >= 3) self.output.release() else self.output.destroy();
        a.free(self.backdrop);
        a.destroy(self);
    }
};
const Seat = struct {
    state: *State,
    name: u32,
    seat: wl.wl_seat,
    keyboard: ?wl.wl_keyboard = null,
    pointer: ?wl.wl_pointer = null,
    xkb: ?*kb.State = null,
    next: ?*Seat = null,
    fn seatEvent(self: *Seat, seat: wl.wl_seat, event: wl.wl_seat.Event) void {
        const flags = switch (event) {
            .capabilities => |value| value.capabilities,
            else => return,
        };
        if (flags & wl.wl_seat.Capability.keyboard != 0 and self.keyboard == null) {
            const keyboard = seat.get_keyboard();
            self.keyboard = keyboard;
            keyboard.listen(Seat, self, keyboardEvent);
        } else if (flags & wl.wl_seat.Capability.keyboard == 0) if (self.keyboard) |keyboard| {
            keyboard.destroy();
            self.keyboard = null;
            kb.xkb_state_unref(self.xkb);
            self.xkb = null;
        };
        if (flags & wl.wl_seat.Capability.pointer != 0 and self.pointer == null) {
            const pointer = seat.get_pointer();
            self.pointer = pointer;
            pointer.listen(Seat, self, pointerEvent);
        } else if (flags & wl.wl_seat.Capability.pointer == 0) if (self.pointer) |pointer| {
            pointer.destroy();
            self.pointer = null;
        };
    }
    fn pointerEvent(self: *Seat, _: wl.wl_pointer, event: wl.wl_pointer.Event) void {
        const s = self.state;
        switch (event) {
            .enter => |value| {
                s.pointer_output = null;
                var output = s.outputs;
                while (output) |o| : (output = o.next) {
                    if (o.surface) |surface| if (surface.proxy.id == value.surface.proxy.id) {
                        s.pointer_output = o;
                    };
                }
                s.pointer_x = value.surface_x;
                s.pointer_y = value.surface_y;
            },
            .leave => s.pointer_output = null,
            .motion => |value| {
                s.pointer_x = value.surface_x;
                s.pointer_y = value.surface_y;
            },
            .button => |value| if (value.state == wl.wl_pointer.ButtonState.pressed) s.click(),
            else => {},
        }
    }
    fn keyboardEvent(self: *Seat, _: wl.wl_keyboard, event: wl.wl_keyboard.Event) void {
        switch (event) {
            .keymap => |value| self.keymap(value.format, value.fd, value.size),
            .leave => if (!self.state.busy) {
                self.state.password.clear();
                self.state.changed();
            },
            .key => |value| self.key(value.key, value.state),
            .modifiers => |value| self.modifiers(value.mods_depressed, value.mods_latched, value.mods_locked, value.group),
            else => {},
        }
    }
    fn keymap(self: *Seat, format: u32, fd: wire.Fd, size: u32) void {
        defer _ = libc.close(fd);
        kb.xkb_state_unref(self.xkb);
        self.xkb = null;
        if (format != wl.wl_keyboard.KeymapFormat.xkb_v1 or size == 0 or size > 16 * 1024 * 1024) return;
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
    fn key(self: *Seat, code: u32, pressed: u32) void {
        const s = self.state;
        if (pressed != wl.wl_keyboard.KeyState.pressed or self.xkb == null or s.busy or !s.locked or s.done) return;
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
    fn modifiers(self: *Seat, depressed: u32, latched: u32, locked: u32, group: u32) void {
        const state = self.xkb orelse return;
        _ = kb.xkb_state_update_mask(state, depressed, latched, locked, 0, 0, group);
        const s = self.state;
        const caps = kb.xkb_state_mod_name_is_active(state, "Lock", 1 << 3) > 0;
        if (caps == s.caps_lock) return;
        s.caps_lock = caps;
        if (s.stage == .prompt) s.render();
    }
    fn deinit(self: *Seat) void {
        if (self.keyboard) |keyboard| keyboard.destroy();
        if (self.pointer) |pointer| pointer.destroy();
        kb.xkb_state_unref(self.xkb);
        if (self.seat.version() >= 5) self.seat.release() else self.seat.destroy();
        a.destroy(self);
    }
};
/// GNOME returns an unattended prompt to the clock after two minutes.
const prompt_timeout_us = 120 * std.time.us_per_s;
const State = struct {
    connection: *wire.Connection,
    compositor: ?wl.wl_compositor = null,
    shm: ?wl.wl_shm = null,
    manager: ?wl.ext_session_lock_manager_v1 = null,
    lock: ?wl.ext_session_lock_v1 = null,
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
            self.lock.?.unlock_and_destroy();
            self.lock = null;
            self.connection.roundtrip() catch std.process.exit(1);
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
    fn lockEvent(self: *State, _: wl.ext_session_lock_v1, event: wl.ext_session_lock_v1.Event) void {
        switch (event) {
            .locked => {
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
            },
            // Never send unlock on rejection or compositor termination.
            .finished => self.done = true,
        }
    }
    fn registryEvent(self: *State, registry: wl.wl_registry, event: wl.wl_registry.Event) void {
        switch (event) {
            .global => |value| self.global(registry, value.name, value.interface, value.version),
            .global_remove => |removed| self.remove(removed.name),
        }
    }
    fn global(self: *State, registry: wl.wl_registry, name: u32, interface: []const u8, version: u32) void {
        if (std.mem.eql(u8, interface, "wl_compositor")) {
            self.compositor = registry.bind(name, wl.wl_compositor, @min(version, 4));
        } else if (std.mem.eql(u8, interface, "wl_shm")) {
            self.shm = registry.bind(name, wl.wl_shm, 1);
        } else if (std.mem.eql(u8, interface, "ext_session_lock_manager_v1")) {
            self.manager = registry.bind(name, wl.ext_session_lock_manager_v1, 1);
        } else if (std.mem.eql(u8, interface, "wl_output")) {
            const output = a.create(Output) catch std.process.exit(1);
            output.* = .{ .state = self, .name = name, .output = registry.bind(name, wl.wl_output, @min(version, 3)), .next = self.outputs };
            output.output.listen(Output, output, Output.outputEvent);
            self.outputs = output;
            if (self.lock != null) output.lock();
        } else if (std.mem.eql(u8, interface, "wl_seat")) {
            const seat = a.create(Seat) catch std.process.exit(1);
            seat.* = .{ .state = self, .name = name, .seat = registry.bind(name, wl.wl_seat, @min(version, 5)), .next = self.seats };
            self.seats = seat;
            seat.seat.listen(Seat, seat, Seat.seatEvent);
        }
    }
    fn remove(self: *State, name: u32) void {
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
        if (condition & (c.G_IO_ERR | c.G_IO_HUP) != 0) std.process.exit(1);
        self.connection.readAndDispatch() catch std.process.exit(1);
        return 1;
    }
};

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
    const connection = wire.Connection.connect(a) catch return error.NoWaylandDisplay;
    defer connection.deinit();
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
    var state = State{ .view = &lock_view, .connection = connection, .password = password, .user = username.ptr, .authenticator = authenticator, .ready_fd = ready_fd, .managed_readiness = !daemonize and ready_fd >= 0 };
    const display: wl.wl_display = .{ .proxy = connection.display() };
    const registry = display.get_registry();
    registry.listen(State, &state, State.registryEvent);
    connection.roundtrip() catch return error.WaylandDisconnected;
    if (state.manager == null or state.compositor == null or state.shm == null) return error.SessionLockUnavailable;
    const lock = state.manager.?.lock();
    state.lock = lock;
    lock.listen(State, &state, State.lockEvent);
    var output = state.outputs;
    while (output) |o| : (output = o.next) o.lock();
    const source = c.g_unix_fd_add(connection.getFd(), c.G_IO_IN | c.G_IO_ERR | c.G_IO_HUP, &State.readable, &state);
    defer _ = c.g_source_remove(source);
    const clock = c.g_timeout_add_seconds(1, &State.tick, &state);
    defer _ = c.g_source_remove(clock);
    defer if (state.spinner != 0) {
        _ = c.g_source_remove(state.spinner);
    };
    while (!state.done) {
        connection.flush() catch std.process.exit(1);
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
