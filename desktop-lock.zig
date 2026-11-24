//! Independent ext-session-lock client. Only successful PAM authentication sends unlock.
const std = @import("std");
const wl = @import("wayland-client");
const wire = @import("wayland-wire");
const dbus = @import("dbus");
const libc = @import("desktop-libc.zig");
const auth = @import("desktop-lock-auth.zig");
const view = @import("desktop-lock-view.zig");
const login = @import("desktop-login-ui.zig");
const login_client = @import("desktop-login-client.zig");
const SecretBuffer = login.SecretBuffer;
const raster = @import("desktop-raster.zig");
const u = @import("desktop-util.zig");

/// Calls the session's secrets service and waits; used outside the GLib loop,
/// including from the authentication thread, so it uses a private connection.
fn secretsCall(a: std.mem.Allocator, member: []const u8, args: anytype, timeout_ms: u32) void {
    const connection = dbus.Connection.open(a, .session) catch return;
    defer connection.close();
    const reply = connection.callBlocking(.{ .destination = "org.freedesktop.secrets", .path = "/org/freedesktop/secrets", .interface = "org.dotfiles.Desktop.Secrets", .member = member, .no_auto_start = true }, args, timeout_ms) catch return;
    reply.deinit();
}
fn screenLocked(a: std.mem.Allocator, locked: bool) void {
    secretsCall(a, "SetScreenLocked", .{locked}, 3000);
}
fn unlockSecrets(password: []const u8) void {
    secretsCall(std.heap.page_allocator, "LoginUnlock", .{dbus.Bytes{ .value = password }}, 30000);
}
const LoginClient = login_client.Client(State);
const Output = LoginClient.Output;
const Seat = LoginClient.Seat;

/// The blurred wallpaper at an output's current buffer size, painted once per size.
const Backdrop = struct {
    pixels: []u32 = &.{},
    width: u32 = 0,
    height: u32 = 0,

    pub fn deinit(self: *Backdrop, a: std.mem.Allocator) void {
        a.free(self.pixels);
        self.* = .{};
    }
};

/// GNOME returns an unattended prompt to the clock after two minutes.
const prompt_timeout_us = 120 * std.time.us_per_s;
const State = struct {
    client: LoginClient,
    manager: ?wl.ext_session_lock_manager_v1 = null,
    lock: ?wl.ext_session_lock_v1 = null,
    view: *view.View,
    stage: view.Stage = .clock,
    last_activity: i64 = 0,
    user: [*:0]const u8,
    authenticator: *const fn ([*:0]const u8, [*:0]const u8) bool = auth.authenticate,
    ready_fd: c_int = -1,
    managed_readiness: bool = false,
    locked: bool = false,
    unlocked: bool = false,

    pub const name = "desktop-lock";
    pub const fail_closed = true;
    pub const cursor_shapes = false;
    pub const retry_ms = 1500;
    pub const Role = wl.ext_session_lock_surface_v1;
    pub const OutputData = Backdrop;

    pub fn canAttach(self: *State) bool {
        return self.lock != null;
    }

    pub fn attachRole(self: *State, output: *Output, surface: wl.wl_surface) Role {
        const lock_surface = self.lock.?.get_lock_surface(surface, output.output);
        lock_surface.listen(Output, output, configured);
        return lock_surface;
    }

    fn configured(output: *Output, lock_surface: wl.ext_session_lock_surface_v1, event: wl.ext_session_lock_surface_v1.Event) void {
        const value = event.configure;
        lock_surface.ack_configure(value.serial);
        output.configure(value.width, value.height);
    }

    pub fn bindGlobal(self: *State, registry: wl.wl_registry, global: u32, interface: []const u8, _: u32) void {
        if (std.mem.eql(u8, interface, "ext_session_lock_manager_v1")) {
            self.manager = registry.bind(global, wl.ext_session_lock_manager_v1, 1);
        }
    }

    pub fn paint(self: *State, output: *Output, target: raster.Buffer, scale: u32) void {
        const backdrop = &output.data;
        if (backdrop.width != target.width or backdrop.height != target.height) {
            backdrop.deinit(self.client.allocator);
            if (self.client.allocator.alloc(u32, target.pixels.len)) |memory| {
                self.view.background(.{ .pixels = memory, .width = target.width, .height = target.height });
                backdrop.* = .{ .pixels = memory, .width = target.width, .height = target.height };
            } else |_| {}
        }
        if (backdrop.pixels.len == target.pixels.len) @memcpy(target.pixels, backdrop.pixels) else self.view.background(target);
        self.view.paint(target, scale, self.frame());
    }

    pub fn pointer(self: *State, _: *Seat, event: login_client.Pointer) void {
        if (event == .button) self.click();
    }

    pub fn keyboardLeave(self: *State) void {
        if (self.client.busy) return;
        self.client.password.clear();
        self.client.changed();
    }

    pub fn key(self: *State, seat: *Seat, code: u32, symbol: u32) void {
        if (!self.locked) return;
        self.last_activity = u.monotonicTime();
        if (self.stage == .clock) {
            // Like GNOME, any key raises the prompt and a printable one starts the password.
            self.stage = .prompt;
            if (symbol != 0xff0d and symbol != 0xff8d and symbol != 0xff1b and symbol != 0xff08) seat.typeInto(self.client.password, code);
            _ = self.client.recount();
            self.render();
            return;
        }
        switch (symbol) {
            0xff0d, 0xff8d => self.client.authenticate(),
            0xff1b => self.showClock(),
            0xff08 => {
                self.client.password.backspace();
                self.client.changed();
            },
            else => {
                seat.typeInto(self.client.password, code);
                self.client.changed();
            },
        }
    }

    pub fn capsLockChanged(self: *State) void {
        if (self.stage == .prompt) self.render();
    }

    pub fn verify(self: *State) bool {
        const password = self.client.password;
        const success = self.authenticator(self.user, &password.bytes);
        if (success) {
            screenLocked(self.client.allocator, false);
            unlockSecrets(password.slice());
        }
        return success;
    }

    pub fn acceptAuth(self: *State) bool {
        return self.locked;
    }

    pub fn authenticated(self: *State) void {
        // Revoke managed readiness before the compositor processes unlock.
        if (self.ready_fd >= 0) {
            _ = libc.close(self.ready_fd);
            self.ready_fd = -1;
        }
        self.lock.?.unlock_and_destroy();
        self.lock = null;
        self.client.connection.roundtrip() catch std.process.exit(1);
        self.unlocked = true;
    }

    /// Once a second: advance the clock and retire an unattended prompt.
    pub fn tick(self: *State) void {
        if (self.stage == .prompt and !self.client.busy and u.monotonicTime() - self.last_activity > prompt_timeout_us) {
            _ = self.view.tick();
            self.showClock();
        } else if (self.view.tick() and self.stage == .clock) self.render();
    }

    fn render(self: *State) void {
        self.client.render();
    }

    fn frame(self: *const State) view.Frame {
        return .{
            .stage = self.stage,
            .status = self.client.status(),
            .typed = self.client.typed,
            .caps_lock = self.client.caps_lock,
            .spin = login.spinPhase(),
        };
    }

    fn showClock(self: *State) void {
        // The worker thread owns the password while PAM runs.
        if (self.client.busy) return;
        self.client.resetPassword();
        self.stage = .clock;
        self.render();
    }

    fn click(self: *State) void {
        if (self.client.busy or !self.locked or self.client.done) return;
        self.last_activity = u.monotonicTime();
        if (self.stage == .clock) {
            self.stage = .prompt;
            self.render();
            return;
        }
        const output = self.client.pointer_output orelse return;
        const layout = view.Layout.compute(@floatFromInt(output.width), @floatFromInt(output.height));
        if (layout.back.contains(self.client.pointer_x, self.client.pointer_y)) self.showClock();
    }

    fn lockEvent(self: *State, _: wl.ext_session_lock_v1, event: wl.ext_session_lock_v1.Event) void {
        switch (event) {
            .locked => {
                self.locked = true;
                screenLocked(self.client.allocator, true);
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
            .finished => self.client.done = true,
        }
    }
};

pub fn run(a: std.mem.Allocator, args: []const []const u8) !void {
    return runWithAuthenticator(a, args, auth.authenticate);
}

/// Isolated protocol tests supply an authenticator without changing the module graph.
pub fn runWithAuthenticator(a: std.mem.Allocator, args: []const []const u8, authenticator: *const fn ([*:0]const u8, [*:0]const u8) bool) !void {
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
    const password = try SecretBuffer.create();
    defer password.destroy();
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
    var state = State{
        .client = .{ .allocator = a, .connection = connection, .password = password },
        .view = &lock_view,
        .user = username.ptr,
        .authenticator = authenticator,
        .ready_fd = ready_fd,
        .managed_readiness = !daemonize and ready_fd >= 0,
    };
    defer state.client.deinit();
    try state.client.connect();
    if (state.manager == null or state.client.compositor == null or state.client.shm == null) return error.SessionLockUnavailable;
    const lock = state.manager.?.lock();
    state.lock = lock;
    lock.listen(State, &state, State.lockEvent);
    state.client.attachAll();
    state.client.run();
    ready_fd = state.ready_fd;
    if (!state.unlocked) return error.LockNotAcquired;
}
