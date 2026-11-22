//! Network availability from the kernel routing table over rtnetlink, with the
//! semantics of GIO's netlink GNetworkMonitor, which the portal used before:
//! the network is available when a default route exists, metering is unknown
//! (false), connectivity is full or local, and a host is reachable when one of
//! its addresses falls inside a known route.
const std = @import("std");
const linux = std.os.linux;
const c = @import("desktop-glib.zig");
const u = @import("desktop-util.zig");
const cast = c.__zig.cast;

const RTM_NEWROUTE = 24;
const RTM_DELROUTE = 25;
const RTM_GETROUTE = 26;
const NLMSG_ERROR = 2;
const NLMSG_DONE = 3;
const NLM_F_REQUEST = 0x1;
const NLM_F_DUMP = 0x300;
const RTMGRP_IPV4_ROUTE = 0x40;
const RTMGRP_IPV6_ROUTE = 0x400;
const RTN_UNREACHABLE = 7;
const RTA_DST = 1;
const RTA_OIF = 4;
const RTA_GATEWAY = 5;
const AF_INET = linux.AF.INET;
const AF_INET6 = linux.AF.INET6;

/// GNetworkConnectivity values.
pub const Connectivity = enum(u32) { local = 1, limited = 2, portal = 3, full = 4 };

pub const Address = struct {
    family: Family,
    bytes: [16]u8 = @splat(0),

    pub const Family = enum { ip4, ip6 };

    pub fn fromIp(address: std.Io.net.IpAddress) Address {
        return switch (address) {
            .ip4 => |value| .{ .family = .ip4, .bytes = value.bytes ++ @as([12]u8, @splat(0)) },
            .ip6 => |value| .{ .family = .ip6, .bytes = value.bytes },
        };
    }
};

/// A routed network: an address prefix of `len` bits.
pub const Network = struct {
    address: Address,
    len: u8,

    pub fn contains(self: Network, address: Address) bool {
        if (self.address.family != address.family) return false;
        const whole = self.len / 8;
        if (!std.mem.eql(u8, self.address.bytes[0..whole], address.bytes[0..whole])) return false;
        const rest: u3 = @intCast(self.len % 8);
        if (rest == 0) return true;
        const mask = ~(@as(u8, 0xff) >> rest);
        return self.address.bytes[whole] & mask == address.bytes[whole] & mask;
    }

    fn eql(self: Network, other: Network) bool {
        return self.len == other.len and self.address.family == other.address.family and std.mem.eql(u8, &self.address.bytes, &other.address.bytes);
    }
};

/// The set of routed networks, as GNetworkMonitorBase keeps it.
pub const Routes = struct {
    networks: std.ArrayList(Network) = .empty,

    pub fn deinit(self: *Routes, a: std.mem.Allocator) void {
        self.networks.deinit(a);
    }

    pub fn available(self: *const Routes) bool {
        for (self.networks.items) |network| if (network.len == 0) return true;
        return false;
    }

    pub fn reachable(self: *const Routes, address: Address) bool {
        for (self.networks.items) |network| if (network.contains(address)) return true;
        return false;
    }

    /// Applies route messages; returns whether the set changed.
    pub fn apply(self: *Routes, a: std.mem.Allocator, messages: []const u8) !bool {
        var changed = false;
        var offset: usize = 0;
        while (offset + @sizeOf(linux.nlmsghdr) <= messages.len) {
            const header = std.mem.bytesAsValue(linux.nlmsghdr, messages[offset..][0..@sizeOf(linux.nlmsghdr)]);
            const len: usize = header.len;
            if (len < @sizeOf(linux.nlmsghdr) or offset + len > messages.len) break;
            const kind: u16 = @backingInt(header.type);
            if (kind == RTM_NEWROUTE or kind == RTM_DELROUTE) {
                if (route(messages[offset + @sizeOf(linux.nlmsghdr) .. offset + len])) |network| {
                    if (kind == RTM_NEWROUTE) {
                        if (try self.add(a, network)) changed = true;
                    } else if (self.remove(network)) changed = true;
                }
            }
            offset += std.mem.alignForward(usize, len, 4);
        }
        return changed;
    }

    fn add(self: *Routes, a: std.mem.Allocator, network: Network) !bool {
        for (self.networks.items) |existing| if (existing.eql(network)) return false;
        try self.networks.append(a, network);
        return true;
    }

    fn remove(self: *Routes, network: Network) bool {
        for (self.networks.items, 0..) |existing, i| if (existing.eql(network)) {
            _ = self.networks.swapRemove(i);
            return true;
        };
        return false;
    }

    /// The network a route message describes, if GIO would track it.
    fn route(body: []const u8) ?Network {
        // struct rtmsg: family, dst_len, src_len, tos, table, protocol, scope, type, flags.
        if (body.len < 12) return null;
        const family: Address.Family = switch (body[0]) {
            AF_INET => .ip4,
            AF_INET6 => .ip6,
            else => return null,
        };
        const len = body[1];
        if (body[7] == RTN_UNREACHABLE) return null;
        if (len > @as(u8, if (family == .ip4) 32 else 128)) return null;
        var network: Network = .{ .address = .{ .family = family }, .len = len };
        var has_dst = false;
        var has_target = false;
        var offset: usize = 12;
        while (offset + 4 <= body.len) {
            const attr_len = std.mem.readInt(u16, body[offset..][0..2], .little);
            const attr_type = std.mem.readInt(u16, body[offset + 2 ..][0..2], .little);
            if (attr_len < 4 or offset + attr_len > body.len) break;
            const data = body[offset + 4 .. offset + attr_len];
            switch (attr_type) {
                RTA_DST => {
                    const size: usize = if (family == .ip4) 4 else 16;
                    if (data.len < size) return null;
                    @memcpy(network.address.bytes[0..size], data[0..size]);
                    has_dst = true;
                },
                RTA_GATEWAY, RTA_OIF => has_target = true,
                else => {},
            }
            offset += std.mem.alignForward(usize, attr_len, 4);
        }
        if (!has_dst and !has_target) return null;
        if (family == .ip6) {
            const bytes = network.address.bytes;
            // GIO ignores IPv6 link-local (fe80::/10) and multicast (ff00::/8) routes.
            if (bytes[0] == 0xff or (bytes[0] == 0xfe and bytes[1] & 0xc0 == 0x80)) return null;
        }
        return network;
    }
};

pub const Monitor = struct {
    allocator: std.mem.Allocator,
    fd: linux.fd_t,
    routes: Routes = .{},
    watch: c.guint = 0,
    idle: c.guint = 0,
    changed: *const fn (?*anyopaque) void,
    context: ?*anyopaque,

    /// Reads the current routes and then watches for changes on the GLib loop.
    pub fn create(a: std.mem.Allocator, changed: *const fn (?*anyopaque) void, context: ?*anyopaque) !*Monitor {
        const opened = linux.socket(linux.AF.NETLINK, linux.SOCK.RAW | linux.SOCK.CLOEXEC, linux.NETLINK.ROUTE);
        if (linux.errno(opened) != .SUCCESS) return error.NetlinkUnavailable;
        const fd: linux.fd_t = @intCast(opened);
        errdefer _ = linux.close(fd);
        var local: linux.sockaddr.nl = .{ .pid = 0, .groups = RTMGRP_IPV4_ROUTE | RTMGRP_IPV6_ROUTE };
        if (linux.errno(linux.bind(fd, @ptrCast(&local), @sizeOf(linux.sockaddr.nl))) != .SUCCESS) return error.NetlinkUnavailable;
        const self = try a.create(Monitor);
        errdefer a.destroy(self);
        self.* = .{ .allocator = a, .fd = fd, .changed = changed, .context = context };
        errdefer self.routes.deinit(a);
        try self.dump();
        const flags = linux.fcntl(fd, linux.F.GETFL, 0);
        _ = linux.fcntl(fd, linux.F.SETFL, flags | @as(usize, @as(u32, @bitCast(linux.O{ .NONBLOCK = true }))));
        self.watch = c.g_unix_fd_add(fd, c.G_IO_IN | c.G_IO_ERR | c.G_IO_HUP, &readable, self);
        return self;
    }

    pub fn destroy(self: *Monitor) void {
        if (self.watch != 0) _ = c.g_source_remove(self.watch);
        if (self.idle != 0) _ = c.g_source_remove(self.idle);
        _ = linux.close(self.fd);
        self.routes.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn available(self: *const Monitor) bool {
        return self.routes.available();
    }

    pub fn connectivity(self: *const Monitor) Connectivity {
        return if (self.available()) .full else .local;
    }

    fn dump(self: *Monitor) !void {
        // nlmsghdr followed by a zeroed rtmsg for every family.
        var request: [@sizeOf(linux.nlmsghdr) + 12]u8 align(4) = @splat(0);
        const header = std.mem.bytesAsValue(linux.nlmsghdr, request[0..@sizeOf(linux.nlmsghdr)]);
        header.* = .{ .len = request.len, .type = @fromBackingInt(@intCast(RTM_GETROUTE)), .flags = NLM_F_REQUEST | NLM_F_DUMP, .seq = 1, .pid = 0 };
        var kernel: linux.sockaddr.nl = .{ .pid = 0, .groups = 0 };
        if (linux.errno(linux.sendto(self.fd, &request, request.len, 0, @ptrCast(&kernel), @sizeOf(linux.sockaddr.nl))) != .SUCCESS) return error.NetlinkUnavailable;
        while (true) {
            var buffer: [32 * 1024]u8 align(4) = undefined;
            const got = try self.receive(&buffer) orelse continue;
            _ = try self.routes.apply(self.allocator, got);
            if (finished(got)) return;
        }
    }

    /// One datagram from the kernel; null for anything sent by another process.
    fn receive(self: *Monitor, buffer: []align(4) u8) !?[]const u8 {
        var source: linux.sockaddr.nl = undefined;
        var source_len: linux.socklen_t = @sizeOf(linux.sockaddr.nl);
        const got = linux.recvfrom(self.fd, buffer.ptr, buffer.len, 0, @ptrCast(&source), &source_len);
        switch (linux.errno(got)) {
            .SUCCESS => {},
            .INTR => return null,
            .AGAIN => return error.WouldBlock,
            else => return error.NetlinkFailed,
        }
        if (source.pid != 0) return null;
        return buffer[0..got];
    }

    fn finished(messages: []const u8) bool {
        var offset: usize = 0;
        while (offset + @sizeOf(linux.nlmsghdr) <= messages.len) {
            const header = std.mem.bytesAsValue(linux.nlmsghdr, messages[offset..][0..@sizeOf(linux.nlmsghdr)]);
            const kind: u16 = @backingInt(header.type);
            if (kind == NLMSG_DONE or kind == NLMSG_ERROR) return true;
            if (header.len < @sizeOf(linux.nlmsghdr)) return true;
            offset += std.mem.alignForward(usize, header.len, 4);
        }
        return false;
    }

    fn readable(_: c_int, condition: c.GIOCondition, data: ?*anyopaque) callconv(.c) c_int {
        const self = cast(Monitor, data);
        if (condition & (c.G_IO_ERR | c.G_IO_HUP) != 0) {
            self.watch = 0;
            return 0;
        }
        var buffer: [32 * 1024]u8 align(4) = undefined;
        while (true) {
            const got = (self.receive(&buffer) catch break) orelse continue;
            // An allocation failure loses one update, as a full socket buffer would.
            if (self.routes.apply(self.allocator, got) catch false) self.queueChanged();
        }
        return 1;
    }

    /// Coalesces a burst of route changes into one notification, as GIO does.
    fn queueChanged(self: *Monitor) void {
        if (self.idle == 0) self.idle = c.g_idle_add(&notify, self);
    }

    fn notify(data: ?*anyopaque) callconv(.c) c_int {
        const self = cast(Monitor, data);
        self.idle = 0;
        self.changed(self.context);
        return 0;
    }
};

/// An asynchronous reachability check: the host is resolved on a worker thread,
/// and its addresses are tested against the routes on the main loop. `done`
/// runs exactly once, on the main loop, after `start` returns.
pub const Reach = struct {
    allocator: std.mem.Allocator,
    monitor: ?*const Monitor,
    host: []u8,
    port: u16,
    addresses: [32]Address = undefined,
    count: usize = 0,
    done: *const fn (?*anyopaque, bool) void,
    context: ?*anyopaque,
    delivered: bool = false,
    /// Main-loop references: the worker's completion and a pending cancellation.
    refs: u8 = 1,

    /// With no monitor, every host is reachable, like GIO's fallback monitor.
    pub fn start(a: std.mem.Allocator, monitor: ?*const Monitor, host: []const u8, port: u16, done: *const fn (?*anyopaque, bool) void, context: ?*anyopaque) !*Reach {
        const self = try a.create(Reach);
        errdefer a.destroy(self);
        self.* = .{ .allocator = a, .monitor = monitor, .host = try a.dupe(u8, host), .port = port, .done = done, .context = context };
        errdefer a.free(self.host);
        const thread = try std.Thread.spawn(.{}, work, .{self});
        thread.detach();
        return self;
    }

    /// Answers false now; the worker finishes and frees the check later.
    pub fn cancel(self: *Reach) void {
        if (self.delivered) return;
        self.refs += 1;
        _ = c.g_idle_add(&cancelled, self);
    }

    /// Never calls `done`, for a caller that goes away first.
    pub fn abandon(self: *Reach) void {
        self.delivered = true;
    }

    fn work(self: *Reach) void {
        // IP literals need no lookup, and are not valid host names.
        if (std.Io.net.IpAddress.parse(self.host, self.port)) |address| {
            self.addresses[0] = Address.fromIp(address);
            self.count = 1;
        } else |_| if (std.Io.net.HostName.init(self.host)) |name| {
            var results: [32]std.Io.net.HostName.LookupResult = undefined;
            var queue: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&results);
            // With room for at least 16 results, lookup never blocks on the queue.
            if (name.lookup(u.io, &queue, .{ .port = self.port })) |_| {
                while (queue.getOneUncancelable(u.io)) |result| switch (result) {
                    .address => |address| if (self.count < self.addresses.len) {
                        self.addresses[self.count] = Address.fromIp(address);
                        self.count += 1;
                    },
                    .canonical_name => {},
                } else |_| {}
            } else |_| {}
        } else |_| {}
        _ = c.g_idle_add(&resolved, self);
    }

    fn resolved(data: ?*anyopaque) callconv(.c) c_int {
        const self = cast(Reach, data);
        const monitor = self.monitor orelse return self.finish(true);
        for (self.addresses[0..self.count]) |address| if (monitor.routes.reachable(address)) return self.finish(true);
        self.deliver(false);
        return 0;
    }

    fn finish(self: *Reach, ok: bool) c_int {
        self.deliver(ok);
        return 0;
    }

    fn cancelled(data: ?*anyopaque) callconv(.c) c_int {
        cast(Reach, data).deliver(false);
        return 0;
    }

    fn deliver(self: *Reach, ok: bool) void {
        if (!self.delivered) {
            self.delivered = true;
            self.done(self.context, ok);
        }
        self.refs -= 1;
        if (self.refs == 0) {
            self.allocator.free(self.host);
            self.allocator.destroy(self);
        }
    }
};

fn routeMessage(buffer: []u8, kind: u16, family: u8, len: u8, kind_of_route: u8, dst: ?[]const u8) []u8 {
    const total = @sizeOf(linux.nlmsghdr) + 12 + if (dst) |value| std.mem.alignForward(usize, 4 + value.len, 4) else 8;
    @memset(buffer[0..total], 0);
    std.mem.writeInt(u32, buffer[0..4], @intCast(total), .little);
    std.mem.writeInt(u16, buffer[4..6], kind, .little);
    const body = buffer[@sizeOf(linux.nlmsghdr)..];
    body[0] = family;
    body[1] = len;
    body[7] = kind_of_route;
    if (dst) |value| {
        std.mem.writeInt(u16, body[12..14], @intCast(4 + value.len), .little);
        std.mem.writeInt(u16, body[14..16], RTA_DST, .little);
        @memcpy(body[16..][0..value.len], value);
    } else {
        std.mem.writeInt(u16, body[12..14], 8, .little);
        std.mem.writeInt(u16, body[14..16], RTA_OIF, .little);
    }
    return buffer[0..total];
}

test "route messages build GIO's network set" {
    const a = std.testing.allocator;
    var routes: Routes = .{};
    defer routes.deinit(a);
    var buffer: [128]u8 align(4) = undefined;
    try std.testing.expect(try routes.apply(a, routeMessage(&buffer, RTM_NEWROUTE, AF_INET, 8, 2, &.{ 127, 0, 0, 0 })));
    try std.testing.expect(!try routes.apply(a, routeMessage(&buffer, RTM_NEWROUTE, AF_INET, 8, 2, &.{ 127, 0, 0, 0 })));
    try std.testing.expect(!routes.available());
    const loopback: Address = .{ .family = .ip4, .bytes = .{ 127, 0, 0, 1 } ++ @as([12]u8, @splat(0)) };
    const outside: Address = .{ .family = .ip4, .bytes = .{ 192, 0, 2, 1 } ++ @as([12]u8, @splat(0)) };
    try std.testing.expect(routes.reachable(loopback));
    try std.testing.expect(!routes.reachable(outside));
    // Ignored: unreachable routes, IPv6 link-local and multicast networks.
    try std.testing.expect(!try routes.apply(a, routeMessage(&buffer, RTM_NEWROUTE, AF_INET, 0, RTN_UNREACHABLE, null)));
    try std.testing.expect(!try routes.apply(a, routeMessage(&buffer, RTM_NEWROUTE, AF_INET6, 64, 1, &(.{ 0xfe, 0x80 } ++ @as([14]u8, @splat(0))))));
    try std.testing.expect(!try routes.apply(a, routeMessage(&buffer, RTM_NEWROUTE, AF_INET6, 8, 1, &(.{0xff} ++ @as([15]u8, @splat(0))))));
    // A default route through an interface makes everything of its family reachable.
    try std.testing.expect(try routes.apply(a, routeMessage(&buffer, RTM_NEWROUTE, AF_INET, 0, 1, null)));
    try std.testing.expect(routes.available());
    try std.testing.expect(routes.reachable(outside));
    try std.testing.expect(!routes.reachable(.{ .family = .ip6 }));
    try std.testing.expect(try routes.apply(a, routeMessage(&buffer, RTM_DELROUTE, AF_INET, 0, 1, null)));
    try std.testing.expect(!routes.available());
    const prefix: Network = .{ .address = .{ .family = .ip4, .bytes = .{ 10, 1, 128, 0 } ++ @as([12]u8, @splat(0)) }, .len = 17 };
    try std.testing.expect(prefix.contains(.{ .family = .ip4, .bytes = .{ 10, 1, 255, 9 } ++ @as([12]u8, @splat(0)) }));
    try std.testing.expect(!prefix.contains(.{ .family = .ip4, .bytes = .{ 10, 1, 127, 9 } ++ @as([12]u8, @splat(0)) }));
}

test "the kernel route table matches GIO's netlink monitor" {
    const glib = struct {
        extern fn g_setenv(variable: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
        extern fn g_network_monitor_get_default() ?*anyopaque;
        extern fn g_network_monitor_get_network_available(monitor: ?*anyopaque) c_int;
        extern fn g_network_monitor_get_connectivity(monitor: ?*anyopaque) u32;
        extern fn g_type_name_from_instance(instance: ?*anyopaque) [*:0]const u8;
    };
    const Counter = struct {
        fn changed(_: ?*anyopaque) void {}
    };
    const monitor = Monitor.create(std.testing.allocator, &Counter.changed, null) catch return error.SkipZigTest;
    defer monitor.destroy();
    _ = glib.g_setenv("GIO_USE_NETWORK_MONITOR", "netlink", 1);
    const reference = glib.g_network_monitor_get_default();
    if (!std.mem.eql(u8, std.mem.span(glib.g_type_name_from_instance(reference)), "GNetworkMonitorNetlink")) return error.SkipZigTest;
    try std.testing.expectEqual(glib.g_network_monitor_get_network_available(reference) != 0, monitor.available());
    try std.testing.expectEqual(glib.g_network_monitor_get_connectivity(reference), @backingInt(monitor.connectivity()));
}

test "reachability matches GIO's netlink monitor" {
    const glib = struct {
        extern fn g_setenv(variable: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
        extern fn g_network_monitor_get_default() ?*anyopaque;
        extern fn g_network_monitor_can_reach(monitor: ?*anyopaque, connectable: ?*anyopaque, cancellable: ?*anyopaque, err: ?*?*anyopaque) c_int;
        extern fn g_network_address_new(hostname: [*:0]const u8, port: u16) ?*anyopaque;
        extern fn g_type_name_from_instance(instance: ?*anyopaque) [*:0]const u8;
        extern fn g_object_unref(object: ?*anyopaque) void;
        extern fn g_clear_error(err: ?*?*anyopaque) void;
    };
    const Result = struct {
        value: ?bool = null,
        fn done(data: ?*anyopaque, ok: bool) void {
            cast(@This(), data).value = ok;
        }
        fn changed(_: ?*anyopaque) void {}
    };
    const monitor = Monitor.create(std.testing.allocator, &Result.changed, null) catch return error.SkipZigTest;
    defer monitor.destroy();
    _ = glib.g_setenv("GIO_USE_NETWORK_MONITOR", "netlink", 1);
    const reference = glib.g_network_monitor_get_default();
    if (!std.mem.eql(u8, std.mem.span(glib.g_type_name_from_instance(reference)), "GNetworkMonitorNetlink")) return error.SkipZigTest;
    for ([_][:0]const u8{ "localhost", "127.0.0.1", "::1", "192.0.2.1", "2001:db8::1", "10.255.255.1" }) |host| {
        const address = glib.g_network_address_new(host, 80);
        defer glib.g_object_unref(address);
        var err: ?*anyopaque = null;
        const expected = glib.g_network_monitor_can_reach(reference, address, null, &err) != 0;
        glib.g_clear_error(&err);
        var result: Result = .{};
        _ = try Reach.start(std.testing.allocator, monitor, host, 80, &Result.done, &result);
        while (result.value == null) _ = c.g_main_context_iteration(null, 1);
        std.testing.expectEqual(expected, result.value.?) catch |e| {
            std.debug.print("CanReach({s}) differs from GIO\n", .{host});
            return e;
        };
    }
}
