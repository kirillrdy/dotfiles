//! Small terminal greeter. Authentication and session creation belong to greetd.
//! Wire format: greetd-ipc(7), a native-endian u32 followed by UTF-8 JSON.
const std = @import("std");
const c = @import("desktop-libc.zig");
const allocator = std.heap.page_allocator;
var stopped = std.atomic.Value(bool).init(false);
fn signal(_: c_int) callconv(.c) void {
    stopped.store(true, .monotonic);
}
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn wipe(bytes: []u8) void {
    std.crypto.secureZero(u8, bytes);
}
fn writeAll(fd: c_int, bytes: []const u8, socket: bool) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        if (stopped.load(.monotonic)) return error.Interrupted;
        const n = if (socket) c.send(fd, bytes[offset..].ptr, bytes.len - offset, c.MSG_NOSIGNAL) else c.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (n < 0) {
            if (c.__errno_location().* == c.EINTR) continue;
            return error.WriteFailed;
        }
        if (n == 0) return error.Disconnected;
        offset += @intCast(n);
    }
}
fn wait(fd: c_int, timeout: c_int) !bool {
    var descriptor = c.struct_pollfd{ .fd = fd, .events = c.POLLIN, .revents = 0 };
    while (true) {
        if (stopped.load(.monotonic)) return error.Interrupted;
        const n = c.poll(&descriptor, 1, timeout);
        if (n >= 0) return n > 0;
        if (c.__errno_location().* != c.EINTR) return error.ReadFailed;
    }
}
fn readExact(fd: c_int, bytes: []u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        // Bound a broken daemon's response time; signals remain interruptible.
        if (!try wait(fd, 120_000)) return error.Timeout;
        const n = c.read(fd, bytes[offset..].ptr, bytes.len - offset);
        if (n < 0) {
            if (c.__errno_location().* == c.EINTR) continue;
            return error.ReadFailed;
        }
        if (n == 0) return error.Disconnected;
        offset += @intCast(n);
    }
}
const Reply = struct {
    bytes: []u8,
    parsed: std.json.Parsed(std.json.Value),
    fn deinit(self: *Reply) void {
        self.parsed.deinit();
        wipe(self.bytes);
        allocator.free(self.bytes);
    }
    fn field(self: Reply, name: []const u8) ![]const u8 {
        if (self.parsed.value != .object) return error.InvalidReply;
        const value = self.parsed.value.object.get(name) orelse return error.InvalidReply;
        if (value != .string) return error.InvalidReply;
        return value.string;
    }
};
const Client = struct {
    fd: c_int,
    fn connect(path: []const u8) !Client {
        var address: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
        if (path.len == 0 or path.len >= address.sun_path.len) return error.InvalidSocketPath;
        address.sun_family = c.AF_UNIX;
        @memcpy(@as([*]u8, @ptrCast(&address.sun_path))[0..path.len], path);
        const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = c.close(fd);
        if (c.connect(fd, @ptrCast(&address), @sizeOf(c.struct_sockaddr_un)) != 0) return error.ConnectFailed;
        return .{ .fd = fd };
    }
    fn exchange(self: Client, request: anytype) !Reply {
        const message = try std.json.Stringify.valueAlloc(allocator, request, .{});
        defer {
            wipe(message);
            allocator.free(message);
        }
        var length: u32 = @intCast(message.len);
        try writeAll(self.fd, std.mem.asBytes(&length), true);
        try writeAll(self.fd, message, true);
        try readExact(self.fd, std.mem.asBytes(&length));
        if (length == 0 or length > 64 * 1024) return error.InvalidFrame;
        const bytes = try allocator.alloc(u8, length);
        errdefer allocator.free(bytes);
        try readExact(self.fd, bytes);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        return .{ .bytes = bytes, .parsed = parsed };
    }
    fn cancel(self: Client) !void {
        var reply = try self.exchange(.{ .type = "cancel_session" });
        defer reply.deinit();
        if (!eq(try reply.field("type"), "success")) return error.CancelFailed;
    }
};
const Session = struct { name: []const u8, command: []const u8 };
const Options = struct {
    sessions: std.ArrayList(Session) = .empty,
    remember: ?[:0]const u8 = null,
    clock: bool = false,
    fn parse(args: []const []const u8, a: std.mem.Allocator) !Options {
        var options = Options{};
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (eq(args[i], "--time")) {
                options.clock = true;
            } else if (eq(args[i], "--cmd") and i + 1 < args.len) {
                i += 1;
                if (!std.fs.path.isAbsolute(args[i])) return error.CommandMustBeAbsolute;
                try options.sessions.append(a, .{ .name = "Desktop", .command = args[i] });
            } else if (eq(args[i], "--session") and i + 1 < args.len) {
                i += 1;
                const split = std.mem.indexOfScalar(u8, args[i], '=') orelse return error.InvalidSession;
                const command = args[i][split + 1 ..];
                if (split == 0 or !std.fs.path.isAbsolute(command)) return error.InvalidSession;
                try options.sessions.append(a, .{ .name = args[i][0..split], .command = command });
            } else if (eq(args[i], "--remember-file") and i + 1 < args.len) {
                i += 1;
                options.remember = try a.dupeSentinel(u8, args[i], 0);
            } else return error.InvalidArguments;
        }
        if (options.sessions.items.len == 0) return error.MissingCommand;
        return options;
    }
};
const Terminal = struct {
    original: c.struct_termios,
    options: Options,
    session: usize = 0,
    username: [256]u8 = @splat(0),
    username_len: usize = 0,
    status: [4096]u8 = @splat(0),
    status_len: usize = 0,
    fn init(options: Options) !Terminal {
        var terminal = Terminal{ .original = undefined, .options = options };
        if (c.tcgetattr(0, &terminal.original) != 0 or c.isatty(1) == 0) return error.NoTerminal;
        var mode = terminal.original;
        c.cfmakeraw(&mode);
        mode.c_lflag |= c.ISIG;
        if (c.tcsetattr(0, c.TCSAFLUSH, &mode) != 0) return error.TerminalFailed;
        errdefer _ = c.tcsetattr(0, c.TCSAFLUSH, &terminal.original);
        try writeAll(1, "\x1b[?1049h\x1b[?25l", false);
        if (options.remember) |path| {
            const fd = c.open(path, c.O_RDONLY | c.O_CLOEXEC | c.O_NOFOLLOW);
            if (fd >= 0) {
                defer _ = c.close(fd);
                const n = c.read(fd, &terminal.username, terminal.username.len);
                if (n > 0 and n < terminal.username.len) {
                    const username = std.mem.trim(u8, terminal.username[0..@intCast(n)], " \r\n\t");
                    std.mem.copyForwards(u8, &terminal.username, username);
                    terminal.username_len = username.len;
                }
            }
        }
        return terminal;
    }
    fn deinit(self: *Terminal) void {
        // Restore even after SIGTERM/SIGINT, when writeAll would refuse to run.
        const restore = "\x1b[?25h\x1b[?1049l";
        _ = c.write(1, restore, restore.len);
        _ = c.tcsetattr(0, c.TCSAFLUSH, &self.original);
    }
    fn text(bytes: []const u8) !void {
        // PAM messages and remembered usernames must never inject terminal codes.
        for (bytes) |byte| {
            if (byte >= 32 and byte != 127) try writeAll(1, &.{byte}, false);
        }
    }
    fn setStatus(self: *Terminal, message: []const u8) void {
        self.status_len = @min(message.len, self.status.len);
        @memcpy(self.status[0..self.status_len], message[0..self.status_len]);
    }
    fn draw(self: *Terminal, prompt: []const u8, value: []const u8, secret: bool) !void {
        try writeAll(1, "\x1b[H\x1b[2J\r\n  Desktop Login\r\n", false);
        if (self.options.clock) {
            var now = c.time(null);
            var local: c.struct_tm = undefined;
            var date: [80]u8 = undefined;
            if (c.localtime_r(&now, &local) != null) {
                const n = c.strftime(&date, date.len, "  %a %d %b %Y  %H:%M:%S", &local);
                try writeAll(1, date[0..n], false);
            }
        }
        try writeAll(1, "\r\n\r\n  Session: ", false);
        try text(self.options.sessions.items[self.session].name);
        try writeAll(1, "\r\n  User: ", false);
        try text(self.username[0..self.username_len]);
        try writeAll(1, "\r\n\r\n  ", false);
        try text(self.status[0..self.status_len]);
        try writeAll(1, "\r\n\r\n  ", false);
        try text(prompt);
        try writeAll(1, " ", false);
        if (secret) {
            for (value) |byte| {
                if (byte & 0xc0 != 0x80) try writeAll(1, "*", false);
            }
        } else try text(value);
        try writeAll(1, "\r\n\r\n  Enter: continue   Esc: cancel   Ctrl-U: clear", false);
        if (self.options.sessions.items.len > 1) try writeAll(1, "   F2: session", false);
    }
    fn readByte(timeout: c_int) !?u8 {
        if (!try wait(0, timeout)) return null;
        var value: u8 = undefined;
        const n = c.read(0, &value, 1);
        if (n == 0) return error.TerminalClosed;
        if (n < 0) {
            if (c.__errno_location().* == c.EINTR) return null;
            return error.ReadFailed;
        }
        return value;
    }
    fn input(self: *Terminal, prompt: []const u8, secret: bool, buffer: []u8, initial: usize, choose_session: bool) !?[]const u8 {
        var length = initial;
        while (true) {
            try self.draw(prompt, buffer[0..length], secret);
            const key = try readByte(1000) orelse continue;
            switch (key) {
                10, 13 => return buffer[0..length],
                4 => return error.TerminalClosed,
                21 => {
                    wipe(buffer);
                    length = 0;
                },
                8, 127 => {
                    if (length > 0) {
                        length -= 1;
                        while (length > 0 and buffer[length] & 0xc0 == 0x80) : (length -= 1) {}
                        wipe(buffer[length..]);
                    }
                },
                27 => {
                    var sequence: [16]u8 = undefined;
                    var count: usize = 0;
                    while (count < sequence.len) {
                        sequence[count] = try readByte(40) orelse break;
                        count += 1;
                    }
                    if (count == 0) return null;
                    if (choose_session and (eq(sequence[0..count], "OQ") or eq(sequence[0..count], "[12~"))) self.session = (self.session + 1) % self.options.sessions.items.len;
                },
                else => if (key >= 32 and length < buffer.len) {
                    buffer[length] = key;
                    length += 1;
                },
            }
        }
    }
    fn remember(self: *Terminal) void {
        const path = self.options.remember orelse return;
        const fd = c.open(path, c.O_WRONLY | c.O_CREAT | c.O_TRUNC | c.O_CLOEXEC | c.O_NOFOLLOW, @as(c_uint, 0o600));
        if (fd < 0) return;
        defer _ = c.close(fd);
        writeAll(fd, self.username[0..self.username_len], false) catch {};
    }
};

fn authenticate(client: Client, terminal: *Terminal) !bool {
    var reply = try client.exchange(.{ .type = "create_session", .username = terminal.username[0..terminal.username_len] });
    defer reply.deinit();
    while (true) {
        const kind = try reply.field("type");
        if (eq(kind, "success")) return true;
        if (eq(kind, "error")) {
            terminal.setStatus(try reply.field("description"));
            try client.cancel();
            return false;
        }
        if (!eq(kind, "auth_message")) return error.InvalidReply;
        const message_type = try reply.field("auth_message_type");
        const message = try reply.field("auth_message");
        var next: Reply = undefined;
        if (eq(message_type, "secret") or eq(message_type, "visible")) {
            var answer: [4096]u8 = @splat(0);
            defer wipe(&answer);
            const response = try terminal.input(message, eq(message_type, "secret"), &answer, 0, false) orelse {
                try client.cancel();
                terminal.setStatus("Login cancelled");
                return false;
            };
            next = try client.exchange(.{ .type = "post_auth_message_response", .response = response });
        } else if (eq(message_type, "info") or eq(message_type, "error")) {
            terminal.setStatus(message);
            try terminal.draw("Authenticating...", "", false);
            next = try client.exchange(.{ .type = "post_auth_message_response", .response = @as(?[]const u8, null) });
        } else return error.InvalidReply;
        reply.deinit();
        reply = next;
    }
}
pub fn runArgs(init: std.process.Init, args: []const []const u8) !void {
    _ = init;
    // No credentials in core dumps; all authentication stays with greetd/PAM.
    if (c.prctl(c.PR_SET_DUMPABLE, @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0)) != 0) return error.PrctlFailed;
    const previous_term = c.signal(c.SIGTERM, &signal);
    defer _ = c.signal(c.SIGTERM, previous_term);
    const previous_int = c.signal(c.SIGINT, &signal);
    defer _ = c.signal(c.SIGINT, previous_int);
    const previous_hup = c.signal(c.SIGHUP, &signal);
    defer _ = c.signal(c.SIGHUP, previous_hup);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const options = try Options.parse(args, arena.allocator());
    const path = c.getenv("GREETD_SOCK") orelse return error.MissingGreetdSocket;
    const client = try Client.connect(std.mem.span(path));
    defer _ = c.close(client.fd);
    var terminal = try Terminal.init(options);
    defer terminal.deinit();
    while (true) {
        const username = try terminal.input("Username:", false, &terminal.username, terminal.username_len, true) orelse {
            terminal.username_len = 0;
            wipe(&terminal.username);
            terminal.setStatus("");
            continue;
        };
        terminal.username_len = username.len;
        if (username.len == 0) continue;
        if (!try authenticate(client, &terminal)) continue;
        var reply = try client.exchange(.{ .type = "start_session", .cmd = [_][]const u8{options.sessions.items[terminal.session].command}, .env = [_][]const u8{} });
        defer reply.deinit();
        if (eq(try reply.field("type"), "success")) {
            terminal.remember();
            return;
        }
        terminal.setStatus(try reply.field("description"));
        try client.cancel();
    }
}
