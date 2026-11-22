//! Native portal broker, dialogs and capture for host desktop applications.
const std = @import("std");
const c = @import("desktop-glib.zig");
const libc = @import("desktop-libc.zig");
const netmon = @import("desktop-netmon.zig");
const dbus = @import("dbus");
const loop = @import("desktop-dbus-loop.zig");
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
const portal_options = @import("desktop-portal-options.zig");
const Dict = portal_options.Dict;
/// Options (`a{sv}`) from a method argument; entries borrow from the message.
fn dictionary(arena: std.mem.Allocator, value: dbus.Value) !Dict {
    const items = value.array.items;
    const entries = try arena.alloc(Dict.Entry, items.len);
    for (entries, items) |*entry, item| entry.* = .{ .key = item.dict_entry[0].string, .value = item.dict_entry[1].variant.* };
    return .{ .entries = entries };
}
fn option(options: Dict, key: []const u8) ?dbus.Value {
    for (options.entries) |entry| if (eq(entry.key, key)) return entry.value;
    return null;
}
fn errorReply(connection: *dbus.Connection, message: *const dbus.Message, text_value: []const u8) void {
    connection.replyError(message, "org.freedesktop.portal.Error.Failed", text_value) catch {};
}
fn validToken(value: []const u8) bool {
    if (value.len == 0 or value.len > 128) return false;
    for (value) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    return true;
}
const Client = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    sender: [:0]const u8,
    component: [:0]const u8,
    app: [:0]const u8,
    registered: bool = false,
    fn destroy(self: *Client) void {
        self.arena.deinit();
        self.allocator.destroy(self);
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
        self.server.allocator.destroy(self);
    }
};
const Server = struct {
    allocator: std.mem.Allocator,
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
    /// Null when rtnetlink is unavailable; every host then counts as reachable, as with GIO's fallback.
    network: ?*netmon.Monitor = null,
    idle_inhibited: bool = false,
    serial: u64 = 0,
    quitting: bool = false,

    fn info(self: *Server, name: []const u8) *const dbus.InterfaceInfo {
        return self.introspection.find(name).?;
    }
    fn start(self: *Server) !void {
        for (self.introspection.interfaces) |*item| {
            if (eq(item.name, public ++ "Request") or eq(item.name, public ++ "Session")) continue;
            try self.registrations.append(self.allocator, try self.connection.exportObject(path, item, &methodCall, &getProperty, self));
        }
        self.idle_introspection = try dbus.Introspection.parse(self.allocator, idle_portal_xml);
        try self.registrations.append(self.allocator, try self.connection.exportObject(idle_portal_path, &self.idle_introspection.?.interfaces[0], &idlePortalCall, null, self));
        try self.subscriptions.append(self.allocator, try self.connection.subscribe(bus, bus, "NameOwnerChanged", bus_path, &ownerChanged, self));
        self.settings = try Settings.create(self.allocator, self.connection);
        self.notifications = try Notifications.create(self.allocator, self.connection);
        self.network = netmon.Monitor.create(self.allocator, &networkChanged, self) catch null;
    }
    fn deinit(self: *Server) void {
        self.quitting = true;
        if (self.settings) |settings| settings.destroy();
        if (self.notifications) |notifications| notifications.destroy();
        if (self.network) |monitor| monitor.destroy();
        self.network = null;
        for (self.subscriptions.items) |id| self.connection.unsubscribe(id);
        self.cancelRequests(null);
        while (self.requests.items.len > 0) _ = c.g_main_context_iteration(null, 1);
        while (self.sessions.items.len > 0) self.closeSession(self.sessions.items[0]);
        for (self.registrations.items) |id| self.connection.unregister(id);
        if (self.idle_introspection) |*idle| idle.deinit();
        for (self.clients.items) |client| client.destroy();
        self.registrations.deinit(self.allocator);
        self.subscriptions.deinit(self.allocator);
        self.requests.deinit(self.allocator);
        self.sessions.deinit(self.allocator);
        self.clients.deinit(self.allocator);
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
        const contents = @import("desktop-paths.zig").readFile(self.allocator, environ, 1 << 20) catch return error.CannotIdentifyClient;
        defer self.allocator.free(contents);
        var entries = std.mem.splitScalar(u8, contents, 0);
        while (entries.next()) |entry| if (std.mem.startsWith(u8, entry, "SNAP=")) return error.SandboxedClientUnsupported;
        const item = try self.allocator.create(Client);
        errdefer self.allocator.destroy(item);
        item.registered = false;
        item.allocator = self.allocator;
        item.arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer item.arena.deinit();
        const alloc = item.arena.allocator();
        item.sender = try alloc.dupeSentinel(u8, sender, 0);
        item.component = try alloc.dupeSentinel(u8, std.mem.trimStart(u8, item.sender, ":"), 0);
        for (@constCast(item.component)) |*ch| if (ch.* == '.') {
            ch.* = '_';
        };
        item.app = try std.fmt.allocPrintSentinel(alloc, "org.dotfiles.portal.client{s}", .{item.component}, 0);
        try self.clients.append(self.allocator, item);
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
        self.connection.emitTo(item.owner, item.handle, public ++ "Session", "Closed", .{Dict{ .entries = &.{} }}) catch {};
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
    fn createSession(self: *Server, client_info: *Client, options: Dict) !*Session {
        if (self.sessions.items.len >= 64) return error.TooManySessions;
        const token = option(options, "session_handle_token");
        self.serial +%= 1;
        var buffer: [64]u8 = undefined;
        const suffix = if (token) |value| blk: {
            if (value != .string or !validToken(value.string)) return error.InvalidSessionToken;
            break :blk value.string;
        } else try std.fmt.bufPrint(&buffer, "session{d}", .{self.serial});
        const item = try self.allocator.create(Session);
        errdefer self.allocator.destroy(item);
        item.* = .{ .server = self, .arena = std.heap.ArenaAllocator.init(self.allocator), .owner = undefined, .handle = undefined };
        errdefer item.arena.deinit();
        const alloc = item.arena.allocator();
        item.owner = try alloc.dupeSentinel(u8, client_info.sender, 0);
        item.handle = try std.fmt.allocPrintSentinel(alloc, "/org/freedesktop/portal/desktop/session/{s}/{s}", .{ client_info.component, suffix }, 0);
        if (self.session(item.handle, item.owner) != null) return error.DuplicateSession;
        item.registration = self.connection.exportObject(item.handle, self.info(public ++ "Session"), &closeSessionCall, null, item) catch 0;
        if (item.registration == 0) return error.SessionRegistrationFailed;
        errdefer self.connection.unregister(item.registration);
        try self.sessions.append(self.allocator, item);
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
    fn networkChanged(data: ?*anyopaque) void {
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
    reach: ?*netmon.Reach = null,
    closed: bool = false,
    inhibit_idle: bool = false,
    inhibitor_fd: c_int = -1,
    dialog: ?*FileChooser = null,
    account: ?*Account = null,
    screenshot: ?*Capture.Operation = null,
    picker: ?*Capture.Picker = null,
    idle: c.guint = 0,

    fn create(server: *Server, client_info: *Client, interface: []const u8, method: []const u8, options: Dict, kind: Kind) !*Request {
        if (server.requests.items.len >= 128) return error.TooManyRequests;
        var count: usize = 0;
        for (server.requests.items) |item| if (eq(item.owner, client_info.sender)) {
            count += 1;
        };
        if (count >= 32) return error.TooManyClientRequests;
        const item = try server.allocator.create(Request);
        errdefer server.allocator.destroy(item);
        item.* = .{ .server = server, .arena = std.heap.ArenaAllocator.init(server.allocator), .owner = undefined, .app = undefined, .handle = undefined, .interface = undefined, .method = undefined, .cancel = c.g_cancellable_new().?, .kind = kind };
        errdefer {
            item.arena.deinit();
            c.g_object_unref(item.cancel);
        }
        const alloc = item.arena.allocator();
        item.owner = try alloc.dupeSentinel(u8, client_info.sender, 0);
        item.app = try alloc.dupeSentinel(u8, client_info.app, 0);
        item.interface = try alloc.dupeSentinel(u8, interface, 0);
        item.method = try alloc.dupeSentinel(u8, method, 0);
        const token = if (kind != .direct) option(options, "handle_token") else null;
        if (token) |value| if (value != .string) return error.InvalidHandleToken;
        server.serial +%= 1;
        const suffix = if (token) |value| value.string else try std.fmt.allocPrint(alloc, "request{d}", .{server.serial});
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
        try server.requests.append(server.allocator, item);
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
        if (self.reach) |reach| reach.cancel();
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
        if (self.reach) |reach| reach.abandon();
        c.g_object_unref(self.cancel);
        for (self.server.requests.items, 0..) |item, index| if (item == self) {
            _ = self.server.requests.swapRemove(index);
            break;
        };
        self.arena.deinit();
        server.allocator.destroy(self);
        if (had_idle) server.updateIdleInhibition();
    }
    fn respond(self: *Request, code: u32, results: Dict) void {
        if (!self.closed and !self.server.quitting) self.server.connection.emitTo(self.owner, self.handle, public ++ "Request", "Response", .{ code, results }) catch {};
    }
    fn nativeFinished(data: ?*anyopaque) callconv(.c) c_int {
        const self = cast(Request, data);
        self.idle = 0;
        defer self.destroy();
        const session_info = self.server.session(self.session_handle.?, self.owner) orelse return 0;
        const handle = [_]Dict.Entry{.{ .key = "session_handle", .value = .{ .string = session_info.handle } }};
        if (eq(self.method, "CreateSession")) {
            session_info.state = .created;
            self.respond(0, .{ .entries = &handle });
        } else {
            session_info.state = .selected;
            self.respond(0, portal_options.empty);
        }
        return 0;
    }
    fn picked(data: ?*anyopaque, chosen: ?Capture.Picked, _: bool) void {
        const self = cast(Request, data);
        const session_info = self.server.session(self.session_handle.?, self.owner) orelse return;
        if (chosen) |output| {
            session_info.width = output.width;
            session_info.height = output.height;
            session_info.stream = Video.Stream.create(self.server.allocator, output.name, session_info.cursor, &streamReady, session_info) catch {
                streamReady(session_info, null);
                return;
            };
        } else {
            self.respond(1, portal_options.empty);
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
            // streams: a(ua{sv}) of the PipeWire node and its properties.
            const size = [_]dbus.Value{ .{ .int32 = session_info.width }, .{ .int32 = session_info.height } };
            const properties = [_]Dict.Entry{ .{ .key = "source_type", .value = .{ .uint32 = 1 } }, .{ .key = "size", .value = .{ .structure = &size } } };
            // Results are a{sv}, so the stream's own dictionary is built as a dynamic value.
            var property_items: [2]dbus.Value = undefined;
            var property_pairs: [2][2]dbus.Value = undefined;
            var boxed: [2]dbus.Value = .{ properties[0].value, properties[1].value };
            for (&property_items, &property_pairs, properties, &boxed) |*item, *pair, entry, *value| {
                pair.* = .{ .{ .string = entry.key }, .{ .variant = value } };
                item.* = .{ .dict_entry = pair };
            }
            const stream = [_]dbus.Value{ .{ .uint32 = id }, .{ .array = .{ .element = "{sv}", .items = &property_items } } };
            const stream_list = [_]dbus.Value{.{ .structure = &stream }};
            const results = [_]Dict.Entry{.{ .key = "streams", .value = .{ .array = .{ .element = "(ua{sv})", .items = &stream_list } } }};
            request.respond(0, .{ .entries = &results });
            request.destroy();
        } else {
            if (session_info.pending) |request| {
                request.respond(2, portal_options.empty);
                request.destroy();
            }
            server.closeSession(session_info);
        }
    }
    fn dialogFinished(data: ?*anyopaque, code: u32, results: Dict) void {
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
        self.respond(2, portal_options.empty);
        self.destroy();
    }
    fn networkFinished(data: ?*anyopaque, ok: bool) void {
        const self = cast(Request, data);
        self.reach = null;
        defer self.destroy();
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
        self.respond(if (ok) 0 else 2, portal_options.empty);
    }
};

/// A string argument as a C string for GLib, allocated from the message's arena.
fn cstring(message: *const dbus.Message, value: dbus.Value) ![:0]const u8 {
    return message.arena.dupeSentinel(u8, value.string, 0);
}
fn screencast(server: *Server, client_info: *Client, method: []const u8, args: []const dbus.Value, message: *const dbus.Message) !void {
    const options = try dictionary(message.arena, args[args.len - 1]);
    const session_info = if (eq(method, "CreateSession")) try server.createSession(client_info, options) else server.session(args[0].object_path, client_info.sender) orelse return error.InvalidSession;
    errdefer if (eq(method, "CreateSession")) server.closeSession(session_info);
    if (!eq(method, "CreateSession")) {
        const needed: State = if (eq(method, "SelectSources")) .created else .selected;
        if (session_info.state != needed) return error.InvalidSessionState;
    }
    if (eq(method, "SelectSources")) {
        if (option(options, "types")) |types| if (types != .uint32 or types.uint32 & 1 == 0) return error.UnsupportedSourceTypes;
        if (option(options, "cursor_mode")) |cursor| {
            if (cursor != .uint32) return error.InvalidCursorMode;
            if (cursor.uint32 != 1 and cursor.uint32 != 2) return error.UnsupportedCursorMode;
            session_info.cursor = cursor.uint32 == 2;
        }
        if (option(options, "multiple")) |multiple| if (multiple != .boolean) return error.InvalidMultipleOption;
    }
    const request = try Request.create(server, client_info, "ScreenCast", method, options, .dialog);
    errdefer request.destroy();
    request.session_handle = try request.arena.allocator().dupeSentinel(u8, session_info.handle, 0);
    session_info.pending = request;
    if (eq(method, "Start")) {
        request.picker = try Capture.Picker.create(server.allocator, client_info.app, try cstring(message, args[1]), "Share your screen", false, &Request.picked, request);
        session_info.state = .starting;
    } else {
        session_info.state = if (eq(method, "CreateSession")) .creating else .selecting;
        request.idle = c.g_idle_add(&Request.nativeFinished, request);
    }
    replyHandle(server, message, request.handle);
}
fn screenshot(server: *Server, client_info: *Client, method: []const u8, args: []const dbus.Value, message: *const dbus.Message) !void {
    const options = try dictionary(message.arena, args[1]);
    const request = try Request.create(server, client_info, "Screenshot", method, options, .dialog);
    errdefer request.destroy();
    request.screenshot = try Capture.Operation.create(server.allocator, client_info.app, try cstring(message, args[0]), method, options, &Request.dialogFinished, request);
    replyHandle(server, message, request.handle);
}
fn chooseFile(server: *Server, client_info: *Client, method: []const u8, args: []const dbus.Value, message: *const dbus.Message) !void {
    const options = try dictionary(message.arena, args[2]);
    const request = try Request.create(server, client_info, "FileChooser", method, options, .dialog);
    errdefer request.destroy();
    request.dialog = try FileChooser.create(server.allocator, method, try cstring(message, args[0]), try cstring(message, args[1]), options, &Request.dialogFinished, request);
    replyHandle(server, message, request.handle);
}
fn userInformation(server: *Server, client_info: *Client, args: []const dbus.Value, message: *const dbus.Message) !void {
    const options = try dictionary(message.arena, args[1]);
    const request = try Request.create(server, client_info, "Account", "GetUserInformation", options, .dialog);
    errdefer request.destroy();
    request.account = try Account.create(server.allocator, client_info.app, try cstring(message, args[0]), options, &Request.dialogFinished, request);
    replyHandle(server, message, request.handle);
}
fn openRemote(server: *Server, client_info: *Client, args: []const dbus.Value, message: *const dbus.Message) !void {
    const session_info = server.session(args[0].object_path, client_info.sender) orelse return error.InvalidSession;
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
fn openUri(server: *Server, client_info: *Client, method: []const u8, args: []const dbus.Value, message: *const dbus.Message) !void {
    if (eq(method, "SchemeSupported")) {
        const app_info = c.g_app_info_get_default_for_uri_scheme(try cstring(message, args[0]));
        defer if (app_info != null) c.g_object_unref(app_info);
        server.connection.reply(message, .{app_info != null}) catch {};
        return;
    }
    const options = try dictionary(message.arena, args[2]);
    const request = try Request.create(server, client_info, "OpenURI", method, options, .uri);
    errdefer request.destroy();
    var uri: [*:0]const u8 = undefined;
    if (eq(method, "OpenURI")) {
        uri = try request.arena.allocator().dupeSentinel(u8, args[1].string, 0);
        if (std.mem.indexOfScalar(u8, std.mem.span(uri), ':') == null) return error.InvalidUri;
    } else {
        // The handle carries the descriptor number; the message owns it, so work on a duplicate.
        const passed = args[1].fd;
        if (std.mem.indexOfScalar(i32, message.fds, passed) == null) return error.InvalidFileDescriptor;
        const fd = std.c.fcntl(passed, std.c.F.DUPFD_CLOEXEC, @as(c_int, 0));
        if (fd < 0) return error.InvalidFileDescriptor;
        defer _ = libc.close(fd);
        const proc_path = try std.fmt.allocPrintSentinel(request.arena.allocator(), "/proc/self/fd/{d}", .{fd}, 0);
        const files = @import("desktop-paths.zig");
        const arena = request.arena.allocator();
        const target = files.readLink(arena, proc_path) catch return error.InvalidFileDescriptor;
        if (!std.mem.startsWith(u8, target, "/")) return error.InvalidFileDescriptor;
        var filename: []const u8 = target;
        if (eq(method, "OpenDirectory") and !files.isDirectory(filename)) filename = std.fs.path.dirname(filename) orelse "/";
        uri = try files.fileUri(arena, filename);
    }
    replyHandle(server, message, request.handle);
    c.g_app_info_launch_default_for_uri_async(uri, null, request.cancel, &Request.uriFinished, request);
}
fn composeEmail(server: *Server, client_info: *Client, args: []const dbus.Value, message: *const dbus.Message) !void {
    const options = try dictionary(message.arena, args[1]);
    const request = try Request.create(server, client_info, "Email", "ComposeEmail", options, .uri);
    errdefer request.destroy();
    const uri = try Email.composeUri(request.arena.allocator(), options, message.fds);
    const context = try Email.launchContext(server.allocator, options);
    defer c.g_object_unref(context);
    replyHandle(server, message, request.handle);
    c.g_app_info_launch_default_for_uri_async(uri, context, request.cancel, &Request.uriFinished, request);
}
fn inhibit(server: *Server, client_info: *Client, args: []const dbus.Value, message: *const dbus.Message) !void {
    const flags = args[1].uint32;
    if (flags == 0 or flags & ~@as(u32, 15) != 0 or flags & 2 != 0) return error.NotSupported;
    const options = try dictionary(message.arena, args[2]);
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
    const why: []const u8 = if (option(options, "reason")) |reason| (if (reason == .string) reason.string else "Application requested inhibition") else "Application requested inhibition";
    request.inhibit_idle = flags & 8 != 0;
    replyHandle(server, message, request.handle);
    server.updateIdleInhibition();
    loop.request(server.allocator, .system, .{ .destination = "org.freedesktop.login1", .path = "/org/freedesktop/login1", .interface = "org.freedesktop.login1.Manager", .member = "Inhibit" }, .{ buffer[0..used], @as([]const u8, request.app), why, "block" }, 10000, request.cancel, &Request.inhibitorFinished, request);
}
fn network(server: *Server, client_info: *Client, method: []const u8, args: []const dbus.Value, message: *const dbus.Message) !void {
    if (eq(method, "CanReach")) {
        const host = args[0].string;
        const number = args[1].uint32;
        if (number > 65535 or host.len == 0 or host.len > 255) return error.InvalidAddress;
        _ = try cstring(message, args[0]);
        const request = try Request.create(server, client_info, "NetworkMonitor", method, portal_options.empty, .direct);
        request.invocation = server.connection.hold(message) catch |err| {
            request.destroy();
            return err;
        };
        request.reach = netmon.Reach.start(server.allocator, server.network, host, @intCast(number), &Request.networkFinished, request) catch |err| {
            request.destroy();
            return err;
        };
        return;
    }
    const available = if (server.network) |monitor| monitor.available() else true;
    // Like GIO's netlink monitor, the routing table says nothing about metering.
    const metered = false;
    const connectivity: u32 = if (server.network) |monitor| @backingInt(monitor.connectivity()) else @backingInt(netmon.Connectivity.full);
    const connection = server.connection;
    if (eq(method, "GetAvailable")) return connection.reply(message, .{available});
    if (eq(method, "GetMetered")) return connection.reply(message, .{metered});
    if (eq(method, "GetConnectivity")) return connection.reply(message, .{connectivity});
    if (eq(method, "GetStatus")) {
        const entries = [_]Dict.Entry{ .{ .key = "available", .value = .{ .boolean = available } }, .{ .key = "metered", .value = .{ .boolean = metered } }, .{ .key = "connectivity", .value = .{ .uint32 = connectivity } } };
        return connection.reply(message, .{Dict{ .entries = &entries }});
    }
    return error.NotSupported;
}
fn replyHandle(server: *Server, message: *const dbus.Message, handle: []const u8) void {
    server.connection.reply(message, .{dbus.ObjectPath{ .value = handle }}) catch {};
}
fn methodCall(data: ?*anyopaque, message: *const dbus.Message) void {
    const server = cast(Server, data);
    // Exported methods only receive arguments matching their introspected signature.
    const args = message.values() catch return server.connection.replyError(message, "org.freedesktop.portal.Error.InvalidArgument", "InvalidArguments") catch {};
    dispatch(server, message.sender orelse "", message.interface orelse "", message.member orelse "", args, message) catch |err| {
        server.connection.replyError(message, if (err == error.SandboxedClientUnsupported) "org.freedesktop.portal.Error.NotAllowed" else if (err == error.NotSupported) "org.freedesktop.portal.Error.NotSupported" else "org.freedesktop.portal.Error.InvalidArgument", @errorName(err)) catch {};
    };
}
fn dispatch(server: *Server, sender: []const u8, interface: []const u8, method: []const u8, args: []const dbus.Value, message: *const dbus.Message) !void {
    if (server.quitting) return error.PortalStopping;
    const client_info = try server.getClient(sender);
    if (eq(interface, "org.freedesktop.host.portal.Registry")) {
        if (client_info.registered) return error.AlreadyRegistered;
        const id = args[0].string;
        if (id.len == 0 or id.len > 255 or std.mem.indexOfScalar(u8, id, '.') == null) return error.InvalidAppId;
        for (id) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '.' and ch != '_' and ch != '-') return error.InvalidAppId;
        client_info.app = try client_info.arena.allocator().dupeSentinel(u8, id, 0);
        client_info.registered = true;
        return server.connection.reply(message, .{});
    }
    if (!std.mem.startsWith(u8, interface, public)) return error.NotSupported;
    const short = interface[public.len..];
    if (eq(short, "Account")) return userInformation(server, client_info, args, message);
    if (eq(short, "FileChooser")) return chooseFile(server, client_info, method, args, message);
    if (eq(short, "Settings")) return server.settings.?.call(method, message);
    if (eq(short, "Notification")) {
        const id = try cstring(message, args[0]);
        if (eq(method, "AddNotification")) {
            try server.notifications.?.add(client_info.sender, client_info.app, id, try dictionary(message.arena, args[1]));
        } else server.notifications.?.remove(client_info.sender, id);
        return server.connection.reply(message, .{});
    }
    if (eq(short, "Email")) return composeEmail(server, client_info, args, message);
    if (eq(short, "Inhibit")) return inhibit(server, client_info, args, message);
    if (eq(short, "OpenURI")) return openUri(server, client_info, method, args, message);
    if (eq(short, "NetworkMonitor")) return network(server, client_info, method, args, message);
    if (eq(short, "ScreenCast") and eq(method, "OpenPipeWireRemote")) return openRemote(server, client_info, args, message);
    if (eq(short, "Screenshot")) return screenshot(server, client_info, method, args, message);
    if (eq(short, "ScreenCast")) return screencast(server, client_info, method, args, message);
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
pub fn run(allocator: std.mem.Allocator) !void {
    return runWithAllocator(allocator);
}
/// The broker owns a single GLib main context; fixtures supply a checked allocator.
pub fn runWithAllocator(allocator: std.mem.Allocator) !void {
    _ = c.g_setenv("GIO_USE_PORTALS", "0", 1);
    _ = c.g_setenv("GTK_USE_PORTAL", "0", 1);
    const source = loop.acquire(allocator, .session) catch return error.SessionBusUnavailable;
    defer loop.release(source);
    const connection = source.connection;
    var server = Server{ .allocator = allocator, .connection = connection, .introspection = try dbus.Introspection.parse(allocator, @embedFile("desktop-portal.xml")) };
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
