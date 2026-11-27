//! Run only through desktop-session-fixture.nix and its private system bus.
const std = @import("std");
const mainloop = @import("desktop").mainloop;
const util = @import("desktop").util;
const session = @import("desktop").session_actions;
const quick = @import("desktop").quick;

const pump = @import("fixture-util.zig").pump;
fn env(key: [:0]const u8) []const u8 {
    return util.env(key) orelse "";
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
fn cancelLater(cancel: *mainloop.Cancellable) bool {
    cancel.cancel();
    return false;
}
fn finalized(live: *bool) void {
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
    dialog.pointerButton(true, rect.x + rect.width / 2, rect.y + rect.height / 2 - dialog.offset);
    dialog.pointerButton(false, rect.x + rect.width / 2, rect.y + rect.height / 2 - dialog.offset);
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
    pump();
    try std.testing.expect(controls.dialog == null);
}

test "session: private logind actions and quick-settings lifecycle" {
    defer @import("desktop").gsettings.deinit();
    defer @import("desktop").window.deinit();
    try std.testing.expectEqualStrings("1", env("DESKTOP_SESSION_TEST_RUN"));
    try std.testing.expect(env("DBUS_SYSTEM_BUS_ADDRESS").len != 0);
    const scenario = env("SESSION_CASE");
    const deadline = util.monotonicTime() + 8_000_000;
    if (std.mem.startsWith(u8, scenario, "ui-")) {
        const controls = quick.Controls.create(std.testing.allocator, "true", "true");
        var live = true;
        controls.cancel.onFinalize(&live, finalized);
        var battery_live = controls.battery_service != null;
        if (controls.battery_service) |service| service.cancel.onFinalize(&battery_live, finalized);
        const network = @import("desktop").network;
        try checkPowerDialog(controls);
        // Power Off asks first, as GNOME does, with the action focused and a countdown.
        controls.view.submenu = .power;
        controls.redraw();
        controls.activate(.poweroff);
        try std.testing.expect(controls.dialog != null);
        try std.testing.expectEqualStrings("Cancel", controls.dialog.?.view.cancel_label.?);
        try std.testing.expectEqualStrings("Power Off", controls.dialog.?.view.accept_label.?);
        try std.testing.expectEqual(@import("desktop").askpass.native.Target.accept, controls.dialog.?.view.focus);
        try std.testing.expect(std.mem.indexOf(u8, controls.dialog.?.prompt, "60 seconds") != null);
        try std.testing.expect(controls.dialog.?.handleKey(0xff1b, 0));
        pump();
        try std.testing.expect(controls.dialog == null and !controls.session_busy and controls.end_session_timer == 0);
        // Suspend has no confirmation in GNOME and sends exactly one action.
        controls.view.submenu = .power;
        controls.redraw();
        controls.activate(.suspend_action);
        try std.testing.expect(controls.dialog == null);
        pump();
        controls.sessionAction(.reboot); // A pending action must prevent duplicate requests.
        if (std.mem.eql(u8, scenario, "ui-denied")) {
            while (controls.session_busy and util.monotonicTime() < deadline) pump();
            try std.testing.expect(!controls.session_busy);
            try std.testing.expect(std.mem.indexOf(u8, controls.view.model.message.slice(), "denied") != null);
        } else {
            const ready = util.monotonicTime() + 100_000;
            while (util.monotonicTime() < ready) pump();
            try std.testing.expect(controls.session_busy);
        }
        // A shown native dialog must release its reference during shutdown.
        controls.view.submenu = .profiles;
        controls.redraw();
        controls.activate(.power_settings);
        try std.testing.expect(controls.dialog != null);
        controls.deinit();
        // Device workers retain their own cancellation objects after Controls
        // is freed. Drain their completion callbacks before the allocator audit.
        while ((live or battery_live or network.live_services != 0) and util.monotonicTime() < deadline) pump();
        try std.testing.expect(!live and !battery_live and network.live_services == 0);
        return;
    }
    const action = std.meta.stringToEnum(session.Action, env("SESSION_ACTION")) orelse return error.UnknownAction;
    const cancel = mainloop.Cancellable.create();
    defer cancel.unref();
    var completion: Completion = .{};
    session.perform(std.testing.allocator, action, cancel, &Completion.done, &completion);
    if (std.mem.eql(u8, scenario, "cancel-immediate")) cancel.cancel();
    if (std.mem.startsWith(u8, scenario, "cancel-delayed")) _ = mainloop.timeout(100, cancel, cancelLater);
    while (completion.count == 0 and util.monotonicTime() < deadline) pump();
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
