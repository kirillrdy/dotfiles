//! Isolated D-Bus integration driver; never run against the host system bus.
const std = @import("std");
const mainloop = @import("desktop").mainloop;
const util = @import("desktop").util;
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
const fixture_util = @import("fixture-util.zig");
const pump = fixture_util.pump;
fn settle() void {
    fixture_util.pumpFor(100_000);
}
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(std.heap.page_allocator);
    defer std.heap.page_allocator.free(args);
    const client = try network.Client.create(init.gpa, &changed, null);
    defer {
        client.destroy();
        settle();
    }
    const limit = util.monotonicTime() + 5_000_000;
    while ((!client.state().available or client.state().profiles.items.len == 0) and util.monotonicTime() < limit) pump();
    try std.testing.expect(client.state().available);
    const state = client.state();
    if (std.mem.eql(u8, args[1], "events")) {
        fixture_io = init.io;
        watching = true;
        changed(null, client);
        const deadline = util.monotonicTime() + 8_000_000;
        while (util.monotonicTime() < deadline) pump();
        watching = false;
        return;
    }
    if (std.mem.eql(u8, args[1], "state")) {
        const output = try std.json.Stringify.valueAlloc(std.heap.page_allocator, .{ .available = state.available, .wifi = state.wifi_enabled, .hardware = state.hardware_enabled, .aps = state.access_points.items, .devices = state.devices.items, .profiles = state.profiles.items.len, .icon = state.indicator().icon }, .{});
        defer std.heap.page_allocator.free(output);
        try std.Io.File.stdout().writeStreamingAll(init.io, output);
        return;
    }
    if (std.mem.eql(u8, args[1], "ui-parity")) {
        const window = settings.Settings.create(init.gpa, .network);
        settle();
        try std.testing.expect(window.rows.items.len > 0);
        for (window.ui.items.items) |item| try std.testing.expect(item.kind != .choice);
        // Duplicate and hidden APs must not produce extra rows. Row paths must
        // survive replacement of the snapshot while keyboard focus is restored.
        const allocator = std.heap.page_allocator;
        const temporary_path = try allocator.dupeSentinel(u8, state.access_points.items[0].path, 0);
        var points: [3]network.AccessPoint = @splat(state.access_points.items[0]);
        points[0].path = temporary_path;
        points[2].ssid = &.{};
        var snapshot = state.*;
        snapshot.access_points.items = &points;
        window.renderNetwork(&snapshot);
        try std.testing.expectEqual(@as(usize, 1), window.rows.items.len);
        window.ui.focusItem(window.rows.items[0].item);
        allocator.free(temporary_path);
        try std.testing.expectEqualStrings(state.access_points.items[0].path, window.rows.items[0].key);
        window.renderNetwork(state);
        try std.testing.expectEqual(window.rows.items[0].item, window.ui.focus.?);
        try std.testing.expect(!window.manual.visible);
        window.showPage(.hidden);
        try std.testing.expect(window.manual.visible);
        try std.testing.expect(window.ui.get(window.view.connect).visible);
        window.showPage(.saved);
        try std.testing.expect(!window.manual.visible);
        window.showPage(.wifi);
        window.ui.activate(window.view.search);
        try std.testing.expect(window.ui.get(window.view.query).entry.?.public_text);
        try window.ui.setText(window.view.query, "no matching network");
        window.ui.changed(window.ui.context, window.view.query);
        try std.testing.expectEqual(@as(usize, 0), window.rows.items.len);
        try std.testing.expect(window.ui.shortcut.?(window.ui.context, 0xff1b, 0));
        try std.testing.expect(!window.view.searching and window.rows.items.len > 0);
        const native_window = window.window;
        window.ui.activate(window.view.sound_nav);
        try std.testing.expect(window.mode == .sound);
        try std.testing.expect(window.sound.?.window == native_window);
        try std.testing.expect(!window.manual.visible);
        // Navigation still works with no PipeWire daemon in this fixture.
        window.sound.?.activate(.{ .control = .network_nav });
        try std.testing.expect(window.mode == .network and window.view.page == .network);
        window.showPage(.wifi);
        try std.testing.expect(window.ui.get(window.view.sound_nav).visible);
        try std.testing.expect(window.rows.items.len > 0);
        try window.ui.setText(window.view.refresh, "Reload networks");
        window.ui.activate(window.view.refresh);
        try std.testing.expect(window.network_operations > 0);
        while (window.network_operations != 0) pump();
        const properties = editor.Editor.create(window.window, state.profiles.items[0]);
        settle();
        properties.ui.activate(properties.view.tabs[2]);
        try std.testing.expect(properties.view.page == .ipv4);
        try std.testing.expect(properties.ui.select(properties.view.ipv4, "manual"));
        properties.ui.changed(properties.ui.context, properties.view.ipv4);
        try std.testing.expectEqualStrings("manual", properties.row("ipv4", "method").?.widget.value());
        try std.testing.expect(properties.row("ipv4", "address-data").?.widget.visible);
        try properties.setValue("ipv4", "address-data", "192.0.2.15/24");
        properties.ui.activate(properties.view.tabs[3]);
        try std.testing.expect(properties.ui.select(properties.view.ipv6, "disabled"));
        properties.ui.changed(properties.ui.context, properties.view.ipv6);
        try std.testing.expect(!properties.row("ipv6", "address-data").?.widget.visible);
        properties.ui.activate(properties.view.tabs[4]);
        try std.testing.expect(properties.ui.select(properties.view.security, ""));
        properties.ui.changed(properties.ui.context, properties.view.security);
        try std.testing.expect(properties.row("802-11-wireless-security", "key-mgmt").?.remove.checked);
        const values = try properties.values();
        defer values.unref();
        try std.testing.expect(values.group("802-11-wireless-security") == null);
        properties.ui.close();
        window.ui.close();
        while (!window.closed) pump();
        while (window.network_operations != 0 or (window.sound != null and window.sound.?.operations != 0)) pump();
        window.destroy();
        settle();
        return;
    }
    if (std.mem.startsWith(u8, args[1], "preview")) {
        const window = settings.Settings.create(init.gpa, .network);
        if (std.mem.eql(u8, args[1], "preview-network")) window.showPage(.network);
        if (std.mem.eql(u8, args[1], "preview-search")) {
            window.ui.activate(window.view.search);
            try window.ui.setText(window.view.query, "Home Wi-Fi");
            window.ui.changed(window.ui.context, window.view.query);
        }
        if (std.mem.startsWith(u8, args[1], "preview-editor")) {
            const properties = editor.Editor.create(window.window, state.profiles.items[0]);
            if (std.mem.endsWith(u8, args[1], "ipv4")) properties.view.page = .ipv4;
            if (std.mem.endsWith(u8, args[1], "security")) properties.view.page = .security;
            properties.ui.relayout();
        }
        while (!window.closed) _ = mainloop.iteration(true);
        while (window.network_operations != 0 or (window.sound != null and window.sound.?.operations != 0)) pump();
        window.destroy();
        return;
    }
    if (std.mem.eql(u8, args[1], "edit") or std.mem.eql(u8, args[1], "new") or std.mem.eql(u8, args[1], "edit-secret") or std.mem.eql(u8, args[1], "edit-cancel")) {
        const Noop = struct {
            fn paint(_: ?*anyopaque, _: @import("desktop").window.wire.Pixels) void {}
        };
        const parent = try @import("desktop").window.Window.create(init.gpa, "Fixture parent", "fixture-parent", 620, 700, &Noop.paint, null);
        defer parent.destroy();
        const is_new = std.mem.eql(u8, args[1], "new");
        const ui = editor.Editor.create(parent, if (is_new) null else state.profiles.items[0]);
        if (std.mem.eql(u8, args[1], "edit-cancel")) {
            try ui.setValue("802-11-wireless-security", "psk", "cancel-secret");
            ui.save();
            ui.ui.close();
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
        defer values.unref();
        const cancel = mainloop.Cancellable.create();
        defer cancel.unref();
        client.perform(.{ .save = .{ .path = ui.path, .settings = values, .version = ui.version } }, cancel, &done, null);
        const deadline = util.monotonicTime() + 8_000_000;
        while (!complete and util.monotonicTime() < deadline) pump();
        ui.ui.close();
        settle();
        try std.testing.expect(complete);
        try std.testing.expect(success);
        return;
    }
    if (std.mem.eql(u8, args[1], "ui")) {
        const controls = quick.Controls.create(init.gpa, "true", "true");
        const ui = settings.Settings.create(init.gpa, .network);
        try std.testing.expect(ui.network_client.?.service == client.service);
        try std.testing.expect(controls.devices.network_client.?.service == client.service);
        settle();
        try std.testing.expect(ui.rows.items.len > 0);
        ui.showPage(.hidden);
        try ui.ui.setText(ui.manual.id, "Cafe: Tokyo\\5G");
        try ui.ui.setText(ui.password.id, "ui-secret");
        // Actions use IDs even when the displayed wording changes.
        try ui.ui.setText(ui.view.connect, "Join network");
        ui.ui.activate(ui.view.connect);
        try std.testing.expectEqualStrings("", ui.password.value());
        ui.ui.close();
        while (!ui.closed) _ = mainloop.iteration(true);
        while (ui.network_operations != 0) pump();
        ui.destroy();
        controls.view.submenu = .network;
        controls.redraw();
        controls.activate(.network0);
        try std.testing.expect(controls.dialog != null);
        try std.testing.expectEqualStrings(state.access_points.items[0].title, controls.dialog.?.prompt);
        // Empty submissions stay open and display an inline error.
        try std.testing.expect(controls.dialog.?.handleKey(0xff0d, 0));
        pump();
        try std.testing.expect(controls.dialog.?.view.status_error);
        try controls.dialog.?.entry.?.insert("cancelled-quick-secret");
        try std.testing.expect(controls.dialog.?.handleKey(0xff1b, 0));
        pump();
        try std.testing.expect(controls.dialog == null);
        controls.view.submenu = .network;
        controls.redraw();
        controls.activate(.network0);
        try controls.dialog.?.entry.?.insert("quick-native-secret");
        try std.testing.expect(controls.dialog.?.handleKey(0xff0d, 0));
        pump();
        try std.testing.expect(controls.dialog == null);
        settle();
        controls.view.submenu = .network;
        controls.redraw();
        controls.activate(.network0);
        try controls.dialog.?.entry.?.insert("teardown-quick-secret");
        controls.deinit();
        settle();
        return;
    }
    const cancel = mainloop.Cancellable.create();
    defer cancel.unref();
    const command = args[1];
    const action: network.Action = if (std.mem.eql(u8, command, "scan") or std.mem.eql(u8, command, "cancel")) .scan else if (std.mem.eql(u8, command, "wifi")) .{ .wifi = std.mem.eql(u8, args[2], "on") } else if (std.mem.eql(u8, command, "activate")) .{ .activate = args[2] } else if (std.mem.eql(u8, command, "deactivate")) .{ .deactivate = args[2] } else if (std.mem.eql(u8, command, "forget")) .{ .forget = args[2] } else if (std.mem.eql(u8, command, "disconnect")) .{ .disconnect = args[2] } else if (std.mem.eql(u8, command, "connect-ap")) blk: {
        const ap = state.ap(args[2]) orelse return error.MissingAP;
        break :blk .{ .connect = .{ .ssid = ap.ssid, .access_point = ap.path, .password = if (args.len > 3) args[3] else "" } };
    } else .{ .connect = .{ .ssid = args[2], .password = if (args.len > 3) args[3] else "", .hidden = true } };
    client.perform(action, cancel, &done, null);
    if (std.mem.eql(u8, command, "cancel")) cancel.cancel();
    const deadline = util.monotonicTime() + 8_000_000;
    while (!complete and util.monotonicTime() < deadline) pump();
    try std.testing.expect(complete);
    if (std.mem.eql(u8, command, "cancel")) try std.testing.expect(!success) else try std.testing.expect(success);
}
