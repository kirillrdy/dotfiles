//! Settings page input routing and teardown while native backends connect.
const std = @import("std");
const settings = @import("desktop").settings;
const mainloop = @import("desktop").mainloop;
const util = @import("desktop").util;
fn pageInput(ui: *settings.Settings) !void {
    const surface = ui.window.surface.?;
    const events = surface.input;
    const context = surface.data;
    const window = ui.window;
    ui.selectMode(.network);
    for (0..3) |_| {
        events.focus.?(context, surface, false);
        try std.testing.expect(!ui.ui.keyboard_focused);
        events.focus.?(context, surface, true);
        try std.testing.expect(ui.ui.keyboard_focused);
        try std.testing.expect(events.symbol.?(context, surface, 0xff09, 0, true));
        try std.testing.expect(ui.ui.focus != null);

        const nav = ui.ui.get(ui.view.sound_nav).bounds;
        const x = nav.x + nav.width / 2;
        const y = nav.y + nav.height / 2;
        events.motion.?(context, surface, x, y);
        try std.testing.expectEqual(ui.view.sound_nav, ui.ui.hover.?);
        events.leave.?(context, surface);
        try std.testing.expect(ui.ui.hover == null);
        events.button.?(context, surface, 272, true, x, y);
        try std.testing.expectEqual(ui.view.sound_nav, ui.ui.pressed.?);
        // Backend startup can rebuild rows and cancel queued form actions.
        // Check press/release routing, then activate navigation synchronously.
        events.button.?(context, surface, 272, false, -1, -1);
        try std.testing.expect(ui.ui.pressed == null);
        ui.ui.activate(ui.view.sound_nav);
        try std.testing.expect(ui.mode == .sound and ui.window == window);
        try std.testing.expect(!ui.manual.visible);

        const sound = ui.sound.?;
        try std.testing.expect(events.symbol.?(context, surface, 0xff09, 0, true));
        try std.testing.expect(sound.view.focus != null and ui.ui.focus == null);
        events.focus.?(context, surface, false);
        try std.testing.expect(!sound.view.keyboard_focus);
        const back = sound.view.rect(.{ .control = .network_nav });
        const bx = back.x + back.width / 2;
        const by = back.y + back.height / 2;
        events.motion.?(context, surface, bx, by);
        try std.testing.expect(sound.view.hover.?.control == .network_nav);
        events.leave.?(context, surface);
        try std.testing.expect(sound.view.hover == null);
        events.button.?(context, surface, 272, true, bx, by);
        events.button.?(context, surface, 272, false, bx, by);
        try std.testing.expect(ui.mode == .network and ui.window == window);
        try std.testing.expect(sound.view.focus == null and sound.view.pressed == null);
        try std.testing.expect(ui.ui.get(ui.view.sound_nav).visible);
    }
}
pub fn main(init: std.process.Init) !void {
    for (0..8) |cycle| {
        const ui = settings.Settings.create(init.gpa, init.io, if (cycle % 2 == 0) .network else .sound);
        try ui.ui.setText(ui.manual.id, "Cafe: Tokyo\\5G");
        const state = ui.network_client.?.state();
        ui.renderNetwork(state);
        try std.testing.expectEqualStrings("Cafe: Tokyo\\5G", ui.manual.value());
        try std.testing.expect(!ui.password.entry.?.echo);
        try pageInput(ui);
        try std.testing.expectEqualStrings("Cafe: Tokyo\\5G", ui.manual.value());
        ui.ui.close();
        while (!ui.closed) _ = mainloop.iteration(init.io, true);
        while (ui.network_operations != 0 or ui.sound.?.operations != 0) _ = mainloop.iteration(init.io, true);
        ui.destroy();
        const deadline = std.Io.Clock.awake.now(init.io).toMicroseconds() + 100000;
        while (std.Io.Clock.awake.now(init.io).toMicroseconds() < deadline) {
            while (mainloop.iteration(init.io, false)) {}
            mainloop.sleep(1000);
        }
    }
    @import("fixture-util.zig").printOut(init.io, "desktop-settings: page switching, pointer and keyboard routing, focus, preserved fields and pending-close teardown passed\n", .{});
}
