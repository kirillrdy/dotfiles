//! Native Wayland layer-shell greeter client styled after GDM.
//! Runs unprivileged inside an embedded compositor; sends auth/power requests to desktop-dm.
const std = @import("std");
const wl = @import("wayland-client");
const wire = @import("wayland-wire");
const helpers = @import("desktop-wayland-client.zig");
const c = @import("desktop-glib.zig");
const libc = @import("desktop-libc.zig");
const posix = @import("posix");
const view = @import("desktop-greeter-view.zig");
const login = @import("desktop-login-ui.zig");
const raster = @import("desktop-raster.zig");
const kb = @import("desktop-keyboard.zig");

const cast = c.__zig.cast;
const SecretBuffer = login.SecretBuffer;

pub const Op = enum(u8) { auth = 1, power = 2 };
pub const Reply = enum(u8) { ok = 0, failed = 1 };

const DiscoveredUser = struct {
    username: [:0]u8,
    display_name: [:0]u8,
    avatar_path: ?[:0]u8 = null,
};

fn isLoginShell(shell: []const u8) bool {
    if (shell.len == 0) return false;
    if (std.mem.endsWith(u8, shell, "/nologin") or std.mem.endsWith(u8, shell, "/false")) return false;
    return true;
}

fn discoverUsers(a: std.mem.Allocator) ![]DiscoveredUser {
    var list: std.ArrayList(DiscoveredUser) = .empty;
    errdefer {
        for (list.items) |entry| {
            a.free(entry.username);
            a.free(entry.display_name);
            if (entry.avatar_path) |p| a.free(p);
        }
        list.deinit(a);
    }
    posix.setpwent();
    defer posix.endpwent();
    while (posix.getpwent()) |pw| {
        const uid = pw.*.pw_uid;
        if (uid < 1000 or uid >= 65534) continue;
        const name = std.mem.span(pw.*.pw_name orelse continue);
        if (name.len == 0) continue;
        const shell = if (pw.*.pw_shell) |s| std.mem.span(s) else "";
        if (!isLoginShell(shell)) continue;
        const gecos = if (pw.*.pw_gecos) |g| std.mem.sliceTo(std.mem.span(g), ',') else "";
        const display = if (gecos.len > 0 and std.unicode.utf8ValidateSlice(gecos)) gecos else name;
        const accounts_icon = try std.fmt.allocPrintSentinel(a, "/var/lib/AccountsService/icons/{s}", .{name}, 0);
        const home = if (pw.*.pw_dir) |d| std.mem.span(d) else "";
        var avatar: ?[:0]u8 = null;
        if (posix.access(accounts_icon.ptr, posix.R_OK) == 0) {
            avatar = accounts_icon;
        } else {
            a.free(accounts_icon);
            if (home.len > 0) {
                const face = try std.fmt.allocPrintSentinel(a, "{s}/.face", .{home}, 0);
                if (posix.access(face.ptr, posix.R_OK) == 0) avatar = face else a.free(face);
            }
        }
        try list.append(a, .{
            .username = try a.dupeSentinel(u8, name, 0),
            .display_name = try a.dupeSentinel(u8, display, 0),
            .avatar_path = avatar,
        });
    }
    std.mem.sort(DiscoveredUser, list.items, {}, struct {
        fn lessThan(_: void, lhs: DiscoveredUser, rhs: DiscoveredUser) bool {
            return std.mem.order(u8, lhs.username, rhs.username) == .lt;
        }
    }.lessThan);
    return list.toOwnedSlice(a);
}

const Output = struct {
    state: *State,
    name: u32,
    output: wl.wl_output,
    surface: ?wl.wl_surface = null,
    layer: ?wl.zwlr_layer_surface_v1 = null,
    width: u32 = 0,
    height: u32 = 0,
    scale: u32 = 1,
    next: ?*Output = null,

    fn attach(self: *Output) void {
        if (self.layer != null) return;
        const s = self.state;
        const comp = s.compositor orelse return;
        const shell = s.layer_shell orelse return;
        const surface = comp.create_surface();
        self.surface = surface;
        const layer = shell.get_layer_surface(surface, self.output, wl.zwlr_layer_shell_v1.Layer.overlay, "desktop-greeter");
        self.layer = layer;
        const anchor = wl.zwlr_layer_surface_v1.Anchor.top | wl.zwlr_layer_surface_v1.Anchor.bottom | wl.zwlr_layer_surface_v1.Anchor.left | wl.zwlr_layer_surface_v1.Anchor.right;
        layer.set_anchor(anchor);
        layer.set_exclusive_zone(-1);
        layer.set_keyboard_interactivity(wl.zwlr_layer_surface_v1.KeyboardInteractivity.exclusive);
        layer.set_size(0, 0);
        layer.listen(Output, self, layerEvent);
        surface.commit();
    }

    fn isPrimary(self: *const Output) bool {
        if (self.state.primary_output) |primary| return primary == self;
        return self.state.outputs == self;
    }

    fn render(self: *Output) void {
        if (self.width == 0 or self.height == 0) return;
        const surface = self.surface orelse return;
        const s = self.state;
        const versioned = surface.version() >= 3;
        const scale: u32 = if (versioned) self.scale else 1;
        const width = self.width * scale;
        const height = self.height * scale;
        if (width > 16384 or height > 16384 or @as(u64, width) * height > 64 * 1024 * 1024) return;
        const frame = helpers.FrameBuffer.create(s.allocator, &s.buffers, s.shm.?, "desktop-greeter", width, height, wl.wl_shm.Format.xrgb8888) catch return;
        const pixels: [*]u32 = @ptrCast(@alignCast(frame.shm.memory));
        const target: raster.Buffer = .{ .pixels = pixels[0 .. frame.shm.size / 4], .width = width, .height = height };
        if (self.isPrimary()) {
            s.view.paint(target, scale, s.frame());
        } else {
            view.View.paintSecondary(target);
        }
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

    fn layerEvent(self: *Output, layer: wl.zwlr_layer_surface_v1, event: wl.zwlr_layer_surface_v1.Event) void {
        switch (event) {
            .configure => |value| {
                layer.ack_configure(value.serial);
                self.width = value.width;
                self.height = value.height;
                self.render();
            },
            .closed => self.state.done = true,
        }
    }

    fn deinit(self: *Output) void {
        if (self.layer) |value| value.destroy();
        if (self.surface) |value| value.destroy();
        if (self.state.pointer_output == self) self.state.pointer_output = null;
        if (self.state.primary_output == self) self.state.primary_output = null;
        if (self.output.version() >= 3) self.output.release() else self.output.destroy();
        self.state.allocator.destroy(self);
    }
};

const Seat = struct {
    state: *State,
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
            if (self.state.cursor_manager) |mgr| self.cursor_shape = mgr.get_pointer(pointer);
        } else if (flags & wl.wl_seat.Capability.pointer == 0) {
            if (self.cursor_shape) |cs| cs.destroy();
            self.cursor_shape = null;
            if (self.pointer) |pointer| {
                pointer.destroy();
                self.pointer = null;
            }
        }
    }

    fn updateCursor(self: *Seat, target: view.Target) void {
        const cs = self.cursor_shape orelse return;
        const shape: u32 = switch (target) {
            .none => wl.wp_cursor_shape_device_v1.Shape.default,
            .entry => wl.wp_cursor_shape_device_v1.Shape.text,
            else => wl.wp_cursor_shape_device_v1.Shape.pointer,
        };
        cs.set_shape(self.last_pointer_serial, shape);
    }

    fn pointerEvent(self: *Seat, _: wl.wl_pointer, event: wl.wl_pointer.Event) void {
        const s = self.state;
        switch (event) {
            .enter => |value| {
                self.last_pointer_serial = value.serial;
                s.pointer_output = null;
                var output = s.outputs;
                while (output) |o| : (output = o.next) {
                    if (o.surface) |surface| if (surface.proxy.id == value.surface.proxy.id) {
                        s.pointer_output = o;
                        s.primary_output = o;
                    };
                }
                s.pointer_x = value.surface_x;
                s.pointer_y = value.surface_y;
                s.updateHover(self);
                s.render();
            },
            .leave => {
                s.pointer_output = null;
                if (!std.meta.eql(s.hover, view.Target.none)) {
                    s.hover = .none;
                    s.render();
                }
            },
            .motion => |value| {
                s.pointer_x = value.surface_x;
                s.pointer_y = value.surface_y;
                s.updateHover(self);
            },
            .button => |value| {
                if (value.button == 0x110 and value.state == wl.wl_pointer.ButtonState.pressed) s.click();
            },
            else => {},
        }
    }

    fn keyboardEvent(self: *Seat, _: wl.wl_keyboard, event: wl.wl_keyboard.Event) void {
        switch (event) {
            .keymap => |value| self.keyboard_state.load(value.fd, value.format, value.size),
            .key => |value| self.key(value.key, value.state),
            .modifiers => |value| self.modifiers(value.mods_depressed, value.mods_latched, value.mods_locked, value.group),
            else => {},
        }
    }

    fn key(self: *Seat, code: u32, pressed: u32) void {
        const s = self.state;
        if (pressed != wl.wl_keyboard.KeyState.pressed or self.keyboard_state.state == null or s.busy or s.done) return;
        const symbol = self.keyboard_state.symbol(code);
        if (symbol >= 0xffe1 and symbol <= 0xffee) return;

        if (s.power_menu_open) {
            if (symbol == 0xff1b) {
                s.power_menu_open = false;
                s.render();
            }
            return;
        }

        switch (s.stage) {
            .user_list => {
                const count = s.users.len + 1;
                switch (symbol) {
                    0xff52 => { // Up
                        s.selected = if (s.selected == 0) count - 1 else s.selected - 1;
                        s.render();
                    },
                    0xff54, 0xff09 => { // Down / Tab
                        s.selected = (s.selected + 1) % count;
                        s.render();
                    },
                    0xff0d, 0xff8d, 0x0020 => s.activateSelected(),
                    else => {},
                }
            },
            .username => switch (symbol) {
                0xff1b => s.showUserList(),
                0xff0d, 0xff8d => s.confirmUsername(),
                0xff08 => {
                    s.custom_username.backspace();
                    s.failed = false;
                    s.render();
                },
                else => {
                    self.typeInto(&s.custom_username, code);
                    s.failed = false;
                    s.render();
                },
            },
            .password => switch (symbol) {
                0xff1b => s.goBackFromPassword(),
                0xff0d, 0xff8d => s.submitPassword(),
                0xff08 => {
                    s.password.backspace();
                    s.changedPassword();
                },
                else => {
                    self.typeInto(s.password, code);
                    s.changedPassword();
                },
            },
        }
    }

    fn typeInto(self: *Seat, target: *SecretBuffer, code: u32) void {
        var bytes: [128]u8 = @splat(0);
        defer std.crypto.secureZero(u8, &bytes);
        const value = self.keyboard_state.text(code, &bytes);
        if (value.len > 0) target.append(value);
    }

    fn modifiers(self: *Seat, depressed: u32, latched: u32, locked: u32, group: u32) void {
        self.keyboard_state.update(depressed, latched, locked, group);
        const s = self.state;
        const caps = self.keyboard_state.capsLock();
        if (caps == s.caps_lock) return;
        s.caps_lock = caps;
        if (s.stage == .password) s.render();
    }

    fn deinit(self: *Seat) void {
        if (self.cursor_shape) |cs| cs.destroy();
        if (self.keyboard) |keyboard| keyboard.destroy();
        if (self.pointer) |pointer| pointer.destroy();
        self.keyboard_state.deinit();
        if (self.seat.version() >= 5) self.seat.release() else self.seat.destroy();
        self.state.allocator.destroy(self);
    }
};

const State = struct {
    allocator: std.mem.Allocator,
    connection: *wire.Connection,
    compositor: ?wl.wl_compositor = null,
    shm: ?wl.wl_shm = null,
    layer_shell: ?wl.zwlr_layer_shell_v1 = null,
    cursor_manager: ?wl.wp_cursor_shape_manager_v1 = null,
    outputs: ?*Output = null,
    primary_output: ?*Output = null,
    seats: ?*Seat = null,
    buffers: ?*helpers.FrameBuffer = null,
    view: *view.View,
    users: []const DiscoveredUser,
    password: *SecretBuffer,
    custom_username: SecretBuffer = .{},
    dm_fd: c_int,
    stage: view.Stage = .user_list,
    selected: usize = 0,
    active_user: ?usize = null,
    typed: usize = 0,
    caps_lock: bool = false,
    busy: bool = false,
    failed: bool = false,
    done: bool = false,
    authenticated: bool = false,
    power_menu_open: bool = false,
    spinner: c.guint = 0,
    pointer_output: ?*Output = null,
    pointer_x: f64 = 0,
    pointer_y: f64 = 0,
    hover: view.Target = .none,

    fn render(self: *State) void {
        var output = self.outputs;
        while (output) |o| : (output = o.next) o.render();
    }

    fn frame(self: *const State) view.Frame {
        return .{
            .stage = self.stage,
            .status = if (self.failed) .failed else if (self.busy) .authenticating else .ready,
            .selected = self.selected,
            .active_user = self.active_user,
            .username_text = self.custom_username.slice(),
            .typed = self.typed,
            .caps_lock = self.caps_lock,
            .spin = login.spinPhase(),
            .power_menu_open = self.power_menu_open,
            .hover = self.hover,
        };
    }

    fn updateHover(self: *State, seat: *Seat) void {
        const output = self.pointer_output orelse return;
        const layout = view.Layout.compute(@floatFromInt(output.width), @floatFromInt(output.height), self.users.len);
        const target = layout.hitTest(self.frame(), self.pointer_x, self.pointer_y);
        seat.updateCursor(target);
        if (!std.meta.eql(target, self.hover)) {
            self.hover = target;
            self.render();
        }
    }

    fn activateSelected(self: *State) void {
        if (self.selected < self.users.len) {
            self.selectUser(self.selected);
        } else {
            self.openCustomUsername();
        }
    }

    fn selectUser(self: *State, index: usize) void {
        self.active_user = index;
        self.selected = index;
        self.password.clear();
        self.typed = 0;
        self.failed = false;
        self.stage = .password;
        self.render();
    }

    fn openCustomUsername(self: *State) void {
        self.active_user = null;
        self.custom_username.clear();
        self.password.clear();
        self.typed = 0;
        self.failed = false;
        self.stage = .username;
        self.render();
    }

    fn showUserList(self: *State) void {
        if (self.busy) return;
        self.password.clear();
        self.typed = 0;
        self.failed = false;
        self.stage = if (self.users.len > 0) .user_list else .username;
        self.render();
    }

    fn confirmUsername(self: *State) void {
        if (self.custom_username.len == 0) return;
        self.active_user = null;
        for (self.users, 0..) |user, i| {
            if (std.mem.eql(u8, user.username, self.custom_username.slice())) {
                self.active_user = i;
                break;
            }
        }
        self.password.clear();
        self.typed = 0;
        self.failed = false;
        self.stage = .password;
        self.render();
    }

    fn goBackFromPassword(self: *State) void {
        if (self.busy) return;
        self.password.clear();
        self.typed = 0;
        self.failed = false;
        if (self.active_user == null) {
            self.stage = .username;
        } else {
            self.stage = .user_list;
        }
        self.render();
    }

    fn changedPassword(self: *State) void {
        const count = self.password.charCount();
        if (count == self.typed) return;
        self.typed = count;
        if (count > 0) self.failed = false;
        self.render();
    }

    fn click(self: *State) void {
        if (self.busy or self.done) return;
        const output = self.pointer_output orelse return;
        const layout = view.Layout.compute(@floatFromInt(output.width), @floatFromInt(output.height), self.users.len);
        const target = layout.hitTest(self.frame(), self.pointer_x, self.pointer_y);
        if (self.power_menu_open) {
            self.power_menu_open = false;
            switch (target) {
                .power_action => |action| self.sendPower(action),
                else => {},
            }
            self.render();
            return;
        }
        switch (target) {
            .power_button => {
                self.power_menu_open = true;
                self.render();
            },
            .user => |idx| self.selectUser(idx),
            .not_listed => self.openCustomUsername(),
            .back => if (self.stage == .username) self.showUserList() else self.goBackFromPassword(),
            .submit => if (self.stage == .username) self.confirmUsername() else self.submitPassword(),
            .entry, .none, .power_action => {},
        }
    }

    fn sendPower(self: *State, action: view.PowerAction) void {
        if (self.dm_fd < 0) return;
        const payload = [2]u8{ @backingInt(Op.power), @backingInt(action) };
        _ = writeAll(self.dm_fd, &payload);
        var reply: [1]u8 = .{1};
        _ = readAll(self.dm_fd, &reply);
    }

    fn submitPassword(self: *State) void {
        if (self.password.len == 0) return;
        const username = self.activeUsername();
        if (username.len == 0) return;
        self.busy = true;
        self.failed = false;
        self.render();
        if (self.spinner == 0) self.spinner = c.g_timeout_add(50, &spin, self);
        const task = c.g_task_new(null, null, &authDone, self);
        c.g_task_set_task_data(task, self, null);
        c.g_task_run_in_thread(task, &authWork);
        c.g_object_unref(task);
    }

    fn activeUsername(self: *const State) []const u8 {
        if (self.active_user) |idx| {
            if (idx < self.users.len) return self.users[idx].username;
        }
        return self.custom_username.slice();
    }

    fn authWork(task: ?*c.GTask, _: ?*anyopaque, data: ?*anyopaque, _: [*c]c.GCancellable) callconv(.c) void {
        const self = cast(State, data);
        const username = self.activeUsername();
        const pass = self.password.slice();
        const ok = sendAuth(self.dm_fd, username, pass);
        self.password.clear();
        c.g_task_return_boolean(task, @intFromBool(ok));
    }

    fn authDone(_: [*c]c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self = cast(State, data);
        self.busy = false;
        self.typed = 0;
        if (c.g_task_propagate_boolean(@ptrCast(result), null) != 0 and !self.done) {
            self.authenticated = true;
            self.done = true;
        } else {
            self.failed = true;
            if (!self.done) {
                self.busy = true;
                _ = c.g_timeout_add(1000, &retry, self);
                self.render();
            }
        }
    }

    fn retry(data: ?*anyopaque) callconv(.c) c_int {
        const self = cast(State, data);
        self.busy = false;
        self.render();
        return 0;
    }

    fn tick(data: ?*anyopaque) callconv(.c) c_int {
        const self = cast(State, data);
        if (self.view.tick()) self.render();
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
        } else if (std.mem.eql(u8, interface, "zwlr_layer_shell_v1")) {
            self.layer_shell = registry.bind(name, wl.zwlr_layer_shell_v1, @min(version, 4));
        } else if (std.mem.eql(u8, interface, "wp_cursor_shape_manager_v1")) {
            self.cursor_manager = registry.bind(name, wl.wp_cursor_shape_manager_v1, 1);
            var seat = self.seats;
            while (seat) |s| : (seat = s.next) {
                if (s.pointer != null and s.cursor_shape == null) s.cursor_shape = self.cursor_manager.?.get_pointer(s.pointer.?);
            }
        } else if (std.mem.eql(u8, interface, "wl_output")) {
            const output = self.allocator.create(Output) catch return;
            output.* = .{ .state = self, .name = name, .output = registry.bind(name, wl.wl_output, @min(version, 3)), .next = self.outputs };
            output.output.listen(Output, output, Output.outputEvent);
            self.outputs = output;
            if (self.primary_output == null) self.primary_output = output;
            output.attach();
        } else if (std.mem.eql(u8, interface, "wl_seat")) {
            const seat = self.allocator.create(Seat) catch return;
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
        if (condition & (c.G_IO_ERR | c.G_IO_HUP) != 0) {
            self.done = true;
            return 0;
        }
        self.connection.readAndDispatch() catch {
            self.done = true;
            return 0;
        };
        return 1;
    }
};

pub fn writeAll(fd: c_int, bytes: []const u8) bool {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = libc.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (n < 0 and libc.__errno_location().* == libc.EINTR) continue;
        if (n <= 0) return false;
        offset += @intCast(n);
    }
    return true;
}

pub fn readAll(fd: c_int, bytes: []u8) bool {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = libc.read(fd, bytes[offset..].ptr, bytes.len - offset);
        if (n < 0 and libc.__errno_location().* == libc.EINTR) continue;
        if (n <= 0) return false;
        offset += @intCast(n);
    }
    return true;
}

fn sendAuth(fd: c_int, username: []const u8, password: []const u8) bool {
    if (fd < 0 or username.len == 0 or username.len > 256 or password.len == 0 or password.len > 1024) return false;
    var header: [5]u8 = undefined;
    header[0] = @backingInt(Op.auth);
    std.mem.writeInt(u16, header[1..3], @intCast(username.len), .little);
    std.mem.writeInt(u16, header[3..5], @intCast(password.len), .little);
    if (!writeAll(fd, &header)) return false;
    if (!writeAll(fd, username)) return false;
    if (!writeAll(fd, password)) return false;
    var reply: [1]u8 = .{@backingInt(Reply.failed)};
    if (!readAll(fd, &reply)) return false;
    return reply[0] == @backingInt(Reply.ok);
}

var greeter_running = true;
fn onSignal(_: c.gpointer) callconv(.c) c.gboolean {
    greeter_running = false;
    return 0;
}

pub fn run(a: std.mem.Allocator) !void {
    if (libc.prctl(libc.PR_SET_DUMPABLE, @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0)) != 0) return error.PrctlFailed;
    const dm_fd: c_int = if (libc.getenv("DESKTOP_DM_FD")) |raw|
        std.fmt.parseInt(c_int, std.mem.span(raw), 10) catch -1
    else
        -1;
    const own_compositor = libc.getenv("WAYLAND_DISPLAY") == null;
    var compositor: ?*@import("desktop-compositor.zig").Handle = null;
    if (own_compositor) {
        compositor = try @import("desktop-compositor.zig").Handle.start(a, .greeter);
    }
    defer if (compositor) |handle| handle.stop();

    const password = try SecretBuffer.createLocked();
    defer password.destroyLocked();

    const users = try discoverUsers(a);
    defer {
        for (users) |entry| {
            a.free(entry.username);
            a.free(entry.display_name);
            if (entry.avatar_path) |p| a.free(p);
        }
        a.free(users);
    }
    const view_entries = try a.alloc(view.UserEntry, users.len);
    defer a.free(view_entries);
    for (users, view_entries) |u_entry, *out| {
        out.* = .{
            .username = u_entry.username,
            .display_name = u_entry.display_name,
            .avatar_path = if (u_entry.avatar_path) |p| p.ptr else null,
        };
    }

    var greeter_view = try view.View.init(a, view_entries);
    defer greeter_view.deinit();

    const connection = wire.Connection.connect(a) catch return error.NoWaylandDisplay;
    defer connection.deinit();

    var state: State = .{
        .allocator = a,
        .connection = connection,
        .view = &greeter_view,
        .users = users,
        .password = password,
        .dm_fd = dm_fd,
        .stage = if (users.len > 0) .user_list else .username,
    };
    defer {
        while (state.outputs) |output| {
            state.outputs = output.next;
            output.deinit();
        }
        while (state.seats) |seat| {
            state.seats = seat.next;
            seat.deinit();
        }
        helpers.FrameBuffer.destroyAll(&state.buffers);
    }

    const display: wl.wl_display = .{ .proxy = connection.display() };
    const registry = display.get_registry();
    registry.listen(State, &state, State.registryEvent);
    connection.roundtrip() catch return error.WaylandDisconnected;
    if (state.compositor == null or state.shm == null or state.layer_shell == null) return error.MissingWaylandGlobals;
    var output = state.outputs;
    while (output) |o| : (output = o.next) o.attach();
    connection.roundtrip() catch return error.WaylandDisconnected;

    greeter_running = true;
    const term = c.g_unix_signal_add(c.SIGTERM, &onSignal, null);
    const interrupt = c.g_unix_signal_add(c.SIGINT, &onSignal, null);
    defer _ = c.g_source_remove(term);
    defer _ = c.g_source_remove(interrupt);

    const source = c.g_unix_fd_add(connection.getFd(), c.G_IO_IN | c.G_IO_ERR | c.G_IO_HUP, &State.readable, &state);
    defer _ = c.g_source_remove(source);
    const clock = c.g_timeout_add_seconds(1, &State.tick, &state);
    defer _ = c.g_source_remove(clock);
    defer if (state.spinner != 0) {
        _ = c.g_source_remove(state.spinner);
    };

    while (!state.done and greeter_running) {
        connection.flush() catch break;
        _ = c.g_main_context_iteration(null, 1);
    }
    while (state.busy) _ = c.g_main_context_iteration(null, 1);
    if (!state.authenticated) return error.NotAuthenticated;
}
