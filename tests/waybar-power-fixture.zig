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
fn rootWidget(module: ?*p.WaybarModule) callconv(.c) [*c]c.GtkContainer {
    return @ptrCast(@alignCast(module));
}
fn root() *c.GtkWidget {
    const widget = c.gtk_event_box_new();
    _ = c.g_object_ref_sink(widget);
    return widget;
}
fn init(widget: *c.GtkWidget, config: []const p.ConfigEntry) *p.Module {
    const info = p.InitInfo{ .obj = @ptrCast(widget), .get_root_widget = &rootWidget };
    return @ptrCast(@alignCast(p.wbcffi_init(&info, config.ptr, config.len).?));
}
fn setProperty(m: *p.Module, name: [:0]const u8, value: ?*c.GVariant) void {
    c.g_dbus_proxy_set_cached_property(m.power, name, value);
    p.update_power(m);
}
fn bluetoothOutput(m: *p.Module, output: [:0]const u8) void {
    var err: [*c]c.GError = null;
    const argv = [_:null]?[*:0]const u8{ "printf", "%s", output };
    const process = c.g_subprocess_newv(@ptrCast(&argv), c.G_SUBPROCESS_FLAGS_STDOUT_PIPE | c.G_SUBPROCESS_FLAGS_STDERR_PIPE, &err);
    assert(err == null and process != null);
    m.refs += 1;
    m.bluetooth_busy = 1;
    c.g_subprocess_communicate_utf8_async(process, null, null, &p.bluetooth_ready, m);
    while (m.bluetooth_busy != 0) _ = c.g_main_context_iteration(null, 1);
    c.g_object_unref(process);
}
pub fn main(process_init: std.process.Init) !void {
    c.gtk_init(null, null);
    c.g_object_set(c.gtk_settings_get_default(), "gtk-enable-animations", @as(c_int, 0), @as(?*anyopaque, null));
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const args = try process_init.minimal.args.toSlice(arena.allocator());
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
    m.power = @ptrCast(@alignCast(c.g_object_new(c.g_dbus_proxy_get_type(), "g-interface-name", @as([*:0]const u8, "org.freedesktop.UPower.PowerProfiles"), @as(?*anyopaque, null))));
    const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
    _ = c.g_object_ref_sink(box);
    m.power_label = c.gtk_label_new("");
    m.power_icon = c.gtk_image_new();
    m.power_message = c.gtk_label_new("");
    m.bluetooth_button = c.gtk_button_new();
    m.bluetooth_label = c.gtk_label_new("");
    m.bluetooth_message = c.gtk_label_new("");
    c.gtk_container_add(cast(c.GtkContainer, m.bluetooth_button), m.bluetooth_label);
    for ([_][*c]c.GtkWidget{ m.power_label, m.power_icon, m.power_message, m.bluetooth_button, m.bluetooth_message }) |widget| c.gtk_container_add(cast(c.GtkContainer, box), widget);
    for (&m.power_buttons) |*button| {
        button.* = c.gtk_button_new();
        c.gtk_container_add(cast(c.GtkContainer, box), button.*);
    }
    p.update_power(&m);
    eq(c.gtk_label_get_text(cast(c.GtkLabel, m.power_message)), "Power profiles unavailable");
    for (m.power_buttons) |button| assert(c.gtk_widget_get_visible(button) == 0);
    var err: [*c]c.GError = null;
    const profiles = c.g_variant_parse(null, "[{'Profile': <'balanced'>}, {'Profile': <'power-saver'>}]", null, null, &err);
    assert(err == null);
    setProperty(&m, "Profiles", profiles);
    c.g_variant_unref(profiles);
    setProperty(&m, "ActiveProfile", c.g_variant_new_string("balanced"));
    assert(c.gtk_widget_get_visible(m.power_buttons[0]) == 0);
    assert(c.gtk_widget_get_visible(m.power_buttons[1]) != 0 and c.gtk_widget_get_visible(m.power_buttons[2]) != 0);
    eq(c.gtk_label_get_text(cast(c.GtkLabel, m.power_label)), "Balanced");
    eq(c.gtk_button_get_label(cast(c.GtkButton, m.power_buttons[1])), "Balanced  ✓");
    setProperty(&m, "ActiveProfile", c.g_variant_new_string("power-saver"));
    eq(c.gtk_label_get_text(cast(c.GtkLabel, m.power_label)), "Power Saver");
    eq(c.gtk_button_get_label(cast(c.GtkButton, m.power_buttons[1])), "Balanced");
    eq(c.gtk_button_get_label(cast(c.GtkButton, m.power_buttons[2])), "Power Saver  ✓");
    m.power_pending = 1;
    p.update_power(&m);
    assert(c.gtk_widget_get_sensitive(m.power_buttons[2]) == 0);
    m.power_pending = 0;
    p.update_power(&m);
    assert(c.gtk_widget_get_sensitive(m.power_buttons[2]) != 0);
    const all_profiles = c.g_variant_parse(null, "[{'Profile': <'performance'>}, {'Profile': <'balanced'>}, {'Profile': <'power-saver'>}]", null, null, &err);
    assert(err == null);
    setProperty(&m, "Profiles", all_profiles);
    c.g_variant_unref(all_profiles);
    assert(c.gtk_widget_get_visible(m.power_buttons[0]) != 0);
    setProperty(&m, "PerformanceInhibited", c.g_variant_new_string("lap-detected"));
    assert(c.gtk_widget_get_sensitive(m.power_buttons[0]) == 0 and c.gtk_widget_get_sensitive(m.power_buttons[1]) != 0);
    setProperty(&m, "PerformanceInhibited", c.g_variant_new_string(""));
    assert(c.gtk_widget_get_sensitive(m.power_buttons[0]) != 0);
    bluetoothOutput(&m, "Controller 00:11:22:33:44:55\n\tPowered: yes\n");
    assert(m.bluetooth_powered != 0 and c.gtk_widget_get_sensitive(m.bluetooth_button) != 0);
    assert(c.gtk_style_context_has_class(c.gtk_widget_get_style_context(m.bluetooth_button), "quick-active") != 0);
    eq(c.gtk_label_get_text(cast(c.GtkLabel, m.bluetooth_label)), "On");
    bluetoothOutput(&m, "Controller 00:11:22:33:44:55\n\tPowered: no\n");
    assert(m.bluetooth_powered == 0 and c.gtk_widget_get_sensitive(m.bluetooth_button) != 0);
    assert(c.gtk_style_context_has_class(c.gtk_widget_get_style_context(m.bluetooth_button), "quick-active") == 0);
    bluetoothOutput(&m, "No default controller available\n");
    assert(c.gtk_widget_get_sensitive(m.bluetooth_button) == 0);
    eq(c.gtk_label_get_text(cast(c.GtkLabel, m.bluetooth_message)), "Bluetooth unavailable");

    const status_root = root();
    const status = init(status_root, &.{ .{ .key = "name", .value = "\"gnome-status\"" }, .{ .key = "kind", .value = "\"indicator\"" } });
    for ([_][*c]c.GtkWidget{ status.power_label, status.bluetooth_button, status.network_icon }) |widget| assert(c.gtk_widget_is_ancestor(widget, status.power_menu) != 0);
    assert(c.gtk_widget_is_ancestor(status.power_label, status.box) == 0);
    p.update_line(status, "{\"items\":[{\"icon\":\"bluetooth-active-symbolic\"},{\"icon\":\"battery-level-80-symbolic\"}]}");
    assert(c.gtk_widget_get_visible(status.item[0].box) != 0 and c.gtk_widget_get_visible(status.item[1].box) != 0);
    p.update_line(status, "{\"items\":[{\"icon\":\"network-wired-symbolic\",\"tooltip\":\"Wired network\"}]}");
    eq(c.gtk_label_get_text(cast(c.GtkLabel, status.network_label)), "Wired network");
    p.wbcffi_deinit(status);
    while (c.g_main_context_iteration(null, 0) != 0) {}
    c.gtk_widget_destroy(status_root);
    c.g_object_unref(status_root);

    const codex_root = root();
    const usage = init(codex_root, &.{ .{ .key = "name", .value = "\"gnome-codex\"" }, .{ .key = "kind", .value = "\"indicator\"" } });
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
    p.update_line(usage, "{\"items\":[{\"text\":\"54%\"}],\"tooltip\":\"5h: 54% remaining\",\"windows\":[{\"percent\":54,\"reset\":\"Resets in 2h 15m\"},{\"percent\":93,\"reset\":\"Resets in 4d 8h\"}],\"checked\":\"Checked: 12:00:00\"}");
    eq(c.gtk_widget_get_tooltip_text(usage.box), "5h: 54% remaining");
    pumpEvents(50);
    var x: c.gint = 0;
    var y: c.gint = 0;
    _ = c.gdk_window_get_origin(c.gtk_widget_get_window(codex_root), &x, &y);
    const pointer = c.gdk_seat_get_pointer(c.gdk_display_get_default_seat(c.gdk_display_get_default()));
    c.gdk_device_warp(pointer, c.gdk_screen_get_default(), x + @divTrunc(c.gtk_widget_get_allocated_width(codex_root), 2), y + @divTrunc(c.gtk_widget_get_allocated_height(codex_root), 2));
    c.gtk_widget_trigger_tooltip_query(usage.box);
    pumpEvents(750);
    assert(tooltipVisible());
    c.g_signal_emit_by_name(codex_root, "button-press-event", &click, &handled);
    assert(handled != 0 and c.gtk_widget_get_visible(usage.codex_menu) != 0);
    assert(!tooltipVisible());
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
    p.wbcffi_deinit(usage);
    c.gtk_widget_destroy(window);
    c.g_object_unref(codex_root);

    const clock_root = root();
    const clock = init(clock_root, &.{.{ .key = "kind", .value = "\"clock\"" }});
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
    p.wbcffi_deinit(clock);
    c.gtk_widget_destroy(clock_root);
    c.g_object_unref(clock_root);
    // Exercise graph history rollover and the native draw callback after migration.
    const graph_root = root();
    const monitors = init(graph_root, &.{.{ .key = "kind", .value = "\"monitors\"" }});
    for (0..130) |i| {
        const sample = try std.fmt.allocPrintSentinel(arena.allocator(), "{{\"monitors\":[{{\"sequence\":{d},\"values\":[{d}],\"colors\":[\"#0072b3\"],\"maximum\":100}}]}}", .{ i, i }, 0);
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
    p.wbcffi_deinit(monitors);
    c.gtk_widget_destroy(graph_root);
    c.g_object_unref(graph_root);
    c.gtk_widget_destroy(box);
    c.g_object_unref(box);
    c.g_object_unref(m.power);
}
