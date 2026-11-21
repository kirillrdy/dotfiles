//! The native D-Bus client against a private dbus-daemon: calls, errors,
//! timeouts, signals and sender filters on well-known names.
const std = @import("std");
const dbus = @import("dbus");
const c = @import("../desktop-glib.zig");
const a = std.testing.allocator;
const gio = struct {
    extern fn g_subprocess_get_stdout_pipe(*c.GSubprocess) *anyopaque;
    extern fn g_input_stream_read(*anyopaque, [*]u8, usize, ?*anyopaque, ?*anyopaque) isize;
    extern fn g_subprocess_force_exit(*c.GSubprocess) void;
    extern fn g_subprocess_wait(*c.GSubprocess, ?*anyopaque, ?*anyopaque) c_int;
    const stdout_pipe: c_uint = 1 << 2; // G_SUBPROCESS_FLAGS_STDOUT_PIPE
};

const Daemon = struct {
    process: *c.GSubprocess,
    address: [:0]u8,

    fn start() !Daemon {
        const argv = [_:null]?[*:0]const u8{ "dbus-daemon", "--session", "--nofork", "--print-address=1", "--address=unix:tmpdir=/tmp" };
        const process = c.g_subprocess_newv(@ptrCast(&argv), gio.stdout_pipe, null) orelse return error.SkipZigTest;
        errdefer c.g_object_unref(process);
        const stream = gio.g_subprocess_get_stdout_pipe(process);
        var line: [512]u8 = undefined;
        var len: usize = 0;
        while (len < line.len) {
            const n = gio.g_input_stream_read(stream, line[len..].ptr, 1, null, null);
            if (n <= 0 or line[len] == '\n') break;
            len += 1;
        }
        // The printed address may carry a guid; the runtime ignores unknown keys.
        return .{ .process = process, .address = try a.dupeSentinel(u8, line[0..len], 0) };
    }
    fn stop(self: Daemon) void {
        gio.g_subprocess_force_exit(self.process);
        _ = gio.g_subprocess_wait(self.process, null, null);
        c.g_object_unref(self.process);
        a.free(self.address);
    }
};

/// Dispatches every connection until `done` holds or a second passes.
fn pump(connections: []const *dbus.Connection, done: anytype) !void {
    var tries: usize = 0;
    while (!done.check()) : (tries += 1) {
        if (tries > 1000) return error.Timeout;
        for (connections) |connection| {
            try connection.readAndDispatch();
            _ = connection.expire();
        }
        c.g_usleep(1000);
    }
}

const State = struct {
    replies: usize = 0,
    failures: usize = 0,
    failure_name: [128]u8 = @splat(0),
    signals: usize = 0,
    last_text: [64]u8 = @splat(0),

    fn replied(context: ?*anyopaque, reply: dbus.Reply) void {
        const self: *State = @ptrCast(@alignCast(context));
        switch (reply) {
            .ok => |message| {
                self.replies += 1;
                const value = message.read(struct { []const u8 }) catch return;
                @memcpy(self.last_text[0..value[0].len], value[0]);
            },
            .failed => |failure| {
                self.failures += 1;
                @memcpy(self.failure_name[0..failure.name.len], failure.name);
            },
        }
    }
    fn signalled(context: ?*anyopaque, _: *const dbus.Message) void {
        const self: *State = @ptrCast(@alignCast(context));
        self.signals += 1;
    }
};

const Echo = struct {
    connection: *dbus.Connection,
    fn handle(context: ?*anyopaque, message: *const dbus.Message) void {
        const self: *Echo = @ptrCast(@alignCast(context));
        const member = message.member orelse "";
        if (std.mem.eql(u8, member, "Echo")) {
            const value = message.read(struct { []const u8 }) catch return;
            self.connection.reply(message, .{value[0]}) catch {};
        } else if (std.mem.eql(u8, member, "Fail")) {
            self.connection.replyError(message, "org.example.Error.Denied", "denied") catch {};
        }
        // Anything else is left unanswered to exercise timeouts.
    }
};

fn requestName(connection: *dbus.Connection, name: []const u8) !void {
    const reply = try connection.callBlocking(.{ .destination = "org.freedesktop.DBus", .path = "/org/freedesktop/DBus", .interface = "org.freedesktop.DBus", .member = "RequestName" }, .{ name, @as(u32, 4) }, 5000);
    defer reply.deinit();
    const result = try reply.message().read(struct { u32 });
    try std.testing.expectEqual(@as(u32, 1), result[0]); // primary owner
}

test "integration: native D-Bus calls, errors, timeouts and owner-filtered signals" {
    if (!@import("options").integration_tests) return error.SkipZigTest;
    const daemon = try Daemon.start();
    defer daemon.stop();
    const client = try dbus.Connection.openBus(a, daemon.address);
    defer client.close();
    const server = try dbus.Connection.openBus(a, daemon.address);
    defer server.close();
    const intruder = try dbus.Connection.openBus(a, daemon.address);
    defer intruder.close();
    const all = [_]*dbus.Connection{ client, server, intruder };

    var echo: Echo = .{ .connection = server };
    _ = try server.register("/org/example/Object", "org.example.Echo", &Echo.handle, &echo);
    try requestName(server, "org.example.Owned");

    var state: State = .{};
    const target: dbus.Connection.Call = .{ .destination = "org.example.Owned", .path = "/org/example/Object", .interface = "org.example.Echo", .member = "Echo" };
    _ = try client.call(target, .{"hello"}, 2000, &State.replied, &state);
    var failing = target;
    failing.member = "Fail";
    _ = try client.call(failing, .{}, 2000, &State.replied, &state);
    try pump(&all, struct {
        s: *State,
        fn check(self: @This()) bool {
            return self.s.replies == 1 and self.s.failures == 1;
        }
    }{ .s = &state });
    try std.testing.expectEqualStrings("hello", std.mem.sliceTo(&state.last_text, 0));
    try std.testing.expectEqualStrings("org.example.Error.Denied", std.mem.sliceTo(&state.failure_name, 0));

    // An unanswered call times out locally.
    var silent = target;
    silent.member = "Ignore";
    _ = try client.call(silent, .{}, 50, &State.replied, &state);
    try pump(&all, struct {
        s: *State,
        fn check(self: @This()) bool {
            return self.s.failures == 2;
        }
    }{ .s = &state });
    try std.testing.expectEqualStrings("org.freedesktop.DBus.Error.Timeout", std.mem.sliceTo(&state.failure_name, 0));

    // A sender filter on a well-known name accepts its owner only.
    const id = try client.subscribe("org.example.Owned", "org.example.Echo", "Changed", "/org/example/Object", &State.signalled, &state);
    try pump(&all, struct {
        connection: *dbus.Connection,
        fn check(self: @This()) bool {
            return self.connection.ownerOf("org.example.Owned") != null;
        }
    }{ .connection = client });
    try std.testing.expectEqualStrings(server.unique_name, client.ownerOf("org.example.Owned").?);
    try intruder.emit("/org/example/Object", "org.example.Echo", "Changed", .{});
    try server.emit("/org/example/Object", "org.example.Echo", "Changed", .{});
    try pump(&all, struct {
        s: *State,
        fn check(self: @This()) bool {
            return self.s.signals >= 1;
        }
    }{ .s = &state });
    // Give a stray intruder signal time to arrive before counting.
    for (0..20) |_| {
        for (all) |connection| try connection.readAndDispatch();
        c.g_usleep(1000);
    }
    try std.testing.expectEqual(@as(usize, 1), state.signals);

    // Ownership changes follow NameOwnerChanged, and unsubscribing stops delivery.
    const release = try server.callBlocking(.{ .destination = "org.freedesktop.DBus", .path = "/org/freedesktop/DBus", .interface = "org.freedesktop.DBus", .member = "ReleaseName" }, .{"org.example.Owned"}, 5000);
    release.deinit();
    try pump(&all, struct {
        connection: *dbus.Connection,
        fn check(self: @This()) bool {
            return self.connection.ownerOf("org.example.Owned") == null;
        }
    }{ .connection = client });
    client.unsubscribe(id);
    try std.testing.expect(client.ownerOf("org.example.Owned") == null);
}
