//! Polkit D-Bus agent. The root-owned system helper performs PAM and grants auth.
const std = @import("std");
const c = @import("desktop-gtk.zig");
const libc = @import("desktop-libc.zig");
const Dialog = @import("desktop-polkit.zig").Dialog;
const name = "org.freedesktop.PolicyKit1";
const authority = name ++ ".Authority";
const authority_path = "/org/freedesktop/PolicyKit1/Authority";
const agent = name ++ ".AuthenticationAgent";
const path = "/org/dotfiles/PolicyKit1/AuthenticationAgent";
const xml = "<node><interface name='" ++ agent ++ "'><method name='BeginAuthentication'><arg type='s' direction='in'/><arg type='s' direction='in'/><arg type='s' direction='in'/><arg type='a{ss}' direction='in'/><arg type='s' direction='in'/><arg type='a(sa{sv})' direction='in'/></method><method name='CancelAuthentication'><arg type='s' direction='in'/></method></interface></node>";
const cast = c.__zig.cast;
fn text(value: ?*c.GVariant) [:0]const u8 {
    return std.mem.span(c.g_variant_get_string(value, null));
}
fn child(value: ?*c.GVariant, index: usize) *c.GVariant {
    return c.g_variant_get_child_value(value, index).?;
}
fn replyError(invocation: ?*c.GDBusMethodInvocation, cancelled: bool, message: [*:0]const u8) void {
    c.g_dbus_method_invocation_return_dbus_error(invocation, if (cancelled) name ++ ".Error.Cancelled" else name ++ ".Error.Failed", message);
}
pub const Options = struct {
    socket_path: [:0]const u8 = "/run/polkit/agent-helper.socket",
    peer_uid: u32 = 0,
};
pub const Service = struct {
    state: *State,
    pub fn init() !Service {
        return initWithOptions(std.heap.page_allocator, .{});
    }
    pub fn initWithOptions(a: std.mem.Allocator, options: Options) !Service {
        const connection = c.g_bus_get_sync(c.G_BUS_TYPE_SYSTEM, null, null) orelse return error.PolicyKitUnavailable;
        errdefer c.g_object_unref(connection);
        const node = c.g_dbus_node_info_new_for_xml(xml, null).?;
        errdefer c.g_dbus_node_info_unref(node);
        const self = try a.create(State);
        const process_subject = subject(connection) catch |err| {
            a.destroy(self);
            return err;
        };
        self.* = .{ .allocator = a, .options = options, .connection = connection, .node = node, .subject = process_subject };
        errdefer {
            c.g_variant_unref(self.subject);
            if (self.owner) |owner| a.free(owner);
            a.destroy(self);
        }
        self.registration = c.g_dbus_connection_register_object(connection, path, node.*.interfaces[0], &vtable, self, null, null);
        if (self.registration == 0) return error.PolicyKitUnavailable;
        errdefer _ = c.g_dbus_connection_unregister_object(connection, self.registration);
        self.subscription = c.g_dbus_connection_signal_subscribe(connection, "org.freedesktop.DBus", "org.freedesktop.DBus", "NameOwnerChanged", "/org/freedesktop/DBus", name, 0, &State.ownerChanged, self, null);
        errdefer c.g_dbus_connection_signal_unsubscribe(connection, self.subscription);
        try self.register();
        self.timer = c.g_timeout_add_seconds(2, &State.maintain, self);
        return .{ .state = self };
    }
    pub fn deinit(self: *Service) void {
        const state = self.state;
        state.stopping = true;
        if (state.advance_source != 0) _ = c.g_source_remove(state.advance_source);
        _ = c.g_source_remove(state.timer);
        c.g_dbus_connection_signal_unsubscribe(state.connection, state.subscription);
        state.cancelAll();
        if (state.registered and state.owner != null) {
            const result = c.g_dbus_connection_call_sync(state.connection, state.owner.?.ptr, authority_path, authority, "UnregisterAuthenticationAgent", c.g_variant_new("(@(sa{sv})o)", c.g_variant_ref(state.subject), @as([*:0]const u8, path)), null, 0, 1000, null, null);
            if (result != null) c.g_variant_unref(result);
        }
        _ = c.g_dbus_connection_unregister_object(state.connection, state.registration);
        state.requests.deinit(state.allocator);
        if (state.owner) |owner| state.allocator.free(owner);
        c.g_variant_unref(state.subject);
        c.g_dbus_node_info_unref(state.node);
        c.g_object_unref(state.connection);
        state.allocator.destroy(state);
    }
};
fn subject(connection: *c.GDBusConnection) !*c.GVariant {
    var session_id: ?[:0]const u8 = null;
    var owned_id: ?*c.GVariant = null;
    defer if (owned_id != null) c.g_variant_unref(owned_id);
    const session = c.g_dbus_connection_call_sync(connection, "org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager", "GetSessionByPID", c.g_variant_new("(u)", @as(c_uint, @intCast(libc.getpid()))), null, 0, 1000, null, null);
    if (session != null) {
        defer c.g_variant_unref(session);
        const object = child(session, 0);
        defer c.g_variant_unref(object);
        const result = c.g_dbus_connection_call_sync(connection, "org.freedesktop.login1", text(object), "org.freedesktop.DBus.Properties", "Get", c.g_variant_new("(ss)", @as([*:0]const u8, "org.freedesktop.login1.Session"), @as([*:0]const u8, "Id")), null, 0, 1000, null, null);
        if (result != null) {
            defer c.g_variant_unref(result);
            const wrapped = child(result, 0);
            defer c.g_variant_unref(wrapped);
            owned_id = c.g_variant_get_variant(wrapped);
            if (std.mem.eql(u8, std.mem.span(c.g_variant_get_type_string(owned_id)), "s")) session_id = text(owned_id);
        }
    }
    if (session_id == null) if (c.g_getenv("XDG_SESSION_ID")) |id| {
        if (id[0] != 0) session_id = std.mem.span(id);
    };
    const builder = c.g_variant_builder_new(@ptrCast(@as([*:0]const u8, "a{sv}")));
    defer c.g_variant_builder_unref(builder);
    if (session_id) |id| {
        c.g_variant_builder_add(builder, "{sv}", @as([*:0]const u8, "session-id"), c.g_variant_new("s", id.ptr));
    } else {
        var contents: [*c]u8 = null;
        var size: usize = 0;
        if (c.g_file_get_contents("/proc/self/stat", &contents, &size, null) == 0) return error.PolicyKitUnavailable;
        defer c.g_free(contents);
        const bytes = contents[0..size];
        const end = std.mem.lastIndexOfScalar(u8, bytes, ')') orelse return error.InvalidProcessStat;
        var fields = std.mem.tokenizeScalar(u8, bytes[end + 1 ..], ' ');
        for (0..19) |_| _ = fields.next() orelse return error.InvalidProcessStat;
        const start = try std.fmt.parseInt(u64, fields.next() orelse return error.InvalidProcessStat, 10);
        c.g_variant_builder_add(builder, "{sv}", @as([*:0]const u8, "pid"), c.g_variant_new("u", @as(c_uint, @intCast(libc.getpid()))));
        c.g_variant_builder_add(builder, "{sv}", @as([*:0]const u8, "uid"), c.g_variant_new("i", @as(c_int, @intCast(libc.getuid()))));
        c.g_variant_builder_add(builder, "{sv}", @as([*:0]const u8, "start-time"), c.g_variant_new("t", start));
    }
    return c.g_variant_take_ref(c.g_variant_new("(s@a{sv})", @as([*:0]const u8, if (session_id != null) "unix-session" else "unix-process"), c.g_variant_builder_end(builder))).?;
}
const State = struct {
    allocator: std.mem.Allocator,
    options: Options,
    connection: *c.GDBusConnection,
    node: *c.GDBusNodeInfo,
    subject: *c.GVariant,
    registration: c.guint = 0,
    subscription: c.guint = 0,
    timer: c.guint = 0,
    advance_source: c.guint = 0,
    owner: ?[:0]u8 = null,
    registered: bool = false,
    stopping: bool = false,
    cancelling: bool = false,
    requests: std.ArrayList(*Auth) = .empty,
    fn register(self: *State) !void {
        const probe = c.g_dbus_connection_call_sync(self.connection, name, authority_path, "org.freedesktop.DBus.Introspectable", "Introspect", null, null, 0, 1500, null, null) orelse return error.PolicyKitUnavailable;
        c.g_variant_unref(probe);
        const result = c.g_dbus_connection_call_sync(self.connection, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetNameOwner", c.g_variant_new("(s)", @as([*:0]const u8, name)), null, 0, 1000, null, null) orelse return error.PolicyKitUnavailable;
        defer c.g_variant_unref(result);
        const value = child(result, 0);
        defer c.g_variant_unref(value);
        const owner = try self.allocator.dupeSentinel(u8, text(value), 0);
        if (self.owner) |old| self.allocator.free(old);
        self.owner = owner;
        const locale = c.g_getenv("LANG") orelse @as([*c]const u8, "C");
        const registered = c.g_dbus_connection_call_sync(self.connection, owner, authority_path, authority, "RegisterAuthenticationAgent", c.g_variant_new("(@(sa{sv})so)", c.g_variant_ref(self.subject), locale, @as([*:0]const u8, path)), null, 0, 1500, null, null) orelse return error.PolicyKitUnavailable;
        c.g_variant_unref(registered);
        self.registered = true;
    }
    fn maintain(data: ?*anyopaque) callconv(.c) c_int {
        const self = cast(State, data);
        if (!self.registered) self.register() catch {};
        return 1;
    }
    fn cancelAll(self: *State) void {
        self.cancelling = true;
        while (self.requests.items.len > 0) self.requests.items[0].complete(false, true, "Authentication cancelled");
        self.cancelling = false;
    }
    fn ownerChanged(_: ?*c.GDBusConnection, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, params: ?*c.GVariant, data: ?*anyopaque) callconv(.c) void {
        const self = cast(State, data);
        const owner = child(params, 2);
        defer c.g_variant_unref(owner);
        if (self.owner) |current| if (std.mem.eql(u8, current, text(owner))) return;
        self.registered = false;
        self.cancelAll();
        if (self.owner) |old| self.allocator.free(old);
        self.owner = null;
    }
    fn advance(data: ?*anyopaque) callconv(.c) c_int {
        const self = cast(State, data);
        self.advance_source = 0;
        if (!self.stopping and self.requests.items.len > 0 and self.requests.items[0].dialog == null) self.requests.items[0].start();
        return 0;
    }
    fn method(_: ?*c.GDBusConnection, sender: [*c]const u8, _: [*c]const u8, _: [*c]const u8, method_name: [*c]const u8, params: ?*c.GVariant, invocation: ?*c.GDBusMethodInvocation, data: ?*anyopaque) callconv(.c) void {
        const self = cast(State, data);
        if (!self.registered or self.owner == null or !std.mem.eql(u8, std.mem.span(sender), self.owner.?)) {
            replyError(invocation, false, "Only the registered PolicyKit authority may authenticate");
            return;
        }
        if (std.mem.eql(u8, std.mem.span(method_name), "CancelAuthentication")) {
            const cookie = child(params, 0);
            defer c.g_variant_unref(cookie);
            for (self.requests.items) |request| if (std.mem.eql(u8, request.cookie, text(cookie))) {
                request.complete(false, true, "Authentication cancelled by authority");
                c.g_dbus_method_invocation_return_value(invocation, null);
                return;
            };
            replyError(invocation, false, "Unknown authentication cookie");
            return;
        }
        if (self.requests.items.len >= 8) {
            replyError(invocation, false, "Too many authentication requests");
            return;
        }
        const request = Auth.create(self, params.?, invocation.?) catch {
            replyError(invocation, false, "Invalid authentication request");
            return;
        };
        for (self.requests.items) |existing| if (std.mem.eql(u8, existing.cookie, request.cookie)) {
            request.destroy();
            replyError(invocation, false, "Duplicate authentication cookie");
            return;
        };
        self.requests.append(self.allocator, request) catch {
            request.destroy();
            replyError(invocation, false, "Could not allocate authentication request");
            return;
        };
        if (self.requests.items.len == 1) request.start();
    }
};
const vtable: c.GDBusInterfaceVTable = .{ .method_call = &State.method };
const Auth = struct {
    state: *State,
    arena: std.heap.ArenaAllocator,
    invocation: *c.GDBusMethodInvocation,
    action: [:0]const u8,
    message: [:0]const u8,
    icon: [:0]const u8,
    cookie: [:0]const u8,
    username: [:0]const u8,
    dialog: ?Dialog = null,
    fd: c_int = -1,
    source: c.guint = 0,
    write_source: c.guint = 0,
    input: [16384]u8 = undefined,
    input_len: usize = 0,
    output: [8192]u8 = @splat(0),
    output_len: usize = 0,
    output_offset: usize = 0,
    attempts: u32 = 0,
    waiting: bool = false,
    fn create(state: *State, params: *c.GVariant, invocation: *c.GDBusMethodInvocation) !*Auth {
        const self = try state.allocator.create(Auth);
        errdefer state.allocator.destroy(self);
        var arena = std.heap.ArenaAllocator.init(state.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const identities = child(params, 5);
        defer c.g_variant_unref(identities);
        var selected: ?u32 = null;
        for (0..c.g_variant_n_children(identities)) |index| {
            const id = child(identities, index);
            defer c.g_variant_unref(id);
            const kind = child(id, 0);
            defer c.g_variant_unref(kind);
            if (!std.mem.eql(u8, text(kind), "unix-user")) continue;
            const details = child(id, 1);
            defer c.g_variant_unref(details);
            const uid = c.g_variant_lookup_value(details, "uid", null) orelse continue;
            defer c.g_variant_unref(uid);
            if (!std.mem.eql(u8, std.mem.span(c.g_variant_get_type_string(uid)), "u")) continue;
            const value = c.g_variant_get_uint32(uid);
            if (selected == null or value == libc.getuid()) selected = value;
        }
        const uid = selected orelse return error.UnsupportedIdentity;
        const passwd = libc.getpwuid(uid);
        if (passwd == null) return error.UnknownUser;
        const username = try a.dupeSentinel(u8, std.mem.span(passwd.*.pw_name), 0);
        if (std.mem.indexOfAny(u8, username, "\r\n") != null) return error.InvalidUser;
        var strings: [4][:0]const u8 = undefined;
        for ([_]usize{ 0, 1, 2, 4 }, 0..) |index, dest| {
            const value = child(params, index);
            defer c.g_variant_unref(value);
            strings[dest] = try a.dupeSentinel(u8, text(value), 0);
        }
        if (strings[3].len == 0 or strings[3].len > 4096 or std.mem.indexOfAny(u8, strings[3], "\r\n") != null) return error.InvalidCookie;
        self.* = .{ .state = state, .arena = arena, .invocation = cast(c.GDBusMethodInvocation, c.g_object_ref(invocation)), .action = strings[0], .message = strings[1], .icon = strings[2], .cookie = strings[3], .username = username };
        return self;
    }
    fn start(self: *Auth) void {
        self.dialog = Dialog.create(self.action, self.message, self.username, if (self.icon.len > 0) self.icon else null);
        _ = c.g_signal_connect_data(self.dialog.?.window, "response", @ptrCast(&response), self, null, 0);
        self.restart();
    }
    fn closeTransport(self: *Auth) void {
        if (self.source != 0) _ = c.g_source_remove(self.source);
        if (self.write_source != 0) _ = c.g_source_remove(self.write_source);
        self.source = 0;
        self.write_source = 0;
        if (self.fd >= 0) _ = libc.close(self.fd);
        self.fd = -1;
        self.input_len = 0;
        self.output_len = 0;
        self.output_offset = 0;
        std.crypto.secureZero(u8, &self.output);
    }
    fn restart(self: *Auth) void {
        self.closeTransport();
        self.attempts += 1;
        self.waiting = false;
        c.gtk_widget_set_sensitive(self.dialog.?.entry, 0);
        c.gtk_widget_set_sensitive(self.dialog.?.auth_button, 0);
        var address = std.mem.zeroes(libc.struct_sockaddr_un);
        const endpoint = self.state.options.socket_path;
        if (endpoint.len >= address.sun_path.len) {
            self.complete(false, false, "Authentication helper path is too long");
            return;
        }
        address.sun_family = libc.AF_UNIX;
        @memcpy(address.sun_path[0..endpoint.len], endpoint);
        self.fd = libc.socket(libc.AF_UNIX, libc.SOCK_STREAM | libc.SOCK_CLOEXEC | @as(c_int, @intCast(std.c.SOCK.NONBLOCK)), 0);
        if (self.fd < 0 or libc.connect(self.fd, @ptrCast(&address), @intCast(@offsetOf(libc.struct_sockaddr_un, "sun_path") + endpoint.len + 1)) != 0) {
            self.complete(false, false, "Authentication helper is unavailable");
            return;
        }
        var peer: libc.struct_ucred = undefined;
        var size: libc.socklen_t = @sizeOf(libc.struct_ucred);
        if (libc.getsockopt(self.fd, libc.SOL_SOCKET, libc.SO_PEERCRED, &peer, &size) != 0 or size != @sizeOf(libc.struct_ucred) or peer.uid != self.state.options.peer_uid) {
            self.complete(false, false, "Authentication helper has an unexpected owner");
            return;
        }
        self.source = c.g_unix_fd_add(self.fd, c.G_IO_IN | c.G_IO_ERR | c.G_IO_HUP, &readable, self);
        const bytes = std.fmt.bufPrint(&self.output, "{s}\n{s}\n", .{ self.username, self.cookie }) catch {
            self.complete(false, false, "Authentication request is too large");
            return;
        };
        self.output_len = bytes.len;
        if (!self.flush()) return;
    }
    fn flush(self: *Auth) bool {
        while (self.output_offset < self.output_len) {
            const count = libc.send(self.fd, self.output[self.output_offset..self.output_len].ptr, self.output_len - self.output_offset, libc.MSG_NOSIGNAL);
            if (count < 0) {
                const err = libc.__errno_location().*;
                if (err == libc.EINTR) continue;
                if (err == 11) {
                    if (self.write_source == 0) self.write_source = c.g_unix_fd_add(self.fd, c.G_IO_OUT | c.G_IO_ERR | c.G_IO_HUP, &writable, self);
                    return true;
                }
                self.complete(false, false, "Could not contact authentication helper");
                return false;
            }
            if (count == 0) {
                self.complete(false, false, "Authentication helper disconnected");
                return false;
            }
            const end = self.output_offset + @as(usize, @intCast(count));
            std.crypto.secureZero(u8, self.output[self.output_offset..end]);
            self.output_offset = end;
        }
        self.output_offset = 0;
        self.output_len = 0;
        return true;
    }
    fn writable(_: c_int, _: c.GIOCondition, data: ?*anyopaque) callconv(.c) c_int {
        const self = cast(Auth, data);
        // Remove this source before flush can finish or dispose the request.
        self.write_source = 0;
        if (!self.flush()) return 0;
        return 0;
    }
    fn readable(_: c_int, _: c.GIOCondition, data: ?*anyopaque) callconv(.c) c_int {
        const self = cast(Auth, data);
        while (true) {
            if (self.input_len == self.input.len) {
                self.complete(false, false, "Authentication helper sent an oversized message");
                return 0;
            }
            const count = libc.read(self.fd, self.input[self.input_len..].ptr, self.input.len - self.input_len);
            if (count < 0) {
                const err = libc.__errno_location().*;
                if (err == libc.EINTR) continue;
                if (err == 11) return 1;
                self.complete(false, false, "Authentication helper read failed");
                return 0;
            }
            if (count == 0) {
                self.complete(false, false, "Authentication helper disconnected");
                return 0;
            }
            self.input_len += @intCast(count);
            while (std.mem.indexOfScalar(u8, self.input[0..self.input_len], '\n')) |end| {
                self.input[end] = 0;
                const decoded = c.g_strcompress(@ptrCast(self.input[0..end :0].ptr));
                const decoded_line = std.mem.span(decoded);
                const live = self.line(decoded_line);
                c.g_free(decoded);
                if (!live) return 0;
                const remaining = self.input_len - end - 1;
                std.mem.copyForwards(u8, self.input[0..remaining], self.input[end + 1 .. self.input_len]);
                self.input_len = remaining;
            }
        }
    }
    fn line(self: *Auth, value: [:0]const u8) bool {
        if (!std.unicode.utf8ValidateSlice(value)) {
            self.complete(false, false, "Authentication helper sent invalid text");
            return false;
        }
        const off = "PAM_PROMPT_ECHO_OFF ";
        const on = "PAM_PROMPT_ECHO_ON ";
        if (std.mem.startsWith(u8, value, off) or std.mem.startsWith(u8, value, on)) {
            const echo = std.mem.startsWith(u8, value, on);
            const prompt = value[if (echo) on.len else off.len..];
            const label = c.g_strdup_printf("%s (%s)", prompt.ptr, self.username.ptr);
            defer c.g_free(label);
            c.gtk_label_set_text(cast(c.GtkLabel, self.dialog.?.user_label.?), label);
            c.gtk_entry_set_visibility(cast(c.GtkEntry, self.dialog.?.entry), @intFromBool(echo));
            c.gtk_widget_set_sensitive(self.dialog.?.entry, 1);
            c.gtk_widget_set_sensitive(self.dialog.?.auth_button, 1);
            c.gtk_widget_grab_focus(self.dialog.?.entry);
            self.waiting = true;
        } else if (std.mem.startsWith(u8, value, "PAM_ERROR_MSG ")) {
            self.dialog.?.setError(value[14..]);
        } else if (std.mem.startsWith(u8, value, "PAM_TEXT_INFO ")) {
            c.gtk_label_set_text(cast(c.GtkLabel, self.dialog.?.error_label), value[14..].ptr);
            c.gtk_widget_show(self.dialog.?.error_label);
        } else if (std.mem.eql(u8, value, "SUCCESS")) {
            self.complete(true, false, "");
            return false;
        } else if (std.mem.eql(u8, value, "FAILURE")) {
            if (self.attempts < 3) {
                self.dialog.?.setError("Authentication failed. Please try again.");
                self.dialog.?.clear();
                self.restart();
            } else self.complete(false, false, "Authentication failed");
            return false;
        } else {
            self.complete(false, false, "Invalid authentication helper response");
            return false;
        }
        return true;
    }
    fn response(_: ?*c.GtkDialog, id: c_int, data: ?*anyopaque) callconv(.c) void {
        const self = cast(Auth, data);
        if (id != c.GTK_RESPONSE_OK) {
            self.complete(false, true, "Authentication cancelled");
            return;
        }
        if (!self.waiting or self.output_len != 0) return;
        const answer = std.mem.span(c.gtk_entry_get_text(cast(c.GtkEntry, self.dialog.?.entry)));
        if (answer.len > self.output.len - 1 or std.mem.indexOfAny(u8, answer, "\r\n") != null) {
            self.dialog.?.setError("The authentication response is too long or contains a newline.");
            self.dialog.?.clear();
            return;
        }
        @memcpy(self.output[0..answer.len], answer);
        self.output[answer.len] = '\n';
        self.output_len = answer.len + 1;
        self.waiting = false;
        self.dialog.?.clear();
        c.gtk_widget_set_sensitive(self.dialog.?.entry, 0);
        c.gtk_widget_set_sensitive(self.dialog.?.auth_button, 0);
        _ = self.flush();
    }
    fn complete(self: *Auth, success: bool, cancelled: bool, message: [*:0]const u8) void {
        const state = self.state;
        for (state.requests.items, 0..) |request, i| if (request == self) {
            _ = state.requests.orderedRemove(i);
            break;
        };
        if (success) c.g_dbus_method_invocation_return_value(self.invocation, null) else replyError(self.invocation, cancelled, message);
        self.destroy();
        if (!state.stopping and !state.cancelling and state.requests.items.len > 0 and state.advance_source == 0) state.advance_source = c.g_idle_add(&State.advance, state);
    }
    fn destroy(self: *Auth) void {
        self.closeTransport();
        if (self.dialog) |*dialog| {
            _ = c.g_signal_handlers_disconnect_matched(dialog.window, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
            dialog.destroy();
        }
        c.g_object_unref(self.invocation);
        self.arena.deinit();
        self.state.allocator.destroy(self);
    }
};
