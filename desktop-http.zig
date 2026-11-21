//! Bounded HTTP requests for background desktop collectors.
const std = @import("std");

pub const Response = struct {
    status: std.http.Status,
    body: []u8,
    /// Seconds from a numeric Retry-After header; HTTP-date values are ignored.
    retry_after: ?u32 = null,
};
pub const Options = struct {
    url: []const u8,
    headers: []const std.http.Header = &.{},
    timeout: std.Io.Duration = .fromSeconds(10),
    max_bytes: usize = 1024 * 1024,
    use_proxy: bool = true,
    user_agent: []const u8 = "codex-cli",
    /// Sent as a POST body when set; otherwise the request is a bodiless GET.
    body: ?[]const u8 = null,
};

pub fn get(a: std.mem.Allocator, io: std.Io, options: Options) !Response {
    const Result = union(enum) { response: anyerror!Response, timeout: std.Io.Cancelable!void };
    var buffer: [2]Result = undefined;
    var pending = std.Io.Select(Result).init(io, &buffer);
    // A response can finish at the same time as the deadline. Drain and free
    // any unclaimed result after canceling, before the caller's allocator dies.
    defer while (pending.cancel()) |result| switch (result) {
        .response => |value| if (value) |response| a.free(response.body) else |_| {},
        .timeout => {},
    };
    try pending.concurrent(.timeout, deadline, .{ io, options.timeout });
    try pending.concurrent(.response, request, .{ a, io, options });
    return switch (try pending.await()) {
        .response => |response| response,
        .timeout => |result| blk: {
            try result;
            break :blk error.Timeout;
        },
    };
}

fn deadline(io: std.Io, duration: std.Io.Duration) std.Io.Cancelable!void {
    try io.sleep(duration, .awake);
}

fn request(a: std.mem.Allocator, io: std.Io, options: Options) !Response {
    var client = std.http.Client{ .allocator = a, .io = io };
    defer client.deinit();
    const environ = std.process.Environ{ .block = .{ .slice = std.mem.span(std.c.environ) } };
    var env = try environ.createMap(a);
    defer env.deinit();
    var proxy_arena = std.heap.ArenaAllocator.init(a);
    defer proxy_arena.deinit();
    if (options.use_proxy) try client.initDefaultProxies(proxy_arena.allocator(), &env);
    const uri = try std.Uri.parse(options.url);
    const connection = try connectBounded(&client, a, io, uri, options.timeout);
    var req = try client.request(if (options.body == null) .GET else .POST, uri, .{
        .redirect_behavior = .unhandled,
        .keep_alive = false,
        .connection = connection,
        .headers = .{
            .user_agent = .{ .override = options.user_agent },
            .accept_encoding = .{ .override = "identity" },
        },
        // Redirects are disabled, so credentials remain on the original URL.
        .extra_headers = options.headers,
    });
    defer req.deinit();
    if (options.body) |body| {
        // sendBodyComplete uses the body as its write buffer, so it must be mutable.
        const copy = try a.dupe(u8, body);
        defer a.free(copy);
        try req.sendBodyComplete(copy);
    } else try req.sendBodiless();
    var response = try req.receiveHead(&.{});
    if (response.head.content_encoding != .identity) return error.UnsupportedEncoding;
    // Head bytes are only valid until the body reader takes over the buffer.
    var retry_after: ?u32 = null;
    var headers = response.head.iterateHeaders();
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "retry-after")) retry_after = std.fmt.parseInt(u32, std.mem.trim(u8, header.value, " \t"), 10) catch null;
    }
    var transfer_buffer: [4096]u8 = undefined;
    const body = try response.reader(&transfer_buffer).allocRemaining(a, .limited(options.max_bytes));
    return .{ .status = response.head.status, .body = body, .retry_after = retry_after };
}

fn isLoopback(addr: std.Io.net.IpAddress) bool {
    return switch (addr) {
        .ip4 => |v4| v4.bytes[0] == 127,
        .ip6 => |v6| std.mem.eql(u8, &v6.bytes, &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 }),
    };
}

/// Probes resolved addresses with non-blocking sockets and `poll()` so a
/// blackholed IPv6 route or unreachable host fails at `timeout` instead of
/// stalling inside `HostName.connect` cancellation.
fn connectBounded(client: *std.http.Client, a: std.mem.Allocator, io: std.Io, uri: std.Uri, timeout: std.Io.Duration) !?*std.http.Client.Connection {
    const protocol = std.http.Client.Protocol.fromUri(uri) orelse return error.UnsupportedUriScheme;
    if ((protocol == .plain and client.http_proxy != null) or (protocol == .tls and client.https_proxy != null)) return null;
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host_name = std.Io.net.HostName.fromUri(uri, &host_buf) catch |err| switch (err) {
        error.UriMissingHost => return error.UriMissingHost,
        error.NameTooLong, error.InvalidHostName => return error.InvalidHostName,
    };
    const port: u16 = uri.port orelse switch (protocol) {
        .plain => 80,
        .tls => 443,
    };

    var addrs: [16]std.Io.net.IpAddress = undefined;
    var count: usize = 0;
    if (std.Io.net.IpAddress.parse(host_name.bytes, port)) |ip| {
        addrs[0] = ip;
        count = 1;
    } else |_| {
        var canon: [std.Io.net.HostName.max_len]u8 = undefined;
        var queue_buf: [32]std.Io.net.HostName.LookupResult = undefined;
        var queue: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&queue_buf);
        try host_name.lookup(io, &queue, .{ .port = port, .canonical_name_buffer = &canon });
        while (queue.getOne(io)) |entry| switch (entry) {
            .address => |ip| if (count < addrs.len) {
                addrs[count] = ip;
                count += 1;
            },
            .canonical_name => {},
        } else |_| {}
    }
    if (count == 0) return error.UnknownHostName;
    if (count == 1 and isLoopback(addrs[0])) return null;

    const winner = try probeAddresses(io, addrs[0..count], timeout);
    var ip_buf: [64]u8 = undefined;
    const ip_text = switch (winner) {
        .ip4 => |v4| try std.fmt.bufPrint(&ip_buf, "{d}.{d}.{d}.{d}", .{ v4.bytes[0], v4.bytes[1], v4.bytes[2], v4.bytes[3] }),
        .ip6 => |v6| blk: {
            var groups: [8]u16 = undefined;
            for (&groups, 0..) |*g, i| g.* = std.mem.readInt(u16, v6.bytes[i * 2 ..][0..2], .big);
            break :blk try std.fmt.bufPrint(&ip_buf, "{x}:{x}:{x}:{x}:{x}:{x}:{x}:{x}", .{
                groups[0], groups[1], groups[2], groups[3], groups[4], groups[5], groups[6], groups[7],
            });
        },
    };
    if (protocol == .tls) {
        const now = std.Io.Clock.real.now(io);
        try client.ca_bundle.rescan(a, io, now);
        client.now = now;
    }
    return try client.connectTcpOptions(.{
        .host = .{ .bytes = ip_text },
        .port = port,
        .protocol = protocol,
        .proxied_host = host_name,
        .proxied_port = port,
    });
}

fn probeAddresses(io: std.Io, addrs: []const std.Io.net.IpAddress, timeout: std.Io.Duration) !std.Io.net.IpAddress {
    var pollfds: [16]std.posix.pollfd = undefined;
    var indices: [16]usize = undefined;
    var poll_count: usize = 0;
    defer for (pollfds[0..poll_count]) |pfd| {
        if (pfd.fd >= 0) _ = std.c.close(pfd.fd);
    };

    for (addrs, 0..) |addr, idx| {
        var storage: std.posix.sockaddr.storage = std.mem.zeroes(std.posix.sockaddr.storage);
        const family: u32, const addr_len: std.posix.socklen_t = switch (addr) {
            .ip4 => |v4| blk: {
                const sa: *std.posix.sockaddr.in = @ptrCast(@alignCast(&storage));
                sa.* = .{
                    .family = std.posix.AF.INET,
                    .port = std.mem.nativeToBig(u16, v4.port),
                    .addr = @bitCast(v4.bytes),
                };
                break :blk .{ std.posix.AF.INET, @sizeOf(std.posix.sockaddr.in) };
            },
            .ip6 => |v6| blk: {
                const sa: *std.posix.sockaddr.in6 = @ptrCast(@alignCast(&storage));
                sa.* = .{
                    .family = std.posix.AF.INET6,
                    .port = std.mem.nativeToBig(u16, v6.port),
                    .flowinfo = v6.flow,
                    .addr = v6.bytes,
                    .scope_id = v6.interface.index,
                };
                break :blk .{ std.posix.AF.INET6, @sizeOf(std.posix.sockaddr.in6) };
            },
        };
        const fd = std.c.socket(family, std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC, 0);
        if (fd < 0) continue;
        const rc = std.c.connect(fd, @ptrCast(&storage), addr_len);
        if (rc == 0) {
            _ = std.c.close(fd);
            return addr;
        }
        if (std.posix.errno(rc) == .INPROGRESS) {
            pollfds[poll_count] = .{ .fd = fd, .events = std.posix.POLL.OUT, .revents = 0 };
            indices[poll_count] = idx;
            poll_count += 1;
        } else {
            _ = std.c.close(fd);
        }
    }
    if (poll_count == 0) return error.ConnectionRefused;

    const started = std.Io.Clock.awake.now(io);
    const limit_ns = timeout.toNanoseconds();
    var active = poll_count;
    while (active > 0) {
        const elapsed_ns = started.untilNow(io, .awake).toNanoseconds();
        if (elapsed_ns >= limit_ns) return error.Timeout;
        const remaining_ms: i32 = @intCast(@min(@as(i64, std.math.maxInt(i32)), @max(@as(i64, 1), @divTrunc(limit_ns - elapsed_ns, std.time.ns_per_ms))));
        const rc = std.c.poll(&pollfds, @intCast(poll_count), remaining_ms);
        if (rc == 0) return error.Timeout;
        if (rc < 0) {
            if (std.posix.errno(rc) == .INTR) continue;
            return error.Unexpected;
        }
        for (pollfds[0..poll_count], indices[0..poll_count]) |*pfd, idx| {
            if (pfd.fd < 0 or pfd.revents == 0) continue;
            var so_err: c_int = 0;
            var len: std.posix.socklen_t = @sizeOf(c_int);
            const ok = std.c.getsockopt(pfd.fd, std.posix.SOL.SOCKET, std.posix.SO.ERROR, &so_err, &len) == 0 and so_err == 0;
            _ = std.c.close(pfd.fd);
            pfd.fd = -1;
            active -= 1;
            if (ok) return addrs[idx];
        }
    }
    return error.ConnectionRefused;
}

const Fixture = struct {
    server: std.Io.net.Server,
    response: []const u8,
    stall: bool = false,
    check_headers: bool = false,

    fn init(response: []const u8) !Fixture {
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        return .{ .server = try address.listen(std.testing.io, .{ .mode = .stream }), .response = response };
    }
    fn serve(self: *Fixture) !void {
        const io = std.testing.io;
        const stream = try self.server.accept(io);
        defer stream.close(io);
        var buffer: [4096]u8 = undefined;
        var reader = stream.reader(io, &buffer);
        var bearer = false;
        var account = false;
        var user_agent = false;
        while (true) {
            const line = try reader.interface.takeDelimiterInclusive('\n');
            if (std.mem.eql(u8, line, "\r\n")) break;
            bearer = bearer or std.mem.indexOf(u8, line, "Bearer fixture-token") != null;
            account = account or std.mem.indexOf(u8, line, "fixture-account") != null;
            user_agent = user_agent or std.mem.indexOf(u8, line, "codex-cli") != null;
        }
        if (self.check_headers) try std.testing.expect(bearer and account and user_agent);
        if (self.stall) try io.sleep(.fromSeconds(30), .awake);
        var writer = stream.writer(io, &buffer);
        try writer.interface.writeAll(self.response);
        try writer.interface.flush();
    }
    fn url(self: *Fixture) ![]u8 {
        return std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/usage", .{self.server.socket.address.getPort()});
    }
};

test "integration: HTTP sends auth headers and reads bounded chunked responses" {
    if (!@import("options").integration_tests) return error.SkipZigTest;
    const io = std.testing.io;
    const a = std.testing.allocator;
    var fixture = try Fixture.init("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n4\r\ntest\r\n0\r\n\r\n");
    defer fixture.server.deinit(io);
    fixture.check_headers = true;
    var worker = try io.concurrent(Fixture.serve, .{&fixture});
    defer worker.cancel(io) catch {};
    const url = try fixture.url();
    defer a.free(url);
    const response = try get(a, io, .{ .url = url, .use_proxy = false, .max_bytes = 4, .headers = &.{
        .{ .name = "Authorization", .value = "Bearer fixture-token" },
        .{ .name = "ChatGPT-Account-Id", .value = "fixture-account" },
    } });
    defer a.free(response.body);
    try std.testing.expectEqual(.ok, response.status);
    try std.testing.expectEqualStrings("test", response.body);
    try worker.await(io);
}

test "integration: HTTP returns login failures and does not follow redirects" {
    if (!@import("options").integration_tests) return error.SkipZigTest;
    const io = std.testing.io;
    const a = std.testing.allocator;
    for ([_][]const u8{
        "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:1/credential-leak\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
    }, [_]std.http.Status{ .forbidden, .found }) |reply, status| {
        var fixture = try Fixture.init(reply);
        defer fixture.server.deinit(io);
        var worker = try io.concurrent(Fixture.serve, .{&fixture});
        defer worker.cancel(io) catch {};
        const url = try fixture.url();
        defer a.free(url);
        const response = try get(a, io, .{ .url = url, .use_proxy = false });
        defer a.free(response.body);
        try std.testing.expectEqual(status, response.status);
        try worker.await(io);
    }
}

test "integration: HTTP rejects oversized responses" {
    if (!@import("options").integration_tests) return error.SkipZigTest;
    const io = std.testing.io;
    const a = std.testing.allocator;
    var fixture = try Fixture.init("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\n12345");
    defer fixture.server.deinit(io);
    var worker = try io.concurrent(Fixture.serve, .{&fixture});
    defer worker.cancel(io) catch {};
    const url = try fixture.url();
    defer a.free(url);
    try std.testing.expectError(error.StreamTooLong, get(a, io, .{ .url = url, .use_proxy = false, .max_bytes = 4 }));
    try worker.await(io);
}

test "integration: HTTP deadline cancels a server that never responds" {
    if (!@import("options").integration_tests) return error.SkipZigTest;
    const io = std.testing.io;
    const a = std.testing.allocator;
    var fixture = try Fixture.init("");
    defer fixture.server.deinit(io);
    fixture.stall = true;
    var worker = try io.concurrent(Fixture.serve, .{&fixture});
    defer worker.cancel(io) catch {};
    const url = try fixture.url();
    defer a.free(url);
    try std.testing.expectError(error.Timeout, get(a, io, .{ .url = url, .use_proxy = false, .timeout = .fromMilliseconds(100) }));
}
