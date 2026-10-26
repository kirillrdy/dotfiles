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
