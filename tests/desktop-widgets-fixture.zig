//! Native panel modules and popup checks on a private Wayland display.
const std = @import("std");
const p = @import("desktop").widgets;
const c = p.c;
const assert = std.debug.assert;
fn eq(a: [*c]const u8, b: [:0]const u8) void {
    assert(std.mem.eql(u8, std.mem.span(a), b));
}
fn pumpEvents(milliseconds: i64) void {
    const end = c.g_get_monotonic_time() + milliseconds * 1000;
    while (c.g_get_monotonic_time() < end) {
        while (c.g_main_context_iteration(null, 0) != 0) {}
        c.g_usleep(1000);
    }
}
var refresh_count: usize = 0;
fn refresh(kind: []const u8) void {
    assert(std.mem.eql(u8, kind, "codex"));
    refresh_count += 1;
}
fn clickControl(controls: *@import("desktop").quick.Controls, target: @import("desktop").quick.Target) void {
    const rect = controls.view.item(target).?.rect;
    controls.pointerButton(true, rect.x + rect.width / 2, rect.y + rect.height / 2);
    controls.pointerButton(false, rect.x + rect.width / 2, rect.y + rect.height / 2);
}
pub fn main(process_init: std.process.Init) !void {
    const args = try process_init.minimal.args.toSlice(process_init.arena.allocator());
    // Re-exec this fixture in place of pkexec to exercise argv, async completion,
    // error reporting and disposal without authorization or real sysfs writes.
    if (args.len == 5 and std.mem.eql(u8, args[1], "--power-fixture")) {
        assert(std.mem.eql(u8, args[2], "power"));
        assert(std.mem.eql(u8, args[3], "set"));
        _ = try @import("desktop").power.Profile.parse(args[4]);
        if (std.mem.eql(u8, args[4], "power-saver")) {
            std.debug.print("fixture: permission denied", .{});
            std.process.exit(1);
        }
        std.process.exit(0);
    }
    _ = c.g_setenv("GSETTINGS_BACKEND", "memory", 1);
    // Resolve and decode the SVGs through the native icon loader.
    if (c.g_getenv("DESKTOP_PANEL_ICON_PATH") != null) {
        for ([_][:0]const u8{
            "network-wireless-signal-good-symbolic",
            "battery-level-90-symbolic",
            "battery-level-50-charging-symbolic",
            "audio-volume-medium-symbolic",
            "microphone-sensitivity-high-symbolic",
            "microphone-sensitivity-muted-symbolic",
            "display-brightness-symbolic",
        }) |name| {
            for ([_]u32{ 1, 2 }) |scale| {
                const pixbuf = c.__icons.load(name, 16, scale, null).?;
                assert(c.gdk_pixbuf_get_width(pixbuf) > 0 and c.gdk_pixbuf_get_height(pixbuf) > 0);
                c.g_object_unref(pixbuf);
            }
        }
    }
    const executable = try process_init.arena.allocator().dupeSentinel(u8, args[0], 0);
    _ = c.g_setenv("DESKTOP_POWER_PKEXEC", executable.ptr, 1);
    _ = c.g_setenv("DESKTOP_POWER_HELPER", "--power-fixture", 1);
    const status = p.init(.{ .name = "gnome-status" }, null, null, null);
    assert(status.quick != null);
    const initial_network_title = status.quick.?.view.model.network_title;
    p.update(status, .{ .items = &.{ .{ .icon = "audio-volume-high-symbolic" }, .{ .icon = "battery-level-80-symbolic" } } });
    assert(status.view.items[0].visible and status.view.items[1].visible);
    p.update(status, .{ .items = &.{.{ .icon = "network-wired-symbolic", .tooltip = "Wired network" }} });
    // Collector tooltips must not overwrite the quick-settings connection name.
    assert(std.mem.eql(u8, status.quick.?.view.model.network_title.slice(), initial_network_title.slice()));
    assert(status.quick.?.view.item(.wifi).?.rect.height == 48);
    const controls = status.quick.?;
    // A second panel borrows the same services and detaches independently.
    const peer = p.init(.{ .name = "gnome-status" }, controls.devices, null, null);
    assert(peer.quick.?.devices == controls.devices);
    assert(controls.devices.subscribers.items.len == 2);
    p.deinit(peer);
    assert(controls.devices.subscribers.items.len == 1);
    p.apply_power_state(status, .{});
    assert(std.mem.eql(u8, controls.view.model.message.slice(), "Power profiles unavailable"));
    clickControl(controls, .profiles);
    assert(controls.view.item(.profile0) == null and controls.view.item(.profile1) == null);
    p.apply_power_state(status, .{ .available = .{ false, true, true }, .active = .balanced });
    assert(controls.view.item(.profile0) == null and controls.view.item(.profile1) != null);
    assert(std.mem.eql(u8, controls.view.item(.profile_toggle).?.subtitle, "Balanced"));
    p.apply_power_state(status, .{ .available = .{ true, true, true }, .active = .balanced });
    clickControl(controls, .profile0);
    assert(status.power_pending != 0 and !controls.view.enabled(.profile0));
    pumpEvents(500);
    assert(status.power_pending == 0);
    assert(controls.view.model.message.len == 0);
    p.apply_power_state(status, .{ .available = .{ true, true, true }, .active = .balanced });
    clickControl(controls, .profile2);
    pumpEvents(500);
    assert(status.power_pending == 0);
    assert(std.mem.eql(u8, controls.view.model.message.slice(), "fixture: permission denied"));
    clickControl(controls, .profiles);

    const refs_before_refresh = status.refs;
    // Refreshing the tile must never launch another profile change, including
    // transitions between balanced (inactive) and either active toggle state.
    for ([_]?@import("desktop").power.Profile{ .performance, .balanced, .@"power-saver", .balanced, null }) |profile| {
        p.apply_power_state(status, .{ .available = .{ true, true, true }, .active = profile });
        assert(status.power_pending == 0 and status.refs == refs_before_refresh);
        assert(controls.view.item(.profile_toggle).?.active == (profile != null and profile.? != .balanced));
    }
    // User clicks still dispatch once; async completion must not dispatch again.
    clickControl(controls, .profile_toggle);
    assert(status.power_pending != 0);
    pumpEvents(500);
    assert(status.power_pending == 0);
    if (controls.interface) |prefs| {
        const before = controls.view.model.dark;
        clickControl(controls, .dark);
        assert(controls.view.model.dark != before);
        const color_scheme = c.g_settings_get_string(prefs, "color-scheme");
        eq(color_scheme, if (!before) "prefer-dark" else "default");
        c.g_free(color_scheme);
    }
    if (controls.notifications) |prefs| {
        const before = c.g_settings_get_boolean(prefs, "show-banners");
        clickControl(controls, .dnd);
        assert(c.g_settings_get_boolean(prefs, "show-banners") != before);
        _ = c.g_settings_set_boolean(prefs, "show-banners", before);
    }
    clickControl(controls, .profiles);
    assert(controls.view.submenu == .profiles);
    clickControl(controls, .network);
    assert(controls.view.submenu == .network and controls.view.item(.power_settings) == null);
    clickControl(controls, .network);
    assert(controls.view.submenu == .none);
    const previous_volume = controls.view.model.volume;
    controls.view.model.volume = 50;
    controls.redraw();
    const slider = controls.view.item(.volume).?.rect;
    controls.pointerButton(true, slider.x + 8, slider.y + slider.height / 2);
    assert(controls.view.model.volume.? == 0);
    controls.pointerMotion(slider.x + slider.width + 100, slider.y + 100);
    assert(controls.view.model.volume.? == 100);
    controls.pointerButton(false, slider.x + slider.width + 100, slider.y + 100);
    assert(controls.view.pressed == .none and controls.view.model.volume.? == 100);
    controls.view.focus = .volume;
    assert(controls.handleKey(0xff50, 0) and controls.view.model.volume.? == 0); // Home
    assert(controls.handleKey(0xff53, 0) and controls.view.model.volume.? == 5); // Right
    assert(controls.handleKey(0xff57, 0) and controls.view.model.volume.? == 100); // End
    controls.view.focus = .network;
    assert(controls.handleKey(0xff0d, 0) and controls.view.submenu == .network);
    assert(controls.handleKey(0xff1b, 0) and controls.view.submenu == .none and controls.view.focus == .network);
    _ = c.g_source_remove(controls.volume_timer);
    controls.volume_timer = 0;
    controls.view.model.volume = previous_volume;
    controls.redraw();
    p.apply_power_state(status, .{ .available = .{ true, true, true }, .active = .balanced });
    clickControl(controls, .profiles);
    clickControl(controls, .profile0);
    p.deinit(status);
    pumpEvents(500);

    const usage = p.init(.{ .name = "gnome-codex", .source = "codex" }, null, null, null);
    p.refresh_source = &refresh;
    defer p.refresh_source = null;
    const codex_menu = usage.codex_menu.?;
    assert(codex_menu.module == usage);
    p.update(usage, .{});
    try codex_menu.show(320, 32);
    pumpEvents(50);
    const refresh_rect = usage.codex.refreshRect();
    const codex_surface = codex_menu.popup.surface.?;
    const zoom = codex_menu.bounds.width / @as(f64, @floatFromInt(usage.codex.width));
    const rx = codex_menu.bounds.x + (refresh_rect.x + refresh_rect.width / 2) * zoom;
    const ry = codex_menu.bounds.y + (refresh_rect.y + refresh_rect.height / 2) * zoom;
    codex_surface.input.button.?(codex_menu, codex_surface, 272, true, rx, ry);
    assert(usage.codex.pressed);
    codex_surface.input.button.?(codex_menu, codex_surface, 272, false, rx, ry);
    assert(refresh_count == 1);
    // Ignore another activation until the collector delivers completion.
    p.codex_refresh(usage);
    assert(refresh_count == 1);
    assert(!usage.codex.enabled);
    eq(usage.codex.checked.value, "Refreshing…");
    p.update(usage, .{ .items = &.{.{ .text = "54%" }}, .tooltip = "5h: 54% remaining", .windows = &.{ .{ .percent = 54, .reset = "Resets in 2h 15m" }, .{ .percent = 93, .reset = "Resets in 4d 8h" } }, .checked = "Checked: 12:00:00" });
    assert(usage.codex.enabled);
    assert(codex_surface.input.symbol.?(codex_menu, codex_surface, 0xff0d, 0, true));
    assert(refresh_count == 2 and !usage.codex.enabled);
    p.update(usage, .{ .windows = &.{ .{ .percent = 54, .reset = "Resets in 2h 15m" }, .{ .percent = 93, .reset = "Resets in 4d 8h" } }, .tooltip = "5h: 54% remaining" });
    codex_menu.hide();
    eq(usage.tooltip, "5h: 54% remaining");
    try codex_menu.show(320, 32);
    p.update(usage, .{ .items = &.{.{ .text = "54%" }}, .tooltip = "5h: 54% remaining", .windows = &.{ .{ .percent = 54, .reset = "Resets in 2h 15m" }, .{ .percent = 93, .reset = "Resets in 4d 8h" } }, .checked = "Checked: 12:00:00" });
    assert(codex_menu.popup.visible);
    codex_menu.hide();
    eq(usage.codex.percent[0].value, "54.0% remaining");
    eq(usage.codex.percent[1].value, "93.0% remaining");
    assert(usage.codex.values[0] == 54);
    assert(p.native.usageColor(54).green > 0.7);
    eq(usage.codex.reset[1].value, "Resets in 4d 8h");
    assert(usage.codex.error_label.value.len == 0);
    p.update(usage, .{ .items = &.{.{ .text = "—" }}, .windows = &.{}, .@"error" = "Sign in with codex login" });
    eq(usage.codex.percent[0].value, "—");
    assert(usage.codex.values[0] == 0 and usage.codex.error_label.value.len > 0);
    // Disposal must cancel a dismissal queued from native keyboard input.
    try codex_menu.show(320, 32);
    assert(codex_menu.handleKey(0xff1b));
    assert(codex_menu.popup.close_idle != 0);
    p.deinit(usage);
    pumpEvents(50);

    const clock = p.init(.{ .kind = "clock" }, null, null, null);
    const date = &clock.date_controls.?.view;
    date.setDate(c.g_date_time_new_local(2024, 2, 29, 12, 0, 0).?);
    try date.prepare(1);
    assert(date.selectedIndex() == 32);
    date.selectDay(33);
    assert(c.g_date_time_get_month(date.selected) == 3 and c.g_date_time_get_day_of_month(date.selected) == 1);
    for (0..3) |_| date.navigate(-1);
    assert(c.g_date_time_get_year(date.selected) == 2023 and c.g_date_time_get_month(date.selected) == 12);
    clock.date_controls.?.reset();
    const now = c.g_date_time_new_now_local();
    assert(c.g_date_time_get_year(date.selected) == c.g_date_time_get_year(now) and c.g_date_time_get_day_of_year(date.selected) == c.g_date_time_get_day_of_year(now));
    c.g_date_time_unref(now);
    p.deinit(clock);
    // Exercise graph history rollover and the native draw callback after migration.
    const monitors = p.init(.{ .kind = "monitors" }, null, null, null);
    for (0..130) |i| {
        p.update(monitors, .{ .monitors = &.{.{ .sequence = @intCast(i), .values = &.{@floatFromInt(i)}, .colors = &.{"#0072b3"}, .maximum = 100 }} });
    }
    assert(monitors.view.graphs[0].count == 100);
    assert(monitors.view.graphs[0].history[0][0] == 30 and monitors.view.graphs[0].history[0][99] == 129);
    var pixels: [100 * 32]u32 = @splat(0);
    monitors.view.graphs[0].paint(.{ .target = .{ .pixels = &pixels, .width = 100, .height = 32 }, .scale = 1 }, 0, 100, 32);
    assert(pixels[pixels.len - 1] != 0);
    // Verify #ffffff16 background and clipped polygon bounds on a step graph.
    const empty_graph = p.init(.{ .kind = "monitors" }, null, null, null);
    var step_pixels: [110 * 32]u32 = @splat(0);
    empty_graph.view.graphs[0].paint(.{ .target = .{ .pixels = &step_pixels, .width = 110, .height = 32 }, .scale = 1 }, 5, 100, 32);
    assert(step_pixels[4] == 0 and step_pixels[5] == 0x16161616 and step_pixels[104] == 0x16161616 and step_pixels[105] == 0);
    p.update(empty_graph, .{ .monitors = &.{.{ .sequence = 1, .values = &.{50}, .colors = &.{"#0072b3"}, .maximum = 100 }} });
    p.update(empty_graph, .{ .monitors = &.{.{ .sequence = 2, .values = &.{50}, .colors = &.{"#0072b3"}, .maximum = 100 }} });
    @memset(&step_pixels, 0);
    empty_graph.view.graphs[0].paint(.{ .target = .{ .pixels = &step_pixels, .width = 110, .height = 32 }, .scale = 1 }, 5, 100, 32);
    assert(step_pixels[104] == 0x16161616);
    assert(step_pixels[31 * 110 + 104] != 0x16161616);
    assert(step_pixels[31 * 110 + 103] == 0xff0072b3);
    assert(step_pixels[31 * 110 + 101] == 0x16161616);
    p.deinit(empty_graph);
    p.deinit(monitors);
    std.debug.print("desktop-widgets: power controls, quick settings, calendar, codex and monitors graph passed\n", .{});
}
