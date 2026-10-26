//! Shared GTK widgets and popups for the standalone desktop panel.
const std = @import("std");
const power_backend = @import("power");
const notification_view = @import("desktop-notification-view.zig");
pub const c = @import("gtk");
fn cast(comptime T: type, p: anytype) [*c]T {
    return @ptrCast(@alignCast(p));
}
fn finite(value: f64) c_int {
    return @intFromBool(std.math.isFinite(value));
}
pub const Options = struct {
    name: [:0]const u8 = "",
    kind: [:0]const u8 = "indicator",
    exec: ?[:0]const u8 = null,
    on_click: ?[:0]const u8 = null,
    network_settings_command: ?[:0]const u8 = null,
    sound_settings_command: [:0]const u8 = "desktop-settings sound",
};
pub const Graph = extern struct {
    box: [*c]c.GtkWidget = null,
    label: [*c]c.GtkWidget = null,
    value: [*c]c.GtkWidget = null,
    area: [*c]c.GtkWidget = null,
    history: [5][100]f64 = std.mem.zeroes([5][100]f64),
    colors: [5]c.GdkRGBA = std.mem.zeroes([5]c.GdkRGBA),
    count: c.guint = 0,
    series: c.guint = 0,
    sequence: c.gint64 = 0,
    maximum: f64 = 0,
    autoscale: c.gboolean = 0,
};
pub const Item = extern struct {
    box: [*c]c.GtkWidget = null,
    image: [*c]c.GtkWidget = null,
    label: [*c]c.GtkWidget = null,
    icon: [*c]u8 = null,
    command: [*c]u8 = null,
};
pub const Module = extern struct {
    refs: c.gint = 0,
    dead: c.gboolean = 0,
    monitors: c.gboolean = 0,
    status: c.gboolean = 0,
    box: [*c]c.GtkWidget = null,
    root: [*c]c.GtkWidget = null,
    clock: [*c]c.GtkWidget = null,
    calendar: [*c]c.GtkWidget = null,
    calendar_today: [*c]c.GtkWidget = null,
    history_container: [*c]c.GtkWidget = null,
    history_empty: [*c]c.GtkWidget = null,
    history_clear: [*c]c.GtkWidget = null,
    history_subscription: c.guint = 0,
    history_busy: bool = false,
    calendar_month: [*c]c.GtkWidget = null,
    calendar_weekday: [*c]c.GtkWidget = null,
    calendar_date: [*c]c.GtkWidget = null,
    calendar_days: [42][*c]c.GtkWidget = std.mem.zeroes([42][*c]c.GtkWidget),
    calendar_selected: ?*c.GDateTime = null,
    graph: [3]Graph = std.mem.zeroes([3]Graph),
    item: [8]Item = std.mem.zeroes([8]Item),
    command: [*c]u8 = null,
    process: ?*c.GSubprocess = null,
    stream: [*c]c.GDataInputStream = null,
    cancel: [*c]c.GCancellable = null,
    restart: c.guint = 0,
    clock_timer: c.guint = 0,
    power_timer: c.guint = 0,
    session: ?*c.GDBusConnection = null,
    device_subscription: c.guint = 0,
    settings_subscription: c.guint = 0,
    power_menu: [*c]c.GtkWidget = null,
    power_label: [*c]c.GtkWidget = null,
    power_icon: [*c]c.GtkWidget = null,
    power_message: [*c]c.GtkWidget = null,
    power_buttons: [3][*c]c.GtkWidget = std.mem.zeroes([3][*c]c.GtkWidget),
    power_pending: c.gboolean = 0,
    network_icon: [*c]c.GtkWidget = null,
    network_label: [*c]c.GtkWidget = null,
    network_settings_command: [*c]u8 = null,
    codex_menu: [*c]c.GtkWidget = null,
    codex_percent: [2][*c]c.GtkWidget = std.mem.zeroes([2][*c]c.GtkWidget),
    codex_progress: [2][*c]c.GtkWidget = std.mem.zeroes([2][*c]c.GtkWidget),
    codex_reset: [2][*c]c.GtkWidget = std.mem.zeroes([2][*c]c.GtkWidget),
    codex_checked: [*c]c.GtkWidget = null,
    codex_refresh: [*c]c.GtkWidget = null,
    codex_error: [*c]c.GtkWidget = null,
    tooltip: [*c]u8 = null,
};
pub fn unref_module(m: *Module) callconv(.c) void {
    m.refs -= 1;
    if (m.refs != 0) return;
    if (m.stream != null) {
        c.g_object_unref(@as(c.gpointer, @ptrCast(m.stream)));
    }
    m.stream = null;
    if (m.process != null) {
        c.g_object_unref(@as(c.gpointer, @ptrCast(m.process)));
    }
    m.process = null;
    if (m.cancel != null) {
        c.g_object_unref(@as(c.gpointer, @ptrCast(m.cancel)));
    }
    m.cancel = null;
    if (m.session != null) c.g_object_unref(m.session);
    c.g_free(@as(c.gpointer, @ptrCast(m.command)));
    c.g_free(@as(c.gpointer, @ptrCast(m.network_settings_command)));
    c.g_free(@as(c.gpointer, @ptrCast(m.tooltip)));
    {
        var i: c.guint = 0;
        while (i < 8) : (i += 1) {
            c.g_free(@as(c.gpointer, @ptrCast(m.item[i].icon)));
            c.g_free(@as(c.gpointer, @ptrCast(m.item[i].command)));
        }
    }
    c.g_free(@as(c.gpointer, @ptrCast(m)));
}
pub fn css(widget: [*c]c.GtkWidget, name: [*c]const u8) callconv(.c) void {
    c.gtk_style_context_add_class(c.gtk_widget_get_style_context(widget), name);
}
pub fn settings_launch(button: [*c]c.GtkButton, data: c.gpointer) callconv(.c) void {
    var @"error": [*c]c.GError = null;
    _ = c.g_spawn_command_line_async(@as([*c]const c.gchar, @ptrCast(@alignCast(data))), &@"error");
    c.gtk_widget_set_tooltip_text(cast(c.GtkWidget, button), if (@"error" != null) @"error".*.message else null);
    c.g_clear_error(&@"error");
}
fn free_command(data: c.gpointer, _: ?*c.GClosure) callconv(.c) void {
    c.g_free(data);
}
pub var power_ids: [3][*c]const u8 = [3][*c]const u8{
    "performance",
    "balanced",
    "power-saver",
};
pub var power_names: [3][*c]const u8 = [3][*c]const u8{
    "Performance",
    "Balanced",
    "Power Saver",
};
pub var power_icons: [3][*c]const u8 = [3][*c]const u8{
    "power-profile-performance-symbolic",
    "power-profile-balanced-symbolic",
    "power-profile-power-saver-symbolic",
};
pub fn power_expand(button: [*c]c.GtkToggleButton, data: c.gpointer) callconv(.c) void {
    c.gtk_revealer_set_reveal_child(cast(c.GtkRevealer, data), c.gtk_toggle_button_get_active(button));
}
pub fn message_changed(label: [*c]c.GObject, property: [*c]c.GParamSpec, data: c.gpointer) callconv(.c) void {
    _ = data;
    _ = property;
    c.gtk_widget_set_visible(cast(c.GtkWidget, label), @intFromBool(@as(c_int, @bitCast(@as(c_uint, c.gtk_label_get_text(cast(c.GtkLabel, label)).*))) != @as(c_int, '\x00')));
}
pub fn quick_tile(button: [*c]c.GtkWidget, title: [*c]const u8, icon: [*c]c.GtkWidget, subtitle: [*c]c.GtkWidget, arrow: c.gboolean) callconv(.c) [*c]c.GtkWidget {
    css(button, "quick-toggle");
    const row: [*c]c.GtkWidget = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 10);
    const labels: [*c]c.GtkWidget = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 2);
    c.gtk_widget_set_valign(labels, c.GTK_ALIGN_CENTER);
    const heading: [*c]c.GtkWidget = c.gtk_label_new(title);
    c.gtk_label_set_xalign(cast(c.GtkLabel, heading), 0);
    css(heading, "quick-toggle-title");
    c.gtk_box_pack_start(cast(c.GtkBox, labels), heading, 0, 0, 0);
    if (subtitle != null) {
        c.gtk_label_set_xalign(cast(c.GtkLabel, subtitle), 0);
        css(subtitle, "quick-toggle-subtitle");
        c.gtk_box_pack_start(cast(c.GtkBox, labels), subtitle, 0, 0, 0);
    }
    c.gtk_box_pack_start(cast(c.GtkBox, row), icon, 0, 0, 0);
    c.gtk_box_pack_start(cast(c.GtkBox, row), labels, 1, 1, 0);
    if (arrow != 0) {
        c.gtk_box_pack_end(cast(c.GtkBox, row), c.gtk_image_new_from_icon_name("go-next-symbolic", c.GTK_ICON_SIZE_MENU), 0, 0, 0);
    }
    c.gtk_container_add(cast(c.GtkContainer, button), row);
    return button;
}
pub fn apply_power_state(m: *Module, state: power_backend.State) void {
    c.gtk_label_set_text(cast(c.GtkLabel, m.power_label), if (state.available[1]) "Custom" else "Power Mode");
    c.gtk_image_set_from_icon_name(cast(c.GtkImage, m.power_icon), power_icons[1], c.GTK_ICON_SIZE_MENU);
    for (0..3) |i| {
        const selected = if (state.active) |active| @backingInt(active) == i else false;
        const style = c.gtk_widget_get_style_context(m.power_buttons[i]);
        if (selected) c.gtk_style_context_add_class(style, "profile-selected") else c.gtk_style_context_remove_class(style, "profile-selected");
        const label = c.g_strdup_printf("%s%s", power_names[i], @as([*:0]const u8, if (selected) "  ✓" else ""));
        defer c.g_free(label);
        c.gtk_button_set_label(cast(c.GtkButton, m.power_buttons[i]), label);
        c.gtk_widget_set_visible(m.power_buttons[i], @intFromBool(state.available[i]));
        c.gtk_widget_set_sensitive(m.power_buttons[i], @intFromBool(m.power_pending == 0));
        if (selected) {
            c.gtk_label_set_text(cast(c.GtkLabel, m.power_label), power_names[i]);
            c.gtk_image_set_from_icon_name(cast(c.GtkImage, m.power_icon), power_icons[i], c.GTK_ICON_SIZE_MENU);
        }
    }
    const available = state.available[0] or state.available[1] or state.available[2];
    if (!available) c.gtk_label_set_text(cast(c.GtkLabel, m.power_message), "Power profiles unavailable") else if (c.g_strcmp0(c.gtk_label_get_text(cast(c.GtkLabel, m.power_message)), "Power profiles unavailable") == 0) c.gtk_label_set_text(cast(c.GtkLabel, m.power_message), "");
}
pub fn update_power(m: *Module) callconv(.c) void {
    apply_power_state(m, (power_backend.Backend{}).inspect());
}
fn refresh_power(data: c.gpointer) callconv(.c) c.gboolean {
    const m: *Module = @ptrCast(@alignCast(data));
    if (m.dead != 0) return 0;
    update_power(m);
    return 1;
}
pub fn power_set_ready(source: ?*c.GObject, result: ?*c.GAsyncResult, data: c.gpointer) callconv(.c) void {
    const m: *Module = @ptrCast(@alignCast(data));
    var err: [*c]c.GError = null;
    var errors: [*c]u8 = null;
    const process: *c.GSubprocess = @ptrCast(@alignCast(source));
    const communicated = c.g_subprocess_communicate_utf8_finish(process, result, null, &errors, &err) != 0;
    defer c.g_clear_error(&err);
    defer c.g_free(errors);
    if (m.dead == 0) {
        m.power_pending = 0;
        update_power(m);
        c.gtk_label_set_text(cast(c.GtkLabel, m.power_message), if (err != null) err.*.message else if (!communicated or c.g_subprocess_get_successful(process) == 0) (if (errors != null and errors[0] != 0) errors else "Could not change the power profile") else "");
    }
    unref_module(m);
}
pub fn power_select(button: [*c]c.GtkButton, data: c.gpointer) callconv(.c) void {
    const m: *Module = @ptrCast(@alignCast(data));
    if (m.power_pending != 0) return;
    const id: [*c]const u8 = @ptrCast(c.g_object_get_data(cast(c.GObject, button), "profile"));
    const helper = c.g_getenv("DESKTOP_POWER_HELPER");
    const pkexec = c.g_getenv("DESKTOP_POWER_PKEXEC");
    if (helper == null or pkexec == null) {
        c.gtk_label_set_text(cast(c.GtkLabel, m.power_message), "Power profile helper unavailable");
        return;
    }
    var err: [*c]c.GError = null;
    const argv = [_][*c]const u8{ pkexec, helper, "set", id, null };
    const process = c.g_subprocess_newv(&argv, c.G_SUBPROCESS_FLAGS_STDERR_PIPE | c.G_SUBPROCESS_FLAGS_STDOUT_SILENCE, &err);
    if (process == null) {
        c.gtk_label_set_text(cast(c.GtkLabel, m.power_message), if (err != null) err.*.message else "Could not start the power profile helper");
        c.g_clear_error(&err);
        return;
    }
    defer c.g_object_unref(process);
    m.power_pending = 1;
    update_power(m);
    c.gtk_label_set_text(cast(c.GtkLabel, m.power_message), "Switching…");
    m.refs += 1;
    c.g_subprocess_communicate_utf8_async(process, null, m.cancel, &power_set_ready, m);
}
pub fn power_click(widget: [*c]c.GtkWidget, event: [*c]c.GdkEventButton, data: c.gpointer) callconv(.c) c.gboolean {
    _ = widget;
    const m: *Module = @as(*Module, @ptrCast(@alignCast(data)));
    if (event.*.button != 1) return 0;
    if (c.gtk_widget_get_visible(m.power_menu) != 0) {
        c.gtk_popover_popdown(cast(c.GtkPopover, m.power_menu));
    } else {
        c.gtk_popover_popup(cast(c.GtkPopover, m.power_menu));
    }
    return 1;
}
pub fn update_clock(data: c.gpointer) callconv(.c) c.gboolean {
    const m: *Module = @as(*Module, @ptrCast(@alignCast(data)));
    const now: ?*c.GDateTime = c.g_date_time_new_now_local();
    const month: [*c]u8 = c.g_date_time_format(now, "%b");
    const time_1: [*c]u8 = c.g_date_time_format(now, "%H:%M");
    const label: [*c]u8 = c.g_strdup_printf("%s %d %s", month, c.g_date_time_get_day_of_month(now), time_1);
    c.gtk_label_set_text(cast(c.GtkLabel, m.clock), label);
    c.g_free(@as(c.gpointer, @ptrCast(label)));
    c.g_free(@as(c.gpointer, @ptrCast(month)));
    c.g_free(@as(c.gpointer, @ptrCast(time_1)));
    c.g_date_time_unref(now);
    return 1;
}
pub fn calendar_refresh(m: *Module) callconv(.c) void {
    const now: ?*c.GDateTime = c.g_date_time_new_now_local();
    const weekday: [*c]u8 = c.g_date_time_format(now, "%A");
    const date: [*c]u8 = c.g_date_time_format(now, "%B %-d %Y");
    const month_format: [*:0]const u8 = if (c.g_date_time_get_year(now) == c.g_date_time_get_year(m.calendar_selected)) "%B" else "%B %Y";
    const month = c.g_date_time_format(m.calendar_selected, month_format);
    c.gtk_widget_set_sensitive(m.calendar_today, @intFromBool(c.g_date_time_get_year(now) != c.g_date_time_get_year(m.calendar_selected) or c.g_date_time_get_day_of_year(now) != c.g_date_time_get_day_of_year(m.calendar_selected)));
    c.gtk_label_set_text(cast(c.GtkLabel, m.calendar_weekday), weekday);
    c.gtk_label_set_text(cast(c.GtkLabel, m.calendar_date), date);
    c.gtk_button_set_label(cast(c.GtkButton, m.calendar_month), month);
    c.g_free(@as(c.gpointer, @ptrCast(weekday)));
    c.g_free(@as(c.gpointer, @ptrCast(date)));
    c.g_free(@as(c.gpointer, @ptrCast(month)));
    const first: ?*c.GDateTime = c.g_date_time_add_days(m.calendar_selected, 1 - c.g_date_time_get_day_of_month(m.calendar_selected));
    const start: ?*c.GDateTime = c.g_date_time_add_days(first, -@import("std").zig.c_translation.helpers.signedRemainder(c.g_date_time_get_day_of_week(first), 7));
    {
        var i: c.guint = 0;
        while (@as(c_ulong, @bitCast(@as(c_ulong, i))) < (@sizeOf([42][*c]c.GtkWidget) / @sizeOf([*c]c.GtkWidget))) : (i += 1) {
            const day: ?*c.GDateTime = c.g_date_time_add_days(start, @as(c.gint, @bitCast(i)));
            const button: [*c]c.GtkWidget = m.calendar_days[i];
            const label: [*c]u8 = c.g_date_time_format(day, "%d");
            c.gtk_button_set_label(cast(c.GtkButton, button), label);
            c.g_free(@as(c.gpointer, @ptrCast(label)));
            c.g_object_set_data_full(cast(c.GObject, button), "date", @as(c.gpointer, @ptrCast(day)), @as(c.GDestroyNotify, @ptrCast(@alignCast(&c.g_date_time_unref))));
            const style: [*c]c.GtkStyleContext = c.gtk_widget_get_style_context(button);
            const classes: [3][*c]const u8 = [3][*c]const u8{
                "calendar-other-month",
                "calendar-today",
                "calendar-selected",
            };
            const active: [3]bool = [3]bool{
                c.g_date_time_get_month(day) != c.g_date_time_get_month(first),
                (c.g_date_time_get_year(day) == c.g_date_time_get_year(now)) and (c.g_date_time_get_day_of_year(day) == c.g_date_time_get_day_of_year(now)),
                (c.g_date_time_get_day_of_month(day) == c.g_date_time_get_day_of_month(m.calendar_selected)) and (c.g_date_time_get_month(day) == c.g_date_time_get_month(m.calendar_selected)),
            };
            {
                var j: c.guint = 0;
                while (@as(c_ulong, @bitCast(@as(c_ulong, j))) < (@sizeOf([3][*c]const u8) / @sizeOf([*c]const u8))) : (j += 1) {
                    if (active[j]) {
                        c.gtk_style_context_add_class(style, classes[j]);
                    } else {
                        c.gtk_style_context_remove_class(style, classes[j]);
                    }
                }
            }
        }
    }
    c.g_date_time_unref(start);
    c.g_date_time_unref(first);
    c.g_date_time_unref(now);
}
pub fn calendar_select(button: [*c]c.GtkButton, data: c.gpointer) callconv(.c) void {
    const m: *Module = @as(*Module, @ptrCast(@alignCast(data)));
    const day: ?*c.GDateTime = c.g_date_time_ref(@as(?*c.GDateTime, @ptrCast(c.g_object_get_data(cast(c.GObject, button), "date"))));
    c.g_date_time_unref(m.calendar_selected);
    m.calendar_selected = day;
    calendar_refresh(m);
}
pub fn calendar_navigate(button: [*c]c.GtkButton, data: c.gpointer) callconv(.c) void {
    const m: *Module = @as(*Module, @ptrCast(@alignCast(data)));
    const offset: c_int = if (button != null) @truncate(@as(isize, @bitCast(@intFromPtr(c.g_object_get_data(cast(c.GObject, button), "month-offset"))))) else 0;
    const day: ?*c.GDateTime = if (offset != 0) c.g_date_time_add_months(m.calendar_selected, offset) else c.g_date_time_new_now_local();
    if (!(day != null)) return;
    c.g_date_time_unref(m.calendar_selected);
    m.calendar_selected = day;
    calendar_refresh(m);
}
pub fn make_calendar(m: *Module) callconv(.c) void {
    const menu = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
    css(menu, "gnome-date-menu");
    c.gtk_container_add(cast(c.GtkContainer, m.calendar), menu);
    const left = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
    c.gtk_widget_set_margin_end(left, 4);
    c.gtk_box_pack_start(cast(c.GtkBox, menu), left, 0, 0, 0);
    const list = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
    c.gtk_box_pack_start(cast(c.GtkBox, left), list, 0, 0, 0);
    const separator = c.gtk_separator_new(c.GTK_ORIENTATION_VERTICAL);
    css(separator, "date-menu-separator");
    c.gtk_box_pack_start(cast(c.GtkBox, left), separator, 0, 0, 0);
    const overlay = c.gtk_overlay_new();
    c.gtk_widget_set_size_request(overlay, 425, 348);
    c.gtk_box_pack_start(cast(c.GtkBox, list), overlay, 1, 1, 0);
    const scroll = c.gtk_scrolled_window_new(null, null);
    c.gtk_scrolled_window_set_policy(cast(c.GtkScrolledWindow, scroll), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
    c.gtk_widget_set_margin_end(scroll, 12);
    c.gtk_container_add(cast(c.GtkContainer, overlay), scroll);
    m.history_container = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 12);
    c.gtk_container_add(cast(c.GtkContainer, scroll), m.history_container);
    m.history_empty = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 12);
    css(m.history_empty, "date-menu-placeholder");
    c.gtk_widget_set_halign(m.history_empty, c.GTK_ALIGN_CENTER);
    c.gtk_widget_set_valign(m.history_empty, c.GTK_ALIGN_CENTER);
    const bell = c.gtk_image_new_from_icon_name("no-notifications-symbolic", c.GTK_ICON_SIZE_DIALOG);
    c.gtk_image_set_pixel_size(cast(c.GtkImage, bell), 96);
    c.gtk_box_pack_start(cast(c.GtkBox, m.history_empty), bell, 0, 0, 0);
    c.gtk_box_pack_start(cast(c.GtkBox, m.history_empty), c.gtk_label_new("No Notifications"), 0, 0, 0);
    c.gtk_overlay_add_overlay(cast(c.GtkOverlay, overlay), m.history_empty);
    const controls = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
    css(controls, "date-menu-controls");
    m.history_clear = c.gtk_button_new_with_label("Clear");
    css(m.history_clear, "date-menu-clear");
    c.gtk_widget_set_sensitive(m.history_clear, 0);
    _ = c.g_signal_connect_data(m.history_clear, "clicked", @ptrCast(&history_clear), m, null, 0);
    c.gtk_box_pack_start(cast(c.GtkBox, controls), m.history_clear, 0, 0, 0);
    c.gtk_box_pack_start(cast(c.GtkBox, list), controls, 0, 0, 0);
    const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 6);
    c.gtk_widget_set_margin_start(box, 6);
    c.gtk_widget_set_size_request(box, 290, 397);
    c.gtk_box_pack_start(cast(c.GtkBox, menu), box, 0, 0, 0);
    const today = c.gtk_button_new();
    m.calendar_today = today;
    css(today, "calendar-today-button");
    c.gtk_widget_set_margin_start(today, 4);
    c.gtk_widget_set_margin_end(today, 4);
    c.gtk_widget_set_margin_top(today, 4);
    c.gtk_widget_set_margin_bottom(today, 4);
    _ = c.g_signal_connect_data(today, "clicked", @ptrCast(&calendar_navigate), m, null, 0);
    const heading = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
    m.calendar_weekday = c.gtk_label_new("");
    m.calendar_date = c.gtk_label_new("");
    css(m.calendar_weekday, "calendar-weekday-label");
    css(m.calendar_date, "calendar-date-label");
    c.gtk_label_set_xalign(cast(c.GtkLabel, m.calendar_weekday), 0);
    c.gtk_label_set_xalign(cast(c.GtkLabel, m.calendar_date), 0);
    c.gtk_box_pack_start(cast(c.GtkBox, heading), m.calendar_weekday, 0, 0, 0);
    c.gtk_box_pack_start(cast(c.GtkBox, heading), m.calendar_date, 0, 0, 0);
    c.gtk_container_add(cast(c.GtkContainer, today), heading);
    c.gtk_box_pack_start(cast(c.GtkBox, box), today, 0, 0, 0);
    const calendar = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
    css(calendar, "calendar-grid");
    c.gtk_widget_set_margin_start(calendar, 4);
    c.gtk_widget_set_margin_end(calendar, 4);
    c.gtk_widget_set_margin_bottom(calendar, 4);
    c.gtk_box_pack_start(cast(c.GtkBox, box), calendar, 0, 0, 0);
    const header = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
    c.gtk_widget_set_size_request(header, 280, 38);
    c.gtk_box_pack_start(cast(c.GtkBox, calendar), header, 0, 0, 0);
    m.calendar_month = c.gtk_button_new();
    css(m.calendar_month, "calendar-month");
    c.gtk_widget_set_valign(m.calendar_month, c.GTK_ALIGN_CENTER);
    _ = c.g_signal_connect_data(m.calendar_month, "clicked", @ptrCast(&calendar_navigate), m, null, 0);
    c.gtk_box_set_center_widget(cast(c.GtkBox, header), m.calendar_month);
    for ([_]c_int{ -1, 1 }) |offset| {
        const arrow = c.gtk_button_new_from_icon_name(if (offset < 0) "pan-start-symbolic" else "pan-end-symbolic", c.GTK_ICON_SIZE_MENU);
        css(arrow, "calendar-pager");
        c.gtk_widget_set_tooltip_text(arrow, if (offset < 0) "Previous month" else "Next month");
        c.g_object_set_data(cast(c.GObject, arrow), "month-offset", @ptrFromInt(@as(usize, @bitCast(@as(isize, offset)))));
        _ = c.g_signal_connect_data(arrow, "clicked", @ptrCast(&calendar_navigate), m, null, 0);
        if (offset < 0) c.gtk_box_pack_start(cast(c.GtkBox, header), arrow, 0, 0, 0) else c.gtk_box_pack_end(cast(c.GtkBox, header), arrow, 0, 0, 0);
    }
    const headings = c.gtk_grid_new();
    c.gtk_grid_set_column_homogeneous(cast(c.GtkGrid, headings), 1);
    c.gtk_widget_set_size_request(headings, 280, 27);
    c.gtk_box_pack_start(cast(c.GtkBox, calendar), headings, 0, 0, 0);
    const sunday = c.g_date_time_new_local(2024, 1, 7, 12, 0, 0);
    for (0..7) |i| {
        const day = c.g_date_time_add_days(sunday, @intCast(i));
        const name = c.g_date_time_format(day, "%a");
        const end = c.g_utf8_offset_to_pointer(name, 1);
        const letter = c.g_strndup(name, @intFromPtr(end) - @intFromPtr(name));
        const label = c.gtk_label_new(letter);
        css(label, "calendar-day-heading");
        c.gtk_widget_set_margin_start(label, 4);
        c.gtk_widget_set_margin_end(label, 4);
        c.gtk_widget_set_margin_top(label, 4);
        c.gtk_widget_set_margin_bottom(label, 2);
        c.gtk_widget_set_tooltip_text(label, name);
        c.gtk_grid_attach(cast(c.GtkGrid, headings), label, @intCast(i), 0, 1, 1);
        c.g_free(letter);
        c.g_free(name);
        c.g_date_time_unref(day);
    }
    c.g_date_time_unref(sunday);
    const grid = c.gtk_grid_new();
    c.gtk_grid_set_column_homogeneous(cast(c.GtkGrid, grid), 1);
    c.gtk_grid_set_row_homogeneous(cast(c.GtkGrid, grid), 1);
    c.gtk_box_pack_start(cast(c.GtkBox, calendar), grid, 0, 0, 0);
    for (&m.calendar_days, 0..) |*slot, i| {
        const button = c.gtk_button_new();
        slot.* = button;
        css(button, "calendar-day");
        if (i % 7 == 0 or i % 7 == 6) css(button, "calendar-weekend");
        c.gtk_widget_set_margin_start(button, 2);
        c.gtk_widget_set_margin_end(button, 2);
        c.gtk_widget_set_margin_top(button, 2);
        c.gtk_widget_set_margin_bottom(button, 2);
        _ = c.g_signal_connect_data(button, "clicked", @ptrCast(&calendar_select), m, null, 0);
        c.gtk_grid_attach(cast(c.GtkGrid, grid), button, @intCast(i % 7), @intCast(i / 7), 1, 1);
    }
    c.gtk_box_pack_start(cast(c.GtkBox, box), c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0), 0, 0, 0);
    m.calendar_selected = c.g_date_time_new_now_local();
    calendar_refresh(m);
    c.gtk_widget_show_all(menu);
}
pub fn clock_click(widget: [*c]c.GtkWidget, event: [*c]c.GdkEventButton, data: c.gpointer) callconv(.c) c.gboolean {
    _ = widget;
    const m: *Module = @as(*Module, @ptrCast(@alignCast(data)));
    if (event.*.button != 1) return 0;
    if (c.gtk_widget_get_visible(m.calendar) != 0) {
        c.gtk_popover_popdown(cast(c.GtkPopover, m.calendar));
    } else {
        history_reload(m);
        history_call(m, "CalendarOpen", c.g_variant_new("(b)", @as(c_int, 1)));
        const pointing = c.GdkRectangle{ .x = 0, .y = 0, .width = c.gtk_widget_get_allocated_width(m.root), .height = 26 };
        c.gtk_popover_set_pointing_to(cast(c.GtkPopover, m.calendar), &pointing);
        calendar_navigate(null, @as(c.gpointer, @ptrCast(m)));
        c.gtk_popover_popup(cast(c.GtkPopover, m.calendar));
    }
    return 1;
}
fn calendar_closed(_: *c.GtkPopover, data: c.gpointer) callconv(.c) void {
    const m: *Module = @ptrCast(@alignCast(data));
    history_call(m, "CalendarOpen", c.g_variant_new("(b)", @as(c_int, 0)));
}
fn history_call(m: *Module, member: [*:0]const u8, parameters: ?*c.GVariant) void {
    if (m.dead != 0 or m.session == null) return;
    c.g_dbus_connection_call(m.session, "org.freedesktop.Notifications", "/org/freedesktop/Notifications", "org.dotfiles.Notifications", member, parameters, null, c.G_DBUS_CALL_FLAGS_NONE, 2000, m.cancel, null, null);
}
fn history_clear(_: *c.GtkButton, data: c.gpointer) callconv(.c) void {
    history_call(@ptrCast(@alignCast(data)), "Clear", null);
}
fn history_dismiss(data: ?*anyopaque, id: u32) void {
    history_call(@ptrCast(@alignCast(data)), "Dismiss", c.g_variant_new("(u)", id));
}
fn history_activate(data: ?*anyopaque, id: u32, key: [:0]const u8) void {
    history_call(@ptrCast(@alignCast(data)), "Activate", c.g_variant_new("(us)", id, key.ptr));
}
fn history_changed(_: ?*c.GDBusConnection, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: ?*c.GVariant, data: c.gpointer) callconv(.c) void {
    history_reload(@ptrCast(@alignCast(data)));
}
fn history_reload(m: *Module) void {
    if (m.dead != 0 or m.session == null or m.history_busy) return;
    m.history_busy = true;
    m.refs += 1;
    c.g_dbus_connection_call(m.session, "org.freedesktop.Notifications", "/org/freedesktop/Notifications", "org.dotfiles.Notifications", "List", null, null, c.G_DBUS_CALL_FLAGS_NONE, 2000, m.cancel, &history_ready, m);
}
fn history_ready(source: [*c]c.GObject, result: ?*c.GAsyncResult, data: c.gpointer) callconv(.c) void {
    const m: *Module = @ptrCast(@alignCast(data));
    defer unref_module(m);
    m.history_busy = false;
    var err: [*c]c.GError = null;
    const reply = c.g_dbus_connection_call_finish(@ptrCast(source), result, &err);
    defer c.g_clear_error(&err);
    if (reply == null) return;
    defer c.g_variant_unref(reply);
    if (m.dead != 0) return;
    const value = c.g_variant_get_child_value(reply, 0);
    defer c.g_variant_unref(value);
    const parser = c.json_parser_new();
    defer c.g_object_unref(parser);
    if (c.json_parser_load_from_data(parser, c.g_variant_get_string(value, null), -1, null) == 0) return;
    const root = c.json_parser_get_root(parser);
    if (c.json_node_get_node_type(root) != c.JSON_NODE_ARRAY) return;
    const children = c.gtk_container_get_children(cast(c.GtkContainer, m.history_container));
    var child = children;
    while (child != null) : (child = child.*.next) c.gtk_widget_destroy(@ptrCast(@alignCast(child.*.data)));
    c.g_list_free(children);
    const array = c.json_node_get_array(root);
    const count = c.json_array_get_length(array);
    var i = count;
    while (i > 0) {
        i -= 1;
        const object = c.json_array_get_object_element(array, i);
        if (object == null or c.json_object_has_member(object, "id") == 0 or c.json_object_has_member(object, "created") == 0) continue;
        var actions: [32]notification_view.Action = undefined;
        var action_count: usize = 0;
        if (c.json_object_has_member(object, "actions") != 0) {
            const list = c.json_object_get_array_member(object, "actions");
            while (action_count < @min(32, c.json_array_get_length(list))) : (action_count += 1) {
                const action = c.json_array_get_object_element(list, @intCast(action_count));
                actions[action_count] = .{ .key = std.mem.span(text(action, "key")), .label = std.mem.span(text(action, "label")) };
            }
        }
        const card = notification_view.View.create(.{
            .id = @intCast(c.json_object_get_int_member(object, "id")),
            .created = c.json_object_get_int_member(object, "created"),
            .app = std.mem.span(text(object, "app")),
            .title = std.mem.span(text(object, "title")),
            .body = std.mem.span(text(object, "body")),
            .icon = std.mem.span(text(object, "icon")),
            .actions = actions[0..action_count],
        }, .{ .context = m, .close = &history_dismiss, .activate = &history_activate });
        css(card.root, "history-notification");
        c.gtk_box_pack_start(cast(c.GtkBox, m.history_container), card.root, 0, 0, 0);
    }
    c.gtk_widget_set_visible(m.history_empty, @intFromBool(count == 0));
    c.gtk_widget_set_sensitive(m.history_clear, @intFromBool(count > 0));
}
pub fn text(o: ?*c.JsonObject, key: [*c]const u8) callconv(.c) [*c]const u8 {
    if (!(c.json_object_has_member(o, key) != 0)) return "";
    const node: ?*c.JsonNode = c.json_object_get_member(o, key);
    return if ((c.json_node_get_node_type(node) == c.JSON_NODE_VALUE) and (c.json_node_get_value_type(node) == @as(c.GType, @bitCast(@as(c_long, 16 << @intCast(2)))))) c.json_node_get_string(node) else @as([*c]const c.gchar, @ptrCast(@alignCast("")));
}
pub fn update_codex_tooltip(m: *Module) callconv(.c) void {
    if (m.dead != 0) return;
    const hide = m.codex_menu != null and c.gtk_widget_get_visible(m.codex_menu) != 0;
    c.gtk_widget_set_tooltip_text(m.box, if (hide or m.tooltip == null or m.tooltip.* == 0) null else m.tooltip);
    if (hide) c.gtk_widget_trigger_tooltip_query(m.box);
}
pub fn codex_menu_visibility(object: ?*c.GObject, pspec: ?*c.GParamSpec, data: c.gpointer) callconv(.c) void {
    _ = object;
    _ = pspec;
    const m: *Module = @as(*Module, @ptrCast(@alignCast(data)));
    update_codex_tooltip(m);
}
pub fn codex_menu_closed(popover: [*c]c.GtkPopover, data: c.gpointer) callconv(.c) void {
    _ = popover;
    const m: *Module = @as(*Module, @ptrCast(@alignCast(data)));
    update_codex_tooltip(m);
}
pub fn codex_click(widget: [*c]c.GtkWidget, event: [*c]c.GdkEventButton, data: c.gpointer) callconv(.c) c.gboolean {
    _ = widget;
    const m: *Module = @as(*Module, @ptrCast(@alignCast(data)));
    if (event.*.button != 1) return 0;
    if (c.gtk_widget_get_visible(m.codex_menu) != 0) {
        c.gtk_popover_popdown(cast(c.GtkPopover, m.codex_menu));
    } else {
        // Dismiss an active tooltip before the popover takes the pointer grab.
        c.gtk_widget_set_tooltip_text(m.box, null);
        c.gtk_widget_trigger_tooltip_query(m.box);
        const pointing = c.GdkRectangle{ .x = 0, .y = 0, .width = c.gtk_widget_get_allocated_width(m.root), .height = 26 };
        c.gtk_popover_set_pointing_to(cast(c.GtkPopover, m.codex_menu), &pointing);
        c.gtk_popover_popup(cast(c.GtkPopover, m.codex_menu));
    }
    update_codex_tooltip(m);
    return 1;
}
pub fn codex_refresh(button: [*c]c.GtkButton, data: c.gpointer) callconv(.c) void {
    const m: *Module = @as(*Module, @ptrCast(@alignCast(data)));
    if (!(m.process != null)) return;
    c.gtk_widget_set_sensitive(cast(c.GtkWidget, button), 0);
    c.gtk_label_set_text(cast(c.GtkLabel, m.codex_checked), "Refreshing…");
    c.g_subprocess_send_signal(m.process, 10);
}
pub fn make_codex_menu(m: *Module) callconv(.c) void {
    m.codex_menu = c.gtk_popover_new(m.root);
    c.gtk_popover_set_constrain_to(cast(c.GtkPopover, m.codex_menu), c.GTK_POPOVER_CONSTRAINT_NONE);
    c.gtk_popover_set_position(cast(c.GtkPopover, m.codex_menu), c.GTK_POS_BOTTOM);
    css(m.codex_menu, "gnome-codex-menu");
    const menu: [*c]c.GtkWidget = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
    css(menu, "codex-menu-content");
    c.gtk_container_add(cast(c.GtkContainer, m.codex_menu), menu);
    const titles: [2][*c]const u8 = [2][*c]const u8{
        "5-Hour Remaining",
        "Weekly Remaining",
    };
    {
        var i: c.guint = 0;
        while (i < 2) : (i += 1) {
            const section: [*c]c.GtkWidget = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 6);
            css(section, "codex-usage-section");
            const header: [*c]c.GtkWidget = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 12);
            const title: [*c]c.GtkWidget = c.gtk_label_new(titles[i]);
            c.gtk_label_set_xalign(cast(c.GtkLabel, title), 0);
            css(title, "codex-section-title");
            m.codex_percent[i] = c.gtk_label_new("—");
            css(m.codex_percent[i], "codex-percent-label");
            c.gtk_box_pack_start(cast(c.GtkBox, header), title, 1, 1, 0);
            c.gtk_box_pack_end(cast(c.GtkBox, header), m.codex_percent[i], 0, 0, 0);
            c.gtk_box_pack_start(cast(c.GtkBox, section), header, 0, 0, 0);
            m.codex_progress[i] = c.gtk_progress_bar_new();
            c.gtk_widget_set_margin_top(m.codex_progress[i], 4);
            c.gtk_widget_set_margin_bottom(m.codex_progress[i], 4);
            c.gtk_box_pack_start(cast(c.GtkBox, section), m.codex_progress[i], 0, 0, 0);
            m.codex_reset[i] = c.gtk_label_new("Resets: —");
            c.gtk_label_set_xalign(cast(c.GtkLabel, m.codex_reset[i]), 0);
            css(m.codex_reset[i], "codex-reset-label");
            c.gtk_box_pack_start(cast(c.GtkBox, section), m.codex_reset[i], 0, 0, 0);
            c.gtk_box_pack_start(cast(c.GtkBox, menu), section, 0, 0, 0);
            const separator = c.gtk_separator_new(c.GTK_ORIENTATION_HORIZONTAL);
            c.gtk_widget_set_margin_start(separator, 12);
            c.gtk_widget_set_margin_end(separator, 12);
            c.gtk_widget_set_margin_top(separator, 9);
            c.gtk_widget_set_margin_bottom(separator, 9);
            c.gtk_box_pack_start(cast(c.GtkBox, menu), separator, 0, 0, 0);
        }
    }
    const footer: [*c]c.GtkWidget = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 10);
    css(footer, "codex-footer");
    m.codex_refresh = c.gtk_button_new();
    c.gtk_widget_set_sensitive(m.codex_refresh, 0);
    const refresh_content = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
    const refresh_icon = c.gtk_image_new_from_icon_name("view-refresh-symbolic", c.GTK_ICON_SIZE_MENU);
    c.gtk_image_set_pixel_size(cast(c.GtkImage, refresh_icon), 14);
    c.gtk_box_pack_start(cast(c.GtkBox, refresh_content), refresh_icon, 0, 0, 0);
    c.gtk_box_pack_start(cast(c.GtkBox, refresh_content), c.gtk_label_new("Refresh"), 0, 0, 0);
    c.gtk_container_add(cast(c.GtkContainer, m.codex_refresh), refresh_content);
    _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(m.codex_refresh)), "clicked", @as(c.GCallback, @ptrCast(@alignCast(&codex_refresh))), @as(c.gpointer, @ptrCast(m)), null, 0);
    c.gtk_box_pack_start(cast(c.GtkBox, footer), m.codex_refresh, 0, 0, 0);
    m.codex_checked = c.gtk_label_new("Checked: —");
    css(m.codex_checked, "codex-checked");
    c.gtk_box_pack_end(cast(c.GtkBox, footer), m.codex_checked, 0, 0, 0);
    c.gtk_box_pack_start(cast(c.GtkBox, menu), footer, 0, 0, 0);
    m.codex_error = c.gtk_label_new("");
    c.gtk_label_set_line_wrap(cast(c.GtkLabel, m.codex_error), 1);
    c.gtk_label_set_max_width_chars(cast(c.GtkLabel, m.codex_error), 40);
    c.gtk_label_set_xalign(cast(c.GtkLabel, m.codex_error), 0);
    css(m.codex_error, "codex-reset-label");
    c.gtk_widget_set_no_show_all(m.codex_error, 1);
    _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(m.codex_error)), "notify::label", @as(c.GCallback, @ptrCast(@alignCast(&message_changed))), @as(?*anyopaque, @ptrFromInt(0)), null, 0);
    c.gtk_box_pack_start(cast(c.GtkBox, menu), m.codex_error, 0, 0, 0);
    c.gtk_widget_show_all(menu);
    _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(m.codex_menu)), "notify::visible", @as(c.GCallback, @ptrCast(@alignCast(&codex_menu_visibility))), @as(c.gpointer, @ptrCast(m)), null, 0);
    _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(m.codex_menu)), "closed", @as(c.GCallback, @ptrCast(@alignCast(&codex_menu_closed))), @as(c.gpointer, @ptrCast(m)), null, 0);
    _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(m.root)), "button-press-event", @as(c.GCallback, @ptrCast(@alignCast(&codex_click))), @as(c.gpointer, @ptrCast(m)), null, 0);
}
pub fn update_codex(m: *Module, o: ?*c.JsonObject) callconv(.c) void {
    const windows: ?*c.JsonArray = if (c.json_object_has_member(o, "windows") != 0) c.json_object_get_array_member(o, "windows") else null;
    const levels: [4][*c]const u8 = [4][*c]const u8{
        "usage-low",
        "usage-medium",
        "usage-high",
        "usage-critical",
    };
    {
        var i: c.guint = 0;
        while (i < 2) : (i += 1) {
            const window: ?*c.JsonObject = if ((windows != null) and (i < c.json_array_get_length(windows))) c.json_array_get_object_element(windows, i) else null;
            const percent: ?*c.JsonNode = if ((window != null) and (c.json_object_has_member(window, "percent") != 0)) c.json_object_get_member(window, "percent") else null;
            var valid: c.gboolean = @intFromBool(((percent != null) and (c.json_node_get_node_type(percent) == c.JSON_NODE_VALUE)) and ((c.json_node_get_value_type(percent) == @as(c.GType, @bitCast(@as(c_long, 15 << @intCast(2))))) or (c.json_node_get_value_type(percent) == @as(c.GType, @bitCast(@as(c_long, 10 << @intCast(2)))))));
            var value: f64 = if (valid != 0) c.json_node_get_double(percent) else 0;
            valid = @intFromBool((valid != 0) and (finite(value) != 0));
            value = if (valid != 0) if (value > 100) 100 else if (value < 0) 0 else value else 0;
            const label: [*c]u8 = if (valid != 0) c.g_strdup_printf("%.1f%% remaining", value) else c.g_strdup("—");
            c.gtk_label_set_text(cast(c.GtkLabel, m.codex_percent[i]), label);
            c.g_free(@as(c.gpointer, @ptrCast(label)));
            c.gtk_progress_bar_set_fraction(cast(c.GtkProgressBar, @as(?*anyopaque, @ptrCast(c.g_type_check_instance_cast(cast(c.GTypeInstance, m.codex_progress[i]), c.gtk_progress_bar_get_type())))), value / 100);
            c.gtk_label_set_text(cast(c.GtkLabel, m.codex_reset[i]), if (window != null) text(window, "reset") else "Resets: —");
            const style: [*c]c.GtkStyleContext = c.gtk_widget_get_style_context(m.codex_progress[i]);
            {
                var j: c.guint = 0;
                while (@as(c_ulong, @bitCast(@as(c_ulong, j))) < (@sizeOf([4][*c]const u8) / @sizeOf([*c]const u8))) : (j += 1) {
                    c.gtk_style_context_remove_class(style, levels[j]);
                }
            }
            css(m.codex_progress[i], levels[@as(usize, if (value <= 10) 3 else if (value <= 30) 2 else if (value <= 60) 1 else 0)]);
        }
    }
    c.gtk_label_set_text(cast(c.GtkLabel, m.codex_checked), if (@as(c_int, @bitCast(@as(c_uint, text(o, "checked").*))) != 0) text(o, "checked") else "Checked: —");
    c.gtk_label_set_text(cast(c.GtkLabel, m.codex_error), text(o, "error"));
    c.gtk_widget_set_sensitive(m.codex_refresh, 1);
}
pub fn draw_graph(widget: [*c]c.GtkWidget, cr: ?*c.cairo_t, data: c.gpointer) callconv(.c) c.gboolean {
    var g: *Graph = @as(*Graph, @ptrCast(@alignCast(data)));
    if ((g.series == 0)) return 0;
    const width: f64 = @as(f64, @floatFromInt(c.gtk_widget_get_allocated_width(widget)));
    const height: f64 = @as(f64, @floatFromInt(c.gtk_widget_get_allocated_height(widget)));
    var max: f64 = g.maximum;
    if (g.autoscale != 0) {
        max = 1;
        {
            var j: c.guint = 0;
            while (j < g.count) : (j += 1) {
                max = if (max > g.history[g.series - 1][j]) max else g.history[g.series - 1][j];
            }
        }
        max = c.pow(2, c.ceil(c.log2(max)));
    }
    if ((max <= 0) or (g.count < 2)) return 0;
    c.cairo_rectangle(cr, 0, 0, width, height);
    c.cairo_clip(cr);
    {
        var i: c.gint = @as(c.gint, @bitCast(g.series)) - 1;
        while (i >= 0) : (i -= 1) {
            c.cairo_move_to(cr, width, height);
            var x: f64 = width - 0.25;
            c.cairo_line_to(cr, x, height * (1 - (g.history[@as(c_uint, @intCast(i))][g.count - 1] / max)));
            x -= 0.5;
            {
                var j: c.gint = @as(c.gint, @bitCast(g.count)) - 1;
                while (j >= 0) : (j -= 1) {
                    const y: f64 = height * (1 - (g.history[@as(c_uint, @intCast(i))][@as(c_uint, @intCast(j))] / max));
                    c.cairo_line_to(cr, x, y);
                    x -= 0.5;
                    c.cairo_line_to(cr, x, y);
                    x -= 0.5;
                }
            }
            c.cairo_line_to(cr, x + 0.75, height);
            c.cairo_close_path(cr);
            c.gdk_cairo_set_source_rgba(cr, &g.colors[@as(c_uint, @intCast(i))]);
            c.cairo_fill(cr);
        }
    }
    return 0;
}
pub fn draw_activities(widget: [*c]c.GtkWidget, cr: ?*c.cairo_t, data: c.gpointer) callconv(.c) c.gboolean {
    _ = data;
    const y: f64 = @as(f64, @floatFromInt(c.gtk_widget_get_allocated_height(widget))) / 2.0;
    c.cairo_set_source_rgb(cr, 1, 1, 1);
    c.cairo_arc(cr, 6, y, 4, 1.5707963267948966, 3 * 1.5707963267948966);
    c.cairo_arc(cr, 24, y, 4, 3 * 1.5707963267948966, 1.5707963267948966);
    c.cairo_close_path(cr);
    c.cairo_fill(cr);
    c.cairo_arc(cr, 37, y, 4, 0, 2 * 3.141592653589793);
    c.cairo_fill(cr);
    return 0;
}
pub fn make_graph(m: *Module, index_1: c.guint, name: [*c]const u8) callconv(.c) void {
    const g: *Graph = &m.graph[index_1];
    g.sequence = @as(c.gint64, -1);
    g.maximum = 100;
    g.box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
    css(g.box, "gnome-monitor");
    g.label = c.gtk_label_new(name);
    c.gtk_label_set_angle(cast(c.GtkLabel, g.label), 90);
    css(g.label, "monitor-name");
    c.gtk_widget_set_margin_end(g.label, 2);
    g.value = c.gtk_label_new("—");
    c.gtk_widget_set_no_show_all(g.value, 1);
    c.gtk_label_set_xalign(cast(c.GtkLabel, g.value), 1);
    css(g.value, "monitor-value");
    g.area = c.gtk_drawing_area_new();
    c.gtk_widget_set_size_request(g.area, 100, 1);
    c.gtk_widget_set_valign(g.area, c.GTK_ALIGN_FILL);
    c.gtk_widget_set_margin_start(g.area, 2);
    c.gtk_widget_set_margin_end(g.area, 2);
    css(g.area, "monitor-graph");
    _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(g.area)), "draw", @as(c.GCallback, @ptrCast(@alignCast(&draw_graph))), @as(c.gpointer, @ptrCast(g)), null, 0);
    c.gtk_box_pack_start(cast(c.GtkBox, g.box), g.label, 0, 0, 0);
    c.gtk_box_pack_start(cast(c.GtkBox, g.box), g.value, 0, 0, 0);
    c.gtk_box_pack_start(cast(c.GtkBox, g.box), g.area, 0, 0, 0);
    c.gtk_box_pack_start(cast(c.GtkBox, m.box), g.box, 0, 0, 0);
}
pub fn item_click(widget: [*c]c.GtkWidget, event: [*c]c.GdkEventButton, data: c.gpointer) callconv(.c) c.gboolean {
    _ = widget;
    const item: *Item = @as(*Item, @ptrCast(@alignCast(data)));
    if (((event.*.button != 1) or !(item.command != null)) or !(item.command.* != 0)) return 0;
    var @"error": [*c]c.GError = null;
    _ = c.g_spawn_command_line_async(item.command, &@"error");
    c.g_clear_error(&@"error");
    return 1;
}
pub fn update_items(m: *Module, array: ?*c.JsonArray) callconv(.c) void {
    const count: c.guint = if (c.json_array_get_length(array) < 8) c.json_array_get_length(array) else 8;
    {
        var i: c.guint = 0;
        while (i < count) : (i += 1) {
            const o: ?*c.JsonObject = c.json_array_get_object_element(array, i);
            const item: *Item = &m.item[i];
            if (!(item.box != null)) {
                item.box = c.gtk_event_box_new();
                const row: [*c]c.GtkWidget = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
                c.gtk_container_add(cast(c.GtkContainer, item.box), row);
                css(item.box, "gnome-item");
                if (m.status != 0) {
                    c.gtk_widget_set_margin_start(item.box, 4);
                    c.gtk_widget_set_margin_end(item.box, 4);
                }
                item.image = c.gtk_image_new();
                item.label = c.gtk_label_new("");
                css(item.image, "gnome-icon");
                css(item.label, "gnome-text");
                c.gtk_box_pack_start(cast(c.GtkBox, row), item.image, 0, 0, 0);
                c.gtk_box_pack_start(cast(c.GtkBox, row), item.label, 0, 0, 0);
                c.gtk_box_pack_start(cast(c.GtkBox, m.box), item.box, 0, 0, 0);
                if ((m.status == 0)) {
                    _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(item.box)), "button-press-event", @as(c.GCallback, @ptrCast(@alignCast(&item_click))), @as(c.gpointer, @ptrCast(item)), null, 0);
                }
            }
            const icon: [*c]const u8 = text(o, "icon");
            if ((m.network_icon != null) and (c.g_str_has_prefix(icon, "network-") != 0)) {
                c.gtk_image_set_from_icon_name(cast(c.GtkImage, m.network_icon), icon, c.GTK_ICON_SIZE_MENU);
                c.gtk_label_set_text(cast(c.GtkLabel, m.network_label), text(o, "tooltip"));
            }
            if (c.g_strcmp0(icon, item.icon) != 0) {
                c.g_free(@as(c.gpointer, @ptrCast(item.icon)));
                item.icon = c.g_strdup(icon);
                if (c.g_path_is_absolute(icon) != 0) {
                    var @"error": [*c]c.GError = null;
                    var pixbuf: ?*c.GdkPixbuf = c.gdk_pixbuf_new_from_file_at_scale(icon, 16, 16, 1, &@"error");
                    c.gtk_image_set_from_pixbuf(cast(c.GtkImage, item.image), pixbuf);
                    if (pixbuf != null) {
                        c.g_object_unref(@as(c.gpointer, @ptrCast(pixbuf)));
                    }
                    pixbuf = null;
                    c.g_clear_error(&@"error");
                } else {
                    c.gtk_image_set_from_icon_name(cast(c.GtkImage, item.image), icon, c.GTK_ICON_SIZE_MENU);
                    c.gtk_image_set_pixel_size(cast(c.GtkImage, item.image), 16);
                }
            }
            c.gtk_label_set_text(cast(c.GtkLabel, item.label), text(o, "text"));
            c.gtk_widget_set_margin_start(item.label, if ((@as(c_int, @bitCast(@as(c_uint, icon.*))) != 0) and (@as(c_int, @bitCast(@as(c_uint, text(o, "text").*))) != 0)) 6 else 0);
            c.gtk_widget_set_tooltip_text(item.box, text(o, "tooltip"));
            c.g_free(@as(c.gpointer, @ptrCast(item.command)));
            item.command = c.g_strdup(text(o, "command"));
            c.gtk_widget_show_all(item.box);
            c.gtk_widget_set_visible(item.image, @intFromBool(@as(c_int, @bitCast(@as(c_uint, icon.*))) != @as(c_int, '\x00')));
            c.gtk_widget_set_visible(item.label, @intFromBool(@as(c_int, @bitCast(@as(c_uint, text(o, "text").*))) != @as(c_int, '\x00')));
        }
    }
    {
        var i: c.guint = count;
        while (i < 8) : (i += 1) if (m.item[i].box != null) {
            c.gtk_widget_hide(m.item[i].box);
        };
    }
}
pub fn update_graph(g: *Graph, o: ?*c.JsonObject) callconv(.c) void {
    c.gtk_label_set_markup(cast(c.GtkLabel, g.value), text(o, "markup"));
    c.gtk_widget_set_tooltip_text(g.box, text(o, "tooltip"));
    const sequence: c.gint64 = c.json_object_get_int_member(o, "sequence");
    if (sequence == g.sequence) return;
    g.sequence = sequence;
    const values: ?*c.JsonArray = c.json_object_get_array_member(o, "values");
    const colors: ?*c.JsonArray = c.json_object_get_array_member(o, "colors");
    g.series = if (c.json_array_get_length(values) < 5) c.json_array_get_length(values) else 5;
    if ((g.series == 0)) return;
    g.maximum = c.json_object_get_double_member(o, "maximum");
    g.autoscale = @intFromBool(g.maximum <= 0);
    if (g.count == 100) {
        {
            var i: c.guint = 0;
            while (i < 5) : (i += 1) {
                _ = c.memmove(@as(?*anyopaque, @ptrCast(@as([*c]f64, @ptrCast(@alignCast(&g.history[i][@as(usize, @intCast(0))]))))), @as(?*const anyopaque, @ptrCast(@as([*c]f64, @ptrCast(@alignCast(&g.history[i][@as(usize, @intCast(0))]))) + @as(usize, @bitCast(@as(isize, @intCast(1)))))), @as(c_ulong, @bitCast(@as(c_long, 100 - 1))) *% @sizeOf(f64));
            }
        }
        g.count -= 1;
    }
    var total: f64 = 0;
    {
        var i: c.guint = 0;
        while (i < g.series) : (i += 1) {
            const value: f64 = c.json_array_get_double_element(values, i);
            total += if (finite(value) != 0) if (0 > value) 0 else value else 0;
            g.history[i][g.count] = total;
            const color: [*c]const u8 = if (i < c.json_array_get_length(colors)) c.json_array_get_string_element(colors, i) else @as([*c]const c.gchar, @ptrCast(@alignCast("white")));
            _ = c.gdk_rgba_parse(&g.colors[i], color);
        }
    }
    g.count += 1;
    c.gtk_widget_queue_draw(g.area);
}
pub fn update_line(m: *Module, line: [*c]const u8) callconv(.c) void {
    const parser: [*c]c.JsonParser = c.json_parser_new();
    if (c.json_parser_load_from_data(parser, line, @as(c.gssize, -1), null) != 0) {
        const node: ?*c.JsonNode = c.json_parser_get_root(parser);
        if (c.json_node_get_node_type(node) == c.JSON_NODE_OBJECT) {
            const o: ?*c.JsonObject = c.json_node_get_object(node);
            if ((m.monitors != 0) and (c.json_object_has_member(o, "monitors") != 0)) {
                const graphs: ?*c.JsonArray = c.json_object_get_array_member(o, "monitors");
                {
                    var i: c.guint = 0;
                    while (i < (if (3 < c.json_array_get_length(graphs)) 3 else c.json_array_get_length(graphs))) : (i += 1) {
                        update_graph(&m.graph[i], c.json_array_get_object_element(graphs, i));
                    }
                }
            } else if ((m.monitors == 0) and (c.json_object_has_member(o, "items") != 0)) {
                update_items(m, c.json_object_get_array_member(o, "items"));
            }
            c.g_free(@as(c.gpointer, @ptrCast(m.tooltip)));
            m.tooltip = c.g_strdup(text(o, "tooltip"));
            update_codex_tooltip(m);
            if (m.codex_menu != null) {
                update_codex(m, o);
            }
        }
    }
    c.g_object_unref(@as(c.gpointer, @ptrCast(parser)));
}
pub fn read_next(m: *Module) callconv(.c) void {
    m.refs += 1;
    c.g_data_input_stream_read_line_async(m.stream, 0, m.cancel, &line_ready, @as(c.gpointer, @ptrCast(m)));
}
pub fn start_process(data: c.gpointer) callconv(.c) c.gboolean {
    const m: *Module = @as(*Module, @ptrCast(@alignCast(data)));
    m.restart = 0;
    if (m.stream != null) {
        c.g_object_unref(@as(c.gpointer, @ptrCast(m.stream)));
    }
    m.stream = null;
    if (m.process != null) {
        c.g_subprocess_force_exit(m.process);
    }
    if (m.process != null) {
        c.g_object_unref(@as(c.gpointer, @ptrCast(m.process)));
    }
    m.process = null;
    var argv: [*c][*c]u8 = null;
    var @"error": [*c]c.GError = null;
    if (c.g_shell_parse_argv(m.command, null, &argv, &@"error") != 0) {
        m.process = c.g_subprocess_newv(@as([*c]const [*c]const u8, @ptrCast(@alignCast(argv))), @as(c_uint, @bitCast(c.G_SUBPROCESS_FLAGS_STDOUT_PIPE | c.G_SUBPROCESS_FLAGS_STDERR_SILENCE)), &@"error");
    }
    c.g_strfreev(argv);
    c.g_clear_error(&@"error");
    if (m.process != null) {
        m.stream = c.g_data_input_stream_new(c.g_subprocess_get_stdout_pipe(m.process));
        read_next(m);
    } else {
        m.restart = c.g_timeout_add_seconds(5, &start_process, @as(c.gpointer, @ptrCast(m)));
    }
    return 0;
}
pub fn line_ready(source: [*c]c.GObject, result: ?*c.GAsyncResult, data: c.gpointer) callconv(.c) void {
    const m: *Module = @as(*Module, @ptrCast(@alignCast(data)));
    var length: c.gsize = 0;
    var @"error": [*c]c.GError = null;
    const line: [*c]u8 = c.g_data_input_stream_read_line_finish(cast(c.GDataInputStream, source), result, &length, &@"error");
    if ((m.dead == 0)) {
        if (line != null) {
            if (length < @as(c.gsize, 65536)) {
                update_line(m, line);
            }
            read_next(m);
        } else {
            c.g_free(@as(c.gpointer, @ptrCast(m.tooltip)));
            m.tooltip = c.g_strdup("Panel data unavailable; retrying");
            update_codex_tooltip(m);
            m.restart = c.g_timeout_add_seconds(5, &start_process, @as(c.gpointer, @ptrCast(m)));
        }
    }
    c.g_free(@as(c.gpointer, @ptrCast(line)));
    c.g_clear_error(&@"error");
    unref_module(m);
}
fn device_changed(_: ?*c.GDBusConnection, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: ?*c.GVariant, data: c.gpointer) callconv(.c) void {
    const m: *Module = @ptrCast(@alignCast(data));
    if (m.dead == 0 and m.process != null) c.g_subprocess_send_signal(m.process, c.SIGUSR1);
}
fn session_ready(_: [*c]c.GObject, result: ?*c.GAsyncResult, data: c.gpointer) callconv(.c) void {
    const m: *Module = @ptrCast(@alignCast(data));
    var err: [*c]c.GError = null;
    const connection = c.g_bus_get_finish(result, &err);
    c.g_clear_error(&err);
    if (m.dead == 0) {
        m.session = connection;
        if (connection != null and m.status != 0) m.device_subscription = c.g_dbus_connection_signal_subscribe(connection, "org.dotfiles.DesktopOsd", "org.dotfiles.DesktopOsd", "DeviceChanged", "/org/dotfiles/DesktopOsd", null, c.G_DBUS_SIGNAL_FLAGS_NONE, &device_changed, m, null);
        if (connection != null and m.status != 0) m.settings_subscription = c.g_dbus_connection_signal_subscribe(connection, null, "org.dotfiles.DesktopSettings", "DeviceChanged", "/org/dotfiles/DesktopSettings", null, c.G_DBUS_SIGNAL_FLAGS_NONE, &device_changed, m, null);
        if (connection != null and m.calendar != null) {
            m.history_subscription = c.g_dbus_connection_signal_subscribe(connection, "org.freedesktop.Notifications", "org.dotfiles.Notifications", "Changed", "/org/freedesktop/Notifications", null, c.G_DBUS_SIGNAL_FLAGS_NONE, &history_changed, m, null);
            history_reload(m);
        }
    } else if (connection != null) c.g_object_unref(connection);
    unref_module(m);
}
pub fn init(root: *c.GtkWidget, options: Options) *Module {
    const m: *Module = @as(*Module, @ptrCast(@alignCast(c.g_malloc0_n(@as(c.gsize, 1), @sizeOf(Module)))));
    m.refs = 1;
    m.cancel = c.g_cancellable_new();
    const kind = options.kind.ptr;
    const name = options.name.ptr;
    m.monitors = @intFromBool(c.g_strcmp0(kind, "monitors") == 0);
    m.status = @intFromBool(c.g_strcmp0(name, "gnome-status") == 0);
    m.box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, if ((m.monitors != 0) or (m.status != 0)) 4 else 0);
    if (c.g_strcmp0(name, "gnome-disk") != 0) {
        // GtkEventBox doesn't allocate the CSS border like St's PanelMenu.
        const padding: c_int = if (c.g_strcmp0(name, "gnome-codex") == 0) 12 else 15;
        c.gtk_widget_set_margin_start(m.box, padding);
        c.gtk_widget_set_margin_end(m.box, padding);
        if ((m.monitors == 0)) {
            c.gtk_widget_set_margin_top(m.box, 3);
            c.gtk_widget_set_margin_bottom(m.box, 3);
        }
    }
    m.root = cast(c.GtkWidget, root);
    if (options.name.len != 0) {
        c.gtk_widget_set_name(cast(c.GtkWidget, root), name);
    }
    css(cast(c.GtkWidget, root), "gnome-panel-module");
    c.gtk_container_add(cast(c.GtkContainer, root), m.box);
    if (m.monitors != 0) {
        make_graph(m, 0, "cpu");
        make_graph(m, 1, "mem");
        make_graph(m, 2, "net");
    } else if (c.g_strcmp0(name, "gnome-codex") == 0) {
        make_codex_menu(m);
    } else if (m.status != 0) {
        m.power_icon = c.gtk_image_new_from_icon_name(power_icons[@as(c_uint, @intCast(1))], c.GTK_ICON_SIZE_MENU);
        m.power_label = c.gtk_label_new("Power Mode");
        m.power_menu = c.gtk_popover_new(m.root);
        c.gtk_popover_set_constrain_to(cast(c.GtkPopover, m.power_menu), c.GTK_POPOVER_CONSTRAINT_NONE);
        c.gtk_popover_set_position(cast(c.GtkPopover, m.power_menu), c.GTK_POS_BOTTOM);
        css(m.power_menu, "gnome-power-menu");
        const menu: [*c]c.GtkWidget = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 12);
        css(menu, "quick-settings-content");
        c.gtk_container_add(cast(c.GtkContainer, m.power_menu), menu);
        const tiles: [*c]c.GtkWidget = c.gtk_grid_new();
        c.gtk_grid_set_row_spacing(cast(c.GtkGrid, tiles), 12);
        c.gtk_grid_set_column_spacing(cast(c.GtkGrid, tiles), 12);
        c.gtk_grid_set_column_homogeneous(cast(c.GtkGrid, tiles), 1);
        c.gtk_box_pack_start(cast(c.GtkBox, menu), tiles, 0, 0, 0);
        m.network_icon = c.gtk_image_new_from_icon_name("network-wireless-symbolic", c.GTK_ICON_SIZE_MENU);
        m.network_label = c.gtk_label_new("Connections");
        const network: [*c]c.GtkWidget = quick_tile(c.gtk_button_new(), "Network", m.network_icon, m.network_label, 1);
        c.gtk_grid_attach(cast(c.GtkGrid, tiles), network, 0, 0, 1, 1);
        m.network_settings_command = if (options.network_settings_command) |command| c.g_strdup(command) else null;
        if (m.network_settings_command != null) {
            _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(network)), "clicked", @as(c.GCallback, @ptrCast(@alignCast(&settings_launch))), @as(c.gpointer, @ptrCast(m.network_settings_command)), null, 0);
        }
        const power: [*c]c.GtkWidget = quick_tile(c.gtk_toggle_button_new(), "Power Mode", m.power_icon, m.power_label, 1);
        c.gtk_grid_attach(cast(c.GtkGrid, tiles), power, 0, 1, 1, 1);
        const sound: [*c]c.GtkWidget = quick_tile(c.gtk_button_new(), "Sound", c.gtk_image_new_from_icon_name("audio-volume-high-symbolic", c.GTK_ICON_SIZE_MENU), null, 1);
        // The signal owns its command independently of the parsed config.
        _ = c.g_signal_connect_data(sound, "clicked", @ptrCast(&settings_launch), c.g_strdup(options.sound_settings_command.ptr), &free_command, 0);
        c.gtk_grid_attach(cast(c.GtkGrid, tiles), sound, 1, 0, 1, 1);
        const profiles: [*c]c.GtkWidget = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 4);
        css(profiles, "quick-toggle-menu");
        const heading: [*c]c.GtkWidget = c.gtk_label_new("Power Mode");
        c.gtk_label_set_xalign(cast(c.GtkLabel, heading), 0);
        css(heading, "quick-menu-title");
        c.gtk_box_pack_start(cast(c.GtkBox, profiles), heading, 0, 0, 0);
        {
            var i: c.guint = 0;
            while (@as(c_ulong, @bitCast(@as(c_ulong, i))) < (@sizeOf([3][*c]const u8) / @sizeOf([*c]const u8))) : (i += 1) {
                m.power_buttons[i] = c.gtk_button_new_with_label(power_names[i]);
                css(m.power_buttons[i], "profile-choice");
                c.gtk_label_set_xalign(cast(c.GtkLabel, c.gtk_bin_get_child(cast(c.GtkBin, @as(?*anyopaque, @ptrCast(c.g_type_check_instance_cast(cast(c.GTypeInstance, m.power_buttons[i]), c.gtk_bin_get_type())))))), 0);
                c.g_object_set_data(cast(c.GObject, m.power_buttons[i]), "profile", @as(c.gpointer, @ptrCast(@constCast(@volatileCast(power_ids[i])))));
                _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(m.power_buttons[i])), "clicked", @as(c.GCallback, @ptrCast(@alignCast(&power_select))), @as(c.gpointer, @ptrCast(m)), null, 0);
                c.gtk_box_pack_start(cast(c.GtkBox, profiles), m.power_buttons[i], 0, 0, 0);
            }
        }
        const revealer: [*c]c.GtkWidget = c.gtk_revealer_new();
        c.gtk_container_add(cast(c.GtkContainer, revealer), profiles);
        c.gtk_box_pack_start(cast(c.GtkBox, menu), revealer, 0, 0, 0);
        _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(power)), "toggled", @as(c.GCallback, @ptrCast(@alignCast(&power_expand))), @as(c.gpointer, @ptrCast(revealer)), null, 0);
        m.power_message = c.gtk_label_new("");
        c.gtk_label_set_line_wrap(cast(c.GtkLabel, m.power_message), 1);
        c.gtk_label_set_max_width_chars(cast(c.GtkLabel, m.power_message), 40);
        css(m.power_message, "quick-message");
        c.gtk_widget_set_no_show_all(m.power_message, 1);
        _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(m.power_message)), "notify::label", @as(c.GCallback, @ptrCast(@alignCast(&message_changed))), @as(?*anyopaque, @ptrFromInt(0)), null, 0);
        message_changed(cast(c.GObject, m.power_message), null, @as(?*anyopaque, @ptrFromInt(0)));
        c.gtk_box_pack_start(cast(c.GtkBox, menu), m.power_message, 0, 0, 0);
        c.gtk_widget_show_all(menu);
        update_power(m);
        _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(m.root)), "button-press-event", @as(c.GCallback, @ptrCast(@alignCast(&power_click))), @as(c.gpointer, @ptrCast(m)), null, 0);
        m.power_timer = c.g_timeout_add_seconds(2, &refresh_power, m);
        m.refs += 1;
        c.g_bus_get(c.G_BUS_TYPE_SESSION, m.cancel, &session_ready, m);
    } else if (c.g_strcmp0(kind, "clock") == 0) {
        m.clock = c.gtk_label_new("");
        c.gtk_container_add(cast(c.GtkContainer, m.box), m.clock);
        m.calendar = c.gtk_popover_new(m.root);
        c.gtk_popover_set_constrain_to(cast(c.GtkPopover, m.calendar), c.GTK_POPOVER_CONSTRAINT_NONE);
        c.gtk_popover_set_position(cast(c.GtkPopover, m.calendar), c.GTK_POS_BOTTOM);
        css(m.calendar, "gnome-calendar");
        make_calendar(m);
        _ = c.g_signal_connect_data(m.calendar, "closed", @ptrCast(&calendar_closed), m, null, 0);
        m.refs += 1;
        c.g_bus_get(c.G_BUS_TYPE_SESSION, m.cancel, &session_ready, m);
        _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(m.root)), "button-press-event", @as(c.GCallback, @ptrCast(@alignCast(&clock_click))), @as(c.gpointer, @ptrCast(m)), null, 0);
        _ = update_clock(@as(c.gpointer, @ptrCast(m)));
        m.clock_timer = c.g_timeout_add_seconds(1, &update_clock, @as(c.gpointer, @ptrCast(m)));
    } else if (c.g_strcmp0(kind, "activities") == 0) {
        const area: [*c]c.GtkWidget = c.gtk_drawing_area_new();
        c.gtk_widget_set_size_request(area, 42, 20);
        _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(area)), "draw", @as(c.GCallback, @ptrCast(@alignCast(&draw_activities))), @as(?*anyopaque, @ptrFromInt(0)), null, 0);
        c.gtk_container_add(cast(c.GtkContainer, m.box), area);
    }
    m.command = if (options.exec) |command| c.g_strdup(command) else null;
    c.gtk_widget_show_all(m.box);
    if (m.command != null) {
        _ = start_process(@as(c.gpointer, @ptrCast(m)));
    }
    return m;
}
pub fn deinit(m: *Module) void {
    m.dead = 1;
    if (m.device_subscription != 0) c.g_dbus_connection_signal_unsubscribe(m.session, m.device_subscription);
    if (m.settings_subscription != 0) c.g_dbus_connection_signal_unsubscribe(m.session, m.settings_subscription);
    if (m.history_subscription != 0) c.g_dbus_connection_signal_unsubscribe(m.session, m.history_subscription);
    if (m.clock_timer != 0) {
        _ = c.g_source_remove(m.clock_timer);
    }
    if (m.calendar != null) {
        c.gtk_widget_destroy(m.calendar);
    }
    if (m.codex_menu != null) {
        c.gtk_widget_destroy(m.codex_menu);
    }
    if (m.calendar_selected != null) {
        c.g_date_time_unref(m.calendar_selected);
    }
    if (m.power_menu != null) {
        c.gtk_widget_destroy(m.power_menu);
    }
    if (m.power_timer != 0) _ = c.g_source_remove(m.power_timer);
    _ = c.g_signal_handlers_disconnect_matched(@as(c.gpointer, @ptrCast(m.root)), c.G_SIGNAL_MATCH_DATA, 0, @as(c.GQuark, 0), null, @as(?*anyopaque, @ptrFromInt(0)), @as(c.gpointer, @ptrCast(m)));
    if (m.restart != 0) {
        _ = c.g_source_remove(m.restart);
    }
    c.g_cancellable_cancel(m.cancel);
    if (m.process != null) {
        c.g_subprocess_force_exit(m.process);
    }
    {
        var i: c.guint = 0;
        while (i < 3) : (i += 1) if (m.graph[i].area != null) {
            _ = c.g_signal_handlers_disconnect_matched(@as(c.gpointer, @ptrCast(m.graph[i].area)), c.G_SIGNAL_MATCH_DATA, 0, @as(c.GQuark, 0), null, @as(?*anyopaque, @ptrFromInt(0)), @as(c.gpointer, @ptrCast(&m.graph[i])));
        };
    }
    {
        var i: c.guint = 0;
        while (i < 8) : (i += 1) if (m.item[i].box != null) {
            _ = c.g_signal_handlers_disconnect_matched(@as(c.gpointer, @ptrCast(m.item[i].box)), c.G_SIGNAL_MATCH_DATA, 0, @as(c.GQuark, 0), null, @as(?*anyopaque, @ptrFromInt(0)), @as(c.gpointer, @ptrCast(&m.item[i])));
        };
    }
    unref_module(m);
}
