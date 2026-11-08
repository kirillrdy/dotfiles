//! Run only through tests/desktop-session-fixture.nix and its private system bus.
const std = @import("std");
const c = @import("desktop").gtk;
const session = @import("desktop").session_actions;
const quick = @import("desktop").quick;

fn env(key: [:0]const u8) []const u8 {
    return if (c.g_getenv(key)) |value| std.mem.span(value) else "";
}
fn pump() void {
    while (c.g_main_context_iteration(null, 0) != 0) {}
    c.g_usleep(1000);
}
const Completion = struct {
    count: usize = 0,
    success: bool = false,
    cancelled: bool = false,
    message: [1024]u8 = @splat(0),
    fn done(ptr: ?*anyopaque, result: session.Result) void {
        const self: *Completion = @ptrCast(@alignCast(ptr));
        self.count += 1;
        self.success = result == .success;
        self.cancelled = result == .cancelled;
        if (result == .failure) {
            const len = @min(result.failure.len, self.message.len - 1);
            @memcpy(self.message[0..len], result.failure[0..len]);
        }
    }
};
fn cancelLater(ptr: c.gpointer) callconv(.c) c.gboolean {
    c.g_cancellable_cancel(@ptrCast(@alignCast(ptr)));
    return 0;
}
extern fn g_object_weak_ref(*c.GObject, *const fn (?*anyopaque, ?*c.GObject) callconv(.c) void, ?*anyopaque) void;
fn finalized(ptr: ?*anyopaque, _: ?*c.GObject) callconv(.c) void {
    const live: *bool = @ptrCast(@alignCast(ptr));
    live.* = false;
}

const Profiles = struct {
    calls: usize = 0,
    index: usize = 0,
    fn selected(ptr: ?*anyopaque, index: usize) void {
        const self: *Profiles = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        self.index = index;
    }
};
fn click(dialog: anytype, target: @import("desktop").askpass.native.Target) void {
    const rect = dialog.view.targetRect(target);
    var event = std.mem.zeroes(c.GdkEventButton);
    event.type = c.GDK_BUTTON_PRESS;
    event.button = 1;
    event.x = rect.x + rect.width / 2;
    event.y = rect.y + rect.height / 2;
    var handled: c.gboolean = 0;
    c.g_signal_emit_by_name(dialog.canvas, "button-press-event", &event, &handled);
    event.type = 7;
    c.g_signal_emit_by_name(dialog.canvas, "button-release-event", &event, &handled);
}
fn checkPowerDialog(controls: *quick.Controls) !void {
    var profiles: Profiles = .{};
    controls.profile_context = &profiles;
    controls.profile_selected = &Profiles.selected;
    defer {
        controls.profile_context = null;
        controls.profile_selected = null;
    }
    controls.setPowerState(.{ .available = .{ false, true, true }, .active = .balanced }, false);
    controls.view.submenu = .profiles;
    controls.redraw();
    controls.activate(.power_settings);
    const dialog = controls.dialog.?;
    try std.testing.expect(dialog.view.choices[1].selected);
    click(dialog, .choice0);
    try std.testing.expectEqual(@as(usize, 0), profiles.calls);
    dialog.focus(.accept);
    try std.testing.expect(dialog.handleKey(0xff09, 0));
    try std.testing.expectEqual(@import("desktop").askpass.native.Target.choice1, dialog.view.focus);
    try std.testing.expect(dialog.handleKey(0xff54, 0));
    try std.testing.expect(dialog.handleKey(0xff0d, 0));
    try std.testing.expectEqual(@as(usize, 1), profiles.calls);
    try std.testing.expectEqual(@as(usize, 2), profiles.index);
    controls.setPowerState(.{ .available = .{ false, true, true }, .active = .balanced }, true);
    try std.testing.expectEqual(@import("desktop").askpass.native.Target.accept, dialog.view.focus);
    click(dialog, .choice2);
    try std.testing.expectEqual(@as(usize, 1), profiles.calls);
    controls.setPowerState(.{ .available = .{ false, true, true }, .active = .@"power-saver" }, false);
    try std.testing.expect(dialog.view.choices[2].selected and !dialog.view.choices[1].selected);
    click(dialog, .choice1);
    try std.testing.expectEqual(@as(usize, 2), profiles.calls);
    try std.testing.expectEqual(@as(usize, 1), profiles.index);
    try std.testing.expect(dialog.handleKey(0xff1b, 0));
    try std.testing.expect(controls.dialog == null);
}

test "session: private logind actions and quick-settings lifecycle" {
    try std.testing.expectEqualStrings("1", env("DESKTOP_SESSION_TEST_RUN"));
    try std.testing.expect(env("DBUS_SYSTEM_BUS_ADDRESS").len != 0);
    const scenario = env("SESSION_CASE");
    const deadline = c.g_get_monotonic_time() + 8_000_000;
    if (std.mem.startsWith(u8, scenario, "ui-")) {
        c.gtk_init(null, null);
        const window = c.gtk_window_new(c.GTK_WINDOW_TOPLEVEL).?;
        const button = c.gtk_button_new().?;
        c.gtk_container_add(@ptrCast(window), button);
        const popover = c.gtk_popover_new(button).?;
        const controls = quick.Controls.create(popover, "true", "true");
        var live = true;
        g_object_weak_ref(@ptrCast(controls.cancel), &finalized, &live);
        var battery_live = controls.battery_service != null;
        if (controls.battery_service) |service| g_object_weak_ref(@ptrCast(service.cancel), &finalized, &battery_live);
        var network_live = controls.devices.network_client != null;
        if (controls.devices.network_client) |client| g_object_weak_ref(@ptrCast(client.service.cancel), &finalized, &network_live);
        try checkPowerDialog(controls);
        // Enter defaults to Cancel. Explicit keyboard selection sends one action.
        controls.view.submenu = .power;
        controls.redraw();
        controls.activate(.suspend_action);
        try std.testing.expect(controls.dialog != null);
        try std.testing.expectEqualStrings("Cancel", controls.dialog.?.view.cancel_label.?);
        try std.testing.expect(controls.dialog.?.handleKey(0xff0d, 0));
        try std.testing.expect(controls.dialog == null and !controls.session_busy);
        controls.view.submenu = .power;
        controls.redraw();
        controls.activate(.suspend_action);
        try std.testing.expect(controls.dialog.?.handleKey(0xff09, 0));
        try std.testing.expect(controls.dialog.?.handleKey(0xff0d, 0));
        controls.sessionAction(.reboot); // A pending action must prevent duplicate requests.
        if (std.mem.eql(u8, scenario, "ui-denied")) {
            while (controls.session_busy and c.g_get_monotonic_time() < deadline) pump();
            try std.testing.expect(!controls.session_busy);
            try std.testing.expect(std.mem.indexOf(u8, controls.view.model.message.slice(), "denied") != null);
        } else {
            const ready = c.g_get_monotonic_time() + 100_000;
            while (c.g_get_monotonic_time() < ready) pump();
            try std.testing.expect(controls.session_busy);
        }
        // A shown native dialog must release its reference during shutdown.
        controls.view.submenu = .profiles;
        controls.redraw();
        controls.activate(.power_settings);
        try std.testing.expect(controls.dialog != null);
        controls.deinit();
        c.gtk_widget_destroy(window);
        // Device workers retain their own cancellation objects after Controls
        // is freed. Drain their completion callbacks before the allocator audit.
        while ((live or battery_live or network_live) and c.g_get_monotonic_time() < deadline) pump();
        try std.testing.expect(!live and !battery_live and !network_live);
        return;
    }
    const action = std.meta.stringToEnum(session.Action, env("SESSION_ACTION")) orelse return error.UnknownAction;
    const cancel = c.g_cancellable_new().?;
    defer c.g_object_unref(cancel);
    var completion: Completion = .{};
    session.perform(action, cancel, &Completion.done, &completion);
    if (std.mem.eql(u8, scenario, "cancel-immediate")) c.g_cancellable_cancel(cancel);
    if (std.mem.startsWith(u8, scenario, "cancel-delayed")) _ = c.g_timeout_add(100, &cancelLater, cancel);
    while (completion.count == 0 and c.g_get_monotonic_time() < deadline) pump();
    try std.testing.expectEqual(@as(usize, 1), completion.count);
    const expected = env("SESSION_EXPECT");
    if (std.mem.eql(u8, expected, "success")) {
        try std.testing.expect(completion.success);
    } else if (std.mem.eql(u8, expected, "cancelled")) {
        try std.testing.expect(completion.cancelled);
    } else {
        try std.testing.expect(!completion.success and !completion.cancelled);
        try std.testing.expect(std.mem.indexOf(u8, std.mem.sliceTo(&completion.message, 0), expected) != null);
    }
}
