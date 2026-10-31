//! Test-only sysfs injection; the installed shell always uses /sys/class/backlight.
const std = @import("std");
const c = @import("desktop").gtk;
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
    const deadline = c.g_get_monotonic_time() + 8_000_000;
    while ((controls.brightness_busy or controls.brightness_timer != 0) and c.g_get_monotonic_time() < deadline) pump();
    assert(!controls.brightness_busy and controls.brightness_timer == 0);
}
fn controlsTest(backend: backlight.Backend, empty: bool, denied: bool) !void {
    if (c.gtk_init_check(null, null) == 0) return error.NoDisplay;
    const window = c.gtk_window_new(c.GTK_WINDOW_TOPLEVEL);
    defer c.gtk_widget_destroy(window);
    const button = c.gtk_button_new();
    c.gtk_container_add(cast(c.GtkContainer, window), button);
    const popover = c.gtk_popover_new(button).?;
    const controls = quick.Controls.create(popover, "true", "true");
    controls.backlight_backend = backend;
    controls.refresh();
    waitControls(controls);
    if (empty) {
        assert(c.gtk_widget_get_visible(controls.brightness_row) == 0);
    } else if (denied) {
        c.gtk_range_set_value(cast(c.GtkRange, controls.brightness), 75);
        waitControls(controls);
        assert(@abs(c.gtk_range_get_value(cast(c.GtkRange, controls.brightness)) - 20) < 0.01);
    } else {
        assert(c.gtk_widget_get_visible(controls.brightness_row) != 0);
        assert(@abs(c.gtk_range_get_value(cast(c.GtkRange, controls.brightness)) - 20) < 0.01);
        c.gtk_range_set_value(cast(c.GtkRange, controls.brightness), 75);
        const deadline = c.g_get_monotonic_time() + 3_000_000;
        while (!controls.brightness_busy and c.g_get_monotonic_time() < deadline) pump();
        assert(controls.brightness_busy);
        c.gtk_range_set_value(cast(c.GtkRange, controls.brightness), 38);
        waitControls(controls);
        assert(@abs(c.gtk_range_get_value(cast(c.GtkRange, controls.brightness)) - 38) < 0.01);
        c.gtk_range_set_value(cast(c.GtkRange, controls.brightness), 0);
        waitControls(controls);
        assert(@abs(c.gtk_range_get_value(cast(c.GtkRange, controls.brightness)) - 1) < 0.01);
        controls.refresh(); // Exercise disposal while a native read is in flight.
    }
    controls.deinit();
    const deadline = c.g_get_monotonic_time() + 250_000;
    while (c.g_get_monotonic_time() < deadline) pump();
}
const Completion = struct {
    result: ?backlight.Result = null,
    fn done(data: ?*anyopaque, result: backlight.Result) void {
        cast(Completion, data).result = result;
    }
};
pub fn main(init: std.process.Init) !void {
    @import("desktop").util.io = init.io;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const args = try init.minimal.args.toSlice(arena.allocator());
    const root = c.g_getenv("DESKTOP_BACKLIGHT_FIXTURE_ROOT") orelse return error.ExpectedFixtureRoot;
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

fn commandLine(app: *c.GApplication, command: *c.GApplicationCommandLine, data: c.gpointer) callconv(.c) c_int {
    const self = cast(osd.Server, data);
    self.connection = c.g_application_get_dbus_connection(app);
    var count: c_int = 0;
    const argv = c.g_application_command_line_get_arguments(command, &count);
    defer c.g_strfreev(argv);
    if (count == 3 and c.g_strcmp0(argv[1], "serve") == 0) {
        if (self.ready) return 0;
        self.start(std.mem.span(argv[2])) catch |err| {
            c.g_application_command_line_printerr(command, "desktop-osd: %s\n", @as([*:0]const u8, @errorName(err)));
            return 1;
        };
        c.g_application_hold(app);
        return 0;
    }
    if (!self.ready) {
        c.g_application_command_line_printerr(command, "desktop-osd: session service is not running\n");
        return 1;
    }
    if (count != 3) return 1;
    const work = osd.parseCommand(&.{ std.mem.span(argv[1]), std.mem.span(argv[2]) }) orelse return 1;
    return if (self.enqueue(work)) 0 else 1;
}

fn quit(data: c.gpointer) callconv(.c) c.gboolean {
    c.g_application_quit(cast(c.GApplication, data));
    return 1;
}

fn runOsd(init: std.process.Init, backend: backlight.Backend) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const args = try init.minimal.args.toSlice(arena.allocator());
    const serve = args.len == 3 and std.mem.eql(u8, args[1], "serve");
    if (!serve and osd.parseCommand(args[1..]) == null) {
        std.debug.print("Usage: desktop-osd serve CONFIG.json | volume up|down|mute | microphone mute | brightness up|down\n", .{});
        return error.InvalidArguments;
    }
    const app = c.g_application_new("org.dotfiles.DesktopOsd", c.G_APPLICATION_HANDLES_COMMAND_LINE);
    defer c.g_object_unref(app);
    var server = osd.Server{ .backlight_backend = backend };
    defer server.deinit();
    _ = c.g_signal_connect_data(app, "command-line", @ptrCast(&commandLine), &server, null, 0);
    const term = c.g_unix_signal_add(c.SIGTERM, &quit, app);
    const interrupt = c.g_unix_signal_add(c.SIGINT, &quit, app);
    defer _ = c.g_source_remove(term);
    defer _ = c.g_source_remove(interrupt);
    const argv = try arena.allocator().allocSentinel(?[*:0]const u8, args.len, null);
    for (args, 0..) |arg, i| argv[i] = (try arena.allocator().dupeSentinel(u8, arg, 0)).ptr;
    if (c.g_application_run(cast(c.GApplication, app), @intCast(args.len), @ptrCast(argv.ptr)) != 0) return error.CommandFailed;
}
