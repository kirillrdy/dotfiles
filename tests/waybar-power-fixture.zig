//! GTK integration tests. Run under Xvfb; never uses the user's desktop.
const std = @import("std");
const p = @import("desktop").widgets;
const c = p.c;
const assert = std.debug.assert;
const cast = c.__zig.cast;
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
fn tooltipVisible() bool {
    const windows = c.gtk_window_list_toplevels();
    defer c.g_list_free(windows);
    var node = windows;
    while (node != null) : (node = node.*.next) {
        if (c.g_strcmp0(c.g_type_name_from_instance(cast(c.GTypeInstance, node.*.data)), "GtkTooltipWindow") == 0 and
            c.gtk_widget_get_visible(cast(c.GtkWidget, node.*.data)) != 0) return true;
    }
    return false;
}
var refresh_count: usize = 0;
fn refresh(kind: []const u8) void {
    assert(std.mem.eql(u8, kind, "codex"));
    refresh_count += 1;
}
fn root() *c.GtkWidget {
    const widget = c.gtk_event_box_new();
    _ = c.g_object_ref_sink(widget);
    return widget;
}
fn clickControl(controls: *@import("desktop").quick.Controls, target: @import("desktop").quick.Target) void {
    const rect = controls.view.item(target).?.rect;
    var event = std.mem.zeroes(c.GdkEventButton);
    event.button = 1;
    event.x = rect.x + rect.width / 2;
    event.y = rect.y + rect.height / 2;
    event.type = c.GDK_BUTTON_PRESS;
    var handled: c.gboolean = 0;
    c.g_signal_emit_by_name(controls.canvas, "button-press-event", &event, &handled);
    assert(handled != 0);
    event.type = 7; // GDK_BUTTON_RELEASE
    c.g_signal_emit_by_name(controls.canvas, "button-release-event", &event, &handled);
    assert(handled != 0);
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
    c.gtk_init(null, null);
    // Resolve and decode the SVGs, rather than only checking GtkImage names.
    if (c.g_getenv("DESKTOP_PANEL_ICON_PATH")) |path| {
        const theme = c.gtk_icon_theme_new();
        defer c.g_object_unref(theme);
        c.gtk_icon_theme_append_search_path(theme, path);
        c.gtk_icon_theme_set_custom_theme(theme, "Adwaita");
        for ([_][*:0]const u8{
            "network-wireless-signal-good-symbolic",
            "battery-level-90-symbolic",
            "battery-level-50-charging-symbolic",
            "audio-volume-medium-symbolic",
            "microphone-sensitivity-high-symbolic",
            "microphone-sensitivity-muted-symbolic",
            "display-brightness-symbolic",
        }) |name| {
            for ([_]c_int{ 1, 2 }) |scale| {
                var err: [*c]c.GError = null;
                const pixbuf = c.gtk_icon_theme_load_icon_for_scale(theme, name, 16, scale, 0, &err);
                if (err != null) c.g_printerr("Cannot load %s: %s\n", name, err.*.message);
                assert(err == null and pixbuf != null);
                assert(c.gdk_pixbuf_get_width(pixbuf) > 0 and c.gdk_pixbuf_get_height(pixbuf) > 0);
                c.g_object_unref(pixbuf);
            }
        }
    }
    c.g_object_set(c.gtk_settings_get_default(), "gtk-enable-animations", @as(c_int, 0), @as(?*anyopaque, null));
    const executable = try process_init.arena.allocator().dupeSentinel(u8, args[0], 0);
    _ = c.g_setenv("DESKTOP_POWER_PKEXEC", executable.ptr, 1);
    _ = c.g_setenv("DESKTOP_POWER_HELPER", "--power-fixture", 1);
    const status_window = c.gtk_window_new(c.GTK_WINDOW_TOPLEVEL);
    c.gtk_widget_set_name(status_window, "desktop-panel");
    const status_root = root();
    c.gtk_container_add(cast(c.GtkContainer, status_window), status_root);
    const status = p.init(status_root, .{ .name = "gnome-status" });
    assert(c.gtk_widget_is_ancestor(status.quick.?.canvas, status.power_menu) != 0);
    assert(c.gtk_widget_is_ancestor(status.quick.?.canvas, status.box) == 0);
    p.update_line(status, "{\"items\":[{\"icon\":\"audio-volume-high-symbolic\"},{\"icon\":\"battery-level-80-symbolic\"}]}");
    assert(status.view.items[0].visible and status.view.items[1].visible);
    p.update_line(status, "{\"items\":[{\"icon\":\"network-wired-symbolic\",\"tooltip\":\"Wired network\"}]}");
    // Collector tooltips must not overwrite the quick-settings connection name.
    assert(status.quick.?.view.model.network_title.len == 0);
    c.gtk_widget_show_all(status_window);
    pumpEvents(50);
    // The panel's CSS reset cannot alter the native tile geometry.
    var border: c.GtkBorder = undefined;
    c.gtk_style_context_get_border(c.gtk_widget_get_style_context(status_root), c.GTK_STATE_FLAG_NORMAL, &border);
    assert(border.top == 0 and border.left == 0);
    assert(status.quick.?.view.item(.wifi).?.rect.height == 48);
    const controls = status.quick.?;
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
    var drag = std.mem.zeroes(c.GdkEventButton);
    drag.type = c.GDK_BUTTON_PRESS;
    drag.button = 1;
    drag.x = slider.x + 8;
    drag.y = slider.y + slider.height / 2;
    var drag_handled: c.gboolean = 0;
    c.g_signal_emit_by_name(controls.canvas, "button-press-event", &drag, &drag_handled);
    assert(drag_handled != 0 and controls.view.model.volume.? == 0);
    var motion = std.mem.zeroes(c.GdkEventMotion);
    motion.type = 3; // GDK_MOTION_NOTIFY
    motion.x = slider.x + slider.width + 100;
    motion.y = slider.y + 100;
    c.g_signal_emit_by_name(controls.canvas, "motion-notify-event", &motion, &drag_handled);
    assert(controls.view.model.volume.? == 100);
    drag.type = 7;
    drag.x = motion.x;
    drag.y = motion.y;
    c.g_signal_emit_by_name(controls.canvas, "button-release-event", &drag, &drag_handled);
    assert(controls.view.pressed == .none and controls.view.model.volume.? == 100);
    controls.view.focus = .volume;
    assert(controls.handleKey(0xff50, 0) != 0 and controls.view.model.volume.? == 0); // Home
    assert(controls.handleKey(0xff53, 0) != 0 and controls.view.model.volume.? == 5); // Right
    assert(controls.handleKey(0xff57, 0) != 0 and controls.view.model.volume.? == 100); // End
    controls.view.focus = .network;
    assert(controls.handleKey(0xff0d, 0) != 0 and controls.view.submenu == .network);
    assert(controls.handleKey(0xff1b, 0) != 0 and controls.view.submenu == .none and controls.view.focus == .network);
    _ = c.g_source_remove(controls.volume_timer);
    controls.volume_timer = 0;
    controls.view.model.volume = previous_volume;
    controls.redraw();
    p.apply_power_state(status, .{ .available = .{ true, true, true }, .active = .balanced });
    clickControl(controls, .profiles);
    clickControl(controls, .profile0);
    p.deinit(status);
    pumpEvents(500);
    c.gtk_widget_destroy(status_window);
    c.g_object_unref(status_root);

    const codex_root = root();
    const usage = p.init(codex_root, .{ .name = "gnome-codex", .source = "codex" });
    p.refresh_source = &refresh;
    defer p.refresh_source = null;
    assert(c.gtk_popover_get_relative_to(cast(c.GtkPopover, usage.codex_menu)) == codex_root);
    const window = c.gtk_window_new(c.GTK_WINDOW_TOPLEVEL);
    c.gtk_container_add(cast(c.GtkContainer, window), codex_root);
    c.gtk_widget_show_all(window);
    var click = std.mem.zeroes(c.GdkEventButton);
    click.type = c.GDK_BUTTON_PRESS;
    click.button = 1;
    var handled: c.gboolean = 0;
    c.g_signal_emit_by_name(codex_root, "button-press-event", &click, &handled);
    assert(handled != 0 and c.gtk_widget_get_visible(usage.codex_menu) != 0);
    c.g_signal_emit_by_name(codex_root, "button-press-event", &click, &handled);
    assert(c.gtk_widget_get_visible(usage.codex_menu) == 0);
    p.update_line(usage, "{}");
    const refresh_rect = usage.codex.refreshRect();
    var refresh_click = std.mem.zeroes(c.GdkEventButton);
    refresh_click.button = 1;
    refresh_click.x = refresh_rect.x + refresh_rect.width / 2;
    refresh_click.y = refresh_rect.y + refresh_rect.height / 2;
    refresh_click.type = c.GDK_BUTTON_PRESS;
    c.g_signal_emit_by_name(usage.codex_canvas, "button-press-event", &refresh_click, &handled);
    refresh_click.type = 7;
    c.g_signal_emit_by_name(usage.codex_canvas, "button-release-event", &refresh_click, &handled);
    assert(refresh_count == 1);
    // Ignore another activation until the collector delivers completion.
    p.codex_refresh(usage);
    assert(refresh_count == 1);
    assert(!usage.codex.enabled);
    eq(usage.codex.checked.value, "Refreshing…");
    p.update_line(usage, "{\"items\":[{\"text\":\"54%\"}],\"tooltip\":\"5h: 54% remaining\",\"windows\":[{\"percent\":54,\"reset\":\"Resets in 2h 15m\"},{\"percent\":93,\"reset\":\"Resets in 4d 8h\"}],\"checked\":\"Checked: 12:00:00\"}");
    assert(usage.codex.enabled);
    var refresh_key = std.mem.zeroes(@import("desktop").apps.KeyEvent);
    refresh_key.event_type = 8; // GDK_KEY_PRESS
    refresh_key.keyval = 0xff0d;
    c.g_signal_emit_by_name(usage.codex_canvas, "key-press-event", &refresh_key, &handled);
    assert(handled != 0 and refresh_count == 2 and !usage.codex.enabled);
    p.update_line(usage, "{\"windows\":[{\"percent\":54,\"reset\":\"Resets in 2h 15m\"},{\"percent\":93,\"reset\":\"Resets in 4d 8h\"}],\"tooltip\":\"5h: 54% remaining\"}");
    eq(c.gtk_widget_get_tooltip_text(usage.box), "5h: 54% remaining");
    pumpEvents(50);
    var x: c.gint = 0;
    var y: c.gint = 0;
    _ = c.gdk_window_get_origin(c.gtk_widget_get_window(codex_root), &x, &y);
    const pointer = c.gdk_seat_get_pointer(c.gdk_display_get_default_seat(c.gdk_display_get_default()));
    c.gdk_device_warp(pointer, c.gdk_screen_get_default(), x + @divTrunc(c.gtk_widget_get_allocated_width(codex_root), 2), y + @divTrunc(c.gtk_widget_get_allocated_height(codex_root), 2));
    c.gtk_widget_trigger_tooltip_query(usage.box);
    pumpEvents(750);
    if (tooltipVisible()) {
        c.g_signal_emit_by_name(codex_root, "button-press-event", &click, &handled);
        assert(handled != 0 and c.gtk_widget_get_visible(usage.codex_menu) != 0);
        assert(!tooltipVisible());
    } else {
        c.g_signal_emit_by_name(codex_root, "button-press-event", &click, &handled);
        assert(handled != 0 and c.gtk_widget_get_visible(usage.codex_menu) != 0);
    }
    assert(c.gtk_widget_get_tooltip_text(usage.box) == null);
    p.update_line(usage, "{\"items\":[{\"text\":\"54%\"}],\"tooltip\":\"5h: 54% remaining\",\"windows\":[{\"percent\":54,\"reset\":\"Resets in 2h 15m\"},{\"percent\":93,\"reset\":\"Resets in 4d 8h\"}],\"checked\":\"Checked: 12:00:00\"}");
    assert(c.gtk_widget_get_tooltip_text(usage.box) == null);
    c.g_signal_emit_by_name(codex_root, "button-press-event", &click, &handled);
    assert(c.gtk_widget_get_visible(usage.codex_menu) == 0);
    eq(c.gtk_widget_get_tooltip_text(usage.box), "5h: 54% remaining");
    eq(usage.codex.percent[0].value, "54.0% remaining");
    eq(usage.codex.percent[1].value, "93.0% remaining");
    assert(usage.codex.values[0] == 54);
    assert(p.native.usageColor(54).green > 0.7);
    eq(usage.codex.reset[1].value, "Resets in 4d 8h");
    assert(usage.codex.error_label.value.len == 0);
    p.update_line(usage, "{\"items\":[{\"text\":\"—\"}],\"windows\":[],\"error\":\"Sign in with codex login\"}");
    eq(usage.codex.percent[0].value, "—");
    assert(usage.codex.values[0] == 0 and usage.codex.error_label.value.len > 0);
    p.deinit(usage);
    c.gtk_widget_destroy(window);
    c.g_object_unref(codex_root);

    const clock_root = root();
    const clock = p.init(clock_root, .{ .kind = "clock" });
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
    c.gtk_widget_destroy(clock_root);
    c.g_object_unref(clock_root);
    // Exercise graph history rollover and the native draw callback after migration.
    const graph_root = root();
    const monitors = p.init(graph_root, .{ .kind = "monitors" });
    var sample_buf: [256:0]u8 = undefined;
    for (0..130) |i| {
        const sample = try std.fmt.bufPrintSentinel(&sample_buf, "{{\"monitors\":[{{\"sequence\":{d},\"values\":[{d}],\"colors\":[\"#0072b3\"],\"maximum\":100}}]}}", .{ i, i }, 0);
        p.update_line(monitors, sample);
    }
    assert(monitors.view.graphs[0].count == 100);
    assert(monitors.view.graphs[0].history[0][0] == 30 and monitors.view.graphs[0].history[0][99] == 129);
    var pixels: [100 * 32]u32 = @splat(0);
    monitors.view.graphs[0].paint(.{ .target = .{ .pixels = &pixels, .width = 100, .height = 32 }, .scale = 1 }, 0, 100, 32);
    assert(pixels[pixels.len - 1] != 0);
    p.deinit(monitors);
    c.gtk_widget_destroy(graph_root);
    c.g_object_unref(graph_root);
    std.debug.print("desktop-widgets: power controls, quick settings, calendar, codex and monitors graph passed\n", .{});
}
