//! Panel data and actions, with native pixel views in GTK window hosts.
const std = @import("std");
const power_backend = @import("desktop-power.zig");
const quick = @import("desktop-quick-settings.zig");
pub const date_menu = @import("desktop-date-menu.zig");
pub const c = @import("desktop-gtk.zig");
pub const native = @import("desktop-panel-view.zig");
const module_allocator = if (@import("builtin").is_test) std.testing.allocator else std.heap.page_allocator;
fn cast(comptime T: type, p: anytype) *T {
    return @ptrCast(@alignCast(p));
}
pub const Options = struct {
    name: [:0]const u8 = "",
    kind: [:0]const u8 = "indicator",
    source: [:0]const u8 = "",
    on_click: ?[:0]const u8 = null,
    network_settings_command: ?[:0]const u8 = null,
    sound_settings_command: [:0]const u8 = "desktop-zig settings sound",
};
pub const Module = struct {
    refs: c.gint = 1,
    dead: c.gboolean = 0,
    monitors: c.gboolean = 0,
    status: c.gboolean = 0,
    box: [*c]c.GtkWidget = null,
    root: [*c]c.GtkWidget = null,
    calendar: [*c]c.GtkWidget = null,
    date_controls: ?*date_menu.Controls = null,
    history_subscription: c.guint = 0,
    history_busy: bool = false,
    history_dirty: bool = false,
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
    codex_canvas: [*c]c.GtkWidget = null,
    view: native.View = .{},
    tip: native.Label = .{},
    tip_canvas: [*c]c.GtkWidget = null,
    codex: native.Codex = .{},
    tooltip: [*c]u8 = null,
};
pub fn unref_module(m: *Module) callconv(.c) void {
    m.refs -= 1;
    if (m.refs != 0) return;
    if (m.cancel != null) c.g_object_unref(m.cancel);
    if (m.session != null) c.g_object_unref(m.session);
    c.g_free(m.tooltip);
    m.tip.deinit();
    m.view.deinit();
    m.codex.deinit();
    module_allocator.destroy(m);
}
var style_loaded = false;
pub fn ensureStyle() void {
    if (style_loaded) return;
    const screen = c.gdk_screen_get_default() orelse return;
    const provider = c.gtk_css_provider_new().?;
    defer c.g_object_unref(provider);
    const rules =
        \\window#desktop-panel { background: #000; color: #fff; }
        \\.gnome-panel-module, .gnome-panel-module * { border: none; border-radius: 0; min-height: 0; padding: 0; margin: 0; }
        \\popover.gnome-calendar, popover.gnome-calendar.background, popover.gnome-calendar > contents,
        \\popover.gnome-codex-menu, popover.gnome-codex-menu.background, popover.gnome-codex-menu > contents,
        \\popover.gnome-power-menu, popover.gnome-power-menu.background, popover.gnome-power-menu > contents,
        \\.gnome-power-menu .quick-native-host, .gnome-power-menu .quick-native-host viewport {
        \\  background: transparent; background-image: none; border: none; border-radius: 0; padding: 0; margin: 0; box-shadow: none;
        \\}
        \\tooltip, tooltip.background {
        \\  background: #36363a; color: #fff; border: 1px solid rgba(255,255,255,0.15); border-radius: 12px;
        \\}
    ;
    _ = c.gtk_css_provider_load_from_data(provider, rules, rules.len, null);
    c.gtk_style_context_add_provider_for_screen(screen, cast(c.GtkStyleProvider, provider), c.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    style_loaded = true;
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
pub var power_ids: [3][*c]const u8 = [3][*c]const u8{
    "performance",
    "balanced",
    "power-saver",
};
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
    m.view.clock.set(std.mem.span(label));
    resize(m);
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
pub fn codex_refresh(m: *Module) void {
    if (!m.codex.enabled or !std.mem.eql(u8, std.mem.span(m.source), "codex")) return;
    m.codex.enabled = false;
    m.codex.checked.set("Refreshing…");
    c.gtk_widget_queue_draw(m.codex_canvas);
    if (refresh_source) |refresh| refresh("codex");
}
pub fn make_codex_menu(m: *Module) callconv(.c) void {
    m.codex_menu = c.gtk_popover_new(m.root);
    c.gtk_popover_set_constrain_to(cast(c.GtkPopover, m.codex_menu), c.GTK_POPOVER_CONSTRAINT_NONE);
    c.gtk_popover_set_position(cast(c.GtkPopover, m.codex_menu), c.GTK_POS_BOTTOM);
    css(m.codex_menu, "gnome-codex-menu");
    m.codex_canvas = c.gtk_drawing_area_new();
    c.gtk_widget_set_can_focus(m.codex_canvas, 1);
    c.gtk_widget_add_events(m.codex_canvas, c.GDK_BUTTON_PRESS_MASK | c.GDK_BUTTON_RELEASE_MASK | c.GDK_POINTER_MOTION_MASK | c.GDK_LEAVE_NOTIFY_MASK | c.GDK_KEY_PRESS_MASK);
    c.gtk_container_add(cast(c.GtkContainer, m.codex_menu), m.codex_canvas);
    connect(m.codex_canvas, "draw", &draw_codex, m);
    connect(m.codex_canvas, "notify::scale-factor", &codex_scale, m);
    connect(m.codex_canvas, "button-press-event", &codex_press, m);
    connect(m.codex_canvas, "button-release-event", &codex_release, m);
    connect(m.codex_canvas, "motion-notify-event", &codex_motion, m);
    connect(m.codex_canvas, "leave-notify-event", &codex_leave, m);
    connect(m.codex_canvas, "key-press-event", &codex_key, m);
    connect(m.codex_menu, "map", &codex_mapped, m);
    connect(m.codex_menu, "notify::visible", &codex_menu_visibility, m);
    connect(m.codex_menu, "closed", &codex_menu_closed, m);
    connect(m.root, "button-press-event", &codex_click, m);
    c.gtk_widget_set_size_request(m.codex_canvas, @intCast(m.codex.width), @intCast(m.codex.height));
    c.gtk_widget_show_all(m.codex_canvas);
}
pub fn update_codex(m: *Module, o: std.json.Value, a: std.mem.Allocator) void {
    const windows_val = o.object.get("windows");
    const windows: ?[]const std.json.Value = if (windows_val) |w| if (w == .array) w.array.items else null else null;
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
        m.codex.percent[i].set(std.mem.span(label));
        c.g_free(@as(c.gpointer, @ptrCast(label)));
        m.codex.values[i] = value;
        const reset_str = if (window) |win| jsonStringZ(a, win.object.get("reset")) else "Resets: —";
        m.codex.reset[i].set(reset_str);
    }
    const checked_str = jsonStringZ(a, o.object.get("checked"));
    m.codex.checked.set(if (checked_str.len != 0) checked_str else "Checked: —");
    m.codex.error_label.set(jsonStringZ(a, o.object.get("error")));
    m.codex.enabled = true;
    resize_codex(m);
}
fn update_items(m: *Module, items: []const std.json.Value, arena: std.mem.Allocator) void {
    const count = @min(items.len, 8);
    for (&m.view.items, 0..) |*item, i| {
        item.visible = i < count and items[i] == .object;
        if (!item.visible) continue;
        const value = items[i];
        item.setIcon(jsonStringZ(arena, value.object.get("icon")));
        item.label.set(jsonStringZ(arena, value.object.get("text")));
        item.tooltip.set(jsonStringZ(arena, value.object.get("tooltip")));
        item.command.set(jsonStringZ(arena, value.object.get("command")));
    }
}

fn update_graph(g: *native.Graph, o: std.json.Value, a: std.mem.Allocator) void {
    const tooltip = jsonStringZ(a, o.object.get("tooltip"));
    g.tooltip.set(tooltip);
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
                if (graph_obj == .object) update_graph(&m.view.graphs[i], graph_obj, arena.allocator());
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
    resize(m);
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
    ensureStyle();
    const m = module_allocator.create(Module) catch @panic("out of memory");
    m.* = .{};
    m.cancel = c.g_cancellable_new();
    const kind = options.kind.ptr;
    const name = options.name.ptr;
    m.monitors = @intFromBool(c.g_strcmp0(kind, "monitors") == 0);
    m.status = @intFromBool(c.g_strcmp0(name, "gnome-status") == 0);
    m.view = .{ .monitors = m.monitors != 0, .status = m.status != 0, .activities = std.mem.eql(u8, options.kind, "activities"), .codex = std.mem.eql(u8, options.name, "gnome-codex"), .disk = std.mem.eql(u8, options.name, "gnome-disk") };
    m.box = c.gtk_drawing_area_new();
    m.root = root;
    m.tip_canvas = c.gtk_drawing_area_new();
    _ = c.g_object_ref_sink(m.tip_canvas);
    connect(m.tip_canvas, "draw", &draw_tooltip, m);
    connect(m.box, "query-tooltip", &query_tooltip, m);
    if (options.name.len != 0) c.gtk_widget_set_name(root, name);
    // The drawing area owns padding and hover rendering, independent of CSS borders.
    c.gtk_container_add(cast(c.GtkContainer, root), m.box);
    c.gtk_widget_set_can_focus(root, 1);
    c.gtk_widget_add_events(root, c.GDK_BUTTON_PRESS_MASK | c.GDK_POINTER_MOTION_MASK | c.GDK_LEAVE_NOTIFY_MASK | c.GDK_KEY_PRESS_MASK | c.GDK_FOCUS_CHANGE_MASK);
    connect(m.box, "draw", &draw_panel, m);
    connect(m.box, "notify::scale-factor", &panel_scale, m);
    connect(root, "motion-notify-event", &panel_motion, m);
    connect(root, "leave-notify-event", &panel_leave, m);
    connect(root, "button-press-event", &panel_press, m);
    connect(root, "key-press-event", &panel_key, m);
    connect(root, "focus-in-event", &panel_focus_in, m);
    connect(root, "focus-out-event", &panel_focus_out, m);
    if (m.monitors != 0) {
        resize(m);
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
    }
    resize(m);
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
    _ = c.g_signal_handlers_disconnect_matched(m.tip_canvas, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, m);
    c.gtk_widget_destroy(m.tip_canvas);
    c.g_object_unref(m.tip_canvas);
    _ = c.g_signal_handlers_disconnect_matched(m.box, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, m);
    unref_module(m);
}

/// Session callback for built-in collectors; invoked only on the GTK thread.
pub var refresh_source: ?*const fn ([]const u8) void = null;

fn connect(widget: anytype, signal: [*:0]const u8, callback: anytype, data: anytype) void {
    _ = c.g_signal_connect_data(widget, signal, @ptrCast(callback), data, null, 0);
}
fn resize(m: *Module) void {
    const scale: u32 = @intCast(@max(1, c.gtk_widget_get_scale_factor(m.box)));
    m.view.prepare(scale, @floatFromInt(@max(1, c.gtk_widget_get_allocated_height(m.box)))) catch |err| {
        std.log.err("panel layout: {s}", .{@errorName(err)});
        return;
    };
    c.gtk_widget_set_size_request(m.box, @intCast(m.view.width), 1);
    c.gtk_widget_queue_draw(m.box);
}
fn draw_panel(widget: *c.GtkWidget, cr: *c.cairo_t, ptr: c.gpointer) callconv(.c) c.gboolean {
    const m = cast(Module, ptr);
    paint(widget, cr, m, false) catch |err| std.log.err("panel paint: {s}", .{@errorName(err)});
    return 1;
}
fn draw_codex(widget: *c.GtkWidget, cr: *c.cairo_t, ptr: c.gpointer) callconv(.c) c.gboolean {
    paint(widget, cr, cast(Module, ptr), true) catch |err| std.log.err("Codex paint: {s}", .{@errorName(err)});
    return 1;
}
fn paint(widget: *c.GtkWidget, cr: *c.cairo_t, m: *Module, codex: bool) !void {
    const scale: u32 = @intCast(@max(1, c.gtk_widget_get_scale_factor(widget)));
    const logical_width: u32 = @intCast(@max(1, c.gtk_widget_get_allocated_width(widget)));
    const logical_height: u32 = @intCast(@max(1, c.gtk_widget_get_allocated_height(widget)));
    if (codex) {
        try m.codex.prepare(scale);
        try c.__zig.paintCairo(cr, logical_width, logical_height, scale, &m.codex, native.Codex.paint);
    } else {
        try m.view.prepare(scale, @floatFromInt(logical_height));
        try c.__zig.paintCairo(cr, logical_width, logical_height, scale, &m.view, native.View.paint);
    }
}
fn panel_motion(_: *c.GtkWidget, event: *c.GdkEventMotion, ptr: c.gpointer) callconv(.c) c.gboolean {
    const m = cast(Module, ptr);
    m.view.hovered = true;
    c.gtk_widget_queue_draw(m.box);
    var tooltip = m.tooltip;
    if (m.view.monitors) {
        const index: usize = @intFromFloat(@max(0, event.x - 18) / 118);
        if (index < 3) tooltip = @constCast(m.view.graphs[index].tooltip.value.ptr);
    } else if (m.codex_menu == null) {
        if (m.view.hit(event.x, event.y)) |index| tooltip = @constCast(m.view.items[index].tooltip.value.ptr);
    }
    if (m.codex_menu != null and c.gtk_widget_get_visible(m.codex_menu) != 0) tooltip = null;
    c.gtk_widget_set_tooltip_text(m.box, tooltip);
    return 0;
}
fn panel_leave(_: *c.GtkWidget, _: *c.GdkEventCrossing, ptr: c.gpointer) callconv(.c) c.gboolean {
    const m = cast(Module, ptr);
    m.view.hovered = false;
    c.gtk_widget_queue_draw(m.box);
    return 0;
}
fn panel_focus_in(_: *c.GtkWidget, _: *c.GdkEvent, ptr: c.gpointer) callconv(.c) c.gboolean {
    const m = cast(Module, ptr);
    m.view.focus = true;
    c.gtk_widget_queue_draw(m.box);
    return 0;
}
fn panel_focus_out(_: *c.GtkWidget, _: *c.GdkEvent, ptr: c.gpointer) callconv(.c) c.gboolean {
    const m = cast(Module, ptr);
    m.view.focus = false;
    c.gtk_widget_queue_draw(m.box);
    return 0;
}
fn panel_press(_: *c.GtkWidget, event: *c.GdkEventButton, ptr: c.gpointer) callconv(.c) c.gboolean {
    const m = cast(Module, ptr);
    if (event.button != 1 or m.status != 0 or m.codex_menu != null or m.calendar != null) return 0;
    const index = m.view.hit(event.x, event.y) orelse return 0;
    const command = m.view.items[index].command.value;
    if (command.len == 0) return 0;
    var err: ?*c.GError = null;
    _ = c.g_spawn_command_line_async(command, &err);
    c.g_clear_error(&err);
    return 1;
}
fn panel_key(widget: *c.GtkWidget, event: *c.GdkEvent, ptr: c.gpointer) callconv(.c) c.gboolean {
    var symbol: c.guint = 0;
    _ = c.gdk_event_get_keyval(event, &symbol);
    if (symbol != 0xff0d and symbol != 0xff8d and symbol != 0x20) return 0;
    var click = std.mem.zeroes(c.GdkEventButton);
    click.button = 1;
    var handled: c.gboolean = 0;
    c.g_signal_emit_by_name(widget, "button-press-event", &click, &handled);
    _ = ptr;
    return handled;
}
fn codex_press(_: *c.GtkWidget, event: *c.GdkEventButton, ptr: c.gpointer) callconv(.c) c.gboolean {
    if (event.button != 1) return 0;
    const m = cast(Module, ptr);
    m.codex.keyboard_focus = false;
    m.codex.pressed = m.codex.enabled and m.codex.refreshRect().contains(event.x, event.y);
    c.gtk_widget_grab_focus(m.codex_canvas);
    c.gtk_widget_queue_draw(m.codex_canvas);
    return 1;
}
fn codex_release(_: *c.GtkWidget, event: *c.GdkEventButton, ptr: c.gpointer) callconv(.c) c.gboolean {
    if (event.button != 1) return 0;
    const m = cast(Module, ptr);
    const activate = m.codex.pressed and m.codex.refreshRect().contains(event.x, event.y);
    m.codex.pressed = false;
    if (activate) codex_refresh(m);
    c.gtk_widget_queue_draw(m.codex_canvas);
    return 1;
}
fn codex_motion(_: *c.GtkWidget, event: *c.GdkEventMotion, ptr: c.gpointer) callconv(.c) c.gboolean {
    const m = cast(Module, ptr);
    m.codex.hovered = m.codex.refreshRect().contains(event.x, event.y);
    c.gtk_widget_queue_draw(m.codex_canvas);
    return 0;
}
fn codex_leave(_: *c.GtkWidget, _: *c.GdkEventCrossing, ptr: c.gpointer) callconv(.c) c.gboolean {
    const m = cast(Module, ptr);
    m.codex.hovered = false;
    c.gtk_widget_queue_draw(m.codex_canvas);
    return 0;
}
fn codex_key(_: *c.GtkWidget, event: *c.GdkEvent, ptr: c.gpointer) callconv(.c) c.gboolean {
    const m = cast(Module, ptr);
    var symbol: c.guint = 0;
    _ = c.gdk_event_get_keyval(event, &symbol);
    switch (symbol) {
        0xff1b => c.gtk_popover_popdown(cast(c.GtkPopover, m.codex_menu)),
        0xff09, 0xfe20 => m.codex.keyboard_focus = true,
        0xff0d, 0xff8d, 0x20 => codex_refresh(m),
        else => return 0,
    }
    c.gtk_widget_queue_draw(m.codex_canvas);
    return 1;
}
fn codex_mapped(_: *c.GtkWidget, ptr: c.gpointer) callconv(.c) void {
    const m = cast(Module, ptr);
    m.codex.pressed = false;
    m.codex.hovered = false;
    m.codex.keyboard_focus = true;
    c.gtk_widget_grab_focus(m.codex_canvas);
}

fn query_tooltip(_: *c.GtkWidget, x: c_int, y: c_int, keyboard: c.gboolean, tooltip: ?*c.GtkTooltip, ptr: c.gpointer) callconv(.c) c.gboolean {
    const m = cast(Module, ptr);
    if (m.codex_menu != null and c.gtk_widget_get_visible(m.codex_menu) != 0) return 0;
    var value: [:0]const u8 = if (m.tooltip != null) std.mem.span(m.tooltip) else "";
    if (keyboard == 0) {
        if (m.monitors != 0) {
            const index: usize = @intCast(@max(0, x - 18));
            if (index / 118 < 3) value = m.view.graphs[index / 118].tooltip.value;
        } else if (!m.view.codex) {
            if (m.view.hit(@floatFromInt(x), @floatFromInt(y))) |index| value = m.view.items[index].tooltip.value;
        }
    }
    if (value.len == 0) return 0;
    m.tip.set(value);
    const scale: u32 = @intCast(@max(1, c.gtk_widget_get_scale_factor(m.box)));
    m.tip.prepare(&m.view.renderer, scale, 13.333, false, null, false) catch return 0;
    if (m.tip.width() > 480) m.tip.prepare(&m.view.renderer, scale, 13.333, false, 480, false) catch return 0;
    c.gtk_widget_set_size_request(m.tip_canvas, @intFromFloat(m.tip.width() + 16), @intFromFloat(m.tip.height() + 16));
    c.gtk_widget_show(m.tip_canvas);
    c.gtk_tooltip_set_custom(tooltip, m.tip_canvas);
    c.gtk_widget_queue_draw(m.tip_canvas);
    return 1;
}
fn paintTooltip(m: *Module, buffer: @import("desktop-raster.zig").Buffer) void {
    @memset(buffer.pixels, 0);
    m.tip.paint(buffer, 8, 8, .{ .red = 1, .green = 1, .blue = 1 });
}
fn draw_tooltip(widget: *c.GtkWidget, cr: *c.cairo_t, ptr: c.gpointer) callconv(.c) c.gboolean {
    const m = cast(Module, ptr);
    const scale: u32 = @intCast(@max(1, c.gtk_widget_get_scale_factor(widget)));
    const limit = m.tip.limit;
    m.tip.prepare(&m.view.renderer, scale, 13.333, false, limit, false) catch return 1;
    c.__zig.paintCairo(cr, @intCast(@max(1, c.gtk_widget_get_allocated_width(widget))), @intCast(@max(1, c.gtk_widget_get_allocated_height(widget))), scale, m, paintTooltip) catch {};
    return 1;
}

fn panel_scale(_: *c.GObject, _: *c.GParamSpec, ptr: c.gpointer) callconv(.c) void {
    resize(cast(Module, ptr));
}
fn codex_scale(_: *c.GObject, _: *c.GParamSpec, ptr: c.gpointer) callconv(.c) void {
    resize_codex(cast(Module, ptr));
}
fn resize_codex(m: *Module) void {
    const scale: u32 = @intCast(@max(1, c.gtk_widget_get_scale_factor(m.codex_canvas)));
    m.codex.prepare(scale) catch |err| {
        std.log.err("Codex layout: {s}", .{@errorName(err)});
        return;
    };
    c.gtk_widget_set_size_request(m.codex_canvas, @intCast(m.codex.width), @intCast(m.codex.height));
    c.gtk_widget_queue_draw(m.codex_canvas);
}
