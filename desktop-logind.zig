//! A logind session for a compositor, as libseat's logind backend: taking
//! control of the session, opening DRM and input devices through TakeDevice,
//! answering PauseDevice and ResumeDevice on VT switches, and switching VTs.
const std = @import("std");
const dbus = @import("dbus");
const libc = @import("desktop-libc.zig");

const login = "org.freedesktop.login1";
const manager_path = "/org/freedesktop/login1";

pub const Listener = struct {
    context: ?*anyopaque = null,
    /// A device was paused; its descriptor stops working until resumed.
    pause: ?*const fn (?*anyopaque, major: u32, minor: u32) void = null,
    /// A device came back with a new descriptor, owned by the listener.
    @"resume": ?*const fn (?*anyopaque, major: u32, minor: u32, fd: i32) void = null,
    /// The session became active or inactive.
    active: ?*const fn (?*anyopaque, bool) void = null,
};

pub const Device = struct { fd: i32, major: u32, minor: u32 };

pub const Session = struct {
    allocator: std.mem.Allocator,
    connection: *dbus.Connection,
    listener: Listener,
    path_buffer: [256]u8 = undefined,
    path_len: usize = 0,
    seat_buffer: [256]u8 = undefined,
    seat_len: usize = 0,
    active: bool = true,
    /// Messages arrived during a blocking call and wait for `dispatch`.
    backlog: bool = false,

    /// Finds this user's graphical session and takes control of it.
    pub fn open(allocator: std.mem.Allocator, listener: Listener) !*Session {
        const connection = try dbus.Connection.open(allocator, .system);
        errdefer connection.close();
        const self = try allocator.create(Session);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .connection = connection, .listener = listener };
        connection.on_backlog = &backlogged;
        connection.schedule_context = self;
        try self.findSession();
        self.findSeat();
        const control = try connection.callBlocking(.{ .destination = login, .path = self.path(), .interface = "org.freedesktop.login1.Session", .member = "TakeControl" }, .{false}, 5000);
        control.deinit();
        _ = try connection.subscribe(login, "org.freedesktop.login1.Session", null, self.path(), &signal, self);
        _ = try connection.subscribe(login, "org.freedesktop.DBus.Properties", "PropertiesChanged", self.path(), &properties, self);
        return self;
    }

    pub fn close(self: *Session) void {
        if (self.connection.callBlocking(.{ .destination = login, .path = self.path(), .interface = "org.freedesktop.login1.Session", .member = "ReleaseControl" }, .{}, 1000)) |reply| reply.deinit() else |_| {}
        self.connection.close();
        self.allocator.destroy(self);
    }

    pub fn path(self: *const Session) []const u8 {
        return self.path_buffer[0..self.path_len];
    }

    pub fn getFd(self: *const Session) i32 {
        return self.connection.getFd();
    }

    /// Reads and handles signals; call when the bus is readable or after `backlog`.
    pub fn dispatch(self: *Session) void {
        self.backlog = false;
        self.connection.readAndDispatch() catch {};
    }

    fn backlogged(context: ?*anyopaque) void {
        const self: *Session = @ptrCast(@alignCast(context));
        self.backlog = true;
    }

    fn setPath(buffer: []u8, len: *usize, value: []const u8) bool {
        if (value.len > buffer.len) return false;
        @memcpy(buffer[0..value.len], value);
        len.* = value.len;
        return true;
    }

    /// XDG_SESSION_ID, else this process's session, else the user's display
    /// session (a compositor started by the user manager is outside the session scope).
    fn findSession(self: *Session) !void {
        const connection = self.connection;
        if (std.c.getenv("XDG_SESSION_ID")) |id| {
            if (connection.callBlocking(.{ .destination = login, .path = manager_path, .interface = "org.freedesktop.login1.Manager", .member = "GetSession" }, .{std.mem.span(id)}, 2000)) |reply| {
                defer reply.deinit();
                const object = try reply.message().read(struct { dbus.ObjectPath });
                if (setPath(&self.path_buffer, &self.path_len, object[0].value)) return;
            } else |_| {}
        }
        if (connection.callBlocking(.{ .destination = login, .path = manager_path, .interface = "org.freedesktop.login1.Manager", .member = "GetSessionByPID" }, .{@as(u32, @intCast(libc.getpid()))}, 2000)) |reply| {
            defer reply.deinit();
            const object = try reply.message().read(struct { dbus.ObjectPath });
            if (setPath(&self.path_buffer, &self.path_len, object[0].value)) return;
        } else |_| {}
        const user = try connection.callBlocking(.{ .destination = login, .path = manager_path, .interface = "org.freedesktop.login1.Manager", .member = "GetUser" }, .{@as(u32, @intCast(std.os.linux.getuid()))}, 2000);
        defer user.deinit();
        const user_path = (try user.message().read(struct { dbus.ObjectPath }))[0].value;
        const display = try connection.callBlocking(.{ .destination = login, .path = user_path, .interface = "org.freedesktop.DBus.Properties", .member = "Get" }, .{ "org.freedesktop.login1.User", "Display" }, 2000);
        defer display.deinit();
        const value = (try display.message().read(struct { dbus.Value }))[0];
        // Display is (so): the session id and its object path.
        const object = value.lookupIndex(1) orelse return error.NoSession;
        const text = switch (object) {
            .object_path => |p| p,
            else => return error.NoSession,
        };
        if (!setPath(&self.path_buffer, &self.path_len, text) or std.mem.eql(u8, text, "/")) return error.NoSession;
    }

    fn findSeat(self: *Session) void {
        const reply = self.connection.callBlocking(.{ .destination = login, .path = self.path(), .interface = "org.freedesktop.DBus.Properties", .member = "Get" }, .{ "org.freedesktop.login1.Session", "Seat" }, 2000) catch return;
        defer reply.deinit();
        const value = (reply.message().read(struct { dbus.Value }) catch return)[0];
        const object = value.lookupIndex(1) orelse return;
        switch (object) {
            .object_path => |p| _ = setPath(&self.seat_buffer, &self.seat_len, p),
            else => {},
        }
    }

    /// Opens a device node through logind; the descriptor survives VT switches as paused.
    pub fn takeDevice(self: *Session, node: [*:0]const u8) !Device {
        const linux = std.os.linux;
        var info: linux.Statx = undefined;
        if (linux.errno(linux.statx(linux.AT.FDCWD, node, 0, .{ .TYPE = true }, &info)) != .SUCCESS) return error.NoDevice;
        const major = info.rdev_major;
        const minor = info.rdev_minor;
        const reply = try self.connection.callBlocking(.{ .destination = login, .path = self.path(), .interface = "org.freedesktop.login1.Session", .member = "TakeDevice" }, .{ major, minor }, 5000);
        defer reply.deinit();
        const result = try reply.message().read(struct { dbus.Fd, bool });
        // The reply closes its descriptors; keep a copy.
        const fd = std.c.fcntl(result[0].value, std.c.F.DUPFD_CLOEXEC, @as(c_int, 0));
        if (fd < 0) return error.NoDevice;
        return .{ .fd = fd, .major = major, .minor = minor };
    }

    pub fn releaseDevice(self: *Session, device: Device) void {
        _ = std.c.close(device.fd);
        const reply = self.connection.callBlocking(.{ .destination = login, .path = self.path(), .interface = "org.freedesktop.login1.Session", .member = "ReleaseDevice" }, .{ device.major, device.minor }, 2000) catch return;
        reply.deinit();
    }

    /// Switches to virtual terminal `vt`, as Ctrl+Alt+Fn does.
    pub fn switchTo(self: *Session, vt: u32) void {
        if (self.seat_len == 0) return;
        self.connection.send(.{ .destination = login, .path = self.seat_buffer[0..self.seat_len], .interface = "org.freedesktop.login1.Seat", .member = "SwitchTo" }, .{vt}) catch {};
    }

    fn signal(context: ?*anyopaque, message: *const dbus.Message) void {
        const self: *Session = @ptrCast(@alignCast(context));
        const member = message.member orelse return;
        if (std.mem.eql(u8, member, "PauseDevice")) {
            const args = message.read(struct { u32, u32, []const u8 }) catch return;
            if (self.listener.pause) |callback| callback(self.listener.context, args[0], args[1]);
            // A "pause" waits for acknowledgement; "force" and "gone" do not.
            if (std.mem.eql(u8, args[2], "pause")) {
                self.connection.send(.{ .destination = login, .path = self.path(), .interface = "org.freedesktop.login1.Session", .member = "PauseDeviceComplete" }, .{ args[0], args[1] }) catch {};
            }
        } else if (std.mem.eql(u8, member, "ResumeDevice")) {
            const args = message.read(struct { u32, u32, dbus.Fd }) catch return;
            const fd = std.c.fcntl(args[2].value, std.c.F.DUPFD_CLOEXEC, @as(c_int, 0));
            if (fd < 0) return;
            if (self.listener.@"resume") |callback| callback(self.listener.context, args[0], args[1], fd) else _ = std.c.close(fd);
        }
    }

    fn properties(context: ?*anyopaque, message: *const dbus.Message) void {
        const self: *Session = @ptrCast(@alignCast(context));
        const args = message.read(struct { []const u8, dbus.Value, dbus.Value }) catch return;
        if (!std.mem.eql(u8, args[0], "org.freedesktop.login1.Session")) return;
        const changed = args[1].lookup("Active") orelse return;
        const active = switch (changed) {
            .boolean => |value| value,
            else => return,
        };
        if (active == self.active) return;
        self.active = active;
        if (self.listener.active) |callback| callback(self.listener.context, active);
    }
};
