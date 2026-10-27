//! Settings UI and subprocess checks, with fake backends and an isolated Xvfb.
const std = @import("std");
const settings = @import("settings");
const c = settings.c;
const assert = std.debug.assert;
fn cast(comptime T: type, p: anytype) *T {
    return @ptrCast(@alignCast(p));
}
fn eq(actual: [*c]const u8, expected: []const u8) void {
    assert(std.mem.eql(u8, std.mem.span(actual), expected));
}
fn pump() void {
    while (c.g_main_context_iteration(null, 0) != 0) {}
    c.g_usleep(1000);
}
fn wait(state: *settings.Settings) void {
    const deadline = c.g_get_monotonic_time() + 10 * 1000 * 1000;
    while (state.jobs != null and c.g_get_monotonic_time() < deadline) pump();
    assert(state.jobs == null and state.queries == 0);
}
fn capture(state: *settings.Settings, name: []const u8) !void {
    const prefix = c.g_getenv("DESKTOP_SETTINGS_SCREENSHOTS") orelse return;
    const deadline = c.g_get_monotonic_time() + 100 * 1000;
    while (c.g_get_monotonic_time() < deadline) pump();
    const path = try std.fmt.allocPrintSentinel(std.heap.page_allocator, "{s}-{s}.png", .{ prefix, name }, 0);
    defer std.heap.page_allocator.free(path);
    const pixbuf = c.gdk_pixbuf_get_from_window(c.gtk_widget_get_window(state.window), 0, 0, c.gtk_widget_get_allocated_width(state.window), c.gtk_widget_get_allocated_height(state.window));
    assert(pixbuf != null);
    defer c.g_object_unref(pixbuf);
    assert(c.gdk_pixbuf_save(pixbuf, path, "png", @as([*c][*c]c.GError, null), @as(?*anyopaque, null)) != 0);
}
fn findButton(widget: *c.GtkWidget, title: []const u8) ?*c.GtkButton {
    if (c.g_type_check_instance_is_a(cast(c.GTypeInstance, widget), c.gtk_button_get_type()) != 0) {
        const name = c.gtk_button_get_label(cast(c.GtkButton, widget));
        if (name != null and std.mem.eql(u8, std.mem.span(name), title)) return cast(c.GtkButton, widget);
    }
    if (c.g_type_check_instance_is_a(cast(c.GTypeInstance, widget), c.gtk_container_get_type()) == 0) return null;
    const children = c.gtk_container_get_children(cast(c.GtkContainer, widget));
    defer c.g_list_free(children);
    var node = children;
    while (node != null) : (node = node.*.next) {
        if (findButton(cast(c.GtkWidget, node.*.data), title)) |found| return found;
    }
    return null;
}
fn marker(init: std.process.Init, name: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{ c.g_getenv("DESKTOP_SETTINGS_FIXTURE_ROOT").?, name });
    defer std.heap.page_allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(init.io, path, std.heap.page_allocator, .limited(4096));
}
fn record(init: std.process.Init, name: []const u8, value: []const u8) !void {
    const path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{ c.g_getenv("DESKTOP_SETTINGS_FIXTURE_ROOT").?, name });
    defer std.heap.page_allocator.free(path);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = value });
}
fn mock(init: std.process.Init, args: []const []const u8) !bool {
    const name = std.fs.path.basename(args[0]);
    if (std.mem.eql(u8, name, "nmcli")) {
        const joined = try std.mem.join(std.heap.page_allocator, " ", args[1..]);
        defer std.heap.page_allocator.free(joined);
        if (std.mem.indexOf(u8, joined, "--ask") != null) {
            assert(std.mem.indexOf(u8, joined, "test-secret") == null);
            assert(std.mem.eql(u8, args[7], "Cafe: Tokyo\\5G"));
            var input = std.Io.File.stdin().readerStreaming(init.io, &.{});
            const secret = try input.interface.allocRemaining(std.heap.page_allocator, .limited(4096));
            defer std.heap.page_allocator.free(secret);
            try record(init, "secret", secret);
        } else if (std.mem.indexOf(u8, joined, "IN-USE,SSID,SIGNAL,SECURITY") != null) {
            try std.Io.File.stdout().writeStreamingAll(init.io, "*:Cafe\\: Tokyo\\\\5G:83:WPA2\n:Cafe\\: Tokyo\\\\5G:50:WPA2\n:Guest:90:--\n::10:WPA2\n");
        } else if (std.mem.indexOf(u8, joined, "UUID,NAME,TYPE,DEVICE") != null) {
            try std.Io.File.stdout().writeStreamingAll(init.io, "wifi-uuid:Cafe\\: Tokyo\\\\5G:802-11-wireless:wlan0\nvpn-uuid:Work VPN:vpn:\n");
        } else if (std.mem.indexOf(u8, joined, "DEVICE,TYPE,STATE,CONNECTION") != null) {
            try std.Io.File.stdout().writeStreamingAll(init.io, "wlan0:wifi:connected:Cafe\\: Tokyo\\\\5G\neth0:ethernet:disconnected:--\nlo:loopback:connected:lo\n");
        } else if (std.mem.indexOf(u8, joined, "connection up uuid") != null) {
            try record(init, "profile", args[args.len - 1]);
        } else return error.UnexpectedNetworkCommand;
        return true;
    }
    return false;
}
pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const args = try init.minimal.args.toSlice(arena.allocator());
    if (try mock(init, args)) return;
    const root = c.g_dir_make_tmp("desktop-settings-XXXXXX", null).?;
    defer c.g_free(root);
    defer std.Io.Dir.cwd().deleteTree(init.io, std.mem.span(root)) catch {};
    const executable = try arena.allocator().dupeSentinel(u8, try std.process.executablePathAlloc(init.io, arena.allocator()), 0);
    for ([_][]const u8{"nmcli"}) |name| {
        const path = try std.fmt.allocPrintSentinel(arena.allocator(), "{s}/{s}", .{ root, name }, 0);
        const file = c.g_file_new_for_path(path);
        defer c.g_object_unref(file);
        assert(c.g_file_make_symbolic_link(file, executable, null, null) != 0);
    }
    const path = try std.fmt.allocPrintSentinel(arena.allocator(), "{s}:{s}", .{ root, c.g_getenv("PATH").? }, 0);
    assert(c.g_setenv("PATH", path, 1) != 0);
    assert(c.g_setenv("DESKTOP_SETTINGS_FIXTURE_ROOT", root, 1) != 0);
    c.gtk_init(null, null);
    const network = settings.Settings.create(.network);
    wait(network);
    assert(!network.failed);
    try capture(network, "network");
    const wifi_model = c.gtk_combo_box_get_model(cast(c.GtkComboBox, network.ssids.?));
    assert(c.gtk_tree_model_iter_n_children(wifi_model, null) == 2); // deduplicate APs, skip hidden
    const ssid = cast(c.GtkEntry, c.gtk_bin_get_child(cast(c.GtkBin, network.ssids.?)));
    c.gtk_entry_set_text(ssid, "Cafe: Tokyo\\5G");
    network.refresh();
    wait(network);
    eq(c.gtk_entry_get_text(ssid), "Cafe: Tokyo\\5G");
    c.gtk_entry_set_text(cast(c.GtkEntry, network.password.?), "test-secret:$()\\");
    settings.Settings.wifiConnect(null, network);
    eq(c.gtk_entry_get_text(cast(c.GtkEntry, network.password.?)), "");
    wait(network);
    assert(!network.failed);
    try std.testing.expectEqualStrings("test-secret:$()\\\n", try marker(init, "secret"));
    assert(c.gtk_combo_box_set_active_id(cast(c.GtkComboBox, network.profiles.?), "vpn-uuid") != 0);
    c.gtk_button_clicked(findButton(network.body, "Connect").?);
    wait(network);
    try std.testing.expectEqualStrings("vpn-uuid", try marker(init, "profile"));
    eq(c.gtk_combo_box_get_active_id(cast(c.GtkComboBox, network.profiles.?)), "vpn-uuid");
    assert(std.mem.indexOf(u8, std.mem.span(c.gtk_label_get_text(cast(c.GtkLabel, network.status.?))), "Cafe: Tokyo\\5G") != null);
    // Cancel an in-flight backend while its owning widgets are destroyed.
    network.run(&.{ "sleep", "30" }, .devices, 0, null);
    c.gtk_widget_destroy(network.window);
    wait(network);
    network.destroy();
    std.debug.print("desktop-settings: escaped SSIDs, secrets on stdin, saved connections, errors and cancellation passed\n", .{});
}
