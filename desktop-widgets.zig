//! Shared GTK widgets and popups for the desktop session.
const std = @import("std");
const power_backend = @import("desktop-power.zig");
const quick = @import("desktop-quick-settings.zig");
pub const date_menu = @import("desktop-date-menu.zig");
pub const c = @import("desktop-gtk.zig");
fn cast(comptime T: type, p: anytype) [*c]T {
    return @ptrCast(@alignCast(p));
}
fn finite(value: f64) c_int {
    return @intFromBool(std.math.isFinite(value));
}
pub const Options = struct {
    name: [:0]const u8 = "",
    kind: [:0]const u8 = "indicator",
    source: [:0]const u8 = "",
    on_click: ?[:0]const u8 = null,
    network_settings_command: ?[:0]const u8 = null,
    sound_settings_command: [:0]const u8 = "desktop-zig settings sound",
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
    date_controls: ?*date_menu.Controls = null,
    history_subscription: c.guint = 0,
    history_busy: bool = false,
    history_dirty: bool = false,
    graph: [3]Graph = std.mem.zeroes([3]Graph),
    item: [8]Item = std.mem.zeroes([8]Item),
    source: [*:0]const u8 = "",
    cancel: [*c]c.GCancellable = null,
    clock_timer: c.guint = 0,
    power_timer: c.guint = 0,
    session: ?*c.GDBusConnection = null,
    device_subscription: c.guint = 0,
    settings_subscription: c.guint = 0,
    power_menu: [*c]c.GtkWidget = null,
    quick: ?*quick.Controls = null,
    power_pending: c.gboolean = 0,
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
    if (m.cancel != null) {
        c.g_object_unref(@as(c.gpointer, @ptrCast(m.cancel)));
    }
    m.cancel = null;
    if (m.session != null) c.g_object_unref(m.session);
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
pub fn message_changed(label: [*c]c.GObject, property: [*c]c.GParamSpec, data: c.gpointer) callconv(.c) void {
    _ = data;
    _ = property;
    c.gtk_widget_set_visible(cast(c.GtkWidget, label), @intFromBool(@as(c_int, @bitCast(@as(c_uint, c.gtk_label_get_text(cast(c.GtkLabel, label)).*))) != @as(c_int, '\x00')));
}
pub fn apply_power_state(m: *Module, state: power_backend.State) void {
    if (m.quick) |controls| {
        controls.setPowerState(state, m.power_pending != 0);
        const available = state.available[0] or state.available[1] or state.available[2];
        if (!available) controls.setMessage("Power profiles unavailable") else if (std.mem.eql(u8, controls.view.model.message.slice(), "Power profiles unavailable")) controls.setMessage("");
        return;
    }
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
fn set_power_message(m: *Module, message: [*c]const u8) void {
    if (m.quick) |controls| controls.setMessage(std.mem.span(message));
}
fn native_profile_selected(data: ?*anyopaque, index: usize) void {
    if (index < 3) select_power(cast(Module, data), power_ids[index]);
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
        set_power_message(m, if (err != null) err.*.message else if (!communicated or c.g_subprocess_get_successful(process) == 0) (if (errors != null and errors[0] != 0) errors else "Could not change the power profile") else "");
    }
    unref_module(m);
}
fn select_power(m: *Module, id: [*c]const u8) void {
    if (m.dead != 0 or m.power_pending != 0) return;
    const helper = c.g_getenv("DESKTOP_POWER_HELPER");
    const pkexec = c.g_getenv("DESKTOP_POWER_PKEXEC");
    if (helper == null or pkexec == null) {
        set_power_message(m, "Power profile helper unavailable");
        return;
    }
    var err: [*c]c.GError = null;
    const argv = [_][*c]const u8{ pkexec, helper, "power", "set", id, null };
    const process = c.g_subprocess_newv(&argv, c.G_SUBPROCESS_FLAGS_STDERR_PIPE | c.G_SUBPROCESS_FLAGS_STDOUT_SILENCE, &err);
    if (process == null) {
        set_power_message(m, if (err != null) err.*.message else "Could not start the power profile helper");
        c.g_clear_error(&err);
        return;
    }
    defer c.g_object_unref(process);
    m.power_pending = 1;
    update_power(m);
    set_power_message(m, "Switching…");
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
    if (m.date_controls) |controls| controls.tick();
    return 1;
}
pub fn make_calendar(m: *Module) callconv(.c) void {
    m.date_controls = date_menu.Controls.create(m.calendar.?, .{
        .context = m,
        .clear = &history_clear,
        .dismiss = &history_dismiss,
        .activate = &history_activate,
    }) catch @panic("cannot create date menu");
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
        if (m.date_controls) |controls| controls.reset();
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
fn history_clear(data: ?*anyopaque) void {
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
    if (m.dead != 0 or m.session == null) return;
    if (m.history_busy) {
        m.history_dirty = true;
        return;
    }
    m.history_busy = true;
    m.history_dirty = false;
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
    populate_notifications(m, reply);
    if (m.history_dirty) history_reload(m);
}

fn jsonStringZ(a: std.mem.Allocator, val: ?std.json.Value) [:0]const u8 {
    if (val) |v| {
        if (v == .string) return a.dupeSentinel(u8, v.string, 0) catch "";
    }
    return "";
}

fn populate_notifications(m: *Module, reply: ?*c.GVariant) void {
    if (reply == null) return;
    defer c.g_variant_unref(reply);
    if (m.dead != 0) return;
    const value = c.g_variant_get_child_value(reply, 0);
    defer c.g_variant_unref(value);
    const raw = c.g_variant_get_string(value, null);
    if (raw == null) return;
    if (m.date_controls) |controls| controls.load(std.mem.span(raw));
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
    if (std.mem.eql(u8, std.mem.span(m.source), "codex")) {
        c.gtk_widget_set_sensitive(cast(c.GtkWidget, button), 0);
        c.gtk_label_set_text(cast(c.GtkLabel, m.codex_checked), "Refreshing…");
        if (refresh_source) |refresh| refresh("codex");
    }
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
pub fn update_codex(m: *Module, o: std.json.Value, a: std.mem.Allocator) void {
    const windows_val = o.object.get("windows");
    const windows: ?[]const std.json.Value = if (windows_val) |w| if (w == .array) w.array.items else null else null;
    const levels = [_][*:0]const u8{
        "usage-low",
        "usage-medium",
        "usage-high",
        "usage-critical",
    };
    for (0..2) |i| {
        const window: ?std.json.Value = if (windows) |w| if (i < w.len and w[i] == .object) w[i] else null else null;
        const percent_val = if (window) |win| win.object.get("percent") else null;
        var valid = false;
        var value: f64 = 0;
        if (percent_val) |p| switch (p) {
            .float => |f| {
                value = f;
                valid = std.math.isFinite(f);
            },
            .integer => |iv| {
                value = @floatFromInt(iv);
                valid = true;
            },
            else => {},
        };
        value = if (valid) std.math.clamp(value, 0, 100) else 0;
        const label = if (valid) c.g_strdup_printf("%.1f%% remaining", value) else c.g_strdup("—");
        c.gtk_label_set_text(cast(c.GtkLabel, m.codex_percent[i]), label);
        c.g_free(@as(c.gpointer, @ptrCast(label)));
        c.gtk_progress_bar_set_fraction(cast(c.GtkProgressBar, @as(?*anyopaque, @ptrCast(c.g_type_check_instance_cast(cast(c.GTypeInstance, m.codex_progress[i]), c.gtk_progress_bar_get_type())))), value / 100);
        const reset_str = if (window) |win| jsonStringZ(a, win.object.get("reset")) else "Resets: —";
        c.gtk_label_set_text(cast(c.GtkLabel, m.codex_reset[i]), reset_str);
        const style: [*c]c.GtkStyleContext = c.gtk_widget_get_style_context(m.codex_progress[i]);
        for (levels) |lvl| c.gtk_style_context_remove_class(style, lvl);
        css(m.codex_progress[i], levels[if (value <= 10) 3 else if (value <= 30) 2 else if (value <= 60) 1 else 0]);
    }
    const checked_str = jsonStringZ(a, o.object.get("checked"));
    c.gtk_label_set_text(cast(c.GtkLabel, m.codex_checked), if (checked_str.len != 0) checked_str else "Checked: —");
    c.gtk_label_set_text(cast(c.GtkLabel, m.codex_error), jsonStringZ(a, o.object.get("error")));
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
        max = std.math.pow(f64, 2, @ceil(std.math.log2(max)));
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
fn update_items(m: *Module, items: []const std.json.Value, a: std.mem.Allocator) void {
    const count: usize = @min(items.len, 8);
    for (0..count) |i| {
        const item_val = items[i];
        if (item_val != .object) continue;
        const item: *Item = &m.item[i];
        if (item.box == null) {
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
            if (m.status == 0) {
                _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(item.box)), "button-press-event", @as(c.GCallback, @ptrCast(@alignCast(&item_click))), @as(c.gpointer, @ptrCast(item)), null, 0);
            }
        }
        const icon = jsonStringZ(a, item_val.object.get("icon"));
        const tooltip = jsonStringZ(a, item_val.object.get("tooltip"));
        const text_str = jsonStringZ(a, item_val.object.get("text"));
        const command = jsonStringZ(a, item_val.object.get("command"));

        if (c.g_strcmp0(icon, item.icon) != 0) {
            c.g_free(@as(c.gpointer, @ptrCast(item.icon)));
            item.icon = c.g_strdup(icon);
            if (c.g_path_is_absolute(icon) != 0) {
                var @"error": [*c]c.GError = null;
                const pixbuf: ?*c.GdkPixbuf = c.gdk_pixbuf_new_from_file_at_scale(icon, 16, 16, 1, &@"error");
                c.gtk_image_set_from_pixbuf(cast(c.GtkImage, item.image), pixbuf);
                if (pixbuf != null) {
                    c.g_object_unref(@as(c.gpointer, @ptrCast(pixbuf)));
                }
                c.g_clear_error(&@"error");
            } else {
                c.gtk_image_set_from_icon_name(cast(c.GtkImage, item.image), icon, c.GTK_ICON_SIZE_MENU);
                c.gtk_image_set_pixel_size(cast(c.GtkImage, item.image), 16);
            }
        }
        c.gtk_label_set_text(cast(c.GtkLabel, item.label), text_str);
        c.gtk_widget_set_margin_start(item.label, if (icon.len > 0 and text_str.len > 0) 6 else 0);
        c.gtk_widget_set_tooltip_text(item.box, tooltip);
        c.g_free(@as(c.gpointer, @ptrCast(item.command)));
        item.command = c.g_strdup(command);
        c.gtk_widget_show_all(item.box);
        c.gtk_widget_set_visible(item.image, @intFromBool(icon.len > 0));
        c.gtk_widget_set_visible(item.label, @intFromBool(text_str.len > 0));
    }
    for (count..8) |i| {
        if (m.item[i].box != null) c.gtk_widget_hide(m.item[i].box);
    }
}

fn update_graph(g: *Graph, o: std.json.Value, a: std.mem.Allocator) void {
    const markup = jsonStringZ(a, o.object.get("markup"));
    const tooltip = jsonStringZ(a, o.object.get("tooltip"));
    c.gtk_label_set_markup(cast(c.GtkLabel, g.value), markup);
    c.gtk_widget_set_tooltip_text(g.box, tooltip);
    const seq_val = o.object.get("sequence") orelse return;
    const sequence: i64 = switch (seq_val) {
        .integer => |v| v,
        else => return,
    };
    if (sequence == g.sequence) return;
    g.sequence = sequence;
    const values_val = o.object.get("values") orelse return;
    if (values_val != .array) return;
    const values = values_val.array.items;
    const colors_val = o.object.get("colors");
    const colors = if (colors_val) |cv| if (cv == .array) cv.array.items else &.{} else &.{};
    g.series = @intCast(@min(values.len, 5));
    if (g.series == 0) return;
    g.maximum = if (o.object.get("maximum")) |mv| switch (mv) {
        .float => |f| f,
        .integer => |iv| @floatFromInt(iv),
        else => 0,
    } else 0;
    g.autoscale = @intFromBool(g.maximum <= 0);
    if (g.count == 100) {
        for (0..5) |row| {
            for (0..99) |col| g.history[row][col] = g.history[row][col + 1];
        }
        g.count -= 1;
    }
    var total: f64 = 0;
    for (0..g.series) |i| {
        const val: f64 = switch (values[i]) {
            .float => |f| f,
            .integer => |iv| @floatFromInt(iv),
            else => 0,
        };
        total += if (std.math.isFinite(val)) @max(0, val) else 0;
        g.history[i][g.count] = total;
        var color_buf: [64:0]u8 = undefined;
        const color: [:0]const u8 = if (i < colors.len and colors[i] == .string and colors[i].string.len < 64) blk: {
            @memcpy(color_buf[0..colors[i].string.len], colors[i].string);
            color_buf[colors[i].string.len] = 0;
            break :blk color_buf[0..colors[i].string.len :0];
        } else "white";
        _ = c.gdk_rgba_parse(&g.colors[i], color);
    }
    g.count += 1;
    c.gtk_widget_queue_draw(g.area);
}

pub fn update_line(m: *Module, line: [*c]const u8) callconv(.c) void {
    if (line == null) return;
    const slice = std.mem.span(line);
    var arena = std.heap.ArenaAllocator.init(if (@import("builtin").is_test) std.testing.allocator else std.heap.page_allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), slice, .{}) catch return;
    if (parsed.value != .object) return;
    const o = parsed.value;
    if (m.monitors != 0 and o.object.get("monitors") != null) {
        if (o.object.get("monitors").? == .array) {
            const graphs = o.object.get("monitors").?.array.items;
            for (graphs[0..@min(3, graphs.len)], 0..) |graph_obj, i| {
                if (graph_obj == .object) update_graph(&m.graph[i], graph_obj, arena.allocator());
            }
        }
    } else if (m.monitors == 0 and o.object.get("items") != null) {
        if (o.object.get("items").? == .array) {
            update_items(m, o.object.get("items").?.array.items, arena.allocator());
        }
    }
    c.g_free(@as(c.gpointer, @ptrCast(m.tooltip)));
    const tooltip_str = jsonStringZ(arena.allocator(), o.object.get("tooltip"));
    m.tooltip = c.g_strdup(tooltip_str);
    update_codex_tooltip(m);
    if (m.codex_menu != null) {
        update_codex(m, o, arena.allocator());
    }
}
fn device_changed(_: ?*c.GDBusConnection, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: ?*c.GVariant, data: c.gpointer) callconv(.c) void {
    const m: *Module = @ptrCast(@alignCast(data));
    if (m.dead != 0) return;
    if (m.source[0] != 0) {
        if (refresh_source) |refresh| refresh(std.mem.span(m.source));
    }
}
fn session_ready(_: [*c]c.GObject, result: ?*c.GAsyncResult, data: c.gpointer) callconv(.c) void {
    const m: *Module = @ptrCast(@alignCast(data));
    var err: [*c]c.GError = null;
    const connection = c.g_bus_get_finish(result, &err);
    c.g_clear_error(&err);
    if (m.dead == 0) {
        m.session = connection;
        if (connection != null and m.status != 0) m.device_subscription = c.g_dbus_connection_signal_subscribe(connection, null, "org.dotfiles.DesktopOsd", "DeviceChanged", "/org/dotfiles/DesktopOsd", null, c.G_DBUS_SIGNAL_FLAGS_NONE, &device_changed, m, null);
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
        m.power_menu = c.gtk_popover_new(m.root);
        c.gtk_popover_set_constrain_to(cast(c.GtkPopover, m.power_menu), c.GTK_POPOVER_CONSTRAINT_NONE);
        c.gtk_popover_set_position(cast(c.GtkPopover, m.power_menu), c.GTK_POS_BOTTOM);
        css(m.power_menu, "gnome-power-menu");
        m.quick = quick.Controls.create(m.power_menu.?, if (options.network_settings_command) |command| command.ptr else options.sound_settings_command.ptr, options.sound_settings_command.ptr);
        const controls = m.quick.?;
        controls.profile_context = m;
        controls.profile_selected = &native_profile_selected;
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
    m.source = options.source.ptr;
    c.gtk_widget_show_all(m.box);
    return m;
}
pub fn deinit(m: *Module) void {
    // Closing a clock during panel/output teardown must restore banners even
    // though its outstanding history requests are about to be cancelled.
    if (m.calendar != null and m.session != null and c.gtk_widget_get_visible(m.calendar) != 0) {
        c.g_dbus_connection_call(m.session, "org.freedesktop.Notifications", "/org/freedesktop/Notifications", "org.dotfiles.Notifications", "CalendarOpen", c.g_variant_new("(b)", @as(c_int, 0)), null, c.G_DBUS_CALL_FLAGS_NONE, 2000, null, null, null);
    }
    m.dead = 1;
    if (m.device_subscription != 0) c.g_dbus_connection_signal_unsubscribe(m.session, m.device_subscription);
    if (m.settings_subscription != 0) c.g_dbus_connection_signal_unsubscribe(m.session, m.settings_subscription);
    if (m.history_subscription != 0) c.g_dbus_connection_signal_unsubscribe(m.session, m.history_subscription);
    if (m.clock_timer != 0) {
        _ = c.g_source_remove(m.clock_timer);
    }
    if (m.calendar != null) {
        _ = c.g_signal_handlers_disconnect_matched(m.calendar, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, m);
        if (m.date_controls) |controls| controls.destroy();
        m.date_controls = null;
        c.gtk_widget_destroy(m.calendar);
    }
    if (m.codex_menu != null) {
        c.gtk_widget_destroy(m.codex_menu);
    }
    if (m.quick) |controls| controls.deinit();
    if (m.power_menu != null) {
        c.gtk_widget_destroy(m.power_menu);
    }
    if (m.power_timer != 0) _ = c.g_source_remove(m.power_timer);
    _ = c.g_signal_handlers_disconnect_matched(@as(c.gpointer, @ptrCast(m.root)), c.G_SIGNAL_MATCH_DATA, 0, @as(c.GQuark, 0), null, @as(?*anyopaque, @ptrFromInt(0)), @as(c.gpointer, @ptrCast(m)));
    c.g_cancellable_cancel(m.cancel);
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

/// Session callback for built-in collectors; invoked only on the GTK thread.
pub var refresh_source: ?*const fn ([]const u8) void = null;
