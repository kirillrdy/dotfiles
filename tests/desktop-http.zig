const std = @import("std");
const http = @import("../desktop-http.zig");
const io = std.testing.io;
const a = std.testing.allocator;

const Fixture = struct {
    server: std.Io.net.Server,
    response: []const u8,
    stall: bool = false,
    check_headers: bool = false,

    fn init(response: []const u8) !Fixture {
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        return .{ .server = try address.listen(io, .{ .mode = .stream }), .response = response };
    }
    fn serve(self: *Fixture) !void {
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
        return std.fmt.allocPrint(a, "http://127.0.0.1:{d}/usage", .{self.server.socket.address.getPort()});
    }
};

test "HTTP sends auth headers and reads bounded chunked responses" {
    var fixture = try Fixture.init("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n4\r\ntest\r\n0\r\n\r\n");
    defer fixture.server.deinit(io);
    fixture.check_headers = true;
    var worker = try io.concurrent(Fixture.serve, .{&fixture});
    defer worker.cancel(io) catch {};
    const url = try fixture.url();
    defer a.free(url);
    const response = try http.get(a, io, .{ .url = url, .use_proxy = false, .max_bytes = 4, .headers = &.{
        .{ .name = "Authorization", .value = "Bearer fixture-token" },
        .{ .name = "ChatGPT-Account-Id", .value = "fixture-account" },
    } });
    defer a.free(response.body);
    try std.testing.expectEqual(.ok, response.status);
    try std.testing.expectEqualStrings("test", response.body);
    try worker.await(io);
}

test "HTTP returns login failures and does not follow redirects" {
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
        const response = try http.get(a, io, .{ .url = url, .use_proxy = false });
        defer a.free(response.body);
        try std.testing.expectEqual(status, response.status);
        try worker.await(io);
    }
}

test "HTTP rejects oversized responses" {
    var fixture = try Fixture.init("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\n12345");
    defer fixture.server.deinit(io);
    var worker = try io.concurrent(Fixture.serve, .{&fixture});
    defer worker.cancel(io) catch {};
    const url = try fixture.url();
    defer a.free(url);
    try std.testing.expectError(error.StreamTooLong, http.get(a, io, .{ .url = url, .use_proxy = false, .max_bytes = 4 }));
    try worker.await(io);
}

test "HTTP deadline cancels a server that never responds" {
    var fixture = try Fixture.init("");
    defer fixture.server.deinit(io);
    fixture.stall = true;
    var worker = try io.concurrent(Fixture.serve, .{&fixture});
    defer worker.cancel(io) catch {};
    const url = try fixture.url();
    defer a.free(url);
    try std.testing.expectError(error.Timeout, http.get(a, io, .{ .url = url, .use_proxy = false, .timeout = .fromMilliseconds(100) }));
}
