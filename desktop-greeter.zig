//! Native Wayland layer-shell greeter client styled after GDM.
//! Runs unprivileged inside an embedded compositor; sends auth/power requests to desktop-dm.
const std = @import("std");
const wl = @import("wayland-client");
const wire = @import("wayland-wire");
const mainloop = @import("desktop-loop.zig");
const util = @import("desktop-util.zig");
const libc = @import("desktop-libc.zig");
const view = @import("desktop-greeter-view.zig");
const login = @import("desktop-login-ui.zig");
const login_client = @import("desktop-login-client.zig");
const raster = @import("desktop-raster.zig");

const cast = util.cast;
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
    libc.setpwent();
    defer libc.endpwent();
    while (libc.getpwent()) |pw| {
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
        if (libc.access(accounts_icon.ptr, libc.R_OK) == 0) {
            avatar = accounts_icon;
        } else {
            a.free(accounts_icon);
            if (home.len > 0) {
                const face = try std.fmt.allocPrintSentinel(a, "{s}/.face", .{home}, 0);
                if (libc.access(face.ptr, libc.R_OK) == 0) avatar = face else a.free(face);
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

const LoginClient = login_client.Client(State);
const Output = LoginClient.Output;
const Seat = LoginClient.Seat;

const State = struct {
    client: LoginClient,
    layer_shell: ?wl.zwlr_layer_shell_v1 = null,
    primary_output: ?*Output = null,
    view: *view.View,
    users: []const DiscoveredUser,
    custom_username: SecretBuffer = .{},
    dm_fd: c_int,
    stage: view.Stage = .user_list,
    selected: usize = 0,
    active_user: ?usize = null,
    accepted: bool = false,
    power_menu_open: bool = false,
    hover: view.Target = .none,

    pub const name = "desktop-greeter";
    pub const fail_closed = false;
    pub const cursor_shapes = true;
    pub const retry_ms = 1000;
    pub const Role = wl.zwlr_layer_surface_v1;

    pub fn canAttach(self: *State) bool {
        return self.layer_shell != null;
    }

    pub fn attachRole(self: *State, output: *Output, surface: wl.wl_surface) Role {
        const layer = self.layer_shell.?.get_layer_surface(surface, output.output, wl.zwlr_layer_shell_v1.Layer.overlay, "desktop-greeter");
        const anchor = wl.zwlr_layer_surface_v1.Anchor.top | wl.zwlr_layer_surface_v1.Anchor.bottom | wl.zwlr_layer_surface_v1.Anchor.left | wl.zwlr_layer_surface_v1.Anchor.right;
        layer.set_anchor(anchor);
        layer.set_exclusive_zone(-1);
        layer.set_keyboard_interactivity(wl.zwlr_layer_surface_v1.KeyboardInteractivity.exclusive);
        layer.set_size(0, 0);
        layer.listen(Output, output, layerEvent);
        surface.commit();
        return layer;
    }

    fn layerEvent(output: *Output, layer: wl.zwlr_layer_surface_v1, event: wl.zwlr_layer_surface_v1.Event) void {
        switch (event) {
            .configure => |value| {
                layer.ack_configure(value.serial);
                output.configure(value.width, value.height);
            },
            .closed => output.client.done = true,
        }
    }

    pub fn bindGlobal(self: *State, registry: wl.wl_registry, global: u32, interface: []const u8, version: u32) void {
        if (std.mem.eql(u8, interface, "zwlr_layer_shell_v1")) {
            self.layer_shell = registry.bind(global, wl.zwlr_layer_shell_v1, @min(version, 4));
        }
    }

    pub fn outputAdded(self: *State, output: *Output) void {
        if (self.primary_output == null) self.primary_output = output;
    }

    pub fn outputRemoved(self: *State, output: *Output) void {
        if (self.primary_output == output) self.primary_output = null;
    }

    fn isPrimary(self: *const State, output: *const Output) bool {
        if (self.primary_output) |primary| return primary == output;
        return self.client.outputs == output;
    }

    pub fn paint(self: *State, output: *Output, target: raster.Buffer, scale: u32) void {
        if (self.isPrimary(output)) {
            self.view.paint(target, scale, self.frame());
        } else {
            view.View.paintSecondary(target);
        }
    }

    pub fn pointer(self: *State, seat: *Seat, event: login_client.Pointer) void {
        switch (event) {
            .enter => {
                if (self.client.pointer_output) |output| self.primary_output = output;
                self.updateHover(seat);
                self.render();
            },
            .leave => if (!std.meta.eql(self.hover, view.Target.none)) {
                self.hover = .none;
                self.render();
            },
            .motion => self.updateHover(seat),
            .button => |button| if (button == 0x110) self.click(),
        }
    }

    pub fn key(self: *State, seat: *Seat, code: u32, symbol: u32) void {
        if (self.power_menu_open) {
            if (symbol == 0xff1b) {
                self.power_menu_open = false;
                self.render();
            }
            return;
        }

        switch (self.stage) {
            .user_list => {
                const count = self.users.len + 1;
                switch (symbol) {
                    0xff52 => { // Up
                        self.selected = if (self.selected == 0) count - 1 else self.selected - 1;
                        self.render();
                    },
                    0xff54, 0xff09 => { // Down / Tab
                        self.selected = (self.selected + 1) % count;
                        self.render();
                    },
                    0xff0d, 0xff8d, 0x0020 => self.activateSelected(),
                    else => {},
                }
            },
            .username => switch (symbol) {
                0xff1b => self.showUserList(),
                0xff0d, 0xff8d => self.confirmUsername(),
                0xff08 => {
                    self.custom_username.backspace();
                    self.client.failed = false;
                    self.render();
                },
                else => {
                    seat.typeInto(&self.custom_username, code);
                    self.client.failed = false;
                    self.render();
                },
            },
            .password => switch (symbol) {
                0xff1b => self.goBackFromPassword(),
                0xff0d, 0xff8d => self.submitPassword(),
                0xff08 => {
                    self.client.password.backspace();
                    self.client.changed();
                },
                else => {
                    seat.typeInto(self.client.password, code);
                    self.client.changed();
                },
            },
        }
    }

    pub fn keyboardEnter(_: *State) void {
        std.log.info("greeter: keyboard focus ready", .{});
    }

    pub fn capsLockChanged(self: *State) void {
        if (self.stage == .password) self.render();
    }

    pub fn verify(self: *State) bool {
        return sendAuth(self.dm_fd, self.activeUsername(), self.client.password.slice());
    }

    pub fn acceptAuth(_: *State) bool {
        return true;
    }

    pub fn authenticated(self: *State) void {
        self.accepted = true;
    }

    pub fn tick(self: *State) void {
        if (self.view.tick()) self.render();
    }

    fn render(self: *State) void {
        self.client.render();
    }

    fn frame(self: *const State) view.Frame {
        return .{
            .stage = self.stage,
            .status = self.client.status(),
            .selected = self.selected,
            .active_user = self.active_user,
            .username_text = self.custom_username.slice(),
            .typed = self.client.typed,
            .caps_lock = self.client.caps_lock,
            .spin = login.spinPhase(self.client.io),
            .power_menu_open = self.power_menu_open,
            .hover = self.hover,
        };
    }

    fn updateHover(self: *State, seat: *Seat) void {
        const output = self.client.pointer_output orelse return;
        const layout = view.Layout.compute(@floatFromInt(output.width), @floatFromInt(output.height), self.users.len);
        const target = layout.hitTest(self.frame(), self.client.pointer_x, self.client.pointer_y);
        seat.setCursor(switch (target) {
            .none => wl.wp_cursor_shape_device_v1.Shape.default,
            .entry => wl.wp_cursor_shape_device_v1.Shape.text,
            else => wl.wp_cursor_shape_device_v1.Shape.pointer,
        });
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
        self.client.resetPassword();
        self.stage = .password;
        self.render();
    }

    fn openCustomUsername(self: *State) void {
        self.active_user = null;
        self.custom_username.clear();
        self.client.resetPassword();
        self.stage = .username;
        self.render();
    }

    fn showUserList(self: *State) void {
        if (self.client.busy) return;
        self.client.resetPassword();
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
        self.client.resetPassword();
        self.stage = .password;
        self.render();
    }

    fn goBackFromPassword(self: *State) void {
        if (self.client.busy) return;
        self.client.resetPassword();
        self.stage = if (self.active_user == null) .username else .user_list;
        self.render();
    }

    fn click(self: *State) void {
        if (self.client.busy or self.client.done) return;
        const output = self.client.pointer_output orelse return;
        const layout = view.Layout.compute(@floatFromInt(output.width), @floatFromInt(output.height), self.users.len);
        const target = layout.hitTest(self.frame(), self.client.pointer_x, self.client.pointer_y);
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
        if (self.activeUsername().len == 0) return;
        self.client.authenticate();
    }

    fn activeUsername(self: *const State) []const u8 {
        if (self.active_user) |idx| {
            if (idx < self.users.len) return self.users[idx].username;
        }
        return self.custom_username.slice();
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

fn onSignal(self: *LoginClient) bool {
    self.stopped = true;
    return false;
}

/// `dm_fd` is the display manager control socket, or -1 when run standalone.
pub fn run(a: std.mem.Allocator, io: std.Io, dm_fd: c_int) !void {
    if (libc.prctl(libc.PR_SET_DUMPABLE, @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0)) != 0) return error.PrctlFailed;
    const own_compositor = libc.getenv("WAYLAND_DISPLAY") == null;
    var compositor: ?*@import("desktop-compositor.zig").Handle = null;
    if (own_compositor) {
        compositor = try @import("desktop-compositor.zig").Handle.start(a, io, .greeter);
    }
    defer if (compositor) |handle| handle.stop();

    const password = try SecretBuffer.create();
    defer password.destroy();

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
        .client = .{ .allocator = a, .io = io, .connection = connection, .password = password },
        .view = &greeter_view,
        .users = users,
        .dm_fd = dm_fd,
        .stage = if (users.len > 0) .user_list else .username,
    };
    defer state.client.deinit();

    try state.client.connect();
    if (state.client.compositor == null or state.client.shm == null or state.layer_shell == null) return error.MissingWaylandGlobals;
    state.client.attachAll();
    connection.roundtrip() catch return error.WaylandDisconnected;

    const term = mainloop.signal(io, mainloop.SIGTERM, &state.client, onSignal);
    const interrupt = mainloop.signal(io, mainloop.SIGINT, &state.client, onSignal);
    defer _ = mainloop.remove(io, term);
    defer _ = mainloop.remove(io, interrupt);

    state.client.run();
    if (!state.accepted) return error.NotAuthenticated;
}
