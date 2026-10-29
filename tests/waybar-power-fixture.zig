//! GTK integration tests. Run under Xvfb; never uses the user's desktop.
const std = @import("std");
const p = @import("panel");
const c = p.c;
const assert = std.debug.assert;
fn cast(comptime T: type, ptr: anytype) *T {
    return @ptrCast(@alignCast(ptr));
}
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
pub fn main(process_init: std.process.Init) !void {
    const args = try process_init.minimal.args.toSlice(process_init.arena.allocator());
    // Re-exec this fixture in place of pkexec to exercise argv, async completion,
    // error reporting and disposal without authorization or real sysfs writes.
    if (args.len == 5 and std.mem.eql(u8, args[1], "--power-fixture")) {
        assert(std.mem.eql(u8, args[2], "power"));
        assert(std.mem.eql(u8, args[3], "set"));
        _ = try @import("power").Profile.parse(args[4]);
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
    if (args.len > 1) {
        const provider = c.gtk_css_provider_new();
        var err: [*c]c.GError = null;
        _ = c.gtk_css_provider_load_from_path(provider, args[1], &err);
        assert(err == null);
        c.gtk_style_context_add_provider_for_screen(c.gdk_screen_get_default(), cast(c.GtkStyleProvider, provider), c.GTK_STYLE_PROVIDER_PRIORITY_USER);
        c.g_object_unref(provider);
    }
    var m = p.Module{};
    m.refs = 1;
    const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
    _ = c.g_object_ref_sink(box);
    m.power_label = c.gtk_label_new("");
    m.power_icon = c.gtk_image_new();
    m.power_message = c.gtk_label_new("");
    for ([_][*c]c.GtkWidget{ m.power_label, m.power_icon, m.power_message }) |widget| c.gtk_container_add(cast(c.GtkContainer, box), widget);
    for (&m.power_buttons) |*button| {
        button.* = c.gtk_button_new();
        c.gtk_container_add(cast(c.GtkContainer, box), button.*);
    }
    p.apply_power_state(&m, .{});
    eq(c.gtk_label_get_text(cast(c.GtkLabel, m.power_message)), "Power profiles unavailable");
    for (m.power_buttons) |button| assert(c.gtk_widget_get_visible(button) == 0);
    p.apply_power_state(&m, .{ .available = .{ false, true, true }, .active = .balanced });
    assert(c.gtk_widget_get_visible(m.power_buttons[0]) == 0);
    assert(c.gtk_widget_get_visible(m.power_buttons[1]) != 0 and c.gtk_widget_get_visible(m.power_buttons[2]) != 0);
    eq(c.gtk_label_get_text(cast(c.GtkLabel, m.power_label)), "Balanced");
    eq(c.gtk_button_get_label(cast(c.GtkButton, m.power_buttons[1])), "Balanced  ✓");
    eq(c.gtk_label_get_text(cast(c.GtkLabel, m.power_message)), "");
    const saver = @import("power").State{ .available = .{ true, true, true }, .active = .@"power-saver" };
    p.apply_power_state(&m, saver);
    eq(c.gtk_label_get_text(cast(c.GtkLabel, m.power_label)), "Power Saver");
    eq(c.gtk_button_get_label(cast(c.GtkButton, m.power_buttons[1])), "Balanced");
    eq(c.gtk_button_get_label(cast(c.GtkButton, m.power_buttons[2])), "Power Saver  ✓");
    m.power_pending = 1;
    p.apply_power_state(&m, saver);
    assert(c.gtk_widget_get_sensitive(m.power_buttons[2]) == 0);
    m.power_pending = 0;
    p.apply_power_state(&m, saver);
    assert(c.gtk_widget_get_sensitive(m.power_buttons[2]) != 0);
    assert(c.gtk_widget_get_visible(m.power_buttons[0]) != 0);
    p.apply_power_state(&m, .{ .available = .{ true, true, true } });
    eq(c.gtk_label_get_text(cast(c.GtkLabel, m.power_label)), "Custom");
    const executable = try process_init.arena.allocator().dupeSentinel(u8, args[0], 0);
    _ = c.g_setenv("DESKTOP_POWER_PKEXEC", executable.ptr, 1);
    _ = c.g_setenv("DESKTOP_POWER_HELPER", "--power-fixture", 1);
    c.g_object_set_data(cast(c.GObject, m.power_buttons[0]), "profile", @constCast("performance"));
    p.power_select(cast(c.GtkButton, m.power_buttons[0]), &m);
    assert(m.power_pending != 0);
    pumpEvents(500);
    assert(m.power_pending == 0 and m.refs == 1);
    eq(c.gtk_label_get_text(cast(c.GtkLabel, m.power_message)), "");
    c.g_object_set_data(cast(c.GObject, m.power_buttons[2]), "profile", @constCast("power-saver"));
    p.power_select(cast(c.GtkButton, m.power_buttons[2]), &m);
    pumpEvents(500);
    assert(m.power_pending == 0 and m.refs == 1);
    eq(c.gtk_label_get_text(cast(c.GtkLabel, m.power_message)), "fixture: permission denied");

    const status_window = c.gtk_window_new(c.GTK_WINDOW_TOPLEVEL);
    c.gtk_widget_set_name(status_window, "desktop-panel");
    const status_root = root();
    c.gtk_container_add(cast(c.GtkContainer, status_window), status_root);
    const status = p.init(status_root, .{ .name = "gnome-status" });
    for ([_][*c]c.GtkWidget{ status.power_label, status.network_icon }) |widget| assert(c.gtk_widget_is_ancestor(widget, status.power_menu) != 0);
    assert(c.gtk_widget_is_ancestor(status.power_label, status.box) == 0);
    p.update_line(status, "{\"items\":[{\"icon\":\"audio-volume-high-symbolic\"},{\"icon\":\"battery-level-80-symbolic\"}]}");
    assert(c.gtk_widget_get_visible(status.item[0].box) != 0 and c.gtk_widget_get_visible(status.item[1].box) != 0);
    p.update_line(status, "{\"items\":[{\"icon\":\"network-wired-symbolic\",\"tooltip\":\"Wired network\"}]}");
    // Collector tooltips must not overwrite the quick-settings connection name.
    eq(c.gtk_label_get_text(cast(c.GtkLabel, status.network_label)), "");
    if (args.len > 1) {
        c.gtk_widget_show_all(status_window);
        pumpEvents(50);
        // A panel-scoped reset must not override the popup's more specific styles.
        const content = c.gtk_bin_get_child(cast(c.GtkBin, status.power_menu));
        var border: c.GtkBorder = undefined;
        c.gtk_style_context_get_border(c.gtk_widget_get_style_context(content), c.GTK_STATE_FLAG_NORMAL, &border);
        std.debug.print("quick settings: content border {d}px\n", .{border.top});
        assert(border.top == 1 and border.left == 1);
        c.gtk_style_context_get_border(c.gtk_widget_get_style_context(status_root), c.GTK_STATE_FLAG_NORMAL, &border);
        std.debug.print("quick settings: panel module border {d}px\n", .{border.top});
        assert(border.top == 3 and border.left == 3);
        const network = status.quick.?.network.button;
        var height: c.GValue = std.mem.zeroes(c.GValue);
        c.gtk_style_context_get_property(c.gtk_widget_get_style_context(network), "min-height", c.GTK_STATE_FLAG_NORMAL, &height);
        std.debug.print("quick settings: tile minimum height {d}px\n", .{c.g_value_get_int(&height)});
        assert(c.g_value_get_int(&height) == 48);
        c.g_value_unset(&height);
    }
    const controls = status.quick.?;
    const refs_before_refresh = status.refs;
    // Refreshing the tile must never launch another profile change, including
    // transitions between balanced (inactive) and either active toggle state.
    for ([_]?@import("power").Profile{ .performance, .balanced, .@"power-saver", .balanced, null }) |profile| {
        p.apply_power_state(status, .{ .available = .{ true, true, true }, .active = profile });
        assert(status.power_pending == 0 and status.refs == refs_before_refresh);
        assert(c.gtk_toggle_button_get_active(cast(c.GtkToggleButton, controls.power.button)) == @intFromBool(profile != null and profile.? != .balanced));
    }
    // User clicks still dispatch once; async completion must not dispatch again.
    c.gtk_button_clicked(cast(c.GtkButton, controls.power.button));
    assert(status.power_pending != 0);
    pumpEvents(500);
    assert(status.power_pending == 0);
    if (controls.interface) |prefs| {
        const before = c.gtk_toggle_button_get_active(cast(c.GtkToggleButton, controls.dark.button));
        c.gtk_button_clicked(cast(c.GtkButton, controls.dark.button));
        assert(c.gtk_toggle_button_get_active(cast(c.GtkToggleButton, controls.dark.button)) != before);
        const color_scheme = c.g_settings_get_string(prefs, "color-scheme");
        eq(color_scheme, if (before == 0) "prefer-dark" else "default");
        c.g_free(color_scheme);
    }
    if (controls.notifications) |prefs| {
        const before = c.g_settings_get_boolean(prefs, "show-banners");
        c.gtk_button_clicked(cast(c.GtkButton, controls.dnd.button));
        assert(c.g_settings_get_boolean(prefs, "show-banners") != before);
        _ = c.g_settings_set_boolean(prefs, "show-banners", before);
    }
    c.gtk_toggle_button_set_active(cast(c.GtkToggleButton, controls.power.arrow.?), 1);
    assert(c.gtk_widget_get_visible(controls.profile_menu) != 0);
    c.gtk_toggle_button_set_active(cast(c.GtkToggleButton, controls.network.arrow.?), 1);
    assert(c.gtk_widget_get_visible(controls.network_menu) != 0 and c.gtk_widget_get_visible(controls.profile_menu) == 0);
    c.gtk_toggle_button_set_active(cast(c.GtkToggleButton, controls.network.arrow.?), 0);
    assert(c.gtk_widget_get_visible(controls.network_menu) == 0);
    p.power_select(cast(c.GtkButton, status.power_buttons[0]), status);
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
    c.gtk_button_clicked(cast(c.GtkButton, usage.codex_refresh));
    assert(refresh_count == 1);
    assert(c.gtk_widget_get_sensitive(usage.codex_refresh) == 0);
    eq(c.gtk_label_get_text(cast(c.GtkLabel, usage.codex_checked)), "Refreshing…");
    p.update_line(usage, "{\"items\":[{\"text\":\"54%\"}],\"tooltip\":\"5h: 54% remaining\",\"windows\":[{\"percent\":54,\"reset\":\"Resets in 2h 15m\"},{\"percent\":93,\"reset\":\"Resets in 4d 8h\"}],\"checked\":\"Checked: 12:00:00\"}");
    assert(c.gtk_widget_get_sensitive(usage.codex_refresh) != 0);
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
    eq(c.gtk_label_get_text(cast(c.GtkLabel, usage.codex_percent[0])), "54.0% remaining");
    eq(c.gtk_label_get_text(cast(c.GtkLabel, usage.codex_percent[1])), "93.0% remaining");
    assert(@abs(c.gtk_progress_bar_get_fraction(cast(c.GtkProgressBar, usage.codex_progress[0])) - 0.54) < 0.001);
    assert(c.gtk_style_context_has_class(c.gtk_widget_get_style_context(usage.codex_progress[0]), "usage-medium") != 0);
    eq(c.gtk_label_get_text(cast(c.GtkLabel, usage.codex_reset[1])), "Resets in 4d 8h");
    assert(c.gtk_widget_get_visible(usage.codex_error) == 0);
    p.update_line(usage, "{\"items\":[{\"text\":\"—\"}],\"windows\":[],\"error\":\"Sign in with codex login\"}");
    eq(c.gtk_label_get_text(cast(c.GtkLabel, usage.codex_percent[0])), "—");
    assert(c.gtk_progress_bar_get_fraction(cast(c.GtkProgressBar, usage.codex_progress[0])) == 0 and c.gtk_widget_get_visible(usage.codex_error) != 0);
    p.deinit(usage);
    c.gtk_widget_destroy(window);
    c.g_object_unref(codex_root);

    const clock_root = root();
    const clock = p.init(clock_root, .{ .kind = "clock" });
    c.g_date_time_unref(clock.calendar_selected);
    clock.calendar_selected = c.g_date_time_new_local(2024, 2, 29, 12, 0, 0);
    p.calendar_refresh(clock);
    eq(c.gtk_button_get_label(cast(c.GtkButton, clock.calendar_days[32])), "29");
    assert(c.gtk_style_context_has_class(c.gtk_widget_get_style_context(clock.calendar_days[32]), "calendar-selected") != 0);
    p.calendar_select(cast(c.GtkButton, clock.calendar_days[33]), clock);
    assert(c.g_date_time_get_month(clock.calendar_selected) == 3 and c.g_date_time_get_day_of_month(clock.calendar_selected) == 1);
    const previous = c.gtk_button_new();
    _ = c.g_object_ref_sink(previous);
    c.g_object_set_data(cast(c.GObject, previous), "month-offset", @ptrFromInt(@as(usize, @bitCast(@as(isize, -1)))));
    for (0..3) |_| p.calendar_navigate(cast(c.GtkButton, previous), clock);
    assert(c.g_date_time_get_year(clock.calendar_selected) == 2023 and c.g_date_time_get_month(clock.calendar_selected) == 12);
    p.calendar_navigate(null, clock);
    const now = c.g_date_time_new_now_local();
    assert(c.g_date_time_get_year(clock.calendar_selected) == c.g_date_time_get_year(now) and c.g_date_time_get_day_of_year(clock.calendar_selected) == c.g_date_time_get_day_of_year(now));
    c.g_date_time_unref(now);
    c.gtk_widget_destroy(previous);
    c.g_object_unref(previous);
    p.deinit(clock);
    c.gtk_widget_destroy(clock_root);
    c.g_object_unref(clock_root);
    // Exercise graph history rollover and the native draw callback after migration.
    const graph_root = root();
    const monitors = p.init(graph_root, .{ .kind = "monitors" });
    var sample_buf: [256:0]u8 = undefined;
    var num_buf: [16]u8 = undefined;
    for (0..130) |i| {
        const num_len = std.fmt.printInt(&num_buf, i, 10, .lower, .{});
        const num = num_buf[0..num_len];
        var pos: usize = 0;
        const p1 = "{\"monitors\":[{\"sequence\":";
        @memcpy(sample_buf[pos..pos + p1.len], p1); pos += p1.len;
        @memcpy(sample_buf[pos..pos + num.len], num); pos += num.len;
        const p2 = ",\"values\":[";
        @memcpy(sample_buf[pos..pos + p2.len], p2); pos += p2.len;
        @memcpy(sample_buf[pos..pos + num.len], num); pos += num.len;
        const p3 = "],\"colors\":[\"#0072b3\"],\"maximum\":100}]}";
        @memcpy(sample_buf[pos..pos + p3.len], p3); pos += p3.len;
        sample_buf[pos] = 0;
        const sample: [:0]const u8 = sample_buf[0..pos :0];
        p.update_line(monitors, sample);
    }
    assert(monitors.graph[0].count == 100);
    assert(monitors.graph[0].history[0][0] == 30 and monitors.graph[0].history[0][99] == 129);
    const surface = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, 100, 32);
    const context = c.cairo_create(surface);
    _ = p.draw_graph(monitors.graph[0].area, context, &monitors.graph[0]);
    assert(c.cairo_status(context) == c.CAIRO_STATUS_SUCCESS);
    c.cairo_destroy(context);
    c.cairo_surface_destroy(surface);
    p.deinit(monitors);
    c.gtk_widget_destroy(graph_root);
    c.g_object_unref(graph_root);
    c.gtk_widget_destroy(box);
    c.g_object_unref(box);
    std.debug.print("desktop-widgets: power controls, quick settings, calendar, codex and monitors graph passed\n", .{});
}
