//! One-shot display scaling through wlr-output-management, independent of the shell daemon.
const std = @import("std");
const c = @import("desktop-gtk.zig");
const p = @import("desktop-protocols.zig");
const a = std.heap.page_allocator;
const Proxy = c.wl_proxy;
extern const wl_callback_interface: c.wl_interface;

pub const Options = struct { name: []const u8, scale: i32 };
pub fn parse(args: []const []const u8) !Options {
    if (args.len != 4 or !std.mem.eql(u8, args[0], "--output") or args[1].len == 0 or
        !std.mem.eql(u8, args[2], "--scale")) return error.InvalidOutputArguments;
    const value = std.fmt.parseFloat(f64, args[3]) catch return error.InvalidOutputScale;
    const fixed = @round(value * 256);
    if (!std.math.isFinite(fixed) or fixed < 1 or fixed > std.math.maxInt(i32)) return error.InvalidOutputScale;
    return .{ .name = args[1], .scale = @intFromFloat(fixed) };
}
fn cast(comptime T: type, ptr: ?*anyopaque) *T {
    return @ptrCast(@alignCast(ptr));
}
fn request(proxy: *Proxy, opcode: u32, interface: ?*const c.wl_interface, flags: u32, args: []c.wl_argument) ?*Proxy {
    return c.wl_proxy_marshal_array_flags(proxy, opcode, interface, c.wl_proxy_get_version(proxy), flags, if (args.len == 0) null else args.ptr);
}
const Head = struct {
    proxy: *Proxy,
    name: ?[]u8 = null,
    modes: std.ArrayList(*Proxy) = .empty,
    enabled: bool = false,
    alive: bool = true,
    fn nameEvent(data: ?*anyopaque, _: ?*Proxy, name: [*:0]const u8) callconv(.c) void {
        const self = cast(Head, data);
        self.name = a.dupe(u8, std.mem.span(name)) catch @panic("out of memory");
    }
    fn text(_: ?*anyopaque, _: ?*Proxy, _: [*:0]const u8) callconv(.c) void {}
    fn pair(_: ?*anyopaque, _: ?*Proxy, _: i32, _: i32) callconv(.c) void {}
    fn mode(data: ?*anyopaque, _: ?*Proxy, proxy: *Proxy) callconv(.c) void {
        cast(Head, data).modes.append(a, proxy) catch @panic("out of memory");
        _ = c.wl_proxy_add_listener(proxy, @ptrCast(@constCast(&mode_listener)), null);
    }
    fn enabledEvent(data: ?*anyopaque, _: ?*Proxy, enabled: i32) callconv(.c) void {
        cast(Head, data).enabled = enabled != 0;
    }
    fn currentMode(_: ?*anyopaque, _: ?*Proxy, _: ?*Proxy) callconv(.c) void {}
    fn integer(_: ?*anyopaque, _: ?*Proxy, _: i32) callconv(.c) void {}
    fn finished(data: ?*anyopaque, _: ?*Proxy) callconv(.c) void {
        cast(Head, data).alive = false;
    }
};
const head_listener = extern struct {
    name: *const @TypeOf(Head.nameEvent) = Head.nameEvent,
    description: *const @TypeOf(Head.text) = Head.text,
    physical_size: *const @TypeOf(Head.pair) = Head.pair,
    mode: *const @TypeOf(Head.mode) = Head.mode,
    enabled: *const @TypeOf(Head.enabledEvent) = Head.enabledEvent,
    current_mode: *const @TypeOf(Head.currentMode) = Head.currentMode,
    position: *const @TypeOf(Head.pair) = Head.pair,
    transform: *const @TypeOf(Head.integer) = Head.integer,
    scale: *const @TypeOf(Head.integer) = Head.integer,
    finished: *const @TypeOf(Head.finished) = Head.finished,
}{};
const mode_listener = extern struct {
    size: *const @TypeOf(Head.pair) = Head.pair,
    refresh: *const @TypeOf(Head.integer) = Head.integer,
    preferred: *const @TypeOf(modeEvent) = modeEvent,
    finished: *const @TypeOf(modeEvent) = modeEvent,
}{};
fn modeEvent(_: ?*anyopaque, _: ?*Proxy) callconv(.c) void {}
const Result = enum { pending, succeeded, failed, cancelled };
const Client = struct {
    display: *c.wl_display,
    manager: ?*Proxy = null,
    manager_name: u32 = 0,
    heads: std.ArrayList(*Head) = .empty,
    serial: ?u32 = null,
    failure: ?anyerror = null,
    result: Result = .pending,

    fn global(data: ?*anyopaque, registry: ?*c.wl_registry, name: u32, interface: [*c]const u8, _: u32) callconv(.c) void {
        const self = cast(Client, data);
        if (!std.mem.eql(u8, std.mem.span(interface), "zwlr_output_manager_v1") or self.manager != null) return;
        // Version 1 supports scaling and preserves newer properties by inheritance.
        self.manager = @ptrCast(c.wl_registry_bind(registry, name, &p.zwlr_output_manager_v1_interface, 1));
        self.manager_name = name;
        if (self.manager == null or c.wl_proxy_add_listener(self.manager, @ptrCast(@constCast(&manager_listener)), self) != 0) self.failure = error.OutputManagerUnavailable;
    }
    fn removed(data: ?*anyopaque, _: ?*c.wl_registry, name: u32) callconv(.c) void {
        const self = cast(Client, data);
        if (self.manager_name == name) self.failure = error.OutputManagerUnavailable;
    }
    fn head(data: ?*anyopaque, _: ?*Proxy, proxy: *Proxy) callconv(.c) void {
        const self = cast(Client, data);
        const item = a.create(Head) catch @panic("out of memory");
        item.* = .{ .proxy = proxy };
        self.heads.append(a, item) catch @panic("out of memory");
        if (c.wl_proxy_add_listener(proxy, @ptrCast(@constCast(&head_listener)), item) != 0) self.failure = error.WaylandListenerFailed;
    }
    fn done(data: ?*anyopaque, _: ?*Proxy, serial: u32) callconv(.c) void {
        cast(Client, data).serial = serial;
    }
    fn finished(data: ?*anyopaque, _: ?*Proxy) callconv(.c) void {
        cast(Client, data).failure = error.OutputManagerUnavailable;
    }
    fn succeeded(data: ?*anyopaque, _: ?*Proxy) callconv(.c) void {
        cast(Client, data).result = .succeeded;
    }
    fn failed(data: ?*anyopaque, _: ?*Proxy) callconv(.c) void {
        cast(Client, data).result = .failed;
    }
    fn cancelled(data: ?*anyopaque, _: ?*Proxy) callconv(.c) void {
        cast(Client, data).result = .cancelled;
    }
    fn registryDone(data: ?*anyopaque, _: ?*Proxy, _: u32) callconv(.c) void {
        const self = cast(Client, data);
        if (self.manager == null) self.failure = error.OutputManagerUnavailable;
    }
    fn timeout(data: ?*anyopaque) callconv(.c) c_int {
        cast(Client, data).failure = error.OutputConfigurationTimedOut;
        return 1;
    }
    fn dispatch(_: c_int, condition: c.GIOCondition, data: ?*anyopaque) callconv(.c) c_int {
        const self = cast(Client, data);
        if (condition & (c.G_IO_ERR | c.G_IO_HUP) != 0 or c.wl_display_dispatch(self.display) < 0) self.failure = error.WaylandDisconnected;
        _ = c.wl_display_flush(self.display);
        return 1;
    }
    fn wait(self: *Client, snapshot: bool) !void {
        _ = c.wl_display_flush(self.display);
        while (true) {
            if (self.failure) |err| return err;
            if (if (snapshot) self.serial != null else self.result != .pending) return;
            _ = c.g_main_context_iteration(null, 1);
        }
    }
};
const sync_listener = extern struct { done: *const @TypeOf(Client.registryDone) = Client.registryDone }{};
const registry_listener = c.wl_registry_listener{ .global = Client.global, .global_remove = Client.removed };
const manager_listener = extern struct {
    head: *const @TypeOf(Client.head) = Client.head,
    done: *const @TypeOf(Client.done) = Client.done,
    finished: *const @TypeOf(Client.finished) = Client.finished,
}{};
const configuration_listener = extern struct {
    succeeded: *const @TypeOf(Client.succeeded) = Client.succeeded,
    failed: *const @TypeOf(Client.failed) = Client.failed,
    cancelled: *const @TypeOf(Client.cancelled) = Client.cancelled,
}{};

pub fn run(args: []const []const u8) !void {
    const options = try parse(args);
    const display = c.wl_display_connect(null) orelse return error.WaylandUnavailable;
    defer c.wl_display_disconnect(display);
    var client = Client{ .display = display };
    defer {
        for (client.heads.items) |item| {
            for (item.modes.items) |mode| c.wl_proxy_destroy(mode);
            item.modes.deinit(a);
            c.wl_proxy_destroy(item.proxy);
            if (item.name) |name| a.free(name);
            a.destroy(item);
        }
        client.heads.deinit(a);
        if (client.manager) |manager| c.wl_proxy_destroy(manager);
    }
    const registry = c.wl_display_get_registry(display) orelse return error.WaylandRegistryUnavailable;
    defer c.wl_registry_destroy(registry);
    if (c.wl_registry_add_listener(registry, &registry_listener, &client) != 0) return error.WaylandListenerFailed;
    // This sync follows registry enumeration, so a missing protocol fails promptly.
    var sync_args = [_]c.wl_argument{.{ .o = null }};
    const sync = request(@ptrCast(display), 0, &wl_callback_interface, 0, &sync_args) orelse return error.WaylandListenerFailed;
    defer c.wl_proxy_destroy(sync);
    if (c.wl_proxy_add_listener(sync, @ptrCast(@constCast(&sync_listener)), &client) != 0) return error.WaylandListenerFailed;
    const source = c.g_unix_fd_add(c.wl_display_get_fd(display), c.G_IO_IN | c.G_IO_ERR | c.G_IO_HUP, &Client.dispatch, &client);
    defer _ = c.g_source_remove(source);
    const timer = c.g_timeout_add_seconds(5, &Client.timeout, &client);
    defer _ = c.g_source_remove(timer);
    try client.wait(true);
    var selected: ?*Head = null;
    for (client.heads.items) |item| {
        if (item.alive and item.name != null and std.mem.eql(u8, item.name.?, options.name)) selected = item;
    }
    const target = selected orelse return error.OutputNotFound;
    if (!target.enabled) return error.OutputDisabled;
    var create_args = [_]c.wl_argument{ .{ .o = null }, .{ .u = client.serial.? } };
    const configuration = request(client.manager.?, 0, &p.zwlr_output_configuration_v1_interface, 0, &create_args) orelse return error.OutputConfigurationUnavailable;
    defer _ = request(configuration, 4, null, 1, &.{});
    if (c.wl_proxy_add_listener(configuration, @ptrCast(@constCast(&configuration_listener)), &client) != 0) return error.WaylandListenerFailed;
    for (client.heads.items) |item| {
        if (!item.alive) continue;
        if (!item.enabled) {
            var disable_args = [_]c.wl_argument{.{ .o = @ptrCast(item.proxy) }};
            _ = request(configuration, 1, null, 0, &disable_args);
            continue;
        }
        var enable_args = [_]c.wl_argument{ .{ .o = null }, .{ .o = @ptrCast(item.proxy) } };
        const head_configuration = request(configuration, 0, &p.zwlr_output_configuration_head_v1_interface, 0, &enable_args) orelse return error.OutputConfigurationUnavailable;
        defer c.wl_proxy_destroy(head_configuration);
        // Unset properties inherit current mode, position, transform and adaptive sync.
        if (item == target) {
            var scale_args = [_]c.wl_argument{.{ .f = options.scale }};
            _ = request(head_configuration, 4, null, 0, &scale_args);
        }
    }
    _ = request(configuration, 2, null, 0, &.{});
    try client.wait(false);
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
