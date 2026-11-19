//! Native idle locking and logind suspend coordination. All callbacks run on the GLib context.
const std = @import("std");
const wayland = @import("desktop-wayland.zig");
const c = @import("desktop-glib.zig");
const libc = @import("desktop-libc.zig");
const p = @import("desktop-protocols.zig");
const a = if (@import("builtin").is_test) std.testing.allocator else std.heap.page_allocator;
const Proxy = c.wl_proxy;
const login_name = "org.freedesktop.login1";
const login_path = "/org/freedesktop/login1";
const login_interface = "org.freedesktop.login1.Manager";
const screensaver_name = "org.freedesktop.ScreenSaver";
const screensaver_paths = [_][*:0]const u8{ "/org/freedesktop/ScreenSaver", "/ScreenSaver" };
const screensaver_xml =
    "<node><interface name=\"org.freedesktop.ScreenSaver\">" ++
    "<method name=\"Inhibit\"><arg type=\"s\" name=\"application_name\" direction=\"in\"/><arg type=\"s\" name=\"reason_for_inhibit\" direction=\"in\"/><arg type=\"u\" name=\"cookie\" direction=\"out\"/></method>" ++
    "<method name=\"UnInhibit\"><arg type=\"u\" name=\"cookie\" direction=\"in\"/></method>" ++
    "<method name=\"SimulateUserActivity\"/>" ++
    "</interface></node>";
const portal_name = "org.freedesktop.portal.Desktop";
const portal_path = "/org/dotfiles/Portal";
const portal_interface = "org.dotfiles.Portal";
const cast = c.__zig.cast;
fn destroyProxy(proxy: *Proxy) void {
    _ = c.wl_proxy_marshal_flags(proxy, 0, null, c.wl_proxy_get_version(proxy), 1);
}

pub const Options = struct {
    timeout_ms: u32 = 10 * 60 * 1000,
    // Explicit dependency injection for the standalone compositor fixture.
    lock_executable: ?[:0]const u8 = null,
    session_inhibit: bool = false,
};
const ScreenSaverInhibitor = struct {
    cookie: u32,
    sender: [:0]u8,
};
const Seat = struct {
    service: *Service,
    name: u32,
    proxy: *c.wl_seat,
    notification: ?*Proxy = null,
    idle: bool = false,
    next: ?*Seat = null,
    fn watch(self: *Seat) void {
        if (self.service.idleInhibited() or self.notification != null or self.service.notifier == null) return;
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
    portal_epoch: u64,
    fn create(self: *Service) *Call {
        const call = a.create(Call) catch @panic("out of memory");
        self.refs += 1;
        call.* = .{ .service = self, .epoch = self.epoch, .sleep_serial = self.sleep_serial, .portal_epoch = self.portal_epoch };
        return call;
    }
    fn current(self: *Call) bool {
        return !self.service.stopped and self.epoch == self.service.epoch;
    }
    fn currentPortal(self: *Call) bool {
        return !self.service.stopped and self.portal_epoch == self.service.portal_epoch;
    }
    fn deinit(self: *Call) void {
        self.service.unref();
        a.destroy(self);
    }
};

pub const Service = struct {
    timeout_ms: u32,
    executable: [:0]u8,
    session_inhibit: bool = false,
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
    session_bus: ?*c.GDBusConnection = null,
    session_pending: bool = false,
    screensaver_owner: c.guint = 0,
    screensaver_node: ?*c.GDBusNodeInfo = null,
    screensaver_regs: [screensaver_paths.len]c.guint = @splat(0),
    name_signal: c.guint = 0,
    portal_watch: c.guint = 0,
    portal_signal: c.guint = 0,
    portal_owner: ?[:0]u8 = null,
    portal_epoch: u64 = 0,
    screensaver_inhibitors: std.ArrayList(ScreenSaverInhibitor) = .empty,
    screensaver_serial: u32 = 0,
    portal_inhibited: bool = false,
    audio_inhibited: bool = false,
    last_inhibited: bool = false,
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
        self.* = .{ .timeout_ms = options.timeout_ms, .executable = path, .session_inhibit = options.session_inhibit, .cancel = c.g_cancellable_new() };
        self.connectWayland();
        self.connectBus();
        self.connectSessionBus();
        self.timer = c.g_timeout_add_seconds(5, &maintain, self);
        return self;
    }
    pub fn destroy(self: *Service) void {
        self.stopped = true;
        if (self.timer != 0) _ = c.g_source_remove(self.timer);
        self.disconnectWayland();
        self.disconnectBus();
        self.disconnectSessionBus();
        self.closeReady();
        // A running locker continues independently when the shell exits.
        c.g_cancellable_cancel(self.cancel);
        self.unref();
    }
    fn unref(self: *Service) void {
        self.refs -= 1;
        if (self.refs == 0) {
            c.g_object_unref(self.cancel);
            self.screensaver_inhibitors.deinit(a);
            a.free(self.executable);
            a.destroy(self);
        }
    }
    fn maintain(data: ?*anyopaque) callconv(.c) c_int {
        const self = cast(Service, data);
        if (self.display == null) self.connectWayland();
        if (self.bus) |bus| if (c.g_dbus_connection_is_closed(bus) != 0) self.disconnectBus();
        if (self.bus == null) self.connectBus();
        if (self.session_inhibit) {
            if (self.session_bus) |bus| if (c.g_dbus_connection_is_closed(bus) != 0) self.disconnectSessionBus();
            if (self.session_bus == null) self.connectSessionBus();
        }
        self.acquire();
        if (self.sleeping or self.allIdle()) self.ensureLocked();
        return 1;
    }
    pub fn setAudioInhibited(self: *Service, active: bool) void {
        if (self.stopped or self.audio_inhibited == active) return;
        self.audio_inhibited = active;
        self.syncInhibition();
    }
    pub fn idleInhibited(self: *const Service) bool {
        return self.portal_inhibited or self.audio_inhibited or self.screensaver_inhibitors.items.len > 0;
    }
    fn syncInhibition(self: *Service) void {
        if (self.stopped) return;
        const active = self.idleInhibited();
        if (active == self.last_inhibited) return;
        self.last_inhibited = active;
        var seat = self.seats;
        if (active) {
            while (seat) |s| : (seat = s.next) {
                s.idle = false;
                if (s.notification) |notification| {
                    destroyProxy(notification);
                    s.notification = null;
                }
            }
        } else {
            while (seat) |s| : (seat = s.next) s.watch();
        }
        if (self.display) |display| _ = c.wl_display_flush(display);
    }
    fn resetIdleTimer(self: *Service) void {
        if (self.stopped or self.idleInhibited()) return;
        var seat = self.seats;
        while (seat) |s| : (seat = s.next) {
            s.idle = false;
            if (s.notification) |notification| {
                destroyProxy(notification);
                s.notification = null;
            }
            s.watch();
        }
        if (self.display) |display| _ = c.wl_display_flush(display);
    }
    fn allIdle(self: *Service) bool {
        if (self.idleInhibited()) return false;
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
        _ = c.wl_display_dispatch_pending(self.display);
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
            seat.* = .{ .service = self, .name = name, .proxy = cast(c.wl_seat, c.wl_registry_bind(registry, name, &wayland.wl_seat_interface, 1)), .next = self.seats };
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
        if (flags & (c.G_IO_HUP | c.G_IO_ERR) != 0 or !c.__zig.dispatchWayland(self.display)) {
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
    fn connectSessionBus(self: *Service) void {
        if (!self.session_inhibit or self.session_pending) return;
        self.session_pending = true;
        self.refs += 1;
        c.g_bus_get(c.G_BUS_TYPE_SESSION, self.cancel, &sessionBusConnected, self);
    }
    fn sessionBusConnected(_: [*c]c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self = cast(Service, data);
        defer self.unref();
        self.session_pending = false;
        const bus = c.g_bus_get_finish(result, null) orelse {
            if (!self.stopped) std.log.warn("idle: session bus unavailable; will retry", .{});
            return;
        };
        if (self.stopped) {
            c.g_object_unref(bus);
            return;
        }
        self.session_bus = bus;
        c.g_dbus_connection_set_exit_on_close(bus, 0);
        const node = c.g_dbus_node_info_new_for_xml(screensaver_xml, null) orelse @panic("invalid ScreenSaver XML");
        self.screensaver_node = node;
        for (screensaver_paths, 0..) |object_path, i| {
            self.screensaver_regs[i] = c.g_dbus_connection_register_object(bus, object_path, node.*.interfaces[0], &screensaver_vtable, self, null, null);
            if (self.screensaver_regs[i] == 0) std.log.warn("idle: failed to register ScreenSaver at {s}", .{object_path});
        }
        self.screensaver_owner = c.g_bus_own_name_on_connection(bus, screensaver_name, c.G_BUS_NAME_OWNER_FLAGS_NONE, null, null, null, null);
        self.name_signal = c.g_dbus_connection_signal_subscribe(bus, "org.freedesktop.DBus", "org.freedesktop.DBus", "NameOwnerChanged", "/org/freedesktop/DBus", null, 0, &sessionOwnerChanged, self, null);
        self.portal_watch = c.g_bus_watch_name_on_connection(bus, portal_name, 0, &portalAppeared, &portalVanished, self, null);
    }
    fn disconnectSessionBus(self: *Service) void {
        if (self.portal_watch != 0) c.g_bus_unwatch_name(self.portal_watch);
        self.portal_watch = 0;
        self.resetPortal();
        if (self.name_signal != 0 and self.session_bus != null) c.g_dbus_connection_signal_unsubscribe(self.session_bus, self.name_signal);
        self.name_signal = 0;
        if (self.screensaver_owner != 0) c.g_bus_unown_name(self.screensaver_owner);
        self.screensaver_owner = 0;
        for (&self.screensaver_regs) |*reg| {
            if (reg.* != 0 and self.session_bus != null) _ = c.g_dbus_connection_unregister_object(self.session_bus, reg.*);
            reg.* = 0;
        }
        if (self.screensaver_node) |node| c.g_dbus_node_info_unref(node);
        self.screensaver_node = null;
        self.clearScreenSaverInhibitors();
        if (self.session_bus) |bus| c.g_object_unref(bus);
        self.session_bus = null;
    }
    fn resetPortal(self: *Service) void {
        self.portal_epoch +%= 1;
        if (self.portal_signal != 0 and self.session_bus != null) c.g_dbus_connection_signal_unsubscribe(self.session_bus, self.portal_signal);
        self.portal_signal = 0;
        if (self.portal_owner) |owner| a.free(owner);
        self.portal_owner = null;
        self.portal_inhibited = false;
        self.syncInhibition();
    }
    fn portalAppeared(_: ?*c.GDBusConnection, _: [*c]const u8, owner: [*c]const u8, data: ?*anyopaque) callconv(.c) void {
        const self = cast(Service, data);
        self.resetPortal();
        self.portal_owner = a.dupeSentinel(u8, std.mem.span(owner), 0) catch @panic("out of memory");
        self.portal_signal = c.g_dbus_connection_signal_subscribe(self.session_bus, self.portal_owner.?.ptr, portal_interface, "IdleInhibitedChanged", portal_path, null, 0, &portalChanged, self, null);
        c.g_dbus_connection_call(self.session_bus, self.portal_owner.?.ptr, portal_path, portal_interface, "IdleInhibited", null, @ptrCast(@as([*:0]const u8, "(b)")), c.G_DBUS_CALL_FLAGS_NONE, 3000, self.cancel, &portalRead, Call.create(self));
    }
    fn portalVanished(_: ?*c.GDBusConnection, _: [*c]const u8, data: ?*anyopaque) callconv(.c) void {
        cast(Service, data).resetPortal();
    }
    fn portalRead(source: [*c]c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
        const call = cast(Call, data);
        defer call.deinit();
        const reply = c.g_dbus_connection_call_finish(@ptrCast(source), result, null) orelse return;
        defer c.g_variant_unref(reply);
        if (!call.currentPortal()) return;
        const value = c.g_variant_get_child_value(reply, 0);
        defer c.g_variant_unref(value);
        call.service.portal_inhibited = c.g_variant_get_boolean(value) != 0;
        call.service.syncInhibition();
    }
    fn portalChanged(_: ?*c.GDBusConnection, sender: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, parameters: ?*c.GVariant, data: ?*anyopaque) callconv(.c) void {
        const self = cast(Service, data);
        if (self.portal_owner == null or !std.mem.eql(u8, std.mem.span(sender), self.portal_owner.?)) return;
        const value = c.g_variant_get_child_value(parameters, 0);
        defer c.g_variant_unref(value);
        self.portal_inhibited = c.g_variant_get_boolean(value) != 0;
        self.syncInhibition();
    }
    fn clearScreenSaverInhibitors(self: *Service) void {
        for (self.screensaver_inhibitors.items) |item| a.free(item.sender);
        self.screensaver_inhibitors.clearRetainingCapacity();
        self.syncInhibition();
    }
    fn hasScreenSaverCookie(self: *const Service, cookie: u32) bool {
        for (self.screensaver_inhibitors.items) |item| if (item.cookie == cookie) return true;
        return false;
    }
    fn senderScreenSaverCount(self: *const Service, sender: []const u8) usize {
        var count: usize = 0;
        for (self.screensaver_inhibitors.items) |item| if (std.mem.eql(u8, item.sender, sender)) {
            count += 1;
        };
        return count;
    }
    fn addScreenSaverInhibitor(self: *Service, sender: []const u8) !u32 {
        if (self.screensaver_inhibitors.items.len >= 256 or self.senderScreenSaverCount(sender) >= 64) return error.TooManyInhibitors;
        var cookie: u32 = 0;
        while (cookie == 0 or self.hasScreenSaverCookie(cookie)) {
            self.screensaver_serial +%= 1;
            if (self.screensaver_serial == 0) self.screensaver_serial = 1;
            cookie = self.screensaver_serial;
        }
        const owned_sender = try a.dupeSentinel(u8, sender, 0);
        errdefer a.free(owned_sender);
        try self.screensaver_inhibitors.append(a, .{ .cookie = cookie, .sender = owned_sender });
        self.syncInhibition();
        return cookie;
    }
    fn removeScreenSaverInhibitor(self: *Service, sender: []const u8, cookie: u32) !void {
        for (self.screensaver_inhibitors.items, 0..) |item, i| if (item.cookie == cookie) {
            if (!std.mem.eql(u8, item.sender, sender)) return error.AccessDenied;
            a.free(item.sender);
            _ = self.screensaver_inhibitors.swapRemove(i);
            self.syncInhibition();
            return;
        };
        return error.InvalidCookie;
    }
    fn removeScreenSaverSender(self: *Service, sender: []const u8) void {
        var changed = false;
        var i: usize = 0;
        while (i < self.screensaver_inhibitors.items.len) {
            if (std.mem.eql(u8, self.screensaver_inhibitors.items[i].sender, sender)) {
                a.free(self.screensaver_inhibitors.items[i].sender);
                _ = self.screensaver_inhibitors.swapRemove(i);
                changed = true;
            } else i += 1;
        }
        if (changed) self.syncInhibition();
    }
    fn sessionOwnerChanged(_: ?*c.GDBusConnection, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, parameters: ?*c.GVariant, data: ?*anyopaque) callconv(.c) void {
        const self = cast(Service, data);
        const name_val = c.g_variant_get_child_value(parameters, 0);
        defer c.g_variant_unref(name_val);
        const owner_val = c.g_variant_get_child_value(parameters, 2);
        defer c.g_variant_unref(owner_val);
        const name = std.mem.span(c.g_variant_get_string(name_val, null));
        const new_owner = std.mem.span(c.g_variant_get_string(owner_val, null));
        if (new_owner.len == 0 and std.mem.startsWith(u8, name, ":")) self.removeScreenSaverSender(name);
    }
    fn screensaverCall(_: ?*c.GDBusConnection, sender: [*c]const u8, _: [*c]const u8, _: [*c]const u8, method_name: [*c]const u8, parameters: ?*c.GVariant, invocation: ?*c.GDBusMethodInvocation, data: ?*anyopaque) callconv(.c) void {
        const self = cast(Service, data);
        const caller = std.mem.span(sender);
        const method = std.mem.span(method_name);
        if (std.mem.eql(u8, method, "Inhibit")) {
            const cookie = self.addScreenSaverInhibitor(caller) catch {
                c.g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.DBus.Error.LimitsExceeded", "Too many idle inhibitors");
                return;
            };
            c.g_dbus_method_invocation_return_value(invocation, c.g_variant_new("(u)", cookie));
        } else if (std.mem.eql(u8, method, "UnInhibit")) {
            const cookie_val = c.g_variant_get_child_value(parameters, 0);
            defer c.g_variant_unref(cookie_val);
            self.removeScreenSaverInhibitor(caller, c.g_variant_get_uint32(cookie_val)) catch |err| {
                const err_name: [*:0]const u8 = if (err == error.AccessDenied) "org.freedesktop.DBus.Error.AccessDenied" else "org.freedesktop.DBus.Error.InvalidArgs";
                c.g_dbus_method_invocation_return_dbus_error(invocation, err_name, @errorName(err));
                return;
            };
            c.g_dbus_method_invocation_return_value(invocation, null);
        } else if (std.mem.eql(u8, method, "SimulateUserActivity")) {
            self.resetIdleTimer();
            c.g_dbus_method_invocation_return_value(invocation, null);
        } else {
            c.g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.DBus.Error.UnknownMethod", "Unknown method");
        }
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
const screensaver_vtable = c.GDBusInterfaceVTable{ .method_call = &Service.screensaverCall };

test "ScreenSaver inhibitors track senders and enforce ownership" {
    var service = Service{ .timeout_ms = 600_000, .executable = try a.dupeSentinel(u8, "/bin/false", 0), .session_inhibit = true, .cancel = c.g_cancellable_new() };
    defer {
        service.stopped = true;
        service.clearScreenSaverInhibitors();
        service.screensaver_inhibitors.deinit(a);
        c.g_object_unref(service.cancel);
        a.free(service.executable);
    }
    try std.testing.expect(!service.idleInhibited());
    const first = try service.addScreenSaverInhibitor(":1.10");
    const second = try service.addScreenSaverInhibitor(":1.11");
    try std.testing.expect(first != 0 and second != 0 and first != second);
    try std.testing.expect(service.idleInhibited());
    try std.testing.expectError(error.AccessDenied, service.removeScreenSaverInhibitor(":1.11", first));
    try std.testing.expectError(error.InvalidCookie, service.removeScreenSaverInhibitor(":1.10", 9999));
    try service.removeScreenSaverInhibitor(":1.10", first);
    try std.testing.expect(service.idleInhibited());
    service.removeScreenSaverSender(":1.11");
    try std.testing.expect(!service.idleInhibited());
    service.portal_inhibited = true;
    try std.testing.expect(service.idleInhibited());
    service.portal_inhibited = false;
    service.audio_inhibited = true;
    try std.testing.expect(service.idleInhibited());
    service.audio_inhibited = false;
    try std.testing.expect(!service.idleInhibited());
}
