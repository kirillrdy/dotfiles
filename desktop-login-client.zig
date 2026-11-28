//! Wayland client plumbing shared by the greeter and the lock screen: outputs,
//! seats, password typing and the threaded authentication round trip.
//!
//! `App` embeds a `Client(App)` as its `client` field and declares these hooks:
//!   name: [*:0]const u8            shared-memory buffer name
//!   fail_closed: bool              exit the process on any client failure
//!   cursor_shapes: bool            bind wp_cursor_shape_manager_v1
//!   retry_ms: u32              pause after a rejected password
//!   Role: type                     per-output role object with `destroy()`
//!   fn canAttach(*App) bool
//!   fn attachRole(*App, *Output, wl_surface) Role
//!   fn bindGlobal(*App, wl_registry, name, interface, version) void
//!   fn paint(*App, *Output, raster.Buffer, scale) void
//!   fn pointer(*App, *Seat, Pointer) void
//!   fn key(*App, *Seat, code, symbol) void
//!   fn capsLockChanged(*App) void
//!   fn verify(*App) bool           runs on the worker thread, which owns the password
//!   fn acceptAuth(*App) bool       main thread; false treats a success as a failure
//!   fn authenticated(*App) void    after `done` is set
//!   fn tick(*App) void             once a second
//! Optional: OutputData (type with `deinit(allocator)`), outputAdded(*App, *Output),
//! outputRemoved(*App, *Output), keyboardLeave(*App).
const std = @import("std");
const wl = @import("wayland-client");
const wire = @import("wayland-wire");
const helpers = @import("desktop-wayland-client.zig");
const mainloop = @import("desktop-loop.zig");
const util = @import("desktop-util.zig");
const login = @import("desktop-login-ui.zig");
const raster = @import("desktop-raster.zig");
const kb = @import("desktop-keyboard.zig");

const cast = util.cast;

pub const Pointer = union(enum) { enter, leave, motion, button: u32 };

pub fn Client(comptime App: type) type {
    return struct {
        const Self = @This();
        const OutputData = if (@hasDecl(App, "OutputData")) App.OutputData else struct {};

        allocator: std.mem.Allocator,
        io: std.Io,
        connection: *wire.Connection,
        password: *login.SecretBuffer,
        compositor: ?wl.wl_compositor = null,
        shm: ?wl.wl_shm = null,
        cursor_manager: ?wl.wp_cursor_shape_manager_v1 = null,
        outputs: ?*Output = null,
        seats: ?*Seat = null,
        buffers: ?*helpers.FrameBuffer = null,
        pointer_output: ?*Output = null,
        pointer_x: f64 = 0,
        pointer_y: f64 = 0,
        spinner: u32 = 0,
        /// Characters shown as dots, tracked on the main thread so rendering never
        /// reads the password while the authentication thread may be clearing it.
        typed: usize = 0,
        caps_lock: bool = false,
        busy: bool = false,
        failed: bool = false,
        done: bool = false,
        /// Set by a termination signal; ends the loop without completing.
        stopped: bool = false,

        pub const Output = struct {
            client: *Self,
            name: u32,
            output: wl.wl_output,
            surface: ?wl.wl_surface = null,
            role: ?App.Role = null,
            width: u32 = 0,
            height: u32 = 0,
            scale: u32 = 1,
            data: OutputData = .{},
            next: ?*Output = null,

            fn attach(self: *Output) void {
                if (self.surface != null) return;
                const client = self.client;
                const compositor = client.compositor orelse return;
                if (!App.canAttach(client.app())) return;
                const surface = compositor.create_surface();
                self.surface = surface;
                self.role = App.attachRole(client.app(), self, surface);
            }

            /// Applies a size from the role's configure event and repaints.
            pub fn configure(self: *Output, width: u32, height: u32) void {
                self.width = width;
                self.height = height;
                self.render();
            }

            pub fn render(self: *Output) void {
                if (self.width == 0 or self.height == 0) return;
                const surface = self.surface orelse return;
                const client = self.client;
                // Integer buffer scale, as the shell's own surfaces use, needs wl_surface v3.
                const versioned = surface.version() >= 3;
                const scale: u32 = if (versioned) self.scale else 1;
                const width = self.width * scale;
                const height = self.height * scale;
                if (width > 16384 or height > 16384 or @as(u64, width) * height > 64 * 1024 * 1024) return client.fatal();
                const frame = helpers.FrameBuffer.create(client.allocator, &client.buffers, client.shm.?, App.name, width, height, wl.wl_shm.Format.xrgb8888) catch return client.fatal();
                const pixels: [*]u32 = @ptrCast(@alignCast(frame.shm.memory));
                App.paint(client.app(), self, .{ .pixels = pixels[0 .. frame.shm.size / 4], .width = width, .height = height }, scale);
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

            fn deinit(self: *Output) void {
                const client = self.client;
                if (@hasDecl(App, "outputRemoved")) App.outputRemoved(client.app(), self);
                if (self.role) |value| value.destroy();
                if (self.surface) |value| value.destroy();
                if (client.pointer_output == self) client.pointer_output = null;
                if (self.output.version() >= 3) self.output.release() else self.output.destroy();
                if (@hasDecl(OutputData, "deinit")) self.data.deinit(client.allocator);
                client.allocator.destroy(self);
            }
        };

        pub const Seat = struct {
            client: *Self,
            name: u32,
            seat: wl.wl_seat,
            keyboard: ?wl.wl_keyboard = null,
            pointer: ?wl.wl_pointer = null,
            cursor_shape: ?wl.wp_cursor_shape_device_v1 = null,
            last_pointer_serial: u32 = 0,
            keyboard_state: kb.Keyboard = .{},
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
                    self.keyboard_state.deinit();
                };
                if (flags & wl.wl_seat.Capability.pointer != 0 and self.pointer == null) {
                    const pointer = seat.get_pointer();
                    self.pointer = pointer;
                    pointer.listen(Seat, self, pointerEvent);
                    if (self.client.cursor_manager) |mgr| self.cursor_shape = mgr.get_pointer(pointer);
                } else if (flags & wl.wl_seat.Capability.pointer == 0) {
                    if (self.cursor_shape) |cs| cs.destroy();
                    self.cursor_shape = null;
                    if (self.pointer) |pointer| {
                        pointer.destroy();
                        self.pointer = null;
                    }
                }
            }

            /// Sets a wp_cursor_shape_device_v1 shape when cursor shapes are bound.
            pub fn setCursor(self: *Seat, shape: u32) void {
                const cs = self.cursor_shape orelse return;
                cs.set_shape(self.last_pointer_serial, shape);
            }

            fn pointerEvent(self: *Seat, _: wl.wl_pointer, event: wl.wl_pointer.Event) void {
                const client = self.client;
                switch (event) {
                    .enter => |value| {
                        self.last_pointer_serial = value.serial;
                        client.pointer_output = null;
                        var output = client.outputs;
                        while (output) |o| : (output = o.next) {
                            if (o.surface) |surface| if (surface.proxy.id == value.surface.proxy.id) {
                                client.pointer_output = o;
                            };
                        }
                        client.pointer_x = value.surface_x;
                        client.pointer_y = value.surface_y;
                        App.pointer(client.app(), self, .enter);
                    },
                    .leave => {
                        client.pointer_output = null;
                        App.pointer(client.app(), self, .leave);
                    },
                    .motion => |value| {
                        client.pointer_x = value.surface_x;
                        client.pointer_y = value.surface_y;
                        App.pointer(client.app(), self, .motion);
                    },
                    .button => |value| if (value.state == wl.wl_pointer.ButtonState.pressed) App.pointer(client.app(), self, .{ .button = value.button }),
                    else => {},
                }
            }

            fn keyboardEvent(self: *Seat, _: wl.wl_keyboard, event: wl.wl_keyboard.Event) void {
                switch (event) {
                    .keymap => |value| self.keyboard_state.load(value.fd, value.format, value.size),
                    .enter => if (@hasDecl(App, "keyboardEnter") and self.keyboard_state.state != null) App.keyboardEnter(self.client.app()),
                    .leave => if (@hasDecl(App, "keyboardLeave")) App.keyboardLeave(self.client.app()),
                    .key => |value| self.key(value.key, value.state),
                    .modifiers => |value| self.modifiers(value.mods_depressed, value.mods_latched, value.mods_locked, value.group),
                    else => {},
                }
            }

            fn key(self: *Seat, code: u32, pressed: u32) void {
                const client = self.client;
                if (pressed != wl.wl_keyboard.KeyState.pressed or self.keyboard_state.state == null or client.busy or client.done) return;
                const symbol = self.keyboard_state.symbol(code);
                // Modifiers alone, including Caps Lock, neither reveal nor edit the prompt.
                if (symbol >= 0xffe1 and symbol <= 0xffee) return;
                App.key(client.app(), self, code, symbol);
            }

            /// Appends the text `code` produces under the current keymap state.
            pub fn typeInto(self: *Seat, target: *login.SecretBuffer, code: u32) void {
                var bytes: [128]u8 = @splat(0);
                defer std.crypto.secureZero(u8, &bytes);
                const value = self.keyboard_state.text(code, &bytes);
                if (value.len > 0) target.append(value);
            }

            fn modifiers(self: *Seat, depressed: u32, latched: u32, locked: u32, group: u32) void {
                self.keyboard_state.update(depressed, latched, locked, group);
                const client = self.client;
                const caps = self.keyboard_state.capsLock();
                if (caps == client.caps_lock) return;
                client.caps_lock = caps;
                App.capsLockChanged(client.app());
            }

            fn deinit(self: *Seat) void {
                if (self.cursor_shape) |cs| cs.destroy();
                if (self.keyboard) |keyboard| keyboard.destroy();
                if (self.pointer) |pointer| pointer.destroy();
                self.keyboard_state.deinit();
                if (self.seat.version() >= 5) self.seat.release() else self.seat.destroy();
                self.client.allocator.destroy(self);
            }
        };

        fn app(self: *Self) *App {
            return @fieldParentPtr("client", self);
        }

        /// Exits when the app fails closed; otherwise the caller skips the failed step.
        pub fn fatal(_: *Self) void {
            if (App.fail_closed) std.process.exit(1);
        }

        pub fn status(self: *const Self) login.Status {
            return if (self.failed) .failed else if (self.busy) .authenticating else .ready;
        }

        pub fn render(self: *Self) void {
            var output = self.outputs;
            while (output) |o| : (output = o.next) o.render();
        }

        /// Recounts typed characters; returns whether the count changed.
        pub fn recount(self: *Self) bool {
            const count = self.password.charCount();
            if (count == self.typed) return false;
            self.typed = count;
            // Typing again after a rejection returns to the normal prompt.
            if (count > 0) self.failed = false;
            return true;
        }

        pub fn changed(self: *Self) void {
            if (self.recount()) self.render();
        }

        /// Forgets the typed password and any rejection; the caller re-renders.
        pub fn resetPassword(self: *Self) void {
            self.password.clear();
            self.typed = 0;
            self.failed = false;
        }

        /// Hands the password to `App.verify` on a worker thread.
        pub fn authenticate(self: *Self) void {
            if (self.password.len == 0) return;
            self.busy = true;
            self.failed = false;
            self.render();
            if (self.spinner == 0) self.spinner = mainloop.timeout(self.io, 50, self, spin);
            mainloop.background(self.io, self, authWork, authDone);
        }

        fn authWork(self: *Self) bool {
            const success = App.verify(self.app());
            self.password.clear();
            return success;
        }

        fn authDone(self: *Self, success: bool) void {
            self.busy = false;
            self.typed = 0;
            if (success and !self.done and App.acceptAuth(self.app())) {
                self.done = true;
                App.authenticated(self.app());
            } else {
                self.failed = true;
                if (!self.done) {
                    self.busy = true;
                    _ = mainloop.timeout(self.io, App.retry_ms, self, retry);
                    self.render();
                }
            }
        }

        fn retry(self: *Self) bool {
            self.busy = false;
            self.render();
            return false;
        }

        fn spin(self: *Self) bool {
            if (!self.busy or self.failed or self.done) {
                self.spinner = 0;
                return false;
            }
            self.render();
            return true;
        }

        fn tick(self: *Self) bool {
            App.tick(self.app());
            return true;
        }

        fn registryEvent(self: *Self, registry: wl.wl_registry, event: wl.wl_registry.Event) void {
            switch (event) {
                .global => |value| self.global(registry, value.name, value.interface, value.version),
                .global_remove => |removed| self.remove(removed.name),
            }
        }

        fn global(self: *Self, registry: wl.wl_registry, name: u32, interface: []const u8, version: u32) void {
            if (std.mem.eql(u8, interface, "wl_compositor")) {
                self.compositor = registry.bind(name, wl.wl_compositor, @min(version, 4));
            } else if (std.mem.eql(u8, interface, "wl_shm")) {
                self.shm = registry.bind(name, wl.wl_shm, 1);
            } else if (App.cursor_shapes and std.mem.eql(u8, interface, "wp_cursor_shape_manager_v1")) {
                const manager = registry.bind(name, wl.wp_cursor_shape_manager_v1, 1);
                self.cursor_manager = manager;
                var seat = self.seats;
                while (seat) |s| : (seat = s.next) {
                    if (s.pointer) |pointer| if (s.cursor_shape == null) {
                        s.cursor_shape = manager.get_pointer(pointer);
                    };
                }
            } else if (std.mem.eql(u8, interface, "wl_output")) {
                const output = self.allocator.create(Output) catch return self.fatal();
                output.* = .{ .client = self, .name = name, .output = registry.bind(name, wl.wl_output, @min(version, 3)), .next = self.outputs };
                output.output.listen(Output, output, Output.outputEvent);
                self.outputs = output;
                if (@hasDecl(App, "outputAdded")) App.outputAdded(self.app(), output);
                output.attach();
            } else if (std.mem.eql(u8, interface, "wl_seat")) {
                const seat = self.allocator.create(Seat) catch return self.fatal();
                seat.* = .{ .client = self, .name = name, .seat = registry.bind(name, wl.wl_seat, @min(version, 5)), .next = self.seats };
                self.seats = seat;
                seat.seat.listen(Seat, seat, Seat.seatEvent);
            } else App.bindGlobal(self.app(), registry, name, interface, version);
        }

        fn remove(self: *Self, name: u32) void {
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

        fn readable(self: *Self, _: c_int, condition: u32) bool {
            if (condition & (mainloop.ERR | mainloop.HUP) != 0) {
                self.fatal();
                self.done = true;
                return false;
            }
            self.connection.readAndDispatch() catch {
                self.fatal();
                self.done = true;
                return false;
            };
            return true;
        }

        /// Binds globals and waits for the initial burst; `self` must not move afterwards.
        pub fn connect(self: *Self) !void {
            const display: wl.wl_display = .{ .proxy = self.connection.display() };
            const registry = display.get_registry();
            registry.listen(Self, self, registryEvent);
            self.connection.roundtrip() catch return error.WaylandDisconnected;
        }

        /// Gives every known output its role surface once `App.canAttach` allows it.
        pub fn attachAll(self: *Self) void {
            var output = self.outputs;
            while (output) |o| : (output = o.next) o.attach();
        }

        /// Runs the GLib loop until done or stopped, then lets a pending
        /// authentication finish so the worker never outlives its secrets.
        pub fn run(self: *Self) void {
            const source = mainloop.watch(self.io, self.connection.getFd(), mainloop.IN | mainloop.ERR | mainloop.HUP, self, readable);
            defer _ = mainloop.remove(self.io, source);
            const clock = mainloop.timeoutSeconds(self.io, 1, self, tick);
            defer _ = mainloop.remove(self.io, clock);
            defer if (self.spinner != 0) {
                _ = mainloop.remove(self.io, self.spinner);
            };
            while (!self.done and !self.stopped) {
                self.connection.flush() catch {
                    self.fatal();
                    break;
                };
                _ = mainloop.iteration(self.io, true);
            }
            while (self.busy) _ = mainloop.iteration(self.io, true);
        }

        pub fn deinit(self: *Self) void {
            while (self.outputs) |output| {
                self.outputs = output.next;
                output.deinit();
            }
            while (self.seats) |seat| {
                self.seats = seat.next;
                seat.deinit();
            }
            helpers.FrameBuffer.destroyAll(&self.buffers);
        }
    };
}
