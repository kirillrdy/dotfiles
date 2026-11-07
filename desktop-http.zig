//! Bounded HTTP requests for background desktop collectors.
const std = @import("std");

pub const Response = struct {
    status: std.http.Status,
    body: []u8,
};
pub const Options = struct {
    url: []const u8,
    headers: []const std.http.Header = &.{},
    timeout: std.Io.Duration = .fromSeconds(10),
    max_bytes: usize = 1024 * 1024,
    use_proxy: bool = true,
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
    var req = try client.request(.GET, try std.Uri.parse(options.url), .{
        .redirect_behavior = .unhandled,
        .keep_alive = false,
        .headers = .{
            .user_agent = .{ .override = "codex-cli" },
            .accept_encoding = .{ .override = "identity" },
        },
        // Redirects are disabled, so credentials remain on the original URL.
        .extra_headers = options.headers,
    });
    defer req.deinit();
    try req.sendBodiless();
    var response = try req.receiveHead(&.{});
    if (response.head.content_encoding != .identity) return error.UnsupportedEncoding;
    var transfer_buffer: [4096]u8 = undefined;
    const body = try response.reader(&transfer_buffer).allocRemaining(a, .limited(options.max_bytes));
    return .{ .status = response.head.status, .body = body };
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

test "HTTP sends auth headers and reads bounded chunked responses" {
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

test "HTTP returns login failures and does not follow redirects" {
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

test "HTTP rejects oversized responses" {
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

test "HTTP deadline cancels a server that never responds" {
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
