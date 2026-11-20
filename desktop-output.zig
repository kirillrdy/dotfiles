//! One-shot display scaling through wlr-output-management, independent of the shell daemon.
const std = @import("std");
const wl = @import("wayland-client");
const wire = @import("wayland-wire");
const a = std.heap.page_allocator;
fn milliseconds() i64 {
    return @divTrunc(@import("desktop-util.zig").monotonicTime(), 1000);
}

pub const Options = struct { name: []const u8, scale: i32 };
pub fn parse(args: []const []const u8) !Options {
    if (args.len != 4 or !std.mem.eql(u8, args[0], "--output") or args[1].len == 0 or
        !std.mem.eql(u8, args[2], "--scale")) return error.InvalidOutputArguments;
    const value = std.fmt.parseFloat(f64, args[3]) catch return error.InvalidOutputScale;
    const fixed = @round(value * 256);
    if (!std.math.isFinite(fixed) or fixed < 1 or fixed > std.math.maxInt(i32)) return error.InvalidOutputScale;
    return .{ .name = args[1], .scale = @intFromFloat(fixed) };
}
const Head = struct {
    proxy: wl.zwlr_output_head_v1,
    name: ?[]u8 = null,
    modes: std.ArrayList(wl.zwlr_output_mode_v1) = .empty,
    enabled: bool = false,
    alive: bool = true,
    fn headEvent(self: *Head, _: wl.zwlr_output_head_v1, event: wl.zwlr_output_head_v1.Event) void {
        switch (event) {
            .name => |value| self.name = a.dupe(u8, value.name) catch @panic("out of memory"),
            .mode => |value| self.modes.append(a, value.mode) catch @panic("out of memory"),
            .enabled => |value| self.enabled = value.enabled != 0,
            .finished => self.alive = false,
            else => {},
        }
    }
};
const Result = enum { pending, succeeded, failed, cancelled };
const Client = struct {
    manager: ?wl.zwlr_output_manager_v1 = null,
    manager_name: u32 = 0,
    heads: std.ArrayList(*Head) = .empty,
    serial: ?u32 = null,
    failure: ?anyerror = null,
    result: Result = .pending,
    listed: bool = false,

    fn registryEvent(self: *Client, registry: wl.wl_registry, event: wl.wl_registry.Event) void {
        switch (event) {
            .global => |value| {
                if (!std.mem.eql(u8, value.interface, "zwlr_output_manager_v1") or self.manager != null) return;
                // Version 1 supports scaling and preserves newer properties by inheritance.
                const manager = registry.bind(value.name, wl.zwlr_output_manager_v1, 1);
                self.manager = manager;
                self.manager_name = value.name;
                manager.listen(Client, self, managerEvent);
            },
            .global_remove => |value| if (self.manager_name == value.name) {
                self.failure = error.OutputManagerUnavailable;
            },
        }
    }
    fn managerEvent(self: *Client, _: wl.zwlr_output_manager_v1, event: wl.zwlr_output_manager_v1.Event) void {
        switch (event) {
            .head => |value| {
                const item = a.create(Head) catch @panic("out of memory");
                item.* = .{ .proxy = value.head };
                self.heads.append(a, item) catch @panic("out of memory");
                value.head.listen(Head, item, Head.headEvent);
            },
            .done => |value| self.serial = value.serial,
            .finished => self.failure = error.OutputManagerUnavailable,
        }
    }
    fn configurationEvent(self: *Client, _: wl.zwlr_output_configuration_v1, event: wl.zwlr_output_configuration_v1.Event) void {
        self.result = switch (event) {
            .succeeded => .succeeded,
            .failed => .failed,
            .cancelled => .cancelled,
        };
    }
    fn synced(self: *Client, _: wl.wl_callback, _: wl.wl_callback.Event) void {
        self.listed = true;
    }
    fn wait(self: *Client, connection: *wire.Connection, deadline: i64, snapshot: bool) !void {
        while (true) {
            if (self.failure) |err| return err;
            if (if (snapshot) self.serial != null else self.result != .pending) return;
            // Once the registry sync completes, a missing manager will never appear.
            if (snapshot and self.listed and self.manager == null) return error.OutputManagerUnavailable;
            const remaining = deadline - milliseconds();
            if (remaining <= 0) return error.OutputConfigurationTimedOut;
            _ = connection.dispatchTimeout(@intCast(remaining)) catch return error.WaylandDisconnected;
        }
    }
};

pub fn run(args: []const []const u8) !void {
    const options = try parse(args);
    const connection = wire.Connection.connect(a) catch return error.WaylandUnavailable;
    defer connection.deinit();
    var client = Client{};
    defer {
        for (client.heads.items) |item| {
            for (item.modes.items) |mode| mode.destroy();
            item.modes.deinit(a);
            item.proxy.destroy();
            if (item.name) |name| a.free(name);
            a.destroy(item);
        }
        client.heads.deinit(a);
        if (client.manager) |manager| manager.destroy();
    }
    const display: wl.wl_display = .{ .proxy = connection.display() };
    const registry = display.get_registry();
    defer registry.destroy();
    registry.listen(Client, &client, Client.registryEvent);
    const deadline = milliseconds() + 5000;
    // This sync follows registry enumeration, so a missing protocol fails promptly,
    // and a silent compositor still hits the deadline.
    display.sync().listen(Client, &client, Client.synced);
    try client.wait(connection, deadline, true);
    var selected: ?*Head = null;
    for (client.heads.items) |item| {
        if (item.alive and item.name != null and std.mem.eql(u8, item.name.?, options.name)) selected = item;
    }
    const target = selected orelse return error.OutputNotFound;
    if (!target.enabled) return error.OutputDisabled;
    const configuration = client.manager.?.create_configuration(client.serial.?);
    defer configuration.destroy();
    configuration.listen(Client, &client, Client.configurationEvent);
    for (client.heads.items) |item| {
        if (!item.alive) continue;
        if (!item.enabled) {
            configuration.disable_head(item.proxy);
            continue;
        }
        const head_configuration = configuration.enable_head(item.proxy);
        defer head_configuration.destroy();
        // Unset properties inherit current mode, position, transform and adaptive sync.
        if (item == target) head_configuration.set_scale(@as(f64, @floatFromInt(options.scale)) / 256);
    }
    configuration.apply();
    try client.wait(connection, deadline, false);
    switch (client.result) {
        .succeeded => {},
        .failed => return error.OutputConfigurationRejected,
        .cancelled => return error.OutputConfigurationCancelled,
        .pending => unreachable,
    }
}

test "scale is finite positive Wayland fixed point" {
    const options = try parse(&.{ "--output", "eDP-1", "--scale", "1.625" });
    try std.testing.expectEqual(@as(i32, 416), options.scale);
    for ([_][]const u8{ "0", "-1", "nan", "inf", "1e99", "0.00001", "8388608", "bad" }) |value| {
        try std.testing.expectError(error.InvalidOutputScale, parse(&.{ "--output", "eDP-1", "--scale", value }));
    }
    try std.testing.expectError(error.InvalidOutputArguments, parse(&.{}));
    try std.testing.expectError(error.InvalidOutputArguments, parse(&.{ "--output", "", "--scale", "1" }));
}
