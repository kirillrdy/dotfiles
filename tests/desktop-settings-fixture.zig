//! Settings window teardown while the native backend is connecting.
const std = @import("std");
const settings = @import("settings");
const c = settings.c;
pub fn main() !void {
    c.gtk_init(null, null);
    for (0..8) |_| {
        const ui = settings.Settings.create(.network);
        const entry: *c.GtkEntry = @ptrCast(c.gtk_bin_get_child(@ptrCast(ui.ssids.?)));
        c.gtk_entry_set_text(entry, "Cafe: Tokyo\\5G");
        const state = ui.network_client.?.state();
        ui.renderNetwork(state);
        try std.testing.expectEqualStrings("Cafe: Tokyo\\5G", std.mem.span(c.gtk_entry_get_text(entry)));
        try std.testing.expect(c.gtk_entry_get_visibility(@ptrCast(ui.password.?)) == 0);
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
