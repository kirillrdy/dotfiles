//! Test-only sysfs injection; the installed shell always uses /sys/class/backlight.
const std = @import("std");
const c = @import("gtk");
const backlight = @import("backlight");
const osd = @import("desktop-osd.zig");
const quick = @import("desktop-quick-settings.zig");
const assert = std.debug.assert;
fn cast(comptime T: type, ptr: anytype) *T {
    return @ptrCast(@alignCast(ptr));
}
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
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const args = try init.minimal.args.toSlice(arena.allocator());
    const root = c.g_getenv("DESKTOP_BACKLIGHT_FIXTURE_ROOT") orelse return error.ExpectedFixtureRoot;
    const backend = backlight.Backend{ .root = std.mem.span(root) };
    if (args.len < 2) return error.ExpectedMode;
    if (std.mem.eql(u8, args[1], "serve") or osd.parseCommand(args[1..]) != null) return osd.mainWithBackend(init, backend);
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
