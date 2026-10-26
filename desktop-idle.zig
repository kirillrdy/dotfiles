//! Native idle locking and logind suspend coordination. All callbacks run on the GLib context.
const std = @import("std");
const c = @import("gtk");
const libc = @import("libc");
const p = @import("protocols");
const a = std.heap.page_allocator;
const Proxy = c.wl_proxy;
const login_name = "org.freedesktop.login1";
const login_path = "/org/freedesktop/login1";
const login_interface = "org.freedesktop.login1.Manager";
fn cast(comptime T: type, ptr: anytype) *T {
    return @ptrCast(@alignCast(ptr));
}
fn destroyProxy(proxy: *Proxy) void {
    _ = c.wl_proxy_marshal_flags(proxy, 0, null, c.wl_proxy_get_version(proxy), 1);
}

pub const Options = struct {
    timeout_ms: u32 = 10 * 60 * 1000,
    // Explicit dependency injection for the standalone compositor fixture.
    lock_executable: ?[:0]const u8 = null,
};
const Seat = struct {
    service: *Service,
    name: u32,
    proxy: *c.wl_seat,
    notification: ?*Proxy = null,
    idle: bool = false,
    next: ?*Seat = null,
    fn watch(self: *Seat) void {
        if (self.notification != null or self.service.notifier == null) return;
        self.notification = c.wl_proxy_marshal_flags(self.service.notifier, 1, &p.ext_idle_notification_v1_interface, 1, 0, @as(?*anyopaque, null), self.service.timeout_ms, self.proxy) orelse return;
        if (c.wl_proxy_add_listener(self.notification, @ptrCast(@constCast(&idle_listener)), self) != 0) {
            destroyProxy(self.notification.?);
            self.notification = null;
        }
    }
    fn idled(data: ?*anyopaque, _: ?*Proxy) callconv(.c) void {
        const self = cast(Seat, data);
        self.idle = true;
        if (self.service.allIdle()) self.service.ensureLocked();
    }
    fn resumed(data: ?*anyopaque, _: ?*Proxy) callconv(.c) void {
        cast(Seat, data).idle = false;
    }
    fn deinit(self: *Seat) void {
        if (self.notification) |notification| destroyProxy(notification);
        c.wl_seat_destroy(self.proxy);
        a.destroy(self);
    }
};
const idle_listener = extern struct { idled: *const @TypeOf(Seat.idled), resumed: *const @TypeOf(Seat.resumed) }{ .idled = Seat.idled, .resumed = Seat.resumed };

// An epoch prevents replies from a previous logind owner from changing current state.
const Call = struct {
    service: *Service,
    epoch: u64,
    sleep_serial: u64,
    fn create(self: *Service) *Call {
        const call = a.create(Call) catch @panic("out of memory");
        self.refs += 1;
        call.* = .{ .service = self, .epoch = self.epoch, .sleep_serial = self.sleep_serial };
        return call;
    }
    fn current(self: *Call) bool {
        return !self.service.stopped and self.epoch == self.service.epoch;
    }
    fn deinit(self: *Call) void {
        self.service.unref();
        a.destroy(self);
    }
};

pub const Service = struct {
    timeout_ms: u32,
    executable: [:0]u8,
    refs: usize = 1,
    stopped: bool = false,
    timer: c.guint = 0,
    display: ?*c.wl_display = null,
    registry: ?*c.wl_registry = null,
    notifier: ?*Proxy = null,
    notifier_name: u32 = 0,
    seats: ?*Seat = null,
    wayland_source: c.guint = 0,
    bus: ?*c.GDBusConnection = null,
    bus_pending: bool = false,
    bus_watch: c.guint = 0,
    sleep_signal: c.guint = 0,
    owner: ?[:0]u8 = null,
    epoch: u64 = 0,
    sleep_serial: u64 = 0,
    sleeping: bool = false,
    inhibitor: c_int = -1,
    inhibit_pending: bool = false,
    cancel: [*c]c.GCancellable,
    process: ?*c.GSubprocess = null,
    ready_fd: c_int = -1,
    ready_source: c.guint = 0,
    lock_ready: bool = false,

    pub fn create(options: Options) !*Service {
        const path = if (options.lock_executable) |path| try a.dupeSentinel(u8, path, 0) else blk: {
            const resolved = c.g_file_read_link("/proc/self/exe", null);
            if (resolved == null) return error.ExecutablePathUnavailable;
            defer c.g_free(resolved);
            break :blk try a.dupeSentinel(u8, std.mem.span(resolved), 0);
        };
        errdefer a.free(path);
        const self = try a.create(Service);
        self.* = .{ .timeout_ms = options.timeout_ms, .executable = path, .cancel = c.g_cancellable_new() };
        self.connectWayland();
        self.connectBus();
        self.timer = c.g_timeout_add_seconds(5, &maintain, self);
        return self;
    }
    pub fn destroy(self: *Service) void {
        self.stopped = true;
        if (self.timer != 0) _ = c.g_source_remove(self.timer);
        self.disconnectWayland();
        self.disconnectBus();
        self.closeReady();
        // A running locker continues independently when the shell exits.
        c.g_cancellable_cancel(self.cancel);
        self.unref();
    }
    fn unref(self: *Service) void {
        self.refs -= 1;
        if (self.refs == 0) {
            c.g_object_unref(self.cancel);
            a.free(self.executable);
            a.destroy(self);
        }
    }
    fn maintain(data: ?*anyopaque) callconv(.c) c_int {
        const self = cast(Service, data);
        if (self.display == null) self.connectWayland();
        if (self.bus) |bus| if (c.g_dbus_connection_is_closed(bus) != 0) self.disconnectBus();
        if (self.bus == null) self.connectBus();
        self.acquire();
        if (self.sleeping or self.allIdle()) self.ensureLocked();
        return 1;
    }
    fn allIdle(self: *Service) bool {
        var seat = self.seats orelse return false;
        while (true) {
            if (!seat.idle or seat.notification == null) return false;
            seat = seat.next orelse return true;
        }
    }
    fn connectWayland(self: *Service) void {
        self.display = c.wl_display_connect(null) orelse {
            std.log.warn("idle: Wayland connection unavailable; will retry", .{});
            return;
        };
        self.registry = c.wl_display_get_registry(self.display);
        _ = c.wl_registry_add_listener(self.registry, &registry_listener, self);
        if (c.wl_display_roundtrip(self.display) < 0 or c.wl_display_roundtrip(self.display) < 0) {
            self.disconnectWayland();
            return;
        }
        if (self.notifier == null) std.log.warn("idle: ext-idle-notify unavailable", .{});
        self.wayland_source = c.g_unix_fd_add(c.wl_display_get_fd(self.display), c.G_IO_IN | c.G_IO_ERR | c.G_IO_HUP, &dispatch, self);
        _ = c.wl_display_flush(self.display);
    }
    fn disconnectWayland(self: *Service) void {
        if (self.wayland_source != 0) _ = c.g_source_remove(self.wayland_source);
        self.wayland_source = 0;
        while (self.seats) |seat| {
            self.seats = seat.next;
            seat.deinit();
        }
        if (self.notifier) |notifier| destroyProxy(notifier);
        self.notifier = null;
        if (self.registry) |registry| c.wl_registry_destroy(registry);
        self.registry = null;
        if (self.display) |display| c.wl_display_disconnect(display);
        self.display = null;
    }
    fn global(data: ?*anyopaque, registry: ?*c.wl_registry, name: u32, interface: [*c]const u8, _: u32) callconv(.c) void {
        const self = cast(Service, data);
        const kind = std.mem.span(interface);
        if (std.mem.eql(u8, kind, "ext_idle_notifier_v1")) {
            self.notifier = cast(Proxy, c.wl_registry_bind(registry, name, &p.ext_idle_notifier_v1_interface, 1));
            self.notifier_name = name;
            var seat = self.seats;
            while (seat) |s| : (seat = s.next) s.watch();
        } else if (std.mem.eql(u8, kind, "wl_seat")) {
            const seat = a.create(Seat) catch @panic("out of memory");
            seat.* = .{ .service = self, .name = name, .proxy = cast(c.wl_seat, c.wl_registry_bind(registry, name, &c.wl_seat_interface, 1)), .next = self.seats };
            self.seats = seat;
            seat.watch();
        }
    }
    fn globalRemove(data: ?*anyopaque, _: ?*c.wl_registry, name: u32) callconv(.c) void {
        const self = cast(Service, data);
        var seat = &self.seats;
        while (seat.*) |s| {
            if (s.name == name) {
                seat.* = s.next;
                s.deinit();
                break;
            }
            seat = &s.next;
        }
        if (self.notifier != null and self.notifier_name == name) {
            var current = self.seats;
            while (current) |s| : (current = s.next) {
                if (s.notification) |notification| destroyProxy(notification);
                s.notification = null;
                s.idle = false;
            }
            destroyProxy(self.notifier.?);
            self.notifier = null;
        }
        if (self.allIdle()) self.ensureLocked();
    }
    fn dispatch(_: c_int, flags: c.GIOCondition, data: ?*anyopaque) callconv(.c) c_int {
        const self = cast(Service, data);
        if (flags & (c.G_IO_HUP | c.G_IO_ERR) != 0 or c.wl_display_dispatch(self.display) < 0) {
            self.wayland_source = 0;
            self.disconnectWayland();
            return 0;
        }
        _ = c.wl_display_flush(self.display);
        return 1;
    }
    fn connectBus(self: *Service) void {
        if (self.bus_pending) return;
        self.bus_pending = true;
        self.refs += 1;
        c.g_bus_get(c.G_BUS_TYPE_SYSTEM, self.cancel, &busConnected, self);
    }
    fn busConnected(_: [*c]c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self = cast(Service, data);
        defer self.unref();
        self.bus_pending = false;
        const bus = c.g_bus_get_finish(result, null) orelse {
            if (!self.stopped) std.log.warn("idle: system bus unavailable; will retry", .{});
            return;
        };
        if (self.stopped) {
            c.g_object_unref(bus);
            return;
        }
        self.bus = bus;
        c.g_dbus_connection_set_exit_on_close(bus, 0);
        self.bus_watch = c.g_bus_watch_name_on_connection(bus, login_name, 0, &appeared, &vanished, self, null);
    }
    fn resetOwner(self: *Service) void {
        self.epoch +%= 1;
        self.release();
        self.inhibit_pending = false;
        self.sleeping = false;
        if (self.sleep_signal != 0) c.g_dbus_connection_signal_unsubscribe(self.bus, self.sleep_signal);
        self.sleep_signal = 0;
        if (self.owner) |owner| a.free(owner);
        self.owner = null;
    }
    fn disconnectBus(self: *Service) void {
        if (self.bus_watch != 0) c.g_bus_unwatch_name(self.bus_watch);
        self.bus_watch = 0;
        self.resetOwner();
        if (self.bus) |bus| c.g_object_unref(bus);
        self.bus = null;
    }
    fn appeared(_: ?*c.GDBusConnection, _: [*c]const u8, owner: [*c]const u8, data: ?*anyopaque) callconv(.c) void {
        const self = cast(Service, data);
        self.resetOwner();
        self.owner = a.dupeSentinel(u8, std.mem.span(owner), 0) catch @panic("out of memory");
        self.sleep_signal = c.g_dbus_connection_signal_subscribe(self.bus, self.owner.?.ptr, login_interface, "PrepareForSleep", login_path, null, 0, &prepare, self, null);
        self.acquire();
        c.g_dbus_connection_call(self.bus, self.owner.?.ptr, login_path, "org.freedesktop.DBus.Properties", "Get", c.g_variant_new("(ss)", @as([*:0]const u8, login_interface), @as([*:0]const u8, "PreparingForSleep")), null, c.G_DBUS_CALL_FLAGS_NONE, 3000, self.cancel, &preparingRead, Call.create(self));
    }
    fn vanished(_: ?*c.GDBusConnection, _: [*c]const u8, data: ?*anyopaque) callconv(.c) void {
        cast(Service, data).resetOwner();
    }
    fn acquire(self: *Service) void {
        if (self.stopped or self.owner == null or self.inhibitor >= 0 or self.inhibit_pending or self.sleeping) return;
        self.inhibit_pending = true;
        c.g_dbus_connection_call_with_unix_fd_list(self.bus, self.owner.?.ptr, login_path, login_interface, "Inhibit", c.g_variant_new("(ssss)", @as([*:0]const u8, "sleep"), @as([*:0]const u8, "desktop-zig"), @as([*:0]const u8, "Lock the session before sleep"), @as([*:0]const u8, "delay")), null, c.G_DBUS_CALL_FLAGS_NONE, 3000, null, self.cancel, &inhibited, Call.create(self));
    }
    fn inhibited(source: [*c]c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
        const call = cast(Call, data);
        defer call.deinit();
        const self = call.service;
        var list: [*c]c.GUnixFDList = null;
        const reply = c.g_dbus_connection_call_with_unix_fd_list_finish(@ptrCast(source), &list, result, null);
        defer {
            if (list != null) c.g_object_unref(list);
        }
        if (reply == null) {
            if (call.current()) {
                self.inhibit_pending = false;
                std.log.warn("idle: sleep delay inhibitor unavailable; will retry", .{});
            }
            return;
        }
        defer c.g_variant_unref(reply);
        if (!call.current()) return;
        self.inhibit_pending = false;
        const handle = c.g_variant_get_child_value(reply, 0);
        defer c.g_variant_unref(handle);
        if (list != null) self.inhibitor = c.g_unix_fd_list_get(list, c.g_variant_get_handle(handle), null);
        if (self.inhibitor < 0) {
            std.log.warn("idle: invalid sleep inhibitor fd", .{});
            return;
        }
        self.refreshReady();
        if (self.sleeping and self.lock_ready) self.release();
    }
    fn release(self: *Service) void {
        if (self.inhibitor >= 0) _ = libc.close(self.inhibitor);
        self.inhibitor = -1;
    }
    fn preparingRead(source: [*c]c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
        const call = cast(Call, data);
        defer call.deinit();
        const reply = c.g_dbus_connection_call_finish(@ptrCast(source), result, null) orelse return;
        defer c.g_variant_unref(reply);
        if (!call.current() or call.sleep_serial != call.service.sleep_serial) return;
        const child = c.g_variant_get_child_value(reply, 0);
        defer c.g_variant_unref(child);
        const value = c.g_variant_get_variant(child);
        defer c.g_variant_unref(value);
        call.service.setPreparing(c.g_variant_get_boolean(value) != 0);
    }
    fn prepare(_: ?*c.GDBusConnection, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, parameters: ?*c.GVariant, data: ?*anyopaque) callconv(.c) void {
        const self = cast(Service, data);
        self.sleep_serial +%= 1;
        const value = c.g_variant_get_child_value(parameters, 0);
        defer c.g_variant_unref(value);
        self.setPreparing(c.g_variant_get_boolean(value) != 0);
    }
    fn setPreparing(self: *Service, sleeping: bool) void {
        self.sleeping = sleeping;
        if (sleeping) {
            self.ensureLocked();
            self.refreshReady();
            if (self.lock_ready) self.release();
        } else self.acquire();
    }
    fn ensureLocked(self: *Service) void {
        if (self.stopped or self.process != null) return;
        var fds: [2]c_int = undefined;
        if (libc.pipe2(&fds, libc.O_CLOEXEC | libc.O_NONBLOCK) != 0) {
            std.log.warn("idle: lock readiness pipe failed", .{});
            return;
        }
        const launcher = c.g_subprocess_launcher_new(0);
        defer c.g_object_unref(launcher);
        c.g_subprocess_launcher_take_fd(launcher, fds[1], 3);
        const argv = [_:null]?[*:0]const u8{ self.executable.ptr, "lock", "--ready-fd", "3" };
        self.process = c.g_subprocess_launcher_spawnv(launcher, @ptrCast(&argv), null) orelse {
            _ = libc.close(fds[0]);
            std.log.warn("idle: could not start lock client; retaining sleep inhibitor", .{});
            return;
        };
        self.lock_ready = false;
        self.ready_fd = fds[0];
        self.ready_source = c.g_unix_fd_add(self.ready_fd, c.G_IO_IN | c.G_IO_HUP | c.G_IO_ERR, &ready, self);
        self.refs += 1;
        c.g_subprocess_wait_async(self.process, self.cancel, &exited, self);
    }
    fn closeReady(self: *Service) void {
        if (self.ready_source != 0) _ = c.g_source_remove(self.ready_source);
        self.ready_source = 0;
        if (self.ready_fd >= 0) _ = libc.close(self.ready_fd);
        self.ready_fd = -1;
        self.lock_ready = false;
    }
    fn refreshReady(self: *Service) void {
        if (self.ready_fd >= 0) _ = ready(self.ready_fd, 0, self);
    }
    fn ready(_: c_int, _: c.GIOCondition, data: ?*anyopaque) callconv(.c) c_int {
        const self = cast(Service, data);
        var byte: u8 = 0;
        const count = libc.read(self.ready_fd, &byte, 1);
        if (count < 0 and (libc.__errno_location().* == 11 or libc.__errno_location().* == 4)) return 1;
        if (count == 1 and byte == '1') {
            self.lock_ready = true;
            if (self.sleeping) self.release();
            return 1;
        }
        const was_ready = self.lock_ready;
        self.closeReady();
        if (!was_ready) std.log.warn("idle: lock readiness failed; retaining sleep inhibitor", .{});
        return 0;
    }
    fn exited(source: [*c]c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self = cast(Service, data);
        defer self.unref();
        const waited = c.g_subprocess_wait_finish(@ptrCast(source), result, null) != 0;
        const successful = waited and c.g_subprocess_get_successful(@ptrCast(source)) != 0;
        if (!self.stopped and waited and !successful) std.log.warn("idle: lock client failed; retaining sleep inhibitor", .{});
        self.closeReady();
        self.lock_ready = false;
        c.g_object_unref(self.process);
        self.process = null;
        if (!self.stopped and self.sleeping and successful) self.ensureLocked();
    }
};
const registry_listener = c.wl_registry_listener{ .global = Service.global, .global_remove = Service.globalRemove };
