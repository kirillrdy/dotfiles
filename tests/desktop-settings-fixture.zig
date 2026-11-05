//! Settings window teardown while the native backend is connecting.
const std = @import("std");
const settings = @import("desktop").settings;
const c = settings.c;
pub fn main() !void {
    c.gtk_init(null, null);
    for (0..8) |_| {
        const ui = settings.Settings.create(.network);
        try ui.ui.setText(ui.manual.id, "Cafe: Tokyo\\5G");
        const state = ui.network_client.?.state();
        ui.renderNetwork(state);
        try std.testing.expectEqualStrings("Cafe: Tokyo\\5G", ui.manual.value());
        try std.testing.expect(!ui.password.entry.?.echo);
        c.gtk_widget_destroy(ui.window);
        while (ui.network_operations != 0) _ = c.g_main_context_iteration(null, 1);
        ui.destroy();
        const deadline = c.g_get_monotonic_time() + 100000;
        while (c.g_get_monotonic_time() < deadline) {
            while (c.g_main_context_iteration(null, 0) != 0) {}
            c.g_usleep(1000);
        }
    }
}
