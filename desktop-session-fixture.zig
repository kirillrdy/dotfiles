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
        controls.sessionAction(.@"suspend");
        controls.sessionAction(.reboot); // A pending action must prevent duplicate requests.
        if (std.mem.eql(u8, scenario, "ui-denied")) {
            while (controls.session_busy and c.g_get_monotonic_time() < deadline) pump();
            try std.testing.expect(!controls.session_busy);
            const tooltip = c.gtk_widget_get_tooltip_text(controls.content);
            defer c.g_free(tooltip);
            try std.testing.expect(std.mem.indexOf(u8, std.mem.span(tooltip), "denied") != null);
        } else {
            const ready = c.g_get_monotonic_time() + 100_000;
            while (c.g_get_monotonic_time() < ready) pump();
            try std.testing.expect(controls.session_busy);
        }
        controls.deinit();
        c.gtk_widget_destroy(window);
        while (live and c.g_get_monotonic_time() < deadline) pump();
        try std.testing.expect(!live);
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
