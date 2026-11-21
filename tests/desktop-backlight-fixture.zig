//! Test-only sysfs injection; the installed shell always uses /sys/class/backlight.
const std = @import("std");
const c = @import("desktop").glib;
const backlight = @import("desktop").backlight;
const osd = @import("desktop").osd;
const quick = @import("desktop").quick;
const assert = std.debug.assert;
const cast = c.__zig.cast;
fn pump() void {
    while (c.g_main_context_iteration(null, 0) != 0) {}
    c.g_usleep(1000);
}
fn waitControls(controls: *quick.Controls) void {
    const deadline = c.__zig.monotonicTime() + 8_000_000;
    while ((controls.brightness_busy or controls.brightness_timer != 0) and c.__zig.monotonicTime() < deadline) pump();
    assert(!controls.brightness_busy and controls.brightness_timer == 0);
}
fn controlsTest(backend: backlight.Backend, empty: bool, denied: bool) !void {
    const controls = quick.Controls.create("true", "true");
    controls.backlight_backend = backend;
    controls.refresh();
    waitControls(controls);
    if (empty) {
        assert(controls.view.model.brightness == null);
    } else if (denied) {
        controls.setSlider(.brightness, 75);
        waitControls(controls);
        assert(@abs(controls.view.model.brightness.? - 20) < 0.01);
    } else {
        assert(controls.view.model.brightness != null);
        assert(@abs(controls.view.model.brightness.? - 20) < 0.01);
        controls.setSlider(.brightness, 75);
        const deadline = c.__zig.monotonicTime() + 3_000_000;
        while (!controls.brightness_busy and c.__zig.monotonicTime() < deadline) pump();
        assert(controls.brightness_busy);
        controls.setSlider(.brightness, 38);
        waitControls(controls);
        assert(@abs(controls.view.model.brightness.? - 38) < 0.01);
        controls.setSlider(.brightness, 0);
        waitControls(controls);
        assert(@abs(controls.view.model.brightness.? - 1) < 0.01);
        controls.refresh(); // Exercise disposal while a native read is in flight.
    }
    controls.deinit();
    const deadline = c.__zig.monotonicTime() + 250_000;
    while (c.__zig.monotonicTime() < deadline) pump();
}
const Completion = struct {
    result: ?backlight.Result = null,
    fn done(data: ?*anyopaque, result: backlight.Result) void {
        cast(Completion, data).result = result;
    }
};
pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const args = try init.minimal.args.toSlice(arena.allocator());
    const root = c.__zig.getenv("DESKTOP_BACKLIGHT_FIXTURE_ROOT") orelse return error.ExpectedFixtureRoot;
    const backend = backlight.Backend{ .root = std.mem.span(root) };
    if (args.len < 2) return error.ExpectedMode;
    if (std.mem.eql(u8, args[1], "serve") or osd.parseCommand(args[1..]) != null) return runOsd(init, backend);
    if (std.mem.startsWith(u8, args[1], "controls")) return controlsTest(backend, std.mem.eql(u8, args[1], "controls-empty"), std.mem.eql(u8, args[1], "controls-denied"));
    const action: backlight.Action = if (std.mem.eql(u8, args[1], "read")) .read else if (std.mem.eql(u8, args[1], "set") and args.len == 3) .{ .set = try std.fmt.parseFloat(f64, args[2]) } else if (std.mem.eql(u8, args[1], "step") and args.len == 3) .{ .step = try std.fmt.parseInt(i16, args[2], 10) } else return error.InvalidMode;
    const cancel = c.g_cancellable_new().?;
    defer c.g_object_unref(cancel);
    var completion = Completion{};
    backend.start(action, cancel, &Completion.done, &completion);
    while (completion.result == null) _ = c.g_main_context_iteration(null, 1);
    switch (completion.result.?) {
        .failure => |err| return err,
        .value => |device| {
            const json = try std.json.Stringify.valueAlloc(arena.allocator(), .{ .device = std.mem.sliceTo(&device.name, 0), .current = device.current, .maximum = device.maximum, .percent = device.percent() }, .{});
            try std.Io.File.stdout().writeStreamingAll(init.io, json);
        },
    }
}

const dbus = @import("desktop").dbus;
const loop = @import("desktop").dbus_loop;
const osd_name = "org.dotfiles.DesktopOsd";
const osd_path = "/org/dotfiles/DesktopOsd";
var running = true;

/// Runs `serve` or a media command forwarded by another invocation.
fn run(self: *osd.Server, args: []const []const u8) ![]const u8 {
    if ((args.len == 1 or args.len == 2) and std.mem.eql(u8, args[0], "serve")) {
        if (self.ready) return "";
        self.start() catch |err| return @errorName(err);
        return "";
    }
    if (!self.ready) return "session service is not running";
    const work = osd.parseCommand(args) orelse return "invalid command";
    return if (self.enqueue(work)) "" else "queue full";
}
const Instance = struct {
    server: *osd.Server,
    connection: *dbus.Connection,
    fn command(data: ?*anyopaque, message: *const dbus.Message) void {
        const self: *Instance = @ptrCast(@alignCast(data));
        const args = message.read(struct { []const []const u8 }) catch return;
        const failure = run(self.server, args[0]) catch "failed";
        if (failure.len > 0) self.connection.replyError(message, osd_name ++ ".Error.Failed", failure) catch {} else self.connection.reply(message, .{}) catch {};
    }
};

fn quit(_: c.gpointer) callconv(.c) c.gboolean {
    running = false;
    return 1;
}

fn runOsd(init: std.process.Init, backend: backlight.Backend) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const args = try init.minimal.args.toSlice(arena.allocator());
    const serve = (args.len == 2 or args.len == 3) and std.mem.eql(u8, args[1], "serve");
    if (!serve and osd.parseCommand(args[1..]) == null) {
        std.debug.print("Usage: desktop-osd serve | volume up|down|mute | microphone mute | brightness up|down\n", .{});
        return error.InvalidArguments;
    }
    const forwarded = try arena.allocator().alloc([]const u8, args.len - 1);
    for (forwarded, args[1..]) |*out, arg| out.* = arg;
    if (!serve) return loop.forwardCommand("desktop-osd", osd_name, osd_path, forwarded);
    const bus = try loop.acquire(.session);
    defer loop.release(bus);
    if (try bus.connection.requestName(osd_name, 4) != 1) return loop.forwardCommand("desktop-osd", osd_name, osd_path, forwarded);
    var introspection = try dbus.Introspection.parse(std.heap.page_allocator, loop.commandXml(osd_name));
    defer introspection.deinit();
    var server = osd.Server{ .backlight_backend = backend, .connection = bus.connection };
    defer server.deinit();
    var instance: Instance = .{ .server = &server, .connection = bus.connection };
    const exported = try bus.connection.exportObject(osd_path, &introspection.interfaces[0], &Instance.command, null, &instance);
    defer bus.connection.unregister(exported);
    const term = c.g_unix_signal_add(c.SIGTERM, &quit, null);
    const interrupt = c.g_unix_signal_add(c.SIGINT, &quit, null);
    defer _ = c.g_source_remove(term);
    defer _ = c.g_source_remove(interrupt);
    const failure = try run(&server, forwarded);
    if (failure.len > 0) {
        std.debug.print("desktop-osd: {s}\n", .{failure});
        return error.CommandFailed;
    }
    while (running and !bus.connection.closed) _ = c.g_main_context_iteration(null, 1);
}
