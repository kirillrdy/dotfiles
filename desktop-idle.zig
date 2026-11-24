//! Native idle locking and logind suspend coordination. All callbacks run on the GLib context.
const std = @import("std");
const wl = @import("wayland-client");
const wire = @import("wayland-wire");
const mainloop = @import("desktop-loop.zig");
const util = @import("desktop-util.zig");
const libc = @import("desktop-libc.zig");
const dbus = @import("dbus");
const loop = @import("desktop-dbus-loop.zig");
const login_name = "org.freedesktop.login1";
const login_path = "/org/freedesktop/login1";
const login_interface = "org.freedesktop.login1.Manager";
const screensaver_name = "org.freedesktop.ScreenSaver";
const screensaver_paths = [_][]const u8{ "/org/freedesktop/ScreenSaver", "/ScreenSaver" };
const screensaver_xml =
    "<node><interface name=\"org.freedesktop.ScreenSaver\">" ++
    "<method name=\"Inhibit\"><arg type=\"s\" name=\"application_name\" direction=\"in\"/><arg type=\"s\" name=\"reason_for_inhibit\" direction=\"in\"/><arg type=\"u\" name=\"cookie\" direction=\"out\"/></method>" ++
    "<method name=\"UnInhibit\"><arg type=\"u\" name=\"cookie\" direction=\"in\"/></method>" ++
    "<method name=\"SimulateUserActivity\"/>" ++
    "</interface></node>";
const portal_name = "org.freedesktop.portal.Desktop";
const portal_path = "/org/dotfiles/Portal";
const portal_interface = "org.dotfiles.Portal";
const cast = util.cast;
const Process = @import("desktop-process.zig").Process;

pub const Options = struct {
    timeout_ms: u32 = 10 * 60 * 1000,
    // Explicit dependency injection for the standalone compositor fixture.
    lock_executable: ?[:0]const u8 = null,
    session_inhibit: bool = false,
    /// Shown blurred behind the lock screen, as GNOME does.
    wallpaper: ?[:0]const u8 = null,
};
const ScreenSaverInhibitor = struct {
    cookie: u32,
    sender: [:0]u8,
};
const Seat = struct {
    service: *Service,
    name: u32,
    proxy: wl.wl_seat,
    notification: ?wl.ext_idle_notification_v1 = null,
    idle: bool = false,
    next: ?*Seat = null,
    fn watch(self: *Seat) void {
        if (self.service.idleInhibited() or self.notification != null) return;
        const notifier = self.service.notifier orelse return;
        const notification = notifier.get_idle_notification(self.service.timeout_ms, self.proxy);
        self.notification = notification;
        notification.listen(Seat, self, idleEvent);
    }
    fn unwatch(self: *Seat) void {
        if (self.notification) |notification| notification.destroy();
        self.notification = null;
    }
    fn idleEvent(self: *Seat, _: wl.ext_idle_notification_v1, event: wl.ext_idle_notification_v1.Event) void {
        switch (event) {
            .idled => {
                self.idle = true;
                if (self.service.allIdle()) self.service.ensureLocked();
            },
            .resumed => self.idle = false,
        }
    }
    fn deinit(self: *Seat) void {
        self.unwatch();
        self.proxy.destroy();
        self.service.allocator.destroy(self);
    }
};

// An epoch prevents replies from a previous logind owner from changing current state.
const Call = struct {
    service: *Service,
    epoch: u64,
    sleep_serial: u64,
    portal_epoch: u64,
    /// The connection carrying the call and its serial, so a disconnect can cancel it.
    source: ?*loop.Source = null,
    serial: u32 = 0,
    fn create(self: *Service) *Call {
        const call = self.allocator.create(Call) catch @panic("out of memory");
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
        const service = self.service;
        service.allocator.destroy(self);
        service.unref();
    }
};

pub const Service = struct {
    allocator: std.mem.Allocator,
    timeout_ms: u32,
    executable: [:0]u8,
    wallpaper: ?[:0]u8 = null,
    session_inhibit: bool = false,
    refs: usize = 1,
    stopped: bool = false,
    timer: u32 = 0,
    connection: ?*wire.Connection = null,
    registry: ?wl.wl_registry = null,
    notifier: ?wl.ext_idle_notifier_v1 = null,
    notifier_name: u32 = 0,
    seats: ?*Seat = null,
    wayland_source: u32 = 0,
    bus: ?*loop.Source = null,
    login_watch: ?*dbus.NameWatcher = null,
    sleep_signal: u32 = 0,
    owner: ?[:0]u8 = null,
    epoch: u64 = 0,
    sleep_serial: u64 = 0,
    sleeping: bool = false,
    inhibitor: c_int = -1,
    inhibit_pending: bool = false,
    session_bus: ?*loop.Source = null,
    /// Calls awaiting replies; each holds a reference on the service.
    calls: std.ArrayList(*Call) = .empty,
    screensaver_introspection: ?dbus.Introspection = null,
    screensaver_regs: [screensaver_paths.len]u32 = @splat(0),
    name_signal: u32 = 0,
    portal_watch: ?*dbus.NameWatcher = null,
    portal_signal: u32 = 0,
    portal_owner: ?[:0]u8 = null,
    portal_epoch: u64 = 0,
    screensaver_inhibitors: std.ArrayList(ScreenSaverInhibitor) = .empty,
    screensaver_serial: u32 = 0,
    portal_inhibited: bool = false,
    audio_inhibited: bool = false,
    last_inhibited: bool = false,
    cancel: *mainloop.Cancellable,
    process: ?*Process = null,
    ready_fd: c_int = -1,
    ready_source: u32 = 0,
    lock_ready: bool = false,

    pub fn create(a: std.mem.Allocator, options: Options) !*Service {
        const path = if (options.lock_executable) |path| try a.dupeSentinel(u8, path, 0) else blk: {
            break :blk @import("desktop-paths.zig").readLink(a, "/proc/self/exe") catch return error.ExecutablePathUnavailable;
        };
        errdefer a.free(path);
        const wallpaper = if (options.wallpaper) |value| try a.dupeSentinel(u8, value, 0) else null;
        errdefer if (wallpaper) |value| a.free(value);
        const self = try a.create(Service);
        self.* = .{ .allocator = a, .timeout_ms = options.timeout_ms, .executable = path, .wallpaper = wallpaper, .session_inhibit = options.session_inhibit, .cancel = mainloop.Cancellable.create() };
        self.connectWayland();
        self.connectBus();
        self.connectSessionBus();
        self.timer = mainloop.timeoutSeconds(5, self, maintain);
        return self;
    }
    pub fn destroy(self: *Service) void {
        self.stopped = true;
        if (self.timer != 0) _ = mainloop.remove(self.timer);
        self.disconnectWayland();
        self.disconnectBus();
        self.disconnectSessionBus();
        self.closeReady();
        // A running locker continues independently when the shell exits.
        self.cancel.cancel();
        if (self.process) |child| child.cancel();
        self.unref();
    }
    fn unref(self: *Service) void {
        self.refs -= 1;
        if (self.refs == 0) {
            self.cancel.unref();
            self.screensaver_inhibitors.deinit(self.allocator);
            self.calls.deinit(self.allocator);
            self.allocator.free(self.executable);
            if (self.wallpaper) |value| self.allocator.free(value);
            self.allocator.destroy(self);
        }
    }
    fn maintain(self: *Service) bool {
        if (self.connection == null) self.connectWayland();
        if (self.bus) |bus| if (bus.connection.closed) self.disconnectBus();
        if (self.bus == null) self.connectBus();
        if (self.session_inhibit) {
            if (self.session_bus) |bus| if (bus.connection.closed) self.disconnectSessionBus();
            if (self.session_bus == null) self.connectSessionBus();
        }
        self.acquire();
        if (self.sleeping or self.allIdle()) self.ensureLocked();
        return true;
    }
    pub fn setAudioInhibited(self: *Service, active: bool) void {
        if (self.stopped or self.audio_inhibited == active) return;
        self.audio_inhibited = active;
        self.syncInhibition();
    }
    pub fn idleInhibited(self: *const Service) bool {
        return self.portal_inhibited or self.audio_inhibited or self.screensaver_inhibitors.items.len > 0;
    }
    fn flushWayland(self: *Service) void {
        const connection = self.connection orelse return;
        connection.flush() catch self.disconnectWayland();
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
                s.unwatch();
            }
        } else {
            while (seat) |s| : (seat = s.next) s.watch();
        }
        self.flushWayland();
    }
    fn resetIdleTimer(self: *Service) void {
        if (self.stopped or self.idleInhibited()) return;
        var seat = self.seats;
        while (seat) |s| : (seat = s.next) {
            s.idle = false;
            s.unwatch();
            s.watch();
        }
        self.flushWayland();
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
        const connection = wire.Connection.connect(self.allocator) catch {
            std.log.warn("idle: Wayland connection unavailable; will retry", .{});
            return;
        };
        self.connection = connection;
        const display: wl.wl_display = .{ .proxy = connection.display() };
        const registry = display.get_registry();
        self.registry = registry;
        registry.listen(Service, self, registryEvent);
        // The second round trip delivers the seats' initial idle state.
        connection.roundtrip() catch return self.disconnectWayland();
        connection.roundtrip() catch return self.disconnectWayland();
        if (self.notifier == null) std.log.warn("idle: ext-idle-notify unavailable", .{});
        self.wayland_source = mainloop.watch(connection.getFd(), mainloop.IN | mainloop.ERR | mainloop.HUP, self, dispatch);
        self.flushWayland();
    }
    fn disconnectWayland(self: *Service) void {
        if (self.wayland_source != 0) _ = mainloop.remove(self.wayland_source);
        self.wayland_source = 0;
        while (self.seats) |seat| {
            self.seats = seat.next;
            seat.deinit();
        }
        if (self.notifier) |notifier| notifier.destroy();
        self.notifier = null;
        if (self.registry) |registry| registry.destroy();
        self.registry = null;
        if (self.connection) |connection| connection.deinit();
        self.connection = null;
    }
    fn registryEvent(self: *Service, registry: wl.wl_registry, event: wl.wl_registry.Event) void {
        switch (event) {
            .global => |value| self.global(registry, value.name, value.interface),
            .global_remove => |value| self.globalRemove(value.name),
        }
    }
    fn global(self: *Service, registry: wl.wl_registry, name: u32, kind: []const u8) void {
        if (std.mem.eql(u8, kind, "ext_idle_notifier_v1")) {
            self.notifier = registry.bind(name, wl.ext_idle_notifier_v1, 1);
            self.notifier_name = name;
            var seat = self.seats;
            while (seat) |s| : (seat = s.next) s.watch();
        } else if (std.mem.eql(u8, kind, "wl_seat")) {
            const seat = self.allocator.create(Seat) catch @panic("out of memory");
            seat.* = .{ .service = self, .name = name, .proxy = registry.bind(name, wl.wl_seat, 1), .next = self.seats };
            self.seats = seat;
            seat.watch();
        }
    }
    fn globalRemove(self: *Service, name: u32) void {
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
                s.unwatch();
                s.idle = false;
            }
            self.notifier.?.destroy();
            self.notifier = null;
        }
        if (self.allIdle()) self.ensureLocked();
    }
    fn dispatch(self: *Service, _: c_int, flags: u32) bool {
        const ok = flags & (mainloop.HUP | mainloop.ERR) == 0 and if (self.connection) |connection| if (connection.readAndDispatch()) |_| true else |_| false else false;
        if (!ok) {
            self.wayland_source = 0;
            self.disconnectWayland();
            return false;
        }
        return true;
    }
    /// Sends a call that holds a reference on the service until it is answered or cancelled.
    fn send(self: *Service, source: *loop.Source, target: dbus.Connection.Call, args: anytype, handler: dbus.ReplyHandler) bool {
        const call = Call.create(self);
        call.source = source;
        self.calls.ensureUnusedCapacity(self.allocator, 1) catch {
            call.deinit();
            return false;
        };
        call.serial = source.connection.call(target, args, 3000, handler, call) catch {
            call.deinit();
            return false;
        };
        self.calls.appendAssumeCapacity(call);
        return true;
    }
    /// Forgets an answered call; the caller still owns it and must deinit it.
    fn answered(call: *Call) void {
        const calls = &call.service.calls;
        for (calls.items, 0..) |item, i| if (item == call) {
            _ = calls.swapRemove(i);
            break;
        };
    }
    fn cancelCalls(self: *Service, source: *loop.Source) void {
        var i: usize = 0;
        while (i < self.calls.items.len) {
            const call = self.calls.items[i];
            if (call.source != source) {
                i += 1;
                continue;
            }
            _ = self.calls.swapRemove(i);
            source.connection.cancel(call.serial);
            call.deinit();
        }
    }
    fn connectBus(self: *Service) void {
        if (self.stopped) return;
        const source = loop.acquire(self.allocator, .system) catch {
            std.log.warn("idle: system bus unavailable; will retry", .{});
            return;
        };
        self.bus = source;
        self.login_watch = dbus.NameWatcher.create(source.connection, login_name, &appeared, &vanished, self) catch {
            self.disconnectBus();
            return;
        };
    }
    fn resetOwner(self: *Service) void {
        self.epoch +%= 1;
        self.release();
        self.inhibit_pending = false;
        self.sleeping = false;
        if (self.sleep_signal != 0) if (self.bus) |bus| bus.connection.unsubscribe(self.sleep_signal);
        self.sleep_signal = 0;
        if (self.owner) |owner| self.allocator.free(owner);
        self.owner = null;
    }
    fn disconnectBus(self: *Service) void {
        if (self.login_watch) |watch| watch.destroy();
        self.login_watch = null;
        self.resetOwner();
        if (self.bus) |bus| {
            self.cancelCalls(bus);
            loop.release(bus);
        }
        self.bus = null;
    }
    fn appeared(data: ?*anyopaque, owner: []const u8) void {
        const self = cast(Service, data);
        self.resetOwner();
        self.owner = self.allocator.dupeSentinel(u8, owner, 0) catch @panic("out of memory");
        const connection = self.bus.?.connection;
        self.sleep_signal = connection.subscribe(self.owner.?, login_interface, "PrepareForSleep", login_path, &prepare, self) catch 0;
        self.acquire();
        _ = self.send(self.bus.?, .{ .destination = self.owner.?, .path = login_path, .interface = "org.freedesktop.DBus.Properties", .member = "Get" }, .{ login_interface, "PreparingForSleep" }, &preparingRead);
    }
    fn vanished(data: ?*anyopaque) void {
        cast(Service, data).resetOwner();
    }
    fn acquire(self: *Service) void {
        if (self.stopped or self.owner == null or self.inhibitor >= 0 or self.inhibit_pending or self.sleeping) return;
        self.inhibit_pending = self.send(self.bus.?, .{ .destination = self.owner.?, .path = login_path, .interface = login_interface, .member = "Inhibit" }, .{ "sleep", "desktop-zig", "Lock the session before sleep", "delay" }, &inhibited);
    }
    fn inhibited(data: ?*anyopaque, reply: dbus.Reply) void {
        const call = cast(Call, data);
        Service.answered(call);
        defer call.deinit();
        const self = call.service;
        const message = switch (reply) {
            .ok => |message| message,
            .failed => {
                if (call.current()) {
                    self.inhibit_pending = false;
                    std.log.warn("idle: sleep delay inhibitor unavailable; will retry", .{});
                }
                return;
            },
        };
        if (!call.current()) return;
        self.inhibit_pending = false;
        // The reply owns its descriptor; keep a duplicate.
        if (message.read(struct { dbus.Fd })) |args| {
            self.inhibitor = std.c.fcntl(args[0].value, std.c.F.DUPFD_CLOEXEC, @as(c_int, 0));
        } else |_| {}
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
    fn preparingRead(data: ?*anyopaque, reply: dbus.Reply) void {
        const call = cast(Call, data);
        Service.answered(call);
        defer call.deinit();
        const message = switch (reply) {
            .ok => |message| message,
            .failed => return,
        };
        if (!call.current() or call.sleep_serial != call.service.sleep_serial) return;
        const value = (message.read(struct { dbus.Value }) catch return)[0];
        switch (value) {
            .boolean => |sleeping| call.service.setPreparing(sleeping),
            else => {},
        }
    }
    fn connectSessionBus(self: *Service) void {
        if (!self.session_inhibit or self.stopped) return;
        const source = loop.acquire(self.allocator, .session) catch {
            std.log.warn("idle: session bus unavailable; will retry", .{});
            return;
        };
        self.session_bus = source;
        const connection = source.connection;
        self.screensaver_introspection = dbus.Introspection.parse(self.allocator, screensaver_xml) catch @panic("invalid ScreenSaver XML");
        for (screensaver_paths, 0..) |object_path, i| {
            self.screensaver_regs[i] = connection.exportObject(object_path, &self.screensaver_introspection.?.interfaces[0], &screensaverCall, null, self) catch 0;
            if (self.screensaver_regs[i] == 0) std.log.warn("idle: failed to register ScreenSaver at {s}", .{object_path});
        }
        // Like g_bus_own_name without flags: queue behind any current owner.
        connection.send(.{ .destination = "org.freedesktop.DBus", .path = "/org/freedesktop/DBus", .interface = "org.freedesktop.DBus", .member = "RequestName" }, .{ screensaver_name, @as(u32, 0) }) catch {};
        self.name_signal = connection.subscribe("org.freedesktop.DBus", "org.freedesktop.DBus", "NameOwnerChanged", "/org/freedesktop/DBus", &sessionOwnerChanged, self) catch 0;
        self.portal_watch = dbus.NameWatcher.create(connection, portal_name, &portalAppeared, &portalVanished, self) catch null;
    }
    fn disconnectSessionBus(self: *Service) void {
        if (self.portal_watch) |watch| watch.destroy();
        self.portal_watch = null;
        self.resetPortal();
        const source = self.session_bus orelse {
            self.clearScreenSaverInhibitors();
            return;
        };
        const connection = source.connection;
        if (self.name_signal != 0) connection.unsubscribe(self.name_signal);
        self.name_signal = 0;
        connection.send(.{ .destination = "org.freedesktop.DBus", .path = "/org/freedesktop/DBus", .interface = "org.freedesktop.DBus", .member = "ReleaseName" }, .{screensaver_name}) catch {};
        for (&self.screensaver_regs) |*reg| {
            if (reg.* != 0) connection.unregister(reg.*);
            reg.* = 0;
        }
        if (self.screensaver_introspection) |*introspection| introspection.deinit();
        self.screensaver_introspection = null;
        self.clearScreenSaverInhibitors();
        self.cancelCalls(source);
        loop.release(source);
        self.session_bus = null;
    }
    fn resetPortal(self: *Service) void {
        self.portal_epoch +%= 1;
        if (self.portal_signal != 0) if (self.session_bus) |bus| bus.connection.unsubscribe(self.portal_signal);
        self.portal_signal = 0;
        if (self.portal_owner) |owner| self.allocator.free(owner);
        self.portal_owner = null;
        self.portal_inhibited = false;
        self.syncInhibition();
    }
    fn portalAppeared(data: ?*anyopaque, owner: []const u8) void {
        const self = cast(Service, data);
        self.resetPortal();
        self.portal_owner = self.allocator.dupeSentinel(u8, owner, 0) catch @panic("out of memory");
        const source = self.session_bus.?;
        self.portal_signal = source.connection.subscribe(self.portal_owner.?, portal_interface, "IdleInhibitedChanged", portal_path, &portalChanged, self) catch 0;
        _ = self.send(source, .{ .destination = self.portal_owner.?, .path = portal_path, .interface = portal_interface, .member = "IdleInhibited" }, .{}, &portalRead);
    }
    fn portalVanished(data: ?*anyopaque) void {
        cast(Service, data).resetPortal();
    }
    fn portalRead(data: ?*anyopaque, reply: dbus.Reply) void {
        const call = cast(Call, data);
        Service.answered(call);
        defer call.deinit();
        const message = switch (reply) {
            .ok => |message| message,
            .failed => return,
        };
        if (!call.currentPortal()) return;
        call.service.portal_inhibited = (message.read(struct { bool }) catch return)[0];
        call.service.syncInhibition();
    }
    fn portalChanged(data: ?*anyopaque, message: *const dbus.Message) void {
        const self = cast(Service, data);
        if (self.portal_owner == null or !std.mem.eql(u8, message.sender orelse "", self.portal_owner.?)) return;
        self.portal_inhibited = (message.read(struct { bool }) catch return)[0];
        self.syncInhibition();
    }
    fn clearScreenSaverInhibitors(self: *Service) void {
        for (self.screensaver_inhibitors.items) |item| self.allocator.free(item.sender);
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
        const owned_sender = try self.allocator.dupeSentinel(u8, sender, 0);
        errdefer self.allocator.free(owned_sender);
        try self.screensaver_inhibitors.append(self.allocator, .{ .cookie = cookie, .sender = owned_sender });
        self.syncInhibition();
        return cookie;
    }
    fn removeScreenSaverInhibitor(self: *Service, sender: []const u8, cookie: u32) !void {
        for (self.screensaver_inhibitors.items, 0..) |item, i| if (item.cookie == cookie) {
            if (!std.mem.eql(u8, item.sender, sender)) return error.AccessDenied;
            self.allocator.free(item.sender);
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
                self.allocator.free(self.screensaver_inhibitors.items[i].sender);
                _ = self.screensaver_inhibitors.swapRemove(i);
                changed = true;
            } else i += 1;
        }
        if (changed) self.syncInhibition();
    }
    fn sessionOwnerChanged(data: ?*anyopaque, message: *const dbus.Message) void {
        const self = cast(Service, data);
        const args = message.read(struct { []const u8, []const u8, []const u8 }) catch return;
        if (args[2].len == 0 and std.mem.startsWith(u8, args[0], ":")) self.removeScreenSaverSender(args[0]);
    }
    fn screensaverCall(data: ?*anyopaque, message: *const dbus.Message) void {
        const self = cast(Service, data);
        const connection = self.session_bus.?.connection;
        const caller = message.sender orelse "";
        const method = message.member orelse "";
        if (std.mem.eql(u8, method, "Inhibit")) {
            const cookie = self.addScreenSaverInhibitor(caller) catch return connection.replyError(message, "org.freedesktop.DBus.Error.LimitsExceeded", "Too many idle inhibitors") catch {};
            connection.reply(message, .{cookie}) catch {};
        } else if (std.mem.eql(u8, method, "UnInhibit")) {
            const cookie = (message.read(struct { u32 }) catch return)[0];
            self.removeScreenSaverInhibitor(caller, cookie) catch |err| {
                const err_name = if (err == error.AccessDenied) "org.freedesktop.DBus.Error.AccessDenied" else "org.freedesktop.DBus.Error.InvalidArgs";
                return connection.replyError(message, err_name, @errorName(err)) catch {};
            };
            connection.reply(message, .{}) catch {};
        } else if (std.mem.eql(u8, method, "SimulateUserActivity")) {
            self.resetIdleTimer();
            connection.reply(message, .{}) catch {};
        } else {
            connection.replyError(message, "org.freedesktop.DBus.Error.UnknownMethod", "Unknown method") catch {};
        }
    }
    fn prepare(data: ?*anyopaque, message: *const dbus.Message) void {
        const self = cast(Service, data);
        self.sleep_serial +%= 1;
        self.setPreparing((message.read(struct { bool }) catch return)[0]);
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
        const with_wallpaper = [_][:0]const u8{ self.executable, "lock", "--ready-fd", "3", "--wallpaper", self.wallpaper orelse "" };
        const argv = if (self.wallpaper != null) with_wallpaper[0..] else with_wallpaper[0..4];
        // The child receives the pipe's write end as descriptor 3.
        const spawned = Process.spawn(self.allocator, argv, .{ .fds = &.{.{ .source = fds[1], .target = 3 }} }, &exited, self);
        _ = libc.close(fds[1]);
        self.process = spawned catch {
            _ = libc.close(fds[0]);
            std.log.warn("idle: could not start lock client; retaining sleep inhibitor", .{});
            return;
        };
        self.lock_ready = false;
        self.ready_fd = fds[0];
        self.ready_source = mainloop.watch(self.ready_fd, mainloop.IN | mainloop.HUP | mainloop.ERR, self, ready);
        self.refs += 1;
    }
    fn closeReady(self: *Service) void {
        if (self.ready_source != 0) _ = mainloop.remove(self.ready_source);
        self.ready_source = 0;
        if (self.ready_fd >= 0) _ = libc.close(self.ready_fd);
        self.ready_fd = -1;
        self.lock_ready = false;
    }
    fn refreshReady(self: *Service) void {
        if (self.ready_fd >= 0) _ = ready(self, self.ready_fd, 0);
    }
    fn ready(self: *Service, _: c_int, _: u32) bool {
        var byte: u8 = 0;
        const count = libc.read(self.ready_fd, &byte, 1);
        if (count < 0 and (libc.__errno_location().* == 11 or libc.__errno_location().* == 4)) return true;
        if (count == 1 and byte == '1') {
            self.lock_ready = true;
            if (self.sleeping) self.release();
            return true;
        }
        const was_ready = self.lock_ready;
        self.closeReady();
        if (!was_ready) std.log.warn("idle: lock readiness failed; retaining sleep inhibitor", .{});
        return false;
    }
    fn exited(data: ?*anyopaque, result: *const @import("desktop-process.zig").Result) void {
        const self = cast(Service, data);
        defer self.unref();
        const waited = !result.cancelled;
        const successful = result.successful();
        if (!self.stopped and waited and !successful) std.log.warn("idle: lock client failed; retaining sleep inhibitor", .{});
        self.closeReady();
        self.lock_ready = false;
        self.process = null;
        if (!self.stopped and self.sleeping and successful) self.ensureLocked();
    }
};

test "ScreenSaver inhibitors track senders and enforce ownership" {
    const a = std.testing.allocator;
    var service = Service{ .allocator = a, .timeout_ms = 600_000, .executable = try a.dupeSentinel(u8, "/bin/false", 0), .session_inhibit = true, .cancel = mainloop.Cancellable.create() };
    defer {
        service.stopped = true;
        service.clearScreenSaverInhibitors();
        service.screensaver_inhibitors.deinit(a);
        service.cancel.unref();
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
