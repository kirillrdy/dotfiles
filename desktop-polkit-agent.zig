//! Polkit D-Bus agent. The root-owned system helper performs PAM and grants auth.
const std = @import("std");
const mainloop = @import("desktop-loop.zig");
const util = @import("desktop-util.zig");
const libc = @import("desktop-libc.zig");
const dbus = @import("dbus");
const loop = @import("desktop-dbus-loop.zig");
const Dialog = @import("desktop-polkit.zig").Dialog;
const name = "org.freedesktop.PolicyKit1";
const authority = name ++ ".Authority";
const authority_path = "/org/freedesktop/PolicyKit1/Authority";
const agent = name ++ ".AuthenticationAgent";
const path = "/org/dotfiles/PolicyKit1/AuthenticationAgent";
const xml = "<node><interface name='" ++ agent ++ "'><method name='BeginAuthentication'><arg type='s' direction='in'/><arg type='s' direction='in'/><arg type='s' direction='in'/><arg type='a{ss}' direction='in'/><arg type='s' direction='in'/><arg type='a(sa{sv})' direction='in'/></method><method name='CancelAuthentication'><arg type='s' direction='in'/></method></interface></node>";
const cast = util.cast;
const Details = dbus.Dict([]const u8, dbus.Value);
/// A polkit subject or identity: a kind with typed details, `(sa{sv})`.
const Identity = struct { []const u8, Details };
const BeginArgs = struct { []const u8, []const u8, []const u8, dbus.Dict([]const u8, []const u8), []const u8, []const Identity };

pub const Options = struct {
    socket_path: [:0]const u8 = "/run/polkit/agent-helper.socket",
    peer_uid: u32 = 0,
};
pub const Service = struct {
    state: *State,
    pub fn init(a: std.mem.Allocator) !Service {
        return initWithOptions(a, .{});
    }
    pub fn initWithOptions(a: std.mem.Allocator, options: Options) !Service {
        const source = loop.Source.open(a, .system) catch return error.PolicyKitUnavailable;
        errdefer source.destroy();
        var introspection = dbus.Introspection.parse(a, xml) catch unreachable;
        errdefer introspection.deinit();
        const self = try a.create(State);
        errdefer a.destroy(self);
        self.* = .{ .allocator = a, .options = options, .source = source, .introspection = introspection };
        errdefer if (self.owner) |owner| a.free(owner);
        try self.subject.find(source.connection);
        const connection = source.connection;
        self.registration = try connection.exportObject(path, &self.introspection.interfaces[0], &State.method, null, self);
        errdefer connection.unregister(self.registration);
        self.subscription = try connection.subscribeArg0("org.freedesktop.DBus", "org.freedesktop.DBus", "NameOwnerChanged", "/org/freedesktop/DBus", name, &State.ownerChanged, self);
        errdefer connection.unsubscribe(self.subscription);
        try self.register();
        self.timer = mainloop.timeoutSeconds(2, self, State.maintain);
        return .{ .state = self };
    }
    pub fn deinit(self: *Service) void {
        const state = self.state;
        const connection = state.source.connection;
        state.stopping = true;
        if (state.advance_source != 0) _ = mainloop.remove(state.advance_source);
        _ = mainloop.remove(state.timer);
        connection.unsubscribe(state.subscription);
        state.cancelAll();
        if (state.registered and state.owner != null) {
            if (connection.callBlocking(.{ .destination = state.owner.?, .path = authority_path, .interface = authority, .member = "UnregisterAuthenticationAgent" }, .{ state.subject.identity(), dbus.ObjectPath{ .value = path } }, 1000)) |result| result.deinit() else |_| {}
        }
        connection.unregister(state.registration);
        state.requests.deinit(state.allocator);
        if (state.owner) |owner| state.allocator.free(owner);
        state.source.destroy();
        state.introspection.deinit();
        state.allocator.destroy(state);
    }
};

/// The agent's polkit subject: its login session, or this process when there is none.
const Subject = struct {
    session: [64]u8 = undefined,
    session_len: usize = 0,
    start_time: u64 = 0,
    entries: [3]Details.Entry = undefined,

    fn find(self: *Subject, connection: *dbus.Connection) !void {
        if (sessionId(connection, &self.session)) |len| {
            self.session_len = len;
        } else if (std.c.getenv("XDG_SESSION_ID")) |id| {
            const value = std.mem.span(id);
            if (value.len > 0 and value.len <= self.session.len) {
                @memcpy(self.session[0..value.len], value);
                self.session_len = value.len;
            }
        }
        if (self.session_len > 0) return;
        var storage: [16 * 1024]u8 = undefined;
        var fixed: std.heap.FixedBufferAllocator = .init(&storage);
        const bytes = @import("desktop-paths.zig").readFile(fixed.allocator(), "/proc/self/stat", 4096) catch return error.PolicyKitUnavailable;
        const end = std.mem.lastIndexOfScalar(u8, bytes, ')') orelse return error.InvalidProcessStat;
        var fields = std.mem.tokenizeScalar(u8, bytes[end + 1 ..], ' ');
        for (0..19) |_| _ = fields.next() orelse return error.InvalidProcessStat;
        self.start_time = try std.fmt.parseInt(u64, fields.next() orelse return error.InvalidProcessStat, 10);
    }
    /// The logind session ID for this process, through GetSessionByPID and the session's Id property.
    fn sessionId(connection: *dbus.Connection, out: []u8) ?usize {
        const session = connection.callBlocking(.{ .destination = "org.freedesktop.login1", .path = "/org/freedesktop/login1", .interface = "org.freedesktop.login1.Manager", .member = "GetSessionByPID" }, .{@as(u32, @intCast(libc.getpid()))}, 1000) catch return null;
        defer session.deinit();
        const object = session.message().read(struct { dbus.ObjectPath }) catch return null;
        const id = connection.callBlocking(.{ .destination = "org.freedesktop.login1", .path = object[0].value, .interface = "org.freedesktop.DBus.Properties", .member = "Get" }, .{ "org.freedesktop.login1.Session", "Id" }, 1000) catch return null;
        defer id.deinit();
        const value = id.message().read(struct { dbus.Value }) catch return null;
        const text = switch (value[0]) {
            .string => |s| s,
            else => return null,
        };
        if (text.len == 0 or text.len > out.len) return null;
        @memcpy(out[0..text.len], text);
        return text.len;
    }
    /// The `(sa{sv})` subject; points into `self`, which must stay in place while it is used.
    fn identity(self: *Subject) Identity {
        if (self.session_len > 0) {
            self.entries[0] = .{ .key = "session-id", .value = .{ .string = self.session[0..self.session_len] } };
            return .{ "unix-session", .{ .entries = self.entries[0..1] } };
        }
        self.entries = .{
            .{ .key = "pid", .value = .{ .uint32 = @intCast(libc.getpid()) } },
            .{ .key = "uid", .value = .{ .int32 = @intCast(libc.getuid()) } },
            .{ .key = "start-time", .value = .{ .uint64 = self.start_time } },
        };
        return .{ "unix-process", .{ .entries = &self.entries } };
    }
};

const State = struct {
    allocator: std.mem.Allocator,
    options: Options,
    source: *loop.Source,
    introspection: dbus.Introspection,
    subject: Subject = .{},
    registration: u32 = 0,
    subscription: u32 = 0,
    timer: u32 = 0,
    advance_source: u32 = 0,
    owner: ?[:0]u8 = null,
    registered: bool = false,
    stopping: bool = false,
    cancelling: bool = false,
    requests: std.ArrayList(*Auth) = .empty,
    fn register(self: *State) !void {
        const connection = self.source.connection;
        const probe = connection.callBlocking(.{ .destination = name, .path = authority_path, .interface = "org.freedesktop.DBus.Introspectable", .member = "Introspect" }, .{}, 1500) catch return error.PolicyKitUnavailable;
        probe.deinit();
        const result = connection.callBlocking(.{ .destination = "org.freedesktop.DBus", .path = "/org/freedesktop/DBus", .interface = "org.freedesktop.DBus", .member = "GetNameOwner" }, .{name}, 1000) catch return error.PolicyKitUnavailable;
        defer result.deinit();
        const owner_name = result.message().read(struct { []const u8 }) catch return error.PolicyKitUnavailable;
        const owner = try self.allocator.dupeSentinel(u8, owner_name[0], 0);
        if (self.owner) |old| self.allocator.free(old);
        self.owner = owner;
        const locale: []const u8 = if (std.c.getenv("LANG")) |value| std.mem.span(value) else "C";
        const registered = connection.callBlocking(.{ .destination = owner, .path = authority_path, .interface = authority, .member = "RegisterAuthenticationAgent" }, .{ self.subject.identity(), locale, dbus.ObjectPath{ .value = path } }, 1500) catch return error.PolicyKitUnavailable;
        registered.deinit();
        self.registered = true;
    }
    fn maintain(self: *State) bool {
        if (!self.registered) self.register() catch {};
        return true;
    }
    fn cancelAll(self: *State) void {
        self.cancelling = true;
        while (self.requests.items.len > 0) self.requests.items[0].complete(false, true, "Authentication cancelled");
        self.cancelling = false;
    }
    fn ownerChanged(data: ?*anyopaque, message: *const dbus.Message) void {
        const self = cast(State, data);
        const change = message.read(struct { []const u8, []const u8, []const u8 }) catch return;
        if (self.owner) |current| if (std.mem.eql(u8, current, change[2])) return;
        self.registered = false;
        self.cancelAll();
        if (self.owner) |old| self.allocator.free(old);
        self.owner = null;
    }
    fn advance(self: *State) bool {
        self.advance_source = 0;
        if (!self.stopping and self.requests.items.len > 0 and self.requests.items[0].dialog == null) self.requests.items[0].start();
        return false;
    }
    fn replyError(self: *State, message: *const dbus.Message, text: []const u8) void {
        self.source.connection.replyError(message, name ++ ".Error.Failed", text) catch {};
    }
    fn method(data: ?*anyopaque, message: *const dbus.Message) void {
        const self = cast(State, data);
        const connection = self.source.connection;
        const sender = message.sender orelse "";
        if (!self.registered or self.owner == null or !std.mem.eql(u8, sender, self.owner.?)) return self.replyError(message, "Only the registered PolicyKit authority may authenticate");
        if (std.mem.eql(u8, message.member orelse "", "CancelAuthentication")) {
            const cookie = (message.read(struct { []const u8 }) catch return self.replyError(message, "Invalid cancellation"))[0];
            for (self.requests.items) |request| if (std.mem.eql(u8, request.cookie, cookie)) {
                request.complete(false, true, "Authentication cancelled by authority");
                connection.reply(message, .{}) catch {};
                return;
            };
            return self.replyError(message, "Unknown authentication cookie");
        }
        if (self.requests.items.len >= 8) return self.replyError(message, "Too many authentication requests");
        const request = Auth.create(self, message) catch return self.replyError(message, "Invalid authentication request");
        for (self.requests.items) |existing| if (std.mem.eql(u8, existing.cookie, request.cookie)) {
            request.destroy();
            return self.replyError(message, "Duplicate authentication cookie");
        };
        self.requests.append(self.allocator, request) catch {
            request.destroy();
            return self.replyError(message, "Could not allocate authentication request");
        };
        if (self.requests.items.len == 1) request.start();
    }
};
const Auth = struct {
    state: *State,
    arena: std.heap.ArenaAllocator,
    invocation: dbus.Invocation,
    action: [:0]const u8,
    message: [:0]const u8,
    cookie: [:0]const u8,
    username: [:0]const u8,
    dialog: ?Dialog = null,
    fd: c_int = -1,
    source: u32 = 0,
    write_source: u32 = 0,
    input: [16384]u8 = undefined,
    input_len: usize = 0,
    output: [8192]u8 = @splat(0),
    output_len: usize = 0,
    output_offset: usize = 0,
    attempts: u32 = 0,
    waiting: bool = false,
    fn create(state: *State, call: *const dbus.Message) !*Auth {
        const self = try state.allocator.create(Auth);
        errdefer state.allocator.destroy(self);
        var arena = std.heap.ArenaAllocator.init(state.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const args = try call.read(BeginArgs);
        var selected: ?u32 = null;
        for (args[5]) |identity| {
            if (!std.mem.eql(u8, identity[0], "unix-user")) continue;
            for (identity[1].entries) |entry| {
                if (!std.mem.eql(u8, entry.key, "uid")) continue;
                const value = switch (entry.value) {
                    .uint32 => |uid| uid,
                    else => continue,
                };
                if (selected == null or value == libc.getuid()) selected = value;
            }
        }
        const uid = selected orelse return error.UnsupportedIdentity;
        const passwd = libc.getpwuid(uid);
        if (passwd == null) return error.UnknownUser;
        const username = try a.dupeSentinel(u8, std.mem.span(passwd.*.pw_name), 0);
        if (std.mem.indexOfAny(u8, username, "\r\n") != null) return error.InvalidUser;
        const cookie = try a.dupeSentinel(u8, args[4], 0);
        if (cookie.len == 0 or cookie.len > 4096 or std.mem.indexOfAny(u8, cookie, "\r\n") != null) return error.InvalidCookie;
        var invocation = try state.source.connection.hold(call);
        errdefer invocation.release(state.allocator);
        self.* = .{ .state = state, .arena = arena, .invocation = invocation, .action = try a.dupeSentinel(u8, args[0], 0), .message = try a.dupeSentinel(u8, args[1], 0), .cookie = cookie, .username = username };
        return self;
    }
    fn start(self: *Auth) void {
        self.dialog = Dialog.create(self.state.allocator, self.action, self.message, self.username) catch {
            self.complete(false, false, "Could not create authentication dialog");
            return;
        };
        self.dialog.?.native.responded = &response;
        self.dialog.?.native.response_context = self;
        self.restart();
    }
    fn closeTransport(self: *Auth) void {
        if (self.source != 0) _ = mainloop.remove(self.source);
        if (self.write_source != 0) _ = mainloop.remove(self.write_source);
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
        self.dialog.?.setEnabled(false);
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
        self.source = mainloop.watch(self.fd, mainloop.IN | mainloop.ERR | mainloop.HUP, self, readable);
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
                    if (self.write_source == 0) self.write_source = mainloop.watch(self.fd, mainloop.OUT | mainloop.ERR | mainloop.HUP, self, writable);
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
    fn writable(self: *Auth, _: c_int, _: u32) bool {
        // Remove this source before flush can finish or dispose the request.
        self.write_source = 0;
        if (!self.flush()) return false;
        return false;
    }
    fn readable(self: *Auth, _: c_int, _: u32) bool {
        while (true) {
            if (self.input_len == self.input.len) {
                self.complete(false, false, "Authentication helper sent an oversized message");
                return false;
            }
            const count = libc.read(self.fd, self.input[self.input_len..].ptr, self.input.len - self.input_len);
            if (count < 0) {
                const err = libc.__errno_location().*;
                if (err == libc.EINTR) continue;
                if (err == 11) return true;
                self.complete(false, false, "Authentication helper read failed");
                return false;
            }
            if (count == 0) {
                self.complete(false, false, "Authentication helper disconnected");
                return false;
            }
            self.input_len += @intCast(count);
            while (std.mem.indexOfScalar(u8, self.input[0..self.input_len], '\n')) |end| {
                self.input[end] = 0;
                // Escapes decode in place: the result is never longer than the line.
                const decoded_line = unescape(self.input[0..end :0]);
                const live = self.line(decoded_line);
                if (!live) return false;
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
            self.dialog.?.setPrompt(prompt, echo) catch {
                self.complete(false, false, "Could not render authentication prompt");
                return false;
            };
            self.waiting = true;
        } else if (std.mem.startsWith(u8, value, "PAM_ERROR_MSG ")) {
            self.dialog.?.setError(value[14..]) catch {
                self.complete(false, false, "Could not render authentication error");
                return false;
            };
        } else if (std.mem.startsWith(u8, value, "PAM_TEXT_INFO ")) {
            self.dialog.?.setStatus(value[14..]) catch {
                self.complete(false, false, "Could not render authentication status");
                return false;
            };
        } else if (std.mem.eql(u8, value, "SUCCESS")) {
            self.complete(true, false, "");
            return false;
        } else if (std.mem.eql(u8, value, "FAILURE")) {
            if (self.attempts < 3) {
                self.dialog.?.setError("Authentication failed. Please try again.") catch {
                    self.complete(false, false, "Could not render authentication error");
                    return false;
                };
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
    fn response(data: ?*anyopaque, accepted: bool) void {
        const self = cast(Auth, data);
        if (!accepted) {
            self.complete(false, true, "Authentication cancelled");
            return;
        }
        if (!self.waiting or self.output_len != 0) return;
        const answer = self.dialog.?.answer();
        if (answer.len > self.output.len - 1 or std.mem.indexOfAny(u8, answer, "\r\n") != null) {
            self.dialog.?.setError("The authentication response is too long or contains a newline.") catch {
                self.complete(false, false, "Could not render authentication error");
                return;
            };
            self.dialog.?.clear();
            return;
        }
        @memcpy(self.output[0..answer.len], answer);
        self.output[answer.len] = '\n';
        self.output_len = answer.len + 1;
        self.waiting = false;
        self.dialog.?.clear();
        self.dialog.?.setEnabled(false);
        _ = self.flush();
    }
    fn complete(self: *Auth, success: bool, cancelled: bool, message: [*:0]const u8) void {
        const state = self.state;
        for (state.requests.items, 0..) |request, i| if (request == self) {
            _ = state.requests.orderedRemove(i);
            break;
        };
        const connection = state.source.connection;
        if (success) connection.answer(&self.invocation, .{}) catch {} else connection.answerError(&self.invocation, if (cancelled) name ++ ".Error.Cancelled" else name ++ ".Error.Failed", std.mem.span(message)) catch {};
        self.destroy();
        if (!state.stopping and !state.cancelling and state.requests.items.len > 0 and state.advance_source == 0) state.advance_source = mainloop.idle(state, State.advance);
    }
    fn destroy(self: *Auth) void {
        self.closeTransport();
        if (self.dialog) |*dialog| {
            dialog.destroy();
        }
        // Unanswered requests, such as duplicates, just release the held call.
        self.invocation.release(self.state.allocator);
        self.arena.deinit();
        self.state.allocator.destroy(self);
    }
};

/// Decodes C escapes in place, as g_strcompress: \b \f \n \r \t \v, octal
/// \ooo, and any other escaped byte as itself. A trailing backslash is dropped.
fn unescape(text: [:0]u8) [:0]u8 {
    var out: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '\\') {
            text[out] = text[i];
            out += 1;
            continue;
        }
        i += 1;
        if (i == text.len) break;
        text[out] = switch (text[i]) {
            'b' => 0x08,
            'f' => 0x0c,
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            'v' => 0x0b,
            '0'...'7' => octal: {
                var value: u8 = 0;
                var digits: usize = 0;
                while (digits < 3 and i < text.len and text[i] >= '0' and text[i] <= '7') : (digits += 1) {
                    value = value *% 8 +% (text[i] - '0');
                    i += 1;
                }
                i -= 1;
                break :octal value;
            },
            else => |byte| byte,
        };
        out += 1;
    }
    text.ptr[out] = 0;
    return text[0..out :0];
}

test "escape decoding handles C and octal escapes" {
    const cases = [_][2][:0]const u8{
        .{ "plain", "plain" },
        .{ "a\\nb\\tc", "a\nb\tc" },
        .{ "\\101\\0610x", "A10x" },
        .{ "\\\\\\\"q\\'", "\\\"q'" },
        .{ "\\b\\f\\r\\v", "\x08\x0c\r\x0b" },
    };
    for (cases) |case| {
        var copy: [64]u8 = undefined;
        @memcpy(copy[0..case[0].len], case[0]);
        copy[case[0].len] = 0;
        try std.testing.expectEqualSlices(u8, case[1], unescape(copy[0..case[0].len :0]));
    }
}
