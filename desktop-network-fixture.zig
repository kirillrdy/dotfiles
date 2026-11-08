//! Isolated D-Bus integration driver; never run against the host system bus.
const std = @import("std");
const c = @import("desktop").gtk;
const network = @import("desktop").network;
const settings = @import("desktop").settings;
const editor = @import("desktop").network_editor;
const quick = @import("desktop").quick;
var complete = false;
var success = false;
var watching = false;
var fixture_io: std.Io = undefined;
fn changed(_: ?*anyopaque, client: *network.Client) void {
    if (!watching) return;
    const state = client.state();
    const output = std.json.Stringify.valueAlloc(std.heap.page_allocator, .{ .available = state.available, .hardware = state.hardware_enabled, .strength = if (state.access_points.items.len > 0) state.access_points.items[0].strength else @as(u8, 0), .profiles = state.profiles.items.len }, .{}) catch unreachable;
    defer std.heap.page_allocator.free(output);
    std.Io.File.stdout().writeStreamingAll(fixture_io, output) catch return;
    std.Io.File.stdout().writeStreamingAll(fixture_io, "\n") catch return;
}
fn done(_: ?*anyopaque, result: network.Result) void {
    success = result == .success;
    if (result == .failure) std.debug.print("{s}\n", .{result.failure});
    complete = true;
}
fn pump() void {
    while (c.g_main_context_iteration(null, 0) != 0) {}
    c.g_usleep(1000);
}
fn settle() void {
    const deadline = c.g_get_monotonic_time() + 100000;
    while (c.g_get_monotonic_time() < deadline) pump();
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(std.heap.page_allocator);
    defer std.heap.page_allocator.free(args);
    const client = try network.Client.create(&changed, null);
    defer {
        client.destroy();
        settle();
    }
    const limit = c.g_get_monotonic_time() + 5_000_000;
    while ((!client.state().available or client.state().profiles.items.len == 0) and c.g_get_monotonic_time() < limit) pump();
    try std.testing.expect(client.state().available);
    const state = client.state();
    if (std.mem.eql(u8, args[1], "events")) {
        fixture_io = init.io;
        watching = true;
        changed(null, client);
        const deadline = c.g_get_monotonic_time() + 8_000_000;
        while (c.g_get_monotonic_time() < deadline) pump();
        watching = false;
        return;
    }
    if (std.mem.eql(u8, args[1], "state")) {
        const output = try std.json.Stringify.valueAlloc(std.heap.page_allocator, .{ .available = state.available, .wifi = state.wifi_enabled, .hardware = state.hardware_enabled, .aps = state.access_points.items, .devices = state.devices.items, .profiles = state.profiles.items.len, .icon = state.indicator().icon }, .{});
        defer std.heap.page_allocator.free(output);
        try std.Io.File.stdout().writeStreamingAll(init.io, output);
        return;
    }
    if (std.mem.eql(u8, args[1], "edit") or std.mem.eql(u8, args[1], "new") or std.mem.eql(u8, args[1], "edit-secret") or std.mem.eql(u8, args[1], "edit-cancel")) {
        c.gtk_init(null, null);
        const parent = c.gtk_window_new(c.GTK_WINDOW_TOPLEVEL).?;
        defer c.gtk_widget_destroy(parent);
        const is_new = std.mem.eql(u8, args[1], "new");
        const ui = editor.Editor.create(parent, if (is_new) null else state.profiles.items[0]);
        if (std.mem.eql(u8, args[1], "edit-cancel")) {
            try ui.setValue("802-11-wireless-security", "psk", "cancel-secret");
            ui.save();
            c.gtk_widget_destroy(ui.window);
            settle();
            return;
        }
        try ui.setValue("connection", "id", "Native connection");
        if (is_new) {
            try ui.setValue("connection", "type", "bridge");
            try ui.setValue("connection", "interface-name", "fixture-br0");
            ui.ui.activate(ui.row("bridge", "stp").?.widget.id);
            try std.testing.expect(!ui.row("bridge", "stp").?.remove.checked);
        } else {
            try ui.setValue("ipv4", "address-data", "invalid-address");
            try std.testing.expectError(error.AddressNeedsPrefix, ui.values());
            try ui.setValue("ipv4", "address-data", "192.0.2.10/24, 192.0.2.11/24");
            try ui.setValue("ipv4", "dns-data", "1.1.1.1, 9.9.9.9");
            try ui.setValue("ipv6", "method", "manual");
            try ui.setValue("ipv6", "address-data", "2001:db8::10/64");
            if (std.mem.eql(u8, args[1], "edit-secret")) {
                const row = ui.row("802-11-wireless-security", "psk").?;
                try std.testing.expect(!row.widget.entry.?.echo);
                try ui.setValue("802-11-wireless-security", "psk", "updated-wifi-secret");
            }
        }
        const values = try ui.values();
        defer c.g_variant_unref(values);
        const cancel = c.g_cancellable_new().?;
        defer c.g_object_unref(cancel);
        client.perform(.{ .save = .{ .path = ui.path, .settings = values, .version = ui.version } }, cancel, &done, null);
        const deadline = c.g_get_monotonic_time() + 8_000_000;
        while (!complete and c.g_get_monotonic_time() < deadline) pump();
        c.gtk_widget_destroy(ui.window);
        try std.testing.expect(complete);
        try std.testing.expect(success);
        return;
    }
    if (std.mem.eql(u8, args[1], "ui")) {
        c.gtk_init(null, null);
        const window = c.gtk_window_new(c.GTK_WINDOW_TOPLEVEL).?;
        const button = c.gtk_button_new().?;
        c.gtk_container_add(@ptrCast(window), button);
        const popover = c.gtk_popover_new(button).?;
        const controls = quick.Controls.create(popover, "true", "true");
        const ui = settings.Settings.create(.network);
        try std.testing.expect(ui.network_client.?.service == client.service);
        try std.testing.expect(controls.devices.network_client.?.service == client.service);
        settle();
        try std.testing.expect(ui.ssids.options.items.len > 0);
        try std.testing.expect(ui.selectAP(state.access_points.items[0].path));
        try ui.ui.setText(ui.password.id, "ui-secret");
        settings.Settings.wifiConnect(null, ui);
        try std.testing.expectEqualStrings("", ui.password.value());
        c.gtk_widget_destroy(ui.window);
        while (ui.network_operations != 0) pump();
        ui.destroy();
        controls.view.submenu = .network;
        controls.redraw();
        controls.activate(.network0);
        try std.testing.expect(controls.dialog != null);
        try std.testing.expectEqualStrings(state.access_points.items[0].title, controls.dialog.?.prompt);
        // Empty submissions stay open and display an inline error.
        try std.testing.expect(controls.dialog.?.handleKey(0xff0d, 0));
        try std.testing.expect(controls.dialog.?.view.status_error);
        try controls.dialog.?.entry.?.insert("cancelled-quick-secret");
        try std.testing.expect(controls.dialog.?.handleKey(0xff1b, 0));
        try std.testing.expect(controls.dialog == null);
        controls.activate(.network0);
        try controls.dialog.?.entry.?.insert("quick-native-secret");
        try std.testing.expect(controls.dialog.?.handleKey(0xff0d, 0));
        try std.testing.expect(controls.dialog == null);
        settle();
        controls.activate(.network0);
        try controls.dialog.?.entry.?.insert("teardown-quick-secret");
        controls.deinit();
        c.gtk_widget_destroy(window);
        settle();
        return;
    }
    const cancel = c.g_cancellable_new().?;
    defer c.g_object_unref(cancel);
    const command = args[1];
    const action: network.Action = if (std.mem.eql(u8, command, "scan") or std.mem.eql(u8, command, "cancel")) .scan else if (std.mem.eql(u8, command, "wifi")) .{ .wifi = std.mem.eql(u8, args[2], "on") } else if (std.mem.eql(u8, command, "activate")) .{ .activate = args[2] } else if (std.mem.eql(u8, command, "deactivate")) .{ .deactivate = args[2] } else if (std.mem.eql(u8, command, "forget")) .{ .forget = args[2] } else if (std.mem.eql(u8, command, "disconnect")) .{ .disconnect = args[2] } else if (std.mem.eql(u8, command, "connect-ap")) blk: {
        const ap = state.ap(args[2]) orelse return error.MissingAP;
        break :blk .{ .connect = .{ .ssid = ap.ssid, .access_point = ap.path, .password = if (args.len > 3) args[3] else "" } };
    } else .{ .connect = .{ .ssid = args[2], .password = if (args.len > 3) args[3] else "", .hidden = true } };
    client.perform(action, cancel, &done, null);
    if (std.mem.eql(u8, command, "cancel")) c.g_cancellable_cancel(cancel);
    const deadline = c.g_get_monotonic_time() + 8_000_000;
    while (!complete and c.g_get_monotonic_time() < deadline) pump();
    try std.testing.expect(complete);
    if (std.mem.eql(u8, command, "cancel")) try std.testing.expect(!success) else try std.testing.expect(success);
}
