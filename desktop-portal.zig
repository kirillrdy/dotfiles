//! Native portal broker, dialogs and capture for host desktop applications.
const std = @import("std");
const c = @import("desktop-glib.zig");
const libc = @import("desktop-libc.zig");
const dbus = @import("dbus");
const loop = @import("desktop-dbus-loop.zig");
const bridge = @import("desktop-dbus-gvariant.zig");
var a: std.mem.Allocator = std.heap.page_allocator;
const path = "/org/freedesktop/portal/desktop";
const public = "org.freedesktop.portal.";
const Account = @import("desktop-portal-account.zig").Dialog;
const FileChooser = @import("desktop-portal-file-chooser.zig").Dialog;
const Notifications = @import("desktop-portal-notification.zig").Service;
const Settings = @import("desktop-portal-settings.zig").Service;
const Email = @import("desktop-portal-email.zig");
const Capture = @import("desktop-portal-capture.zig");
const Video = @import("desktop-portal-screencast.zig");
const bus = "org.freedesktop.DBus";
const bus_path = "/org/freedesktop/DBus";
const idle_portal_path = "/org/dotfiles/Portal";
const idle_portal_interface = "org.dotfiles.Portal";
const idle_portal_xml =
    "<node><interface name=\"org.dotfiles.Portal\">" ++
    "<method name=\"IdleInhibited\"><arg type=\"b\" name=\"inhibited\" direction=\"out\"/></method>" ++
    "<signal name=\"IdleInhibitedChanged\"><arg type=\"b\" name=\"inhibited\"/></signal>" ++
    "</interface></node>";
const cast = c.__zig.cast;
const eq = c.__zig.eq;
const text = c.__zig.variant.text;
fn string(value: [*:0]const u8) ?*c.GVariant {
    return c.g_variant_new("s", value);
}
fn object(value: [*:0]const u8) ?*c.GVariant {
    return c.g_variant_new("o", value);
}
// Consume owned or floating children, returning a floating tuple.
fn tuple(values: []const ?*c.GVariant) ?*c.GVariant {
    for (values) |value| _ = c.g_variant_take_ref(value);
    const result = c.g_variant_new_tuple(@constCast(values.ptr), values.len);
    for (values) |value| c.g_variant_unref(value);
    return result;
}
const dict = c.__zig.variant.emptyDict;
const child = c.g_variant_get_child_value;
fn errorReply(connection: *dbus.Connection, message: *const dbus.Message, text_value: []const u8) void {
    connection.replyError(message, "org.freedesktop.portal.Error.Failed", text_value) catch {};
}
fn validToken(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    for (value) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    return true;
}
const Client = struct {
    arena: std.heap.ArenaAllocator,
    sender: [:0]const u8,
    component: [:0]const u8,
    app: [:0]const u8,
    registered: bool = false,
    fn destroy(self: *Client) void {
        self.arena.deinit();
        a.destroy(self);
    }
};
const State = enum { creating, created, selecting, selected, starting, started };
const Session = struct {
    server: *Server,
    arena: std.heap.ArenaAllocator,
    owner: [:0]const u8,
    handle: [:0]const u8,
    registration: u32 = 0,
    state: State = .creating,
    cursor: bool = false,
    stream: ?*Video.Stream = null,
    pending: ?*Request = null,
    width: i32 = 0,
    height: i32 = 0,
    fn destroy(self: *Session) void {
        if (self.stream) |stream| stream.destroy();
        self.server.connection.unregister(self.registration);
        self.arena.deinit();
        a.destroy(self);
    }
};
const Server = struct {
    connection: *dbus.Connection,
    introspection: dbus.Introspection,
    idle_introspection: ?dbus.Introspection = null,
    registrations: std.ArrayList(u32) = .empty,
    subscriptions: std.ArrayList(u32) = .empty,
    clients: std.ArrayList(*Client) = .empty,
    requests: std.ArrayList(*Request) = .empty,
    sessions: std.ArrayList(*Session) = .empty,
    settings: ?*Settings = null,
    notifications: ?*Notifications = null,
    idle_inhibited: bool = false,
    serial: u64 = 0,
    quitting: bool = false,

    fn info(self: *Server, name: []const u8) *const dbus.InterfaceInfo {
        return self.introspection.find(name).?;
    }
    fn start(self: *Server) !void {
        for (self.introspection.interfaces) |*item| {
            if (eq(item.name, public ++ "Request") or eq(item.name, public ++ "Session")) continue;
            try self.registrations.append(a, try self.connection.exportObject(path, item, &methodCall, &getProperty, self));
        }
        self.idle_introspection = try dbus.Introspection.parse(a, idle_portal_xml);
        try self.registrations.append(a, try self.connection.exportObject(idle_portal_path, &self.idle_introspection.?.interfaces[0], &idlePortalCall, null, self));
        try self.subscriptions.append(a, try self.connection.subscribe(bus, bus, "NameOwnerChanged", bus_path, &ownerChanged, self));
        self.settings = try Settings.create(a, self.connection);
        self.notifications = try Notifications.create(a, self.connection);
        if (c.g_network_monitor_get_default()) |monitor| _ = c.g_signal_connect_data(monitor, "network-changed", @ptrCast(&networkChanged), self, null, 0);
    }
    fn deinit(self: *Server) void {
        self.quitting = true;
        if (self.settings) |settings| settings.destroy();
        if (self.notifications) |notifications| notifications.destroy();
        if (c.g_network_monitor_get_default()) |monitor| _ = c.g_signal_handlers_disconnect_matched(monitor, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
        for (self.subscriptions.items) |id| self.connection.unsubscribe(id);
        self.cancelRequests(null);
        while (self.requests.items.len > 0) _ = c.g_main_context_iteration(null, 1);
        while (self.sessions.items.len > 0) self.closeSession(self.sessions.items[0]);
        for (self.registrations.items) |id| self.connection.unregister(id);
        if (self.idle_introspection) |*idle| idle.deinit();
        for (self.clients.items) |client| client.destroy();
        self.registrations.deinit(a);
        self.subscriptions.deinit(a);
        self.requests.deinit(a);
        self.sessions.deinit(a);
        self.clients.deinit(a);
    }
    fn cancelRequests(self: *Server, owner: ?[]const u8) void {
        var index: usize = 0;
        while (index < self.requests.items.len) {
            const request = self.requests.items[index];
            if (owner == null or eq(request.owner, owner.?)) request.close();
            if (index < self.requests.items.len and self.requests.items[index] == request) index += 1;
        }
    }
    fn getClient(self: *Server, sender: []const u8) !*Client {
        for (self.clients.items) |item| if (eq(item.sender, sender)) return item;
        if (self.clients.items.len >= 128) return error.TooManyClients;
        const reply = self.connection.callBlocking(.{ .destination = bus, .path = bus_path, .interface = bus, .member = "GetConnectionUnixProcessID" }, .{sender}, 1000) catch return error.UnknownClient;
        defer reply.deinit();
        const pid = (reply.message().read(struct { u32 }) catch return error.UnknownClient)[0];
        var buffer: [128]u8 = undefined;
        const flatpak = try std.fmt.bufPrintSentinel(&buffer, "/proc/{d}/root/.flatpak-info", .{pid}, 0);
        const fd = libc.open(flatpak, libc.O_RDONLY);
        if (fd >= 0) {
            _ = libc.close(fd);
            return error.SandboxedClientUnsupported;
        }
        if (libc.__errno_location().* != libc.ENOENT) return error.CannotIdentifyClient;
        const environ = try std.fmt.bufPrintSentinel(&buffer, "/proc/{d}/environ", .{pid}, 0);
        var contents: [*c]u8 = null;
        var size: usize = 0;
        if (c.g_file_get_contents(environ, &contents, &size, null) == 0) return error.CannotIdentifyClient;
        defer c.g_free(contents);
        var entries = std.mem.splitScalar(u8, contents[0..size], 0);
        while (entries.next()) |entry| if (std.mem.startsWith(u8, entry, "SNAP=")) return error.SandboxedClientUnsupported;
        const item = try a.create(Client);
        errdefer a.destroy(item);
        item.registered = false;
        item.arena = std.heap.ArenaAllocator.init(a);
        errdefer item.arena.deinit();
        const alloc = item.arena.allocator();
        item.sender = try alloc.dupeSentinel(u8, sender, 0);
        item.component = try alloc.dupeSentinel(u8, std.mem.trimStart(u8, item.sender, ":"), 0);
        for (@constCast(item.component)) |*ch| if (ch.* == '.') {
            ch.* = '_';
        };
        item.app = try std.fmt.allocPrintSentinel(alloc, "org.dotfiles.portal.client{s}", .{item.component}, 0);
        try self.clients.append(a, item);
        return item;
    }
    fn session(self: *Server, handle: []const u8, sender: []const u8) ?*Session {
        for (self.sessions.items) |item| if (eq(item.handle, handle) and eq(item.owner, sender)) return item;
        return null;
    }
    fn closeSession(self: *Server, item: *Session) void {
        if (item.pending) |request| {
            item.pending = null;
            request.session_handle = null;
            request.close();
        }
        self.connection.emitTo(item.owner, item.handle, public ++ "Session", "Closed", .{bridge.Dict{ .entries = &.{} }}) catch {};
        for (self.sessions.items, 0..) |current, i| if (current == item) {
            _ = self.sessions.swapRemove(i);
            break;
        };
        item.destroy();
        self.updateIdleInhibition();
    }
    fn hasIdleInhibitor(self: *const Server) bool {
        for (self.requests.items) |item| if (!item.closed and item.kind == .inhibit and item.inhibit_idle) return true;
        for (self.sessions.items) |item| if (item.state == .started) return true;
        return false;
    }
    fn updateIdleInhibition(self: *Server) void {
        if (self.quitting) return;
        const next = self.hasIdleInhibitor();
        if (next == self.idle_inhibited) return;
        self.idle_inhibited = next;
        self.connection.emit(idle_portal_path, idle_portal_interface, "IdleInhibitedChanged", .{next}) catch {};
    }
    fn createSession(self: *Server, client_info: *Client, options: ?*c.GVariant) !*Session {
        if (self.sessions.items.len >= 64) return error.TooManySessions;
        const token = c.g_variant_lookup_value(options, "session_handle_token", null);
        defer if (token != null) c.g_variant_unref(token);
        self.serial +%= 1;
        var buffer: [64]u8 = undefined;
        const suffix = if (token) |value| blk: {
            if (!eq(std.mem.span(c.g_variant_get_type_string(value)), "s") or !validToken(text(value))) return error.InvalidSessionToken;
            break :blk text(value);
        } else try std.fmt.bufPrint(&buffer, "session{d}", .{self.serial});
        const item = try a.create(Session);
        errdefer a.destroy(item);
        item.* = .{ .server = self, .arena = std.heap.ArenaAllocator.init(a), .owner = undefined, .handle = undefined };
        errdefer item.arena.deinit();
        const alloc = item.arena.allocator();
        item.owner = try alloc.dupeSentinel(u8, client_info.sender, 0);
        item.handle = try std.fmt.allocPrintSentinel(alloc, "/org/freedesktop/portal/desktop/session/{s}/{s}", .{ client_info.component, suffix }, 0);
        if (self.session(item.handle, item.owner) != null) return error.DuplicateSession;
        item.registration = self.connection.exportObject(item.handle, self.info(public ++ "Session"), &closeSessionCall, null, item) catch 0;
        if (item.registration == 0) return error.SessionRegistrationFailed;
        errdefer self.connection.unregister(item.registration);
        try self.sessions.append(a, item);
        return item;
    }
    fn ownerChanged(data: ?*anyopaque, message: *const dbus.Message) void {
        const self = cast(Server, data);
        const args = message.read(struct { []const u8, []const u8, []const u8 }) catch return;
        const name = args[0];
        if (args[2].len != 0) return;
        if (!std.mem.startsWith(u8, name, ":")) return;
        self.cancelRequests(name);
        var i: usize = 0;
        while (i < self.sessions.items.len) {
            const item = self.sessions.items[i];
            if (eq(item.owner, name)) self.closeSession(item) else i += 1;
        }
        for (self.clients.items, 0..) |client_info, index| if (eq(client_info.sender, name)) {
            _ = self.clients.swapRemove(index);
            client_info.destroy();
            break;
        };
    }
    fn networkChanged(_: ?*c.GNetworkMonitor, _: c.gboolean, data: ?*anyopaque) callconv(.c) void {
        const self = cast(Server, data);
        self.connection.emit(path, public ++ "NetworkMonitor", "changed", .{}) catch {};
    }
};
const Kind = enum { direct, uri, inhibit, dialog };
const Request = struct {
    server: *Server,
    arena: std.heap.ArenaAllocator,
    owner: [:0]const u8,
    app: [:0]const u8,
    handle: [:0]const u8,
    interface: [:0]const u8,
    method: [:0]const u8,
    session_handle: ?[:0]const u8 = null,
    cancel: *c.GCancellable,
    registration: u32 = 0,
    kind: Kind,
    /// A held NetworkMonitor.CanReach call, answered when the probe finishes.
    invocation: ?dbus.Invocation = null,
    closed: bool = false,
    inhibit_idle: bool = false,
    inhibitor_fd: c_int = -1,
    dialog: ?*FileChooser = null,
    account: ?*Account = null,
    screenshot: ?*Capture.Operation = null,
    picker: ?*Capture.Picker = null,
    idle: c.guint = 0,

    fn create(server: *Server, client_info: *Client, interface: []const u8, method: []const u8, options: ?*c.GVariant, kind: Kind) !*Request {
        if (server.requests.items.len >= 128) return error.TooManyRequests;
        var count: usize = 0;
        for (server.requests.items) |item| if (eq(item.owner, client_info.sender)) {
            count += 1;
        };
        if (count >= 32) return error.TooManyClientRequests;
        const item = try a.create(Request);
        errdefer a.destroy(item);
        item.* = .{ .server = server, .arena = std.heap.ArenaAllocator.init(a), .owner = undefined, .app = undefined, .handle = undefined, .interface = undefined, .method = undefined, .cancel = c.g_cancellable_new().?, .kind = kind };
        errdefer {
            item.arena.deinit();
            c.g_object_unref(item.cancel);
        }
        const alloc = item.arena.allocator();
        item.owner = try alloc.dupeSentinel(u8, client_info.sender, 0);
        item.app = try alloc.dupeSentinel(u8, client_info.app, 0);
        item.interface = try alloc.dupeSentinel(u8, interface, 0);
        item.method = try alloc.dupeSentinel(u8, method, 0);
        const token = if (kind != .direct) c.g_variant_lookup_value(options, "handle_token", null) else null;
        defer if (token != null) c.g_variant_unref(token);
        if (token) |value| if (!eq(std.mem.span(c.g_variant_get_type_string(value)), "s")) return error.InvalidHandleToken;
        server.serial +%= 1;
        const suffix = if (token) |value| text(value) else try std.fmt.allocPrint(alloc, "request{d}", .{server.serial});
        if (!validToken(suffix)) return error.InvalidHandleToken;
        item.handle = try std.fmt.allocPrintSentinel(alloc, "/org/freedesktop/portal/desktop/request/{s}/{s}", .{ client_info.component, suffix }, 0);
        for (server.requests.items) |existing| if (eq(existing.handle, item.handle)) return error.DuplicateHandle;
        if (kind != .direct) {
            item.registration = server.connection.exportObject(item.handle, server.info(public ++ "Request"), &closeRequest, null, item) catch 0;
            if (item.registration == 0) return error.RequestRegistrationFailed;
        }
        errdefer if (item.registration != 0) {
            server.connection.unregister(item.registration);
        };
        try server.requests.append(a, item);
        return item;
    }
    fn close(self: *Request) void {
        if (self.closed) return;
        self.closed = true;
        if (self.registration != 0) {
            self.server.connection.unregister(self.registration);
            self.registration = 0;
        }
        c.g_cancellable_cancel(self.cancel);
        if (self.session_handle) |handle| if (self.server.session(handle, self.owner)) |session_info| {
            session_info.pending = null;
            self.server.closeSession(session_info);
        };
        if (self.kind == .dialog) {
            self.destroy();
            return;
        }
        if (self.kind == .inhibit) {
            self.inhibit_idle = false;
            self.server.updateIdleInhibition();
            if (self.inhibitor_fd >= 0) {
                _ = libc.close(self.inhibitor_fd);
                self.destroy();
            }
            return;
        }
    }
    fn destroy(self: *Request) void {
        const server = self.server;
        const had_idle = self.inhibit_idle;
        self.inhibit_idle = false;
        if (self.idle != 0) _ = c.g_source_remove(self.idle);
        if (self.picker) |picker| picker.destroy();
        if (self.session_handle) |handle| if (self.server.session(handle, self.owner)) |session_info| {
            if (session_info.pending == self) session_info.pending = null;
        };
        if (self.dialog) |dialog| dialog.destroy();
        if (self.account) |dialog| dialog.destroy();
        if (self.screenshot) |operation| operation.destroy();
        if (self.registration != 0) self.server.connection.unregister(self.registration);
        if (self.invocation) |*invocation| invocation.release(self.server.connection.allocator);
        c.g_object_unref(self.cancel);
        for (self.server.requests.items, 0..) |item, index| if (item == self) {
            _ = self.server.requests.swapRemove(index);
            break;
        };
        self.arena.deinit();
        a.destroy(self);
        if (had_idle) server.updateIdleInhibition();
    }
    fn respond(self: *Request, code: u32, results: ?*c.GVariant) void {
        var arena: std.heap.ArenaAllocator = .init(a);
        defer arena.deinit();
        // Converting also releases a floating `results`.
        const values = bridge.dictFromVariant(arena.allocator(), results) catch bridge.Dict{ .entries = &.{} };
        if (!self.closed and !self.server.quitting) self.server.connection.emitTo(self.owner, self.handle, public ++ "Request", "Response", .{ code, values }) catch {};
    }
    fn nativeFinished(data: ?*anyopaque) callconv(.c) c_int {
        const self = cast(Request, data);
        self.idle = 0;
        defer self.destroy();
        const session_info = self.server.session(self.session_handle.?, self.owner) orelse return 0;
        const values = c.g_variant_builder_new(@ptrCast(@as([*:0]const u8, "a{sv}")));
        defer c.g_variant_builder_unref(values);
        if (eq(self.method, "CreateSession")) {
            session_info.state = .created;
            c.g_variant_builder_add(values, "{sv}", @as([*:0]const u8, "session_handle"), string(session_info.handle));
        } else session_info.state = .selected;
        self.respond(0, c.g_variant_builder_end(values));
        return 0;
    }
    fn picked(data: ?*anyopaque, chosen: ?Capture.Picked, _: bool) void {
        const self = cast(Request, data);
        const session_info = self.server.session(self.session_handle.?, self.owner) orelse return;
        if (chosen) |output| {
            session_info.width = output.width;
            session_info.height = output.height;
            session_info.stream = Video.Stream.create(a, output.name, session_info.cursor, &streamReady, session_info) catch {
                streamReady(session_info, null);
                return;
            };
        } else {
            self.respond(1, dict());
            self.destroy();
            session_info.server.closeSession(session_info);
        }
    }
    fn streamReady(data: ?*anyopaque, node: ?u32) void {
        const session_info = cast(Session, data);
        const server = session_info.server;
        if (node) |id| {
            const request = session_info.pending orelse return;
            session_info.state = .started;
            server.updateIdleInhibition();
            const properties = c.g_variant_builder_new(@ptrCast(@as([*:0]const u8, "a{sv}")));
            defer c.g_variant_builder_unref(properties);
            c.g_variant_builder_add(properties, "{sv}", @as([*:0]const u8, "source_type"), c.g_variant_new("u", @as(c_uint, 1)));
            c.g_variant_builder_add(properties, "{sv}", @as([*:0]const u8, "size"), c.g_variant_new("(ii)", session_info.width, session_info.height));
            const streams = c.g_variant_builder_new(@ptrCast(@as([*:0]const u8, "a(ua{sv})")));
            defer c.g_variant_builder_unref(streams);
            c.g_variant_builder_add_value(streams, tuple(&.{ c.g_variant_new("u", id), c.g_variant_builder_end(properties) }));
            const results = c.g_variant_builder_new(@ptrCast(@as([*:0]const u8, "a{sv}")));
            defer c.g_variant_builder_unref(results);
            c.g_variant_builder_add(results, "{sv}", @as([*:0]const u8, "streams"), c.g_variant_builder_end(streams));
            request.respond(0, c.g_variant_builder_end(results));
            request.destroy();
        } else {
            if (session_info.pending) |request| {
                request.respond(2, dict());
                request.destroy();
            }
            server.closeSession(session_info);
        }
    }
    fn dialogFinished(data: ?*anyopaque, code: u32, results: ?*c.GVariant) void {
        const self = cast(Request, data);
        self.respond(code, results);
        self.destroy();
    }
    fn inhibitorFinished(data: ?*anyopaque, reply: dbus.Reply) void {
        const self = cast(Request, data);
        if (!self.closed and !self.server.quitting) switch (reply) {
            .ok => |message| if (message.read(struct { dbus.Fd })) |args| {
                // The reply owns its descriptor; keep a duplicate for the lifetime of the inhibition.
                self.inhibitor_fd = std.c.fcntl(args[0].value, std.c.F.DUPFD_CLOEXEC, @as(c_int, 0));
                if (self.inhibitor_fd >= 0) return;
            } else |_| {},
            .failed => {},
        };
        self.respond(2, dict());
        self.destroy();
    }
    fn networkFinished(_: [*c]c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self = cast(Request, data);
        defer self.destroy();
        var err: ?*c.GError = null;
        const ok = c.g_network_monitor_can_reach_finish(c.g_network_monitor_get_default(), result, &err) != 0;
        defer if (err != null) c.g_error_free(err);
        const connection = self.server.connection;
        if (self.invocation) |*invocation| {
            if (!self.closed and !self.server.quitting) connection.answer(invocation, .{ok}) catch {} else connection.answerError(invocation, "org.freedesktop.portal.Error.Failed", "Request cancelled") catch {};
            self.invocation = null;
        }
    }
    fn uriFinished(_: [*c]c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self = cast(Request, data);
        defer self.destroy();
        var err: ?*c.GError = null;
        const ok = c.g_app_info_launch_default_for_uri_finish(result, &err) != 0;
        defer if (err != null) c.g_error_free(err);
        self.respond(if (ok) 0 else 2, dict());
    }
};

fn screencast(server: *Server, client_info: *Client, method: []const u8, params: ?*c.GVariant, message: *const dbus.Message) !void {
    const count = c.g_variant_n_children(params);
    const options = child(params, count - 1);
    defer c.g_variant_unref(options);
    const session_info = if (eq(method, "CreateSession")) try server.createSession(client_info, options) else blk: {
        const handle = child(params, 0);
        defer c.g_variant_unref(handle);
        break :blk server.session(text(handle), client_info.sender) orelse return error.InvalidSession;
    };
    errdefer if (eq(method, "CreateSession")) server.closeSession(session_info);
    if (!eq(method, "CreateSession")) {
        const needed: State = if (eq(method, "SelectSources")) .created else .selected;
        if (session_info.state != needed) return error.InvalidSessionState;
    }
    if (eq(method, "SelectSources")) {
        const types = c.g_variant_lookup_value(options, "types", null);
        defer if (types != null) c.g_variant_unref(types);
        if (types != null and (!eq(std.mem.span(c.g_variant_get_type_string(types)), "u") or c.g_variant_get_uint32(types) & 1 == 0)) return error.UnsupportedSourceTypes;
        const cursor = c.g_variant_lookup_value(options, "cursor_mode", null);
        defer if (cursor != null) c.g_variant_unref(cursor);
        if (cursor != null) {
            if (!eq(std.mem.span(c.g_variant_get_type_string(cursor)), "u")) return error.InvalidCursorMode;
            const mode = c.g_variant_get_uint32(cursor);
            if (mode != 1 and mode != 2) return error.UnsupportedCursorMode;
            session_info.cursor = mode == 2;
        }
        const multiple = c.g_variant_lookup_value(options, "multiple", null);
        defer if (multiple != null) c.g_variant_unref(multiple);
        if (multiple != null and !eq(std.mem.span(c.g_variant_get_type_string(multiple)), "b")) return error.InvalidMultipleOption;
    }
    const request = try Request.create(server, client_info, "ScreenCast", method, options, .dialog);
    errdefer request.destroy();
    request.session_handle = try request.arena.allocator().dupeSentinel(u8, session_info.handle, 0);
    session_info.pending = request;
    if (eq(method, "Start")) {
        const parent = child(params, 1);
        defer c.g_variant_unref(parent);
        request.picker = try Capture.Picker.create(a, client_info.app, std.mem.span(c.g_variant_get_string(parent, null)), "Share your screen", false, &Request.picked, request);
        session_info.state = .starting;
    } else {
        session_info.state = if (eq(method, "CreateSession")) .creating else .selecting;
        request.idle = c.g_idle_add(&Request.nativeFinished, request);
    }
    replyHandle(server, message, request.handle);
}
fn screenshot(server: *Server, client_info: *Client, method: []const u8, params: ?*c.GVariant, message: *const dbus.Message) !void {
    const parent = child(params, 0);
    defer c.g_variant_unref(parent);
    const options = child(params, 1);
    defer c.g_variant_unref(options);
    const request = try Request.create(server, client_info, "Screenshot", method, options, .dialog);
    errdefer request.destroy();
    request.screenshot = try Capture.Operation.create(a, client_info.app, std.mem.span(c.g_variant_get_string(parent, null)), method, options.?, &Request.dialogFinished, request);
    replyHandle(server, message, request.handle);
}
fn chooseFile(server: *Server, client_info: *Client, method: []const u8, params: ?*c.GVariant, message: *const dbus.Message) !void {
    const parent = child(params, 0);
    defer c.g_variant_unref(parent);
    const title = child(params, 1);
    defer c.g_variant_unref(title);
    const options = child(params, 2);
    defer c.g_variant_unref(options);
    const request = try Request.create(server, client_info, "FileChooser", method, options, .dialog);
    errdefer request.destroy();
    request.dialog = try FileChooser.create(a, method, std.mem.span(c.g_variant_get_string(parent, null)), std.mem.span(c.g_variant_get_string(title, null)), options.?, &Request.dialogFinished, request);
    replyHandle(server, message, request.handle);
}
fn userInformation(server: *Server, client_info: *Client, params: ?*c.GVariant, message: *const dbus.Message) !void {
    const parent = child(params, 0);
    defer c.g_variant_unref(parent);
    const options = child(params, 1);
    defer c.g_variant_unref(options);
    const request = try Request.create(server, client_info, "Account", "GetUserInformation", options, .dialog);
    errdefer request.destroy();
    request.account = try Account.create(a, client_info.app, std.mem.span(c.g_variant_get_string(parent, null)), options.?, &Request.dialogFinished, request);
    replyHandle(server, message, request.handle);
}
fn openRemote(server: *Server, client_info: *Client, params: ?*c.GVariant, message: *const dbus.Message) !void {
    const handle = child(params, 0);
    defer c.g_variant_unref(handle);
    const session_info = server.session(text(handle), client_info.sender) orelse return error.InvalidSession;
    if (session_info.state != .started) return error.InvalidSessionState;
    // Host clients already have access to this socket. Sandboxed callers are
    // rejected before dispatch rather than receiving an unrestricted remote.
    const runtime = c.__zig.getenv("XDG_RUNTIME_DIR") orelse return error.NoRuntimeDirectory;
    const remote: [*c]const u8 = c.__zig.getenv("PIPEWIRE_REMOTE") orelse @as([*c]const u8, "pipewire-0");
    var address = std.mem.zeroes(libc.struct_sockaddr_un);
    address.sun_family = libc.AF_UNIX;
    const socket_path = if (std.mem.startsWith(u8, std.mem.span(remote), "/")) try std.fmt.bufPrint(&address.sun_path, "{s}", .{remote}) else try std.fmt.bufPrint(&address.sun_path, "{s}/{s}", .{ runtime, remote });
    if (socket_path.len >= address.sun_path.len) return error.SocketPathTooLong;
    const fd = libc.socket(libc.AF_UNIX, libc.SOCK_STREAM | libc.SOCK_CLOEXEC, 0);
    if (fd < 0) return error.PipeWireUnavailable;
    defer _ = libc.close(fd);
    if (libc.connect(fd, @ptrCast(&address), @intCast(@offsetOf(libc.struct_sockaddr_un, "sun_path") + socket_path.len + 1)) != 0) return error.PipeWireUnavailable;
    server.connection.reply(message, .{dbus.Fd{ .value = fd }}) catch {};
}
fn openUri(server: *Server, client_info: *Client, method: []const u8, params: ?*c.GVariant, message: *const dbus.Message) !void {
    const arg = child(params, if (eq(method, "SchemeSupported")) 0 else 1);
    defer c.g_variant_unref(arg);
    if (eq(method, "SchemeSupported")) {
        const app_info = c.g_app_info_get_default_for_uri_scheme(c.g_variant_get_string(arg, null));
        defer if (app_info != null) c.g_object_unref(app_info);
        server.connection.reply(message, .{app_info != null}) catch {};
        return;
    }
    const options = child(params, 2);
    defer c.g_variant_unref(options);
    const request = try Request.create(server, client_info, "OpenURI", method, options, .uri);
    errdefer request.destroy();
    var uri: [*:0]const u8 = undefined;
    if (eq(method, "OpenURI")) {
        uri = c.g_variant_get_string(arg, null);
        if (std.mem.indexOfScalar(u8, std.mem.span(uri), ':') == null) return error.InvalidUri;
    } else {
        // The handle carries the descriptor number; the message owns it, so work on a duplicate.
        const passed = c.g_variant_get_handle(arg);
        if (std.mem.indexOfScalar(i32, message.fds, passed) == null) return error.InvalidFileDescriptor;
        const fd = std.c.fcntl(passed, std.c.F.DUPFD_CLOEXEC, @as(c_int, 0));
        if (fd < 0) return error.InvalidFileDescriptor;
        defer _ = libc.close(fd);
        const proc_path = try std.fmt.allocPrintSentinel(request.arena.allocator(), "/proc/self/fd/{d}", .{fd}, 0);
        const target = c.g_file_read_link(proc_path, null) orelse return error.InvalidFileDescriptor;
        defer c.g_free(target);
        if (!std.mem.startsWith(u8, std.mem.span(target), "/")) return error.InvalidFileDescriptor;
        var filename: [*:0]const u8 = target;
        if (eq(method, "OpenDirectory")) {
            const file = c.g_file_new_for_path(filename);
            defer c.g_object_unref(file);
            if (c.g_file_query_file_type(file, 0, null) != 2) filename = try request.arena.allocator().dupeSentinel(u8, std.fs.path.dirname(std.mem.span(filename)) orelse "/", 0);
        }
        const file = c.g_file_new_for_path(filename);
        defer c.g_object_unref(file);
        const file_uri = c.g_file_get_uri(file);
        defer c.g_free(file_uri);
        uri = try request.arena.allocator().dupeSentinel(u8, std.mem.span(file_uri), 0);
    }
    replyHandle(server, message, request.handle);
    c.g_app_info_launch_default_for_uri_async(uri, null, request.cancel, &Request.uriFinished, request);
}
fn composeEmail(server: *Server, client_info: *Client, params: ?*c.GVariant, message: *const dbus.Message) !void {
    const options = child(params, 1);
    defer c.g_variant_unref(options);
    const request = try Request.create(server, client_info, "Email", "ComposeEmail", options, .uri);
    errdefer request.destroy();
    const descriptors = message.fds;
    const uri = try Email.composeUri(request.arena.allocator(), options.?, descriptors);
    const context = try Email.launchContext(options.?);
    defer c.g_object_unref(context);
    replyHandle(server, message, request.handle);
    c.g_app_info_launch_default_for_uri_async(uri, context, request.cancel, &Request.uriFinished, request);
}
fn inhibit(server: *Server, client_info: *Client, params: ?*c.GVariant, message: *const dbus.Message) !void {
    const flags_value = child(params, 1);
    defer c.g_variant_unref(flags_value);
    const flags = c.g_variant_get_uint32(flags_value);
    if (flags == 0 or flags & ~@as(u32, 15) != 0 or flags & 2 != 0) return error.NotSupported;
    const options = child(params, 2);
    defer c.g_variant_unref(options);
    const request = try Request.create(server, client_info, "Inhibit", "Inhibit", options, .inhibit);
    errdefer request.destroy();
    var buffer: [64]u8 = undefined;
    var used: usize = 0;
    for ([_]u32{ 1, 4, 8 }, [_][]const u8{ "shutdown", "sleep", "idle" }) |flag, name| if (flags & flag != 0) {
        if (used != 0) {
            buffer[used] = ':';
            used += 1;
        }
        @memcpy(buffer[used..][0..name.len], name);
        used += name.len;
    };
    const reason = c.g_variant_lookup_value(options, "reason", @ptrCast(@as([*:0]const u8, "s")));
    defer if (reason != null) c.g_variant_unref(reason);
    const why: []const u8 = if (reason != null) std.mem.span(c.g_variant_get_string(reason, null)) else "Application requested inhibition";
    request.inhibit_idle = flags & 8 != 0;
    replyHandle(server, message, request.handle);
    server.updateIdleInhibition();
    loop.request(.system, .{ .destination = "org.freedesktop.login1", .path = "/org/freedesktop/login1", .interface = "org.freedesktop.login1.Manager", .member = "Inhibit" }, .{ buffer[0..used], @as([]const u8, request.app), why, "block" }, 10000, request.cancel, &Request.inhibitorFinished, request);
}
fn network(server: *Server, client_info: *Client, method: []const u8, params: ?*c.GVariant, message: *const dbus.Message) !void {
    if (eq(method, "CanReach")) {
        const host = child(params, 0);
        defer c.g_variant_unref(host);
        const port = child(params, 1);
        defer c.g_variant_unref(port);
        const number = c.g_variant_get_uint32(port);
        if (number > 65535 or text(host).len == 0 or text(host).len > 255) return error.InvalidAddress;
        const address = c.g_network_address_new(c.g_variant_get_string(host, null), @intCast(number)) orelse return error.InvalidAddress;
        defer c.g_object_unref(address);
        const request = try Request.create(server, client_info, "NetworkMonitor", method, null, .direct);
        request.invocation = server.connection.hold(message) catch |err| {
            request.destroy();
            return err;
        };
        c.g_network_monitor_can_reach_async(c.g_network_monitor_get_default(), address, request.cancel, &Request.networkFinished, request);
        return;
    }
    const monitor = c.g_network_monitor_get_default();
    const available = c.g_network_monitor_get_network_available(monitor) != 0;
    const metered = c.g_network_monitor_get_network_metered(monitor) != 0;
    const connectivity: u32 = @intCast(c.g_network_monitor_get_connectivity(monitor));
    const connection = server.connection;
    if (eq(method, "GetAvailable")) return connection.reply(message, .{available});
    if (eq(method, "GetMetered")) return connection.reply(message, .{metered});
    if (eq(method, "GetConnectivity")) return connection.reply(message, .{connectivity});
    if (eq(method, "GetStatus")) {
        const entries = [_]bridge.Dict.Entry{ .{ .key = "available", .value = .{ .boolean = available } }, .{ .key = "metered", .value = .{ .boolean = metered } }, .{ .key = "connectivity", .value = .{ .uint32 = connectivity } } };
        return connection.reply(message, .{bridge.Dict{ .entries = &entries }});
    }
    return error.NotSupported;
}
fn replyHandle(server: *Server, message: *const dbus.Message, handle: []const u8) void {
    server.connection.reply(message, .{dbus.ObjectPath{ .value = handle }}) catch {};
}
fn methodCall(data: ?*anyopaque, message: *const dbus.Message) void {
    // Handlers read arguments as a GVariant tuple, the form the dialogs consume.
    const params: ?*c.GVariant = blk: {
        if (message.signature.len == 0) break :blk null;
        break :blk bridge.argumentsVariant(message) orelse return cast(Server, data).connection.replyError(message, "org.freedesktop.portal.Error.InvalidArgument", "InvalidArguments") catch {};
    };
    const server = cast(Server, data);
    defer if (params) |value| c.g_variant_unref(value);
    dispatch(server, message.sender orelse "", message.interface orelse "", message.member orelse "", params, message) catch |err| {
        server.connection.replyError(message, if (err == error.SandboxedClientUnsupported) "org.freedesktop.portal.Error.NotAllowed" else if (err == error.NotSupported) "org.freedesktop.portal.Error.NotSupported" else "org.freedesktop.portal.Error.InvalidArgument", @errorName(err)) catch {};
    };
}
fn dispatch(server: *Server, sender: []const u8, interface: []const u8, method: []const u8, params: ?*c.GVariant, message: *const dbus.Message) !void {
    if (server.quitting) return error.PortalStopping;
    const client_info = try server.getClient(sender);
    if (eq(interface, "org.freedesktop.host.portal.Registry")) {
        if (client_info.registered) return error.AlreadyRegistered;
        const app = child(params, 0);
        defer c.g_variant_unref(app);
        const id = text(app);
        if (id.len == 0 or id.len > 255 or std.mem.indexOfScalar(u8, id, '.') == null) return error.InvalidAppId;
        for (id) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '.' and ch != '_' and ch != '-') return error.InvalidAppId;
        client_info.app = try client_info.arena.allocator().dupeSentinel(u8, id, 0);
        client_info.registered = true;
        return server.connection.reply(message, .{});
    }
    if (!std.mem.startsWith(u8, interface, public)) return error.NotSupported;
    const short = interface[public.len..];
    if (eq(short, "Account")) return userInformation(server, client_info, params, message);
    if (eq(short, "FileChooser")) return chooseFile(server, client_info, method, params, message);
    if (eq(short, "Settings")) return server.settings.?.call(method, message);
    if (eq(short, "Notification")) {
        const id_value = child(params, 0);
        defer c.g_variant_unref(id_value);
        const id: [:0]const u8 = std.mem.span(c.g_variant_get_string(id_value, null));
        if (eq(method, "AddNotification")) {
            const contents = child(params, 1);
            defer c.g_variant_unref(contents);
            try server.notifications.?.add(client_info.sender, client_info.app, id, contents.?);
        } else server.notifications.?.remove(client_info.sender, id);
        return server.connection.reply(message, .{});
    }
    if (eq(short, "Email")) return composeEmail(server, client_info, params, message);
    if (eq(short, "Inhibit")) return inhibit(server, client_info, params, message);
    if (eq(short, "OpenURI")) return openUri(server, client_info, method, params, message);
    if (eq(short, "NetworkMonitor")) return network(server, client_info, method, params, message);
    if (eq(short, "ScreenCast") and eq(method, "OpenPipeWireRemote")) return openRemote(server, client_info, params, message);
    if (eq(short, "Screenshot")) return screenshot(server, client_info, method, params, message);
    if (eq(short, "ScreenCast")) return screencast(server, client_info, method, params, message);
    return error.NotSupported;
}
fn getProperty(_: ?*anyopaque, _: []const u8, interface: []const u8, property: []const u8, _: std.mem.Allocator) ?dbus.Value {
    if (!std.mem.startsWith(u8, interface, public)) return null;
    const short = interface[public.len..];
    if (eq(property, "version")) {
        const version: u32 = if (eq(short, "Settings") or eq(short, "Screenshot")) 2 else if (eq(short, "ScreenCast") or eq(short, "FileChooser") or eq(short, "NetworkMonitor")) 3 else if (eq(short, "OpenURI")) 5 else if (eq(short, "Email")) 4 else 1;
        return .{ .uint32 = version };
    }
    if (eq(short, "Notification")) return .{ .array = .{ .element = "{sv}", .items = &.{} } };
    if (eq(short, "ScreenCast")) return .{ .uint32 = if (eq(property, "AvailableSourceTypes")) 1 else 3 };
    return null;
}
fn closeRequest(data: ?*anyopaque, message: *const dbus.Message) void {
    const request = cast(Request, data);
    const connection = request.server.connection;
    if (!eq(request.owner, message.sender orelse "")) return errorReply(connection, message, "Request belongs to another client");
    request.close();
    connection.reply(message, .{}) catch {};
}
fn closeSessionCall(data: ?*anyopaque, message: *const dbus.Message) void {
    const session_info = cast(Session, data);
    const server = session_info.server;
    if (!eq(session_info.owner, message.sender orelse "")) return errorReply(server.connection, message, "Session belongs to another client");
    server.closeSession(session_info);
    server.connection.reply(message, .{}) catch {};
}
fn idlePortalCall(data: ?*anyopaque, message: *const dbus.Message) void {
    const server = cast(Server, data);
    if (eq(message.member orelse "", "IdleInhibited")) return server.connection.reply(message, .{server.idle_inhibited}) catch {};
    server.connection.replyError(message, "org.freedesktop.DBus.Error.UnknownMethod", "Unknown method") catch {};
}
fn quit(data: ?*anyopaque) callconv(.c) c_int {
    cast(Server, data).quitting = true;
    return 1;
}
pub fn run() !void {
    return runWithAllocator(std.heap.page_allocator);
}
/// The broker owns a single GLib main context; fixtures supply a checked allocator.
pub fn runWithAllocator(allocator: std.mem.Allocator) !void {
    a = allocator;
    _ = c.g_setenv("GIO_USE_NETWORK_MONITOR", "netlink", 1);
    _ = c.g_setenv("GIO_USE_PORTALS", "0", 1);
    _ = c.g_setenv("GTK_USE_PORTAL", "0", 1);
    const source = loop.acquire(.session) catch return error.SessionBusUnavailable;
    defer loop.release(source);
    const connection = source.connection;
    var server = Server{ .connection = connection, .introspection = try dbus.Introspection.parse(allocator, @embedFile("desktop-portal.xml")) };
    defer server.introspection.deinit();
    defer server.deinit();
    try server.start();
    if ((connection.requestName("org.freedesktop.portal.Desktop", 4) catch return error.PortalNameUnavailable) != 1) return error.PortalNameUnavailable;
    const term = c.g_unix_signal_add(c.SIGTERM, &quit, &server);
    const interrupt = c.g_unix_signal_add(c.SIGINT, &quit, &server);
    defer {
        _ = c.g_source_remove(term);
        _ = c.g_source_remove(interrupt);
    }
    while (!server.quitting and !connection.closed) _ = c.g_main_context_iteration(null, 1);
}
