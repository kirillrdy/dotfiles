//! Native portal broker, dialogs and capture for host desktop applications.
const std = @import("std");
const c = @import("gtk");
const libc = @import("libc");
var a: std.mem.Allocator = std.heap.page_allocator;
const path = "/org/freedesktop/portal/desktop";
const public = "org.freedesktop.portal.";
const Account = @import("desktop-portal-account.zig").Dialog;
const FileChooser = @import("desktop-portal-file-chooser.zig").Dialog;
const Notifications = @import("desktop-portal-notification.zig").Service;
const Settings = @import("desktop-portal-settings.zig").Service;
const Printing = @import("desktop-portal-print.zig");
const Email = @import("desktop-portal-email.zig");
const Capture = @import("desktop-portal-capture.zig");
const Video = @import("desktop-portal-screencast.zig");
const bus = "org.freedesktop.DBus";
const bus_path = "/org/freedesktop/DBus";
fn cast(comptime T: type, value: anytype) *T {
    return @ptrCast(@alignCast(value));
}
fn eq(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}
fn text(value: ?*c.GVariant) []const u8 {
    return std.mem.span(c.g_variant_get_string(value, null));
}
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
fn dict() ?*c.GVariant {
    return c.g_variant_new_array(@ptrCast(@as([*:0]const u8, "{sv}")), null, 0);
}
fn child(value: ?*c.GVariant, index: usize) ?*c.GVariant {
    return c.g_variant_get_child_value(value, index);
}
fn errorReply(invocation: ?*c.GDBusMethodInvocation, message: [*:0]const u8) void {
    c.g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.portal.Error.Failed", message);
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
    registration: c.guint = 0,
    state: State = .creating,
    cursor: bool = false,
    stream: ?*Video.Stream = null,
    pending: ?*Request = null,
    width: i32 = 0,
    height: i32 = 0,
    fn destroy(self: *Session) void {
        if (self.stream) |stream| stream.destroy();
        _ = c.g_dbus_connection_unregister_object(self.server.connection, self.registration);
        self.arena.deinit();
        a.destroy(self);
    }
};
const Server = struct {
    connection: *c.GDBusConnection,
    node: *c.GDBusNodeInfo,
    registrations: std.ArrayList(c.guint) = .empty,
    subscriptions: std.ArrayList(c.guint) = .empty,
    clients: std.ArrayList(*Client) = .empty,
    requests: std.ArrayList(*Request) = .empty,
    sessions: std.ArrayList(*Session) = .empty,
    settings: ?*Settings = null,
    notifications: ?*Notifications = null,
    printing: ?*Printing.Service = null,
    serial: u64 = 0,
    quitting: bool = false,

    fn info(self: *Server, name: [*:0]const u8) *c.GDBusInterfaceInfo {
        var i: usize = 0;
        while (self.node.interfaces[i] != null) : (i += 1) {
            const item = self.node.interfaces[i];
            if (eq(std.mem.span(item.*.name), std.mem.span(name))) return item;
        }
        unreachable;
    }
    fn start(self: *Server) !void {
        var i: usize = 0;
        while (self.node.interfaces[i] != null) : (i += 1) {
            const item = self.node.interfaces[i];
            const name = std.mem.span(item.*.name);
            if (eq(name, public ++ "Request") or eq(name, public ++ "Session")) continue;
            const id = c.g_dbus_connection_register_object(self.connection, path, item, &main_vtable, self, null, null);
            if (id == 0) return error.PortalRegistrationFailed;
            try self.registrations.append(a, id);
        }
        try self.subscriptions.append(a, c.g_dbus_connection_signal_subscribe(self.connection, bus, bus, "NameOwnerChanged", bus_path, null, 0, &ownerChanged, self, null));
        self.settings = try Settings.create(a, self.connection);
        self.notifications = try Notifications.create(a, self.connection);
        self.printing = try Printing.Service.create(a);
        if (c.g_network_monitor_get_default()) |monitor| _ = c.g_signal_connect_data(monitor, "network-changed", @ptrCast(&networkChanged), self, null, 0);
    }
    fn deinit(self: *Server) void {
        self.quitting = true;
        if (self.settings) |settings| settings.destroy();
        if (self.notifications) |notifications| notifications.destroy();
        if (c.g_network_monitor_get_default()) |monitor| _ = c.g_signal_handlers_disconnect_matched(monitor, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
        for (self.subscriptions.items) |id| c.g_dbus_connection_signal_unsubscribe(self.connection, id);
        self.cancelRequests(null);
        while (self.requests.items.len > 0) _ = c.g_main_context_iteration(null, 1);
        if (self.printing) |printing| printing.destroy();
        while (self.sessions.items.len > 0) self.closeSession(self.sessions.items[0]);
        for (self.registrations.items) |id| _ = c.g_dbus_connection_unregister_object(self.connection, id);
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
    fn getClient(self: *Server, sender: [*:0]const u8) !*Client {
        for (self.clients.items) |item| if (eq(item.sender, std.mem.span(sender))) return item;
        if (self.clients.items.len >= 128) return error.TooManyClients;
        const reply = c.g_dbus_connection_call_sync(self.connection, bus, bus_path, bus, "GetConnectionUnixProcessID", c.g_variant_new("(s)", sender), @ptrCast(@as([*:0]const u8, "(u)")), 0, 1000, null, null) orelse return error.UnknownClient;
        defer c.g_variant_unref(reply);
        const value = child(reply, 0);
        defer c.g_variant_unref(value);
        const pid = c.g_variant_get_uint32(value);
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
        item.sender = try alloc.dupeSentinel(u8, std.mem.span(sender), 0);
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
        _ = c.g_dbus_connection_emit_signal(self.connection, item.owner, item.handle, public ++ "Session", "Closed", tuple(&.{dict()}), null);
        for (self.sessions.items, 0..) |current, i| if (current == item) {
            _ = self.sessions.swapRemove(i);
            break;
        };
        item.destroy();
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
        item.registration = c.g_dbus_connection_register_object(self.connection, item.handle, self.info(public ++ "Session"), &session_vtable, item, null, null);
        if (item.registration == 0) return error.SessionRegistrationFailed;
        errdefer _ = c.g_dbus_connection_unregister_object(self.connection, item.registration);
        try self.sessions.append(a, item);
        return item;
    }
    fn ownerChanged(_: ?*c.GDBusConnection, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, params: ?*c.GVariant, data: ?*anyopaque) callconv(.c) void {
        const self = cast(Server, data);
        const name = child(params, 0);
        defer c.g_variant_unref(name);
        const owner = child(params, 2);
        defer c.g_variant_unref(owner);
        if (text(owner).len != 0) return;
        if (!std.mem.startsWith(u8, text(name), ":")) return;
        self.cancelRequests(text(name));
        self.printing.?.removeOwner(text(name));
        var i: usize = 0;
        while (i < self.sessions.items.len) {
            const item = self.sessions.items[i];
            if (eq(item.owner, text(name))) self.closeSession(item) else i += 1;
        }
        for (self.clients.items, 0..) |client_info, index| if (eq(client_info.sender, text(name))) {
            _ = self.clients.swapRemove(index);
            client_info.destroy();
            break;
        };
    }
    fn networkChanged(_: ?*c.GNetworkMonitor, _: c.gboolean, data: ?*anyopaque) callconv(.c) void {
        const self = cast(Server, data);
        _ = c.g_dbus_connection_emit_signal(self.connection, null, path, public ++ "NetworkMonitor", "changed", null, null);
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
    registration: c.guint = 0,
    kind: Kind,
    invocation: ?*c.GDBusMethodInvocation = null,
    closed: bool = false,
    inhibitor_fd: c_int = -1,
    dialog: ?*FileChooser = null,
    account: ?*Account = null,
    screenshot: ?*Capture.Operation = null,
    picker: ?*Capture.Picker = null,
    idle: c.guint = 0,
    print_operation: ?*Printing.Operation = null,

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
            item.registration = c.g_dbus_connection_register_object(server.connection, item.handle, server.info(public ++ "Request"), &request_vtable, item, null, null);
            if (item.registration == 0) return error.RequestRegistrationFailed;
        }
        errdefer if (item.registration != 0) {
            _ = c.g_dbus_connection_unregister_object(server.connection, item.registration);
        };
        try server.requests.append(a, item);
        return item;
    }
    fn close(self: *Request) void {
        if (self.closed) return;
        self.closed = true;
        if (self.registration != 0) {
            _ = c.g_dbus_connection_unregister_object(self.server.connection, self.registration);
            self.registration = 0;
        }
        c.g_cancellable_cancel(self.cancel);
        if (self.session_handle) |handle| if (self.server.session(handle, self.owner)) |session_info| {
            session_info.pending = null;
            self.server.closeSession(session_info);
        };
        if (self.kind == .dialog) {
            if (self.print_operation) |operation| if (operation.pending()) return;
            self.destroy();
            return;
        }
        if (self.kind == .inhibit and self.inhibitor_fd >= 0) {
            _ = libc.close(self.inhibitor_fd);
            self.destroy();
            return;
        }
    }
    fn destroy(self: *Request) void {
        if (self.idle != 0) _ = c.g_source_remove(self.idle);
        if (self.picker) |picker| picker.destroy();
        if (self.session_handle) |handle| if (self.server.session(handle, self.owner)) |session_info| {
            if (session_info.pending == self) session_info.pending = null;
        };
        if (self.dialog) |dialog| dialog.destroy();
        if (self.account) |dialog| dialog.destroy();
        if (self.screenshot) |operation| operation.destroy();
        if (self.print_operation) |operation| operation.destroy();
        if (self.registration != 0) _ = c.g_dbus_connection_unregister_object(self.server.connection, self.registration);
        if (self.invocation) |invocation| c.g_object_unref(invocation);
        c.g_object_unref(self.cancel);
        for (self.server.requests.items, 0..) |item, index| if (item == self) {
            _ = self.server.requests.swapRemove(index);
            break;
        };
        self.arena.deinit();
        a.destroy(self);
    }
    fn respond(self: *Request, code: u32, results: ?*c.GVariant) void {
        if (!self.closed and !self.server.quitting) _ = c.g_dbus_connection_emit_signal(self.server.connection, self.owner, self.handle, public ++ "Request", "Response", tuple(&.{ c.g_variant_new("u", code), results }), null) else {
            c.g_variant_unref(c.g_variant_take_ref(results));
        }
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
    fn inhibitorFinished(source: [*c]c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self = cast(Request, data);
        var fds: [*c]c.GUnixFDList = null;
        const reply = c.g_dbus_connection_call_with_unix_fd_list_finish(@ptrCast(source), &fds, result, null);
        defer if (reply != null) c.g_variant_unref(reply);
        defer if (fds != null) c.g_object_unref(fds);
        if (!self.closed and !self.server.quitting and reply != null and fds != null) {
            const handle = child(reply, 0);
            defer c.g_variant_unref(handle);
            self.inhibitor_fd = c.g_unix_fd_list_get(fds, c.g_variant_get_handle(handle), null);
            if (self.inhibitor_fd >= 0) return;
        }
        self.respond(2, dict());
        self.destroy();
    }
    fn networkFinished(_: [*c]c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
        const self = cast(Request, data);
        defer self.destroy();
        var err: ?*c.GError = null;
        const ok = c.g_network_monitor_can_reach_finish(c.g_network_monitor_get_default(), result, &err);
        defer if (err != null) c.g_error_free(err);
        if (!self.closed and !self.server.quitting) c.g_dbus_method_invocation_return_value(self.invocation, c.g_variant_new("(b)", ok)) else errorReply(self.invocation, "Request cancelled");
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

fn screencast(server: *Server, client_info: *Client, method: []const u8, params: ?*c.GVariant, invocation: ?*c.GDBusMethodInvocation) !void {
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
    c.g_dbus_method_invocation_return_value(invocation, tuple(&.{object(request.handle)}));
}
fn screenshot(server: *Server, client_info: *Client, method: []const u8, params: ?*c.GVariant, invocation: ?*c.GDBusMethodInvocation) !void {
    const parent = child(params, 0);
    defer c.g_variant_unref(parent);
    const options = child(params, 1);
    defer c.g_variant_unref(options);
    const request = try Request.create(server, client_info, "Screenshot", method, options, .dialog);
    errdefer request.destroy();
    request.screenshot = try Capture.Operation.create(a, client_info.app, std.mem.span(c.g_variant_get_string(parent, null)), method, options.?, &Request.dialogFinished, request);
    c.g_dbus_method_invocation_return_value(invocation, tuple(&.{object(request.handle)}));
}
fn chooseFile(server: *Server, client_info: *Client, method: []const u8, params: ?*c.GVariant, invocation: ?*c.GDBusMethodInvocation) !void {
    const parent = child(params, 0);
    defer c.g_variant_unref(parent);
    const title = child(params, 1);
    defer c.g_variant_unref(title);
    const options = child(params, 2);
    defer c.g_variant_unref(options);
    const request = try Request.create(server, client_info, "FileChooser", method, options, .dialog);
    errdefer request.destroy();
    request.dialog = try FileChooser.create(a, method, std.mem.span(c.g_variant_get_string(parent, null)), std.mem.span(c.g_variant_get_string(title, null)), options.?, &Request.dialogFinished, request);
    c.g_dbus_method_invocation_return_value(invocation, tuple(&.{object(request.handle)}));
}
fn userInformation(server: *Server, client_info: *Client, params: ?*c.GVariant, invocation: ?*c.GDBusMethodInvocation) !void {
    const parent = child(params, 0);
    defer c.g_variant_unref(parent);
    const options = child(params, 1);
    defer c.g_variant_unref(options);
    const request = try Request.create(server, client_info, "Account", "GetUserInformation", options, .dialog);
    errdefer request.destroy();
    request.account = try Account.create(a, client_info.app, std.mem.span(c.g_variant_get_string(parent, null)), options.?, &Request.dialogFinished, request);
    c.g_dbus_method_invocation_return_value(invocation, tuple(&.{object(request.handle)}));
}
fn openRemote(server: *Server, client_info: *Client, params: ?*c.GVariant, invocation: ?*c.GDBusMethodInvocation) !void {
    const handle = child(params, 0);
    defer c.g_variant_unref(handle);
    const session_info = server.session(text(handle), client_info.sender) orelse return error.InvalidSession;
    if (session_info.state != .started) return error.InvalidSessionState;
    // Host clients already have access to this socket. Sandboxed callers are
    // rejected before dispatch rather than receiving an unrestricted remote.
    const runtime = c.g_getenv("XDG_RUNTIME_DIR") orelse return error.NoRuntimeDirectory;
    const remote: [*c]const u8 = c.g_getenv("PIPEWIRE_REMOTE") orelse @as([*c]const u8, "pipewire-0");
    var address = std.mem.zeroes(libc.struct_sockaddr_un);
    address.sun_family = libc.AF_UNIX;
    const socket_path = if (std.mem.startsWith(u8, std.mem.span(remote), "/")) try std.fmt.bufPrint(&address.sun_path, "{s}", .{remote}) else try std.fmt.bufPrint(&address.sun_path, "{s}/{s}", .{ runtime, remote });
    if (socket_path.len >= address.sun_path.len) return error.SocketPathTooLong;
    const fd = libc.socket(libc.AF_UNIX, libc.SOCK_STREAM | libc.SOCK_CLOEXEC, 0);
    if (fd < 0) return error.PipeWireUnavailable;
    defer _ = libc.close(fd);
    if (libc.connect(fd, @ptrCast(&address), @intCast(@offsetOf(libc.struct_sockaddr_un, "sun_path") + socket_path.len + 1)) != 0) return error.PipeWireUnavailable;
    const fds = c.g_unix_fd_list_new();
    defer c.g_object_unref(fds);
    const index = c.g_unix_fd_list_append(fds, fd, null);
    if (index < 0) return error.FileDescriptorFailed;
    c.g_dbus_method_invocation_return_value_with_unix_fd_list(invocation, c.g_variant_new("(h)", index), fds);
}
fn openUri(server: *Server, client_info: *Client, method: []const u8, params: ?*c.GVariant, invocation: ?*c.GDBusMethodInvocation) !void {
    const arg = child(params, if (eq(method, "SchemeSupported")) 0 else 1);
    defer c.g_variant_unref(arg);
    if (eq(method, "SchemeSupported")) {
        const app_info = c.g_app_info_get_default_for_uri_scheme(c.g_variant_get_string(arg, null));
        defer if (app_info != null) c.g_object_unref(app_info);
        c.g_dbus_method_invocation_return_value(invocation, c.g_variant_new("(b)", @as(c_int, @intFromBool(app_info != null))));
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
        const fds = c.g_dbus_message_get_unix_fd_list(c.g_dbus_method_invocation_get_message(invocation));
        if (fds == null) return error.MissingFileDescriptor;
        const fd = c.g_unix_fd_list_get(fds, c.g_variant_get_handle(arg), null);
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
    c.g_dbus_method_invocation_return_value(invocation, tuple(&.{object(request.handle)}));
    c.g_app_info_launch_default_for_uri_async(uri, null, request.cancel, &Request.uriFinished, request);
}
fn printDocument(server: *Server, client_info: *Client, method: []const u8, params: ?*c.GVariant, invocation: ?*c.GDBusMethodInvocation) !void {
    const prepare = eq(method, "PreparePrint");
    const parent = child(params, 0);
    defer c.g_variant_unref(parent);
    const title = child(params, 1);
    defer c.g_variant_unref(title);
    const settings = if (prepare) child(params, 2) else null;
    defer if (settings != null) c.g_variant_unref(settings);
    const page = if (prepare) child(params, 3) else null;
    defer if (page != null) c.g_variant_unref(page);
    const fd = if (prepare) null else child(params, 2);
    defer if (fd != null) c.g_variant_unref(fd);
    const options = child(params, if (prepare) 4 else 3);
    defer c.g_variant_unref(options);
    const request = try Request.create(server, client_info, "Print", method, options, .dialog);
    errdefer request.destroy();
    const descriptors = c.g_dbus_message_get_unix_fd_list(c.g_dbus_method_invocation_get_message(invocation));
    request.print_operation = try Printing.Operation.create(server.printing.?, client_info.sender, std.mem.span(c.g_variant_get_string(parent, null)), std.mem.span(c.g_variant_get_string(title, null)), settings, page, options.?, descriptors, if (fd != null) c.g_variant_get_handle(fd) else null, &Request.dialogFinished, request);
    c.g_dbus_method_invocation_return_value(invocation, tuple(&.{object(request.handle)}));
}
fn composeEmail(server: *Server, client_info: *Client, params: ?*c.GVariant, invocation: ?*c.GDBusMethodInvocation) !void {
    const options = child(params, 1);
    defer c.g_variant_unref(options);
    const request = try Request.create(server, client_info, "Email", "ComposeEmail", options, .uri);
    errdefer request.destroy();
    const descriptors = c.g_dbus_message_get_unix_fd_list(c.g_dbus_method_invocation_get_message(invocation));
    const uri = try Email.composeUri(request.arena.allocator(), options.?, descriptors);
    const context = try Email.launchContext(options.?);
    defer c.g_object_unref(context);
    c.g_dbus_method_invocation_return_value(invocation, tuple(&.{object(request.handle)}));
    c.g_app_info_launch_default_for_uri_async(uri, context, request.cancel, &Request.uriFinished, request);
}
fn inhibit(server: *Server, client_info: *Client, params: ?*c.GVariant, invocation: ?*c.GDBusMethodInvocation) !void {
    const flags_value = child(params, 1);
    defer c.g_variant_unref(flags_value);
    const flags = c.g_variant_get_uint32(flags_value);
    if (flags == 0 or flags & ~@as(u32, 15) != 0 or flags & 2 != 0) return error.NotSupported;
    const options = child(params, 2);
    defer c.g_variant_unref(options);
    const request = try Request.create(server, client_info, "Inhibit", "Inhibit", options, .inhibit);
    errdefer request.destroy();
    const connection = c.g_bus_get_sync(c.G_BUS_TYPE_SYSTEM, null, null) orelse return error.SystemBusUnavailable;
    defer c.g_object_unref(connection);
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
    buffer[used] = 0;
    const reason = c.g_variant_lookup_value(options, "reason", @ptrCast(@as([*:0]const u8, "s")));
    defer if (reason != null) c.g_variant_unref(reason);
    const why: [*c]const u8 = if (reason != null) c.g_variant_get_string(reason, null) else "Application requested inhibition";
    c.g_dbus_method_invocation_return_value(invocation, tuple(&.{object(request.handle)}));
    c.g_dbus_connection_call_with_unix_fd_list(connection, "org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager", "Inhibit", c.g_variant_new("(ssss)", @as([*:0]const u8, @ptrCast(&buffer)), request.app.ptr, why, @as([*:0]const u8, "block")), @ptrCast(@as([*:0]const u8, "(h)")), 0, 10000, null, request.cancel, &Request.inhibitorFinished, request);
}
fn network(server: *Server, client_info: *Client, method: []const u8, params: ?*c.GVariant, invocation: ?*c.GDBusMethodInvocation) !void {
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
        request.invocation = @ptrCast(c.g_object_ref(invocation));
        c.g_network_monitor_can_reach_async(c.g_network_monitor_get_default(), address, request.cancel, &Request.networkFinished, request);
        return;
    }
    const monitor = c.g_network_monitor_get_default();
    const available = c.g_network_monitor_get_network_available(monitor);
    const metered = c.g_network_monitor_get_network_metered(monitor);
    const connectivity = c.g_network_monitor_get_connectivity(monitor);
    var answer: ?*c.GVariant = null;
    if (eq(method, "GetAvailable")) answer = c.g_variant_new("(b)", available) else if (eq(method, "GetMetered")) answer = c.g_variant_new("(b)", metered) else if (eq(method, "GetConnectivity")) answer = c.g_variant_new("(u)", connectivity) else if (eq(method, "GetStatus")) {
        const builder = c.g_variant_builder_new(@ptrCast(@as([*:0]const u8, "a{sv}")));
        defer c.g_variant_builder_unref(builder);
        c.g_variant_builder_add(builder, "{sv}", @as([*:0]const u8, "available"), c.g_variant_new("b", available));
        c.g_variant_builder_add(builder, "{sv}", @as([*:0]const u8, "metered"), c.g_variant_new("b", metered));
        c.g_variant_builder_add(builder, "{sv}", @as([*:0]const u8, "connectivity"), c.g_variant_new("u", connectivity));
        answer = tuple(&.{c.g_variant_builder_end(builder)});
    } else return error.NotSupported;
    c.g_dbus_method_invocation_return_value(invocation, answer);
}
fn methodCall(_: ?*c.GDBusConnection, sender: [*c]const u8, _: [*c]const u8, interface_name: [*c]const u8, method_name: [*c]const u8, params: ?*c.GVariant, invocation: ?*c.GDBusMethodInvocation, data: ?*anyopaque) callconv(.c) void {
    dispatch(cast(Server, data), sender, std.mem.span(interface_name), std.mem.span(method_name), params, invocation) catch |err| {
        c.g_dbus_method_invocation_return_dbus_error(invocation, if (err == error.SandboxedClientUnsupported) "org.freedesktop.portal.Error.NotAllowed" else if (err == error.NotSupported) "org.freedesktop.portal.Error.NotSupported" else "org.freedesktop.portal.Error.InvalidArgument", @errorName(err));
    };
}
fn dispatch(server: *Server, sender: [*:0]const u8, interface: []const u8, method: []const u8, params: ?*c.GVariant, invocation: ?*c.GDBusMethodInvocation) !void {
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
        c.g_dbus_method_invocation_return_value(invocation, null);
        return;
    }
    const short = interface[public.len..];
    if (eq(short, "Account")) return userInformation(server, client_info, params, invocation);
    if (eq(short, "FileChooser")) return chooseFile(server, client_info, method, params, invocation);
    if (eq(short, "Settings")) {
        server.settings.?.call(method, params, invocation);
        return;
    }
    if (eq(short, "Notification")) {
        const id_value = child(params, 0);
        defer c.g_variant_unref(id_value);
        const id: [:0]const u8 = std.mem.span(c.g_variant_get_string(id_value, null));
        if (eq(method, "AddNotification")) {
            const contents = child(params, 1);
            defer c.g_variant_unref(contents);
            try server.notifications.?.add(client_info.sender, client_info.app, id, contents.?);
        } else server.notifications.?.remove(client_info.sender, id);
        c.g_dbus_method_invocation_return_value(invocation, null);
        return;
    }
    if (eq(short, "Print")) return printDocument(server, client_info, method, params, invocation);
    if (eq(short, "Email")) return composeEmail(server, client_info, params, invocation);
    if (eq(short, "Inhibit")) return inhibit(server, client_info, params, invocation);
    if (eq(short, "OpenURI")) return openUri(server, client_info, method, params, invocation);
    if (eq(short, "NetworkMonitor")) return network(server, client_info, method, params, invocation);
    if (eq(short, "ScreenCast") and eq(method, "OpenPipeWireRemote")) return openRemote(server, client_info, params, invocation);
    if (eq(short, "Screenshot")) return screenshot(server, client_info, method, params, invocation);
    if (eq(short, "ScreenCast")) return screencast(server, client_info, method, params, invocation);
    return error.NotSupported;
}
fn getProperty(_: ?*c.GDBusConnection, _: [*c]const u8, _: [*c]const u8, interface_name: [*c]const u8, property: [*c]const u8, _: [*c][*c]c.GError, _: ?*anyopaque) callconv(.c) ?*c.GVariant {
    const short = std.mem.span(interface_name)[public.len..];
    if (eq(std.mem.span(property), "version")) {
        const version: c_uint = if (eq(short, "Settings") or eq(short, "Screenshot")) 2 else if (eq(short, "ScreenCast") or eq(short, "FileChooser") or eq(short, "NetworkMonitor")) 3 else if (eq(short, "OpenURI")) 5 else if (eq(short, "Email") or eq(short, "Print")) 4 else 1;
        return c.g_variant_new("u", version);
    }
    if (eq(short, "Notification")) return dict();
    if (eq(short, "ScreenCast")) return c.g_variant_new("u", @as(c_uint, if (eq(std.mem.span(property), "AvailableSourceTypes")) 1 else 3));
    return null;
}
fn closeRequest(_: ?*c.GDBusConnection, sender: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: ?*c.GVariant, invocation: ?*c.GDBusMethodInvocation, data: ?*anyopaque) callconv(.c) void {
    const request = cast(Request, data);
    if (!eq(request.owner, std.mem.span(sender))) {
        errorReply(invocation, "Request belongs to another client");
        return;
    }
    request.close();
    c.g_dbus_method_invocation_return_value(invocation, null);
}
fn closeSession(_: ?*c.GDBusConnection, sender: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: ?*c.GVariant, invocation: ?*c.GDBusMethodInvocation, data: ?*anyopaque) callconv(.c) void {
    const session_info = cast(Session, data);
    if (!eq(session_info.owner, std.mem.span(sender))) {
        errorReply(invocation, "Session belongs to another client");
        return;
    }
    const server = session_info.server;
    server.closeSession(session_info);
    c.g_dbus_method_invocation_return_value(invocation, null);
}
const main_vtable = c.GDBusInterfaceVTable{ .method_call = &methodCall, .get_property = &getProperty };
const request_vtable = c.GDBusInterfaceVTable{ .method_call = &closeRequest };
const session_vtable = c.GDBusInterfaceVTable{ .method_call = &closeSession };
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
    const connection = c.g_bus_get_sync(c.G_BUS_TYPE_SESSION, null, null) orelse return error.SessionBusUnavailable;
    defer c.g_object_unref(connection);
    const node = c.g_dbus_node_info_new_for_xml(@embedFile("desktop-portal.xml"), null) orelse return error.InvalidPortalXml;
    defer c.g_dbus_node_info_unref(node);
    var server = Server{ .connection = connection, .node = node };
    defer server.deinit();
    try server.start();
    const reply = c.g_dbus_connection_call_sync(connection, bus, bus_path, bus, "RequestName", c.g_variant_new("(su)", @as([*:0]const u8, "org.freedesktop.portal.Desktop"), @as(c_uint, 4)), @ptrCast(@as([*:0]const u8, "(u)")), 0, 1000, null, null) orelse return error.PortalNameUnavailable;
    defer c.g_variant_unref(reply);
    const status = child(reply, 0);
    defer c.g_variant_unref(status);
    if (c.g_variant_get_uint32(status) != 1) return error.PortalNameUnavailable;
    const term = c.g_unix_signal_add(c.SIGTERM, &quit, &server);
    const interrupt = c.g_unix_signal_add(c.SIGINT, &quit, &server);
    defer {
        _ = c.g_source_remove(term);
        _ = c.g_source_remove(interrupt);
    }
    while (!server.quitting and c.g_dbus_connection_is_closed(connection) == 0) _ = c.g_main_context_iteration(null, 1);
}
