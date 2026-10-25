//! Native Zig implementation of Waybar CFFI ABI v2 and GTK panel popups.
const std = @import("std");
pub const c = @cImport({
    @cInclude("gtk/gtk.h");
    @cInclude("json-glib/json-glib.h");
    @cInclude("math.h");
    @cInclude("signal.h");
    @cInclude("string.h");
});
fn cast(comptime T: type, p: anytype) [*c]T {
    return @ptrCast(@alignCast(p));
}
fn finite(value: f64) c_int {
    return @intFromBool(std.math.isFinite(value));
}
pub const WaybarModule = opaque {};
pub const InitInfo = extern struct {
    obj: ?*WaybarModule = null,
    waybar_version: [*c]const u8 = null,
    get_root_widget: ?*const fn (?*WaybarModule) callconv(.c) [*c]c.GtkContainer = null,
    queue_update: ?*const fn (?*WaybarModule) callconv(.c) void = null,
};
pub const ConfigEntry = extern struct {
    key: [*c]const u8 = null,
    value: [*c]const u8 = null,
};
pub export const wbcffi_version: usize = 2;
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
    power: [*c]c.GDBusProxy = null,
    power_menu: [*c]c.GtkWidget = null,
    power_label: [*c]c.GtkWidget = null,
    power_icon: [*c]c.GtkWidget = null,
    power_message: [*c]c.GtkWidget = null,
    power_buttons: [3][*c]c.GtkWidget = std.mem.zeroes([3][*c]c.GtkWidget),
    power_pending: c.gboolean = 0,
    bluetooth_button: [*c]c.GtkWidget = null,
    bluetooth_label: [*c]c.GtkWidget = null,
    bluetooth_message: [*c]c.GtkWidget = null,
    network_icon: [*c]c.GtkWidget = null,
    network_label: [*c]c.GtkWidget = null,
    bluetooth_command: [*c]u8 = null,
    bluetooth_settings_command: [*c]u8 = null,
    network_settings_command: [*c]u8 = null,
    bluetooth_powered: c.gboolean = 0,
    bluetooth_busy: c.gboolean = 0,
    bluetooth_timer: c.guint = 0,
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
    if (m.power != null) {
        c.g_object_unref(@as(c.gpointer, @ptrCast(m.power)));
    }
    m.power = null;
    c.g_free(@as(c.gpointer, @ptrCast(m.command)));
    c.g_free(@as(c.gpointer, @ptrCast(m.bluetooth_command)));
    c.g_free(@as(c.gpointer, @ptrCast(m.bluetooth_settings_command)));
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
pub fn bluetooth_refresh(data: c.gpointer) callconv(.c) c.gboolean {
    const m: *Module = @as(*Module, @ptrCast(@alignCast(data)));
    if (((m.bluetooth_busy == 0) and (m.bluetooth_command != null)) and (c.gtk_widget_get_visible(m.power_menu) != 0)) {
        bluetooth_run(m, &bluetooth_ready, "show", null);
    }
    return 1;
}
pub fn bluetooth_ready(source: [*c]c.GObject, result: ?*c.GAsyncResult, data: c.gpointer) callconv(.c) void {
    const m: *Module = @as(*Module, @ptrCast(@alignCast(data)));
    var @"error": [*c]c.GError = null;
    var output: [*c]u8 = null;
    var errors: [*c]u8 = null;
    const ok: c.gboolean = c.g_subprocess_communicate_utf8_finish(@as(?*c.GSubprocess, @ptrCast(source)), result, &output, &errors, &@"error");
    if ((m.dead == 0)) {
        m.bluetooth_busy = 0;
        const available: c.gboolean = @intFromBool((((ok != 0) and (c.g_subprocess_get_successful(@as(?*c.GSubprocess, @ptrCast(source))) != 0)) and (output != null)) and (c.strstr(output, "Powered:") != null));
        m.bluetooth_powered = @intFromBool((available != 0) and (c.strstr(output, "Powered: yes") != null));
        c.gtk_label_set_text(cast(c.GtkLabel, m.bluetooth_label), if (m.bluetooth_powered != 0) "On" else "Off");
        const style: [*c]c.GtkStyleContext = c.gtk_widget_get_style_context(m.bluetooth_button);
        if (m.bluetooth_powered != 0) {
            c.gtk_style_context_add_class(style, "quick-active");
        } else {
            c.gtk_style_context_remove_class(style, "quick-active");
        }
        c.gtk_widget_set_sensitive(m.bluetooth_button, available);
        c.gtk_label_set_text(cast(c.GtkLabel, m.bluetooth_message), if (available != 0) "" else if (@"error" != null) @"error".*.message else "Bluetooth unavailable");
    }
    c.g_clear_error(&@"error");
    c.g_free(@as(c.gpointer, @ptrCast(output)));
    c.g_free(@as(c.gpointer, @ptrCast(errors)));
    unref_module(m);
}
pub fn bluetooth_run(m: *Module, callback: c.GAsyncReadyCallback, action: [*c]const u8, value: [*c]const u8) callconv(.c) void {
    var @"error": [*c]c.GError = null;
    const launcher: ?*c.GSubprocessLauncher = c.g_subprocess_launcher_new(@as(c_uint, @bitCast(c.G_SUBPROCESS_FLAGS_STDOUT_PIPE | c.G_SUBPROCESS_FLAGS_STDERR_PIPE)));
    c.g_subprocess_launcher_setenv(launcher, "LC_ALL", "C", 1);
    var argv: [6][*c]const u8 = [6][*c]const u8{
        m.bluetooth_command,
        "--timeout",
        "5",
        action,
        value,
        null,
    };
    const process: ?*c.GSubprocess = c.g_subprocess_launcher_spawnv(launcher, @as([*c][*c]const u8, @ptrCast(@alignCast(&argv[@as(usize, @intCast(0))]))), &@"error");
    c.g_object_unref(@as(c.gpointer, @ptrCast(launcher)));
    if (process != null) {
        m.bluetooth_busy = 1;
        m.refs += 1;
        c.g_subprocess_communicate_utf8_async(process, null, m.cancel, callback, @as(c.gpointer, @ptrCast(m)));
        c.g_object_unref(@as(c.gpointer, @ptrCast(process)));
    } else {
        c.gtk_label_set_text(cast(c.GtkLabel, m.bluetooth_message), @"error".*.message);
        c.g_clear_error(&@"error");
    }
}
pub fn bluetooth_set_ready(source: [*c]c.GObject, result: ?*c.GAsyncResult, data: c.gpointer) callconv(.c) void {
    const m: *Module = @as(*Module, @ptrCast(@alignCast(data)));
    var @"error": [*c]c.GError = null;
    var output: [*c]u8 = null;
    var errors: [*c]u8 = null;
    const ok: c.gboolean = c.g_subprocess_communicate_utf8_finish(@as(?*c.GSubprocess, @ptrCast(source)), result, &output, &errors, &@"error");
    if ((m.dead == 0)) {
        m.bluetooth_busy = 0;
        c.gtk_widget_set_sensitive(m.bluetooth_button, 1);
        if ((ok == 0) or !(c.g_subprocess_get_successful(@as(?*c.GSubprocess, @ptrCast(source))) != 0)) {
            c.gtk_label_set_text(cast(c.GtkLabel, m.bluetooth_message), if (@"error" != null) @"error".*.message else if ((errors != null) and (@as(c_int, @bitCast(@as(c_uint, errors.*))) != 0)) errors else if ((output != null) and (@as(c_int, @bitCast(@as(c_uint, output.*))) != 0)) output else "Could not change Bluetooth power");
        } else {
            _ = bluetooth_refresh(@as(c.gpointer, @ptrCast(m)));
        }
    }
    c.g_clear_error(&@"error");
    c.g_free(@as(c.gpointer, @ptrCast(output)));
    c.g_free(@as(c.gpointer, @ptrCast(errors)));
    unref_module(m);
}
pub fn bluetooth_toggle(button: [*c]c.GtkButton, data: c.gpointer) callconv(.c) void {
    const m: *Module = @as(*Module, @ptrCast(@alignCast(data)));
    if ((m.bluetooth_busy != 0) or !(m.bluetooth_command != null)) return;
    bluetooth_run(m, &bluetooth_set_ready, "power", if (m.bluetooth_powered != 0) "off" else "on");
    c.gtk_widget_set_sensitive(cast(c.GtkWidget, button), @intFromBool((m.bluetooth_busy == 0)));
}
pub fn bluetooth_settings(button: [*c]c.GtkButton, data: c.gpointer) callconv(.c) void {
    _ = button;
    const m: *Module = @as(*Module, @ptrCast(@alignCast(data)));
    var @"error": [*c]c.GError = null;
    if (m.bluetooth_settings_command != null) {
        _ = c.g_spawn_command_line_async(m.bluetooth_settings_command, &@"error");
    }
    if (@"error" != null) {
        c.gtk_label_set_text(cast(c.GtkLabel, m.bluetooth_message), @"error".*.message);
    }
    c.g_clear_error(&@"error");
}
pub fn settings_launch(button: [*c]c.GtkButton, data: c.gpointer) callconv(.c) void {
    var @"error": [*c]c.GError = null;
    _ = c.g_spawn_command_line_async(@as([*c]const c.gchar, @ptrCast(@alignCast(data))), &@"error");
    c.gtk_widget_set_tooltip_text(cast(c.GtkWidget, button), if (@"error" != null) @"error".*.message else null);
    c.g_clear_error(&@"error");
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
pub fn update_power(m: *Module) callconv(.c) void {
    var active: ?*c.GVariant = if (m.power != null) c.g_dbus_proxy_get_cached_property(m.power, "ActiveProfile") else null;
    var profiles: ?*c.GVariant = if (m.power != null) c.g_dbus_proxy_get_cached_property(m.power, "Profiles") else null;
    var inhibited: ?*c.GVariant = if (m.power != null) c.g_dbus_proxy_get_cached_property(m.power, "PerformanceInhibited") else null;
    const current: [*c]const u8 = if (active != null) c.g_variant_get_string(active, null) else @as([*c]const c.gchar, @ptrCast(@alignCast("")));
    c.gtk_label_set_text(cast(c.GtkLabel, m.power_label), "Power Mode");
    {
        var i: c.guint = 0;
        while (@as(c_ulong, @bitCast(@as(c_ulong, i))) < (@sizeOf([3][*c]const u8) / @sizeOf([*c]const u8))) : (i += 1) {
            var available: c.gboolean = 0;
            if (profiles != null) {
                var iter: c.GVariantIter = undefined;
                var entry: ?*c.GVariant = undefined;
                _ = c.g_variant_iter_init(&iter, profiles);
                while ((blk: {
                    const tmp = c.g_variant_iter_next_value(&iter);
                    entry = tmp;
                    break :blk tmp;
                }) != null) {
                    var id: [*c]const u8 = null;
                    if ((c.g_variant_lookup(entry, "Profile", "&s", &id) != 0) and (c.strcmp(id, power_ids[i]) == 0)) {
                        available = 1;
                    }
                    c.g_variant_unref(entry);
                }
            }
            const selected: c.gboolean = @intFromBool(c.strcmp(current, power_ids[i]) == 0);
            const style: [*c]c.GtkStyleContext = c.gtk_widget_get_style_context(m.power_buttons[i]);
            if (selected != 0) {
                c.gtk_style_context_add_class(style, "profile-selected");
            } else {
                c.gtk_style_context_remove_class(style, "profile-selected");
            }
            const label: [*c]u8 = c.g_strdup_printf("%s%s", power_names[i], @as([*:0]const u8, if (selected != 0) "  ✓" else ""));
            c.gtk_button_set_label(cast(c.GtkButton, m.power_buttons[i]), label);
            c.gtk_widget_set_visible(m.power_buttons[i], available);
            const blocked: c.gboolean = @intFromBool(((i == 0) and (inhibited != null)) and (@as(c_int, @bitCast(@as(c_uint, c.g_variant_get_string(inhibited, null).*))) != 0));
            c.gtk_widget_set_sensitive(m.power_buttons[i], @intFromBool((m.power_pending == 0) and (blocked == 0)));
            c.gtk_widget_set_tooltip_text(m.power_buttons[i], if (blocked != 0) c.g_variant_get_string(inhibited, null) else null);
            if (selected != 0) {
                c.gtk_label_set_text(cast(c.GtkLabel, m.power_label), power_names[i]);
                c.gtk_image_set_from_icon_name(cast(c.GtkImage, m.power_icon), power_icons[i], c.GTK_ICON_SIZE_MENU);
            }
            c.g_free(@as(c.gpointer, @ptrCast(label)));
        }
    }
    if ((m.power_pending == 0)) {
        c.gtk_label_set_text(cast(c.GtkLabel, m.power_message), if (active != null) "" else "Power profiles unavailable");
    }
    if (active != null) {
        c.g_variant_unref(active);
    }
    active = null;
    if (profiles != null) {
        c.g_variant_unref(profiles);
    }
    profiles = null;
    if (inhibited != null) {
        c.g_variant_unref(inhibited);
    }
    inhibited = null;
}
pub fn power_changed(proxy: [*c]c.GDBusProxy, changed: ?*c.GVariant, invalidated: [*c]const [*c]const u8, data: c.gpointer) callconv(.c) void {
    _ = invalidated;
    _ = changed;
    _ = proxy;
    update_power(@as(*Module, @ptrCast(@alignCast(data))));
}
pub fn power_set_ready(source: [*c]c.GObject, result: ?*c.GAsyncResult, data: c.gpointer) callconv(.c) void {
    const m: *Module = @as(*Module, @ptrCast(@alignCast(data)));
    var @"error": [*c]c.GError = null;
    var reply: ?*c.GVariant = c.g_dbus_proxy_call_finish(cast(c.GDBusProxy, source), result, &@"error");
    if ((m.dead == 0)) {
        m.power_pending = 0;
        update_power(m);
        c.gtk_label_set_text(cast(c.GtkLabel, m.power_message), if (@"error" != null) @"error".*.message else "");
    }
    if (reply != null) {
        c.g_variant_unref(reply);
    }
    reply = null;
    c.g_clear_error(&@"error");
    unref_module(m);
}
pub fn power_select(button: [*c]c.GtkButton, data: c.gpointer) callconv(.c) void {
    const m: *Module = @as(*Module, @ptrCast(@alignCast(data)));
    const id: [*c]const u8 = @as([*c]const u8, @ptrCast(@alignCast(c.g_object_get_data(cast(c.GObject, button), "profile"))));
    if (!(m.power != null) or (m.power_pending != 0)) return;
    m.power_pending = 1;
    update_power(m);
    c.gtk_label_set_text(cast(c.GtkLabel, m.power_message), "Switching…");
    m.refs += 1;
    c.g_dbus_proxy_call(m.power, "org.freedesktop.DBus.Properties.Set", c.g_variant_new("(ssv)", "org.freedesktop.UPower.PowerProfiles", "ActiveProfile", c.g_variant_new_string(id)), c.G_DBUS_CALL_FLAGS_ALLOW_INTERACTIVE_AUTHORIZATION, -1, m.cancel, &power_set_ready, @as(c.gpointer, @ptrCast(m)));
}
pub fn power_ready(source: [*c]c.GObject, result: ?*c.GAsyncResult, data: c.gpointer) callconv(.c) void {
    _ = source;
    const m: *Module = @as(*Module, @ptrCast(@alignCast(data)));
    var @"error": [*c]c.GError = null;
    var proxy: [*c]c.GDBusProxy = c.g_dbus_proxy_new_for_bus_finish(result, &@"error");
    if ((m.dead == 0)) {
        m.power = proxy;
        proxy = null;
        if (m.power != null) {
            _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(m.power)), "g-properties-changed", @as(c.GCallback, @ptrCast(@alignCast(&power_changed))), @as(c.gpointer, @ptrCast(m)), null, 0);
        }
        update_power(m);
        if (@"error" != null) {
            c.gtk_label_set_text(cast(c.GtkLabel, m.power_message), @"error".*.message);
        }
    }
    if (proxy != null) {
        c.g_object_unref(@as(c.gpointer, @ptrCast(proxy)));
    }
    proxy = null;
    c.g_clear_error(&@"error");
    unref_module(m);
}
pub fn power_click(widget: [*c]c.GtkWidget, event: [*c]c.GdkEventButton, data: c.gpointer) callconv(.c) c.gboolean {
    _ = widget;
    const m: *Module = @as(*Module, @ptrCast(@alignCast(data)));
    if (event.*.button != 1) return 0;
    if (c.gtk_widget_get_visible(m.power_menu) != 0) {
        c.gtk_popover_popdown(cast(c.GtkPopover, m.power_menu));
    } else {
        c.gtk_popover_popup(cast(c.GtkPopover, m.power_menu));
        _ = bluetooth_refresh(@as(c.gpointer, @ptrCast(m)));
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
    const month: [*c]u8 = c.g_date_time_format(m.calendar_selected, "%B %Y");
    c.gtk_label_set_text(cast(c.GtkLabel, m.calendar_weekday), weekday);
    c.gtk_label_set_text(cast(c.GtkLabel, m.calendar_date), date);
    c.gtk_button_set_label(cast(c.GtkButton, m.calendar_month), month);
    c.g_free(@as(c.gpointer, @ptrCast(weekday)));
    c.g_free(@as(c.gpointer, @ptrCast(date)));
    c.g_free(@as(c.gpointer, @ptrCast(month)));
    const first: ?*c.GDateTime = c.g_date_time_add_days(m.calendar_selected, 1 - c.g_date_time_get_day_of_month(m.calendar_selected));
    const start: ?*c.GDateTime = c.g_date_time_add_days(first, -@import("std").zig.c_translation.signedRemainder(c.g_date_time_get_day_of_week(first), 7));
    {
        var i: c.guint = 0;
        while (@as(c_ulong, @bitCast(@as(c_ulong, i))) < (@sizeOf([42][*c]c.GtkWidget) / @sizeOf([*c]c.GtkWidget))) : (i += 1) {
            const day: ?*c.GDateTime = c.g_date_time_add_days(start, @as(c.gint, @bitCast(i)));
            const button: [*c]c.GtkWidget = m.calendar_days[i];
            const label: [*c]u8 = c.g_date_time_format(day, "%-d");
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
    const box: [*c]c.GtkWidget = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 12);
    c.gtk_container_add(cast(c.GtkContainer, m.calendar), box);
    const today: [*c]c.GtkWidget = c.gtk_button_new();
    css(today, "calendar-today-button");
    _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(today)), "clicked", @as(c.GCallback, @ptrCast(@alignCast(&calendar_navigate))), @as(c.gpointer, @ptrCast(m)), null, 0);
    const heading: [*c]c.GtkWidget = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 3);
    m.calendar_weekday = c.gtk_label_new("");
    m.calendar_date = c.gtk_label_new("");
    css(m.calendar_weekday, "calendar-weekday-label");
    css(m.calendar_date, "calendar-date-label");
    c.gtk_label_set_xalign(cast(c.GtkLabel, m.calendar_weekday), 0);
    c.gtk_label_set_xalign(cast(c.GtkLabel, m.calendar_date), 0);
    c.gtk_container_add(cast(c.GtkContainer, heading), m.calendar_weekday);
    c.gtk_container_add(cast(c.GtkContainer, heading), m.calendar_date);
    c.gtk_container_add(cast(c.GtkContainer, today), heading);
    c.gtk_box_pack_start(cast(c.GtkBox, box), today, 0, 0, 0);
    const header: [*c]c.GtkWidget = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
    c.gtk_box_pack_start(cast(c.GtkBox, box), header, 0, 0, 0);
    m.calendar_month = c.gtk_button_new();
    _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(m.calendar_month)), "clicked", @as(c.GCallback, @ptrCast(@alignCast(&calendar_navigate))), @as(c.gpointer, @ptrCast(m)), null, 0);
    {
        var offset: c_int = -1;
        while (offset <= 1) : (offset += 2) {
            const arrow: [*c]c.GtkWidget = c.gtk_button_new_from_icon_name(if (offset < 0) "pan-start-symbolic" else "pan-end-symbolic", c.GTK_ICON_SIZE_MENU);
            css(arrow, "calendar-pager");
            c.gtk_widget_set_tooltip_text(arrow, if (offset < 0) "Previous month" else "Next month");
            c.g_object_set_data(cast(c.GObject, arrow), "month-offset", @as(c.gpointer, @ptrFromInt(@as(usize, @bitCast(@as(isize, offset))))));
            _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(arrow)), "clicked", @as(c.GCallback, @ptrCast(@alignCast(&calendar_navigate))), @as(c.gpointer, @ptrCast(m)), null, 0);
            c.gtk_box_pack_start(cast(c.GtkBox, header), arrow, 0, 0, 0);
            if (offset == -1) {
                c.gtk_box_pack_start(cast(c.GtkBox, header), m.calendar_month, 1, 1, 0);
            }
        }
    }
    const grid: [*c]c.GtkWidget = c.gtk_grid_new();
    c.gtk_grid_set_column_homogeneous(cast(c.GtkGrid, grid), 1);
    c.gtk_grid_set_row_homogeneous(cast(c.GtkGrid, grid), 1);
    c.gtk_box_pack_start(cast(c.GtkBox, box), grid, 0, 0, 0);
    const sunday: ?*c.GDateTime = c.g_date_time_new_local(2024, 1, 7, 12, 0, 0);
    {
        var i: c_int = 0;
        while (i < 7) : (i += 1) {
            const day: ?*c.GDateTime = c.g_date_time_add_days(sunday, i);
            const name: [*c]u8 = c.g_date_time_format(day, "%a");
            const letter: [*c]u8 = c.g_strndup(name, @as(c.gsize, @bitCast(@divExact(@as(c_long, @bitCast(@intFromPtr(name + @as(usize, @bitCast(@as(isize, @intCast(@as(c_int, @bitCast(@as(c_uint, c.g_utf8_skip[@as([*c]const c.guchar, @ptrCast(@alignCast(name))).*])))))))) -% @intFromPtr(name))), @sizeOf(u8)))));
            const label: [*c]c.GtkWidget = c.gtk_label_new(letter);
            css(label, "calendar-day-heading");
            c.gtk_widget_set_tooltip_text(label, name);
            c.gtk_grid_attach(cast(c.GtkGrid, grid), label, i, 0, 1, 1);
            c.g_free(@as(c.gpointer, @ptrCast(letter)));
            c.g_free(@as(c.gpointer, @ptrCast(name)));
            c.g_date_time_unref(day);
        }
    }
    c.g_date_time_unref(sunday);
    {
        var i: c.guint = 0;
        while (@as(c_ulong, @bitCast(@as(c_ulong, i))) < (@sizeOf([42][*c]c.GtkWidget) / @sizeOf([*c]c.GtkWidget))) : (i += 1) {
            const day: [*c]c.GtkWidget = blk: {
                const tmp = c.gtk_button_new();
                m.calendar_days[i] = tmp;
                break :blk tmp;
            };
            c.gtk_widget_set_halign(day, c.GTK_ALIGN_CENTER);
            c.gtk_widget_set_valign(day, c.GTK_ALIGN_CENTER);
            css(day, "calendar-day");
            if (((i % 7) == 0) or ((i % 7) == 6)) {
                css(day, "calendar-weekend");
            }
            _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(day)), "clicked", @as(c.GCallback, @ptrCast(@alignCast(&calendar_select))), @as(c.gpointer, @ptrCast(m)), null, 0);
            c.gtk_grid_attach(cast(c.GtkGrid, grid), day, @as(c.gint, @bitCast(i % 7)), @as(c.gint, @bitCast(1 +% (i / 7))), 1, 1);
        }
    }
    m.calendar_selected = c.g_date_time_new_now_local();
    calendar_refresh(m);
    c.gtk_widget_show_all(box);
}
pub fn clock_click(widget: [*c]c.GtkWidget, event: [*c]c.GdkEventButton, data: c.gpointer) callconv(.c) c.gboolean {
    _ = widget;
    const m: *Module = @as(*Module, @ptrCast(@alignCast(data)));
    if (event.*.button != 1) return 0;
    if (c.gtk_widget_get_visible(m.calendar) != 0) {
        c.gtk_popover_popdown(cast(c.GtkPopover, m.calendar));
    } else {
        calendar_navigate(null, @as(c.gpointer, @ptrCast(m)));
        c.gtk_popover_popup(cast(c.GtkPopover, m.calendar));
    }
    return 1;
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
    const menu: [*c]c.GtkWidget = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 12);
    c.gtk_widget_set_size_request(menu, 300, -1);
    c.gtk_container_add(cast(c.GtkContainer, m.codex_menu), menu);
    const titles: [2][*c]const u8 = [2][*c]const u8{
        "5-Hour Remaining",
        "Weekly Remaining",
    };
    {
        var i: c.guint = 0;
        while (i < 2) : (i += 1) {
            const section: [*c]c.GtkWidget = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 6);
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
            c.gtk_box_pack_start(cast(c.GtkBox, section), m.codex_progress[i], 0, 0, 0);
            m.codex_reset[i] = c.gtk_label_new("Resets: —");
            c.gtk_label_set_xalign(cast(c.GtkLabel, m.codex_reset[i]), 0);
            css(m.codex_reset[i], "codex-reset-label");
            c.gtk_box_pack_start(cast(c.GtkBox, section), m.codex_reset[i], 0, 0, 0);
            c.gtk_box_pack_start(cast(c.GtkBox, menu), section, 0, 0, 0);
            c.gtk_box_pack_start(cast(c.GtkBox, menu), c.gtk_separator_new(c.GTK_ORIENTATION_HORIZONTAL), 0, 0, 0);
        }
    }
    const footer: [*c]c.GtkWidget = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 10);
    m.codex_refresh = c.gtk_button_new_with_label("Refresh");
    c.gtk_widget_set_sensitive(m.codex_refresh, 0);
    c.gtk_button_set_image(cast(c.GtkButton, m.codex_refresh), c.gtk_image_new_from_icon_name("view-refresh-symbolic", c.GTK_ICON_SIZE_MENU));
    c.gtk_button_set_always_show_image(cast(c.GtkButton, m.codex_refresh), 1);
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
pub fn config_string(entries: [*c]const ConfigEntry, length: usize, key: [*c]const u8) callconv(.c) [*c]u8 {
    {
        var i: usize = 0;
        while (i < length) : (i += 1) {
            if (c.strcmp(entries[i].key, key) != 0) continue;
            const parser: [*c]c.JsonParser = c.json_parser_new();
            var value: [*c]u8 = null;
            if (c.json_parser_load_from_data(parser, entries[i].value, @as(c.gssize, -1), null) != 0) {
                value = c.g_strdup(c.json_node_get_string(c.json_parser_get_root(parser)));
            }
            c.g_object_unref(@as(c.gpointer, @ptrCast(parser)));
            return value;
        }
    }
    return null;
}
pub export fn wbcffi_init(info: *const InitInfo, entries: [*c]const ConfigEntry, length: usize) ?*anyopaque {
    const m: *Module = @as(*Module, @ptrCast(@alignCast(c.g_malloc0_n(@as(c.gsize, 1), @sizeOf(Module)))));
    m.refs = 1;
    m.cancel = c.g_cancellable_new();
    const kind: [*c]u8 = config_string(entries, length, "kind");
    const name: [*c]u8 = config_string(entries, length, "name");
    m.monitors = @intFromBool(c.g_strcmp0(kind, "monitors") == 0);
    m.status = @intFromBool(c.g_strcmp0(name, "gnome-status") == 0);
    m.box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, if ((m.monitors != 0) or (m.status != 0)) 4 else 0);
    if (c.g_strcmp0(name, "gnome-disk") != 0) {
        c.gtk_widget_set_margin_start(m.box, 15);
        c.gtk_widget_set_margin_end(m.box, 15);
        if ((m.monitors == 0)) {
            c.gtk_widget_set_margin_top(m.box, 3);
            c.gtk_widget_set_margin_bottom(m.box, 3);
        }
    }
    const root: [*c]c.GtkContainer = info.get_root_widget.?(info.obj);
    m.root = cast(c.GtkWidget, root);
    if (name != null) {
        c.gtk_widget_set_name(cast(c.GtkWidget, root), name);
    }
    css(cast(c.GtkWidget, root), "gnome-panel-module");
    c.gtk_container_add(root, m.box);
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
        m.network_settings_command = config_string(entries, length, "network-settings-command");
        if (m.network_settings_command != null) {
            _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(network)), "clicked", @as(c.GCallback, @ptrCast(@alignCast(&settings_launch))), @as(c.gpointer, @ptrCast(m.network_settings_command)), null, 0);
        }
        const bluetooth: [*c]c.GtkWidget = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
        css(bluetooth, "quick-split");
        m.bluetooth_label = c.gtk_label_new("Off");
        m.bluetooth_button = quick_tile(c.gtk_button_new(), "Bluetooth", c.gtk_image_new_from_icon_name("bluetooth-active-symbolic", c.GTK_ICON_SIZE_MENU), m.bluetooth_label, 0);
        c.gtk_widget_set_sensitive(m.bluetooth_button, 0);
        _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(m.bluetooth_button)), "clicked", @as(c.GCallback, @ptrCast(@alignCast(&bluetooth_toggle))), @as(c.gpointer, @ptrCast(m)), null, 0);
        c.gtk_box_pack_start(cast(c.GtkBox, bluetooth), m.bluetooth_button, 1, 1, 0);
        const devices: [*c]c.GtkWidget = c.gtk_button_new_from_icon_name("go-next-symbolic", c.GTK_ICON_SIZE_MENU);
        css(devices, "quick-menu-arrow");
        c.gtk_widget_set_tooltip_text(devices, "Bluetooth Settings");
        _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(devices)), "clicked", @as(c.GCallback, @ptrCast(@alignCast(&bluetooth_settings))), @as(c.gpointer, @ptrCast(m)), null, 0);
        c.gtk_box_pack_start(cast(c.GtkBox, bluetooth), devices, 0, 0, 0);
        c.gtk_grid_attach(cast(c.GtkGrid, tiles), bluetooth, 1, 0, 1, 1);
        const power: [*c]c.GtkWidget = quick_tile(c.gtk_toggle_button_new(), "Power Mode", m.power_icon, m.power_label, 1);
        c.gtk_grid_attach(cast(c.GtkGrid, tiles), power, 0, 1, 1, 1);
        const sound: [*c]c.GtkWidget = quick_tile(c.gtk_button_new(), "Sound", c.gtk_image_new_from_icon_name("audio-volume-high-symbolic", c.GTK_ICON_SIZE_MENU), null, 1);
        _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(sound)), "clicked", @as(c.GCallback, @ptrCast(@alignCast(&settings_launch))), @as(c.gpointer, @ptrCast(@constCast("pavucontrol"))), null, 0);
        c.gtk_grid_attach(cast(c.GtkGrid, tiles), sound, 1, 1, 1, 1);
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
                c.g_object_set_data(cast(c.GObject, m.power_buttons[i]), "profile", @as(c.gpointer, @ptrCast(@volatileCast(@constCast(power_ids[i])))));
                _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(m.power_buttons[i])), "clicked", @as(c.GCallback, @ptrCast(@alignCast(&power_select))), @as(c.gpointer, @ptrCast(m)), null, 0);
                c.gtk_box_pack_start(cast(c.GtkBox, profiles), m.power_buttons[i], 0, 0, 0);
            }
        }
        const revealer: [*c]c.GtkWidget = c.gtk_revealer_new();
        c.gtk_container_add(cast(c.GtkContainer, revealer), profiles);
        c.gtk_box_pack_start(cast(c.GtkBox, menu), revealer, 0, 0, 0);
        _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(power)), "toggled", @as(c.GCallback, @ptrCast(@alignCast(&power_expand))), @as(c.gpointer, @ptrCast(revealer)), null, 0);
        m.power_message = c.gtk_label_new("Connecting…");
        m.bluetooth_message = c.gtk_label_new("");
        const messages: [2][*c]c.GtkWidget = [2][*c]c.GtkWidget{
            m.power_message,
            m.bluetooth_message,
        };
        {
            var i: c.guint = 0;
            while (@as(c_ulong, @bitCast(@as(c_ulong, i))) < (@sizeOf([2][*c]c.GtkWidget) / @sizeOf([*c]c.GtkWidget))) : (i += 1) {
                c.gtk_label_set_line_wrap(cast(c.GtkLabel, messages[i]), 1);
                c.gtk_label_set_max_width_chars(cast(c.GtkLabel, messages[i]), 40);
                css(messages[i], "quick-message");
                c.gtk_widget_set_no_show_all(messages[i], 1);
                _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(messages[i])), "notify::label", @as(c.GCallback, @ptrCast(@alignCast(&message_changed))), @as(?*anyopaque, @ptrFromInt(0)), null, 0);
                message_changed(cast(c.GObject, messages[i]), null, @as(?*anyopaque, @ptrFromInt(0)));
                c.gtk_box_pack_start(cast(c.GtkBox, menu), messages[i], 0, 0, 0);
            }
        }
        m.bluetooth_command = config_string(entries, length, "bluetooth-command");
        m.bluetooth_settings_command = config_string(entries, length, "bluetooth-settings-command");
        m.bluetooth_timer = c.g_timeout_add_seconds(5, &bluetooth_refresh, @as(c.gpointer, @ptrCast(m)));
        c.gtk_widget_show_all(menu);
        update_power(m);
        _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(m.root)), "button-press-event", @as(c.GCallback, @ptrCast(@alignCast(&power_click))), @as(c.gpointer, @ptrCast(m)), null, 0);
        m.refs += 1;
        c.g_dbus_proxy_new_for_bus(c.G_BUS_TYPE_SYSTEM, c.G_DBUS_PROXY_FLAGS_NONE, null, "org.freedesktop.UPower.PowerProfiles", "/org/freedesktop/UPower/PowerProfiles", "org.freedesktop.UPower.PowerProfiles", m.cancel, &power_ready, @as(c.gpointer, @ptrCast(m)));
    } else if (c.g_strcmp0(kind, "clock") == 0) {
        m.clock = c.gtk_label_new("");
        c.gtk_container_add(cast(c.GtkContainer, m.box), m.clock);
        m.calendar = c.gtk_popover_new(m.root);
        c.gtk_popover_set_constrain_to(cast(c.GtkPopover, m.calendar), c.GTK_POPOVER_CONSTRAINT_NONE);
        c.gtk_popover_set_position(cast(c.GtkPopover, m.calendar), c.GTK_POS_BOTTOM);
        css(m.calendar, "gnome-calendar");
        make_calendar(m);
        _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(m.root)), "button-press-event", @as(c.GCallback, @ptrCast(@alignCast(&clock_click))), @as(c.gpointer, @ptrCast(m)), null, 0);
        _ = update_clock(@as(c.gpointer, @ptrCast(m)));
        m.clock_timer = c.g_timeout_add_seconds(1, &update_clock, @as(c.gpointer, @ptrCast(m)));
    } else if (c.g_strcmp0(kind, "activities") == 0) {
        const area: [*c]c.GtkWidget = c.gtk_drawing_area_new();
        c.gtk_widget_set_size_request(area, 42, 20);
        _ = c.g_signal_connect_data(@as(c.gpointer, @ptrCast(area)), "draw", @as(c.GCallback, @ptrCast(@alignCast(&draw_activities))), @as(?*anyopaque, @ptrFromInt(0)), null, 0);
        c.gtk_container_add(cast(c.GtkContainer, m.box), area);
    }
    m.command = config_string(entries, length, "exec");
    c.gtk_widget_show_all(m.box);
    if (m.command != null) {
        _ = start_process(@as(c.gpointer, @ptrCast(m)));
    }
    c.g_free(@as(c.gpointer, @ptrCast(name)));
    c.g_free(@as(c.gpointer, @ptrCast(kind)));
    return @as(?*anyopaque, @ptrCast(m));
}
pub export fn wbcffi_deinit(instance: ?*anyopaque) void {
    var m: *Module = @as(*Module, @ptrCast(@alignCast(instance)));
    m.dead = 1;
    if (m.clock_timer != 0) {
        _ = c.g_source_remove(m.clock_timer);
    }
    if (m.bluetooth_timer != 0) {
        _ = c.g_source_remove(m.bluetooth_timer);
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
    if (m.power != null) {
        _ = c.g_signal_handlers_disconnect_matched(@as(c.gpointer, @ptrCast(m.power)), c.G_SIGNAL_MATCH_DATA, 0, @as(c.GQuark, 0), null, @as(?*anyopaque, @ptrFromInt(0)), @as(c.gpointer, @ptrCast(m)));
    }
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
pub export fn wbcffi_update(instance: ?*anyopaque) void {
    _ = instance;
}
pub export fn wbcffi_refresh(instance: ?*anyopaque, signal_1: c_int) void {
    _ = signal_1;
    _ = instance;
}
pub export fn wbcffi_doaction(instance: ?*anyopaque, action: [*c]const u8) void {
    _ = action;
    _ = instance;
}
