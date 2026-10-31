//! Main-thread GTK presentation for the compositor's fixed application switcher.
const std = @import("std");
const c = @import("desktop-gtk.zig");
const cast = c.__zig.cast;
const a = std.heap.page_allocator;
const capture = @import("desktop-capture.zig");
pub const Item = struct {
    id: [256:0]u8 = @splat(0),
    app_id: [256:0]u8 = @splat(0),
    title: [256:0]u8 = @splat(0),
    selected: bool = false,
    count: usize = 1,
};
pub const Snapshot = struct { items: [64]Item = @splat(.{}), len: usize = 0, visible: bool = false, window_selection: bool = false, output_x: c_int = 0, output_y: c_int = 0 };
var styled = false;
var window: ?*c.GtkWidget = null;
var row: ?*c.GtkWidget = null;
var boxes: [64]*c.GtkWidget = undefined;
var wrappers: [64]*c.GtkWidget = undefined;
var indicators: [64]*c.GtkWidget = undefined;
var displayed: Snapshot = .{};
var latest: Snapshot = .{};
var previews: Snapshot = .{};
var preview_window: ?*c.GtkWidget = null;
var preview_row: ?*c.GtkWidget = null;
var preview_boxes: [64]*c.GtkWidget = undefined;
var preview_images: [64]*c.GtkWidget = undefined;
var client: ?*capture.Client = null;
var delay: c.guint = 0;
var ticker: c.guint = 0;
var showing_previews = false;
var icon_size: c_int = 96;
var monitor: ?*c.GdkMonitor = null;
var screen_width: c_int = 0;

fn sameApp(left: *const Item, right: *const Item) bool {
    if (left.app_id[0] != 0) return std.mem.eql(u8, std.mem.sliceTo(&left.app_id, 0), std.mem.sliceTo(&right.app_id, 0));
    return left.id[0] != 0 and std.mem.eql(u8, &left.id, &right.id);
}
fn selected(snapshot: *const Snapshot) ?*const Item {
    for (snapshot.items[0..snapshot.len]) |*item| if (item.selected) return item;
    return null;
}
fn applications(snapshot: *const Snapshot) Snapshot {
    var result: Snapshot = .{ .visible = snapshot.visible, .window_selection = snapshot.window_selection };
    for (snapshot.items[0..snapshot.len]) |item| {
        var found = false;
        for (result.items[0..result.len]) |*app| if (sameApp(app, &item)) {
            app.count += 1;
            app.selected = app.selected or item.selected;
            found = true;
            break;
        };
        if (!found) {
            result.items[result.len] = item;
            result.items[result.len].count = 1;
            result.len += 1;
        }
    }
    return result;
}
// GLib's idle queue is thread safe; no GTK objects cross the compositor thread.
pub fn publish(snapshot: Snapshot) void {
    const copy = a.create(Snapshot) catch return;
    copy.* = snapshot;
    _ = c.g_idle_add(&update, copy);
}
pub fn deinit() void {
    stopPreviews();
    if (client) |connection| connection.destroy();
    client = null;
    if (preview_window) |w| c.gtk_widget_destroy(w);
    preview_window = null;
    preview_row = null;
    previews = .{};
    if (window) |w| c.gtk_widget_destroy(w);
    window = null;
    row = null;
    displayed = .{};
    latest = .{};
}
fn update(data: c.gpointer) callconv(.c) c.gboolean {
    const snapshot = cast(Snapshot, data);
    defer a.destroy(snapshot);
    if (!snapshot.visible or snapshot.len == 0) {
        stopPreviews();
        latest = .{};
        if (window) |w| c.gtk_widget_hide(w);
        return 0;
    }
    if (c.gdk_display_get_default() == null) return 0;
    monitor = c.gdk_display_get_monitor_at_point(c.gdk_display_get_default(), snapshot.output_x, snapshot.output_y);
    if (window == null) create();
    const w = window.?;
    c.gtk_layer_set_monitor(cast(c.GtkWindow, w), monitor);
    const apps = applications(snapshot);
    // Selection changes must not unmap the layer surface or reload its icons.
    const width = geometry().width;
    var same_items = displayed.len == apps.len and screen_width == width;
    screen_width = width;
    if (same_items) for (displayed.items[0..displayed.len], apps.items[0..apps.len]) |old, new| {
        if (!std.mem.eql(u8, &old.app_id, &new.app_id) or !std.mem.eql(u8, &old.title, &new.title)) {
            same_items = false;
            break;
        }
    };
    if (!same_items) {
        for (wrappers[0..displayed.len]) |wrapper| c.gtk_widget_destroy(wrapper);
        populate(&apps);
    }
    for (boxes[0..apps.len], apps.items[0..apps.len], 0..) |box, item, index| {
        const style = c.gtk_widget_get_style_context(box);
        if (item.selected and !snapshot.window_selection) c.gtk_style_context_add_class(style, "switcher-selected") else c.gtk_style_context_remove_class(style, "switcher-selected");
        if (item.selected and snapshot.window_selection) c.gtk_style_context_add_class(style, "switcher-highlighted") else c.gtk_style_context_remove_class(style, "switcher-highlighted");
        c.gtk_widget_queue_draw(indicators[index]);
    }
    const old_selected = selected(&latest);
    const new_selected = selected(snapshot);
    const changed_app = old_selected == null or new_selected == null or !sameApp(old_selected.?, new_selected.?);
    const leaving_windows = latest.window_selection and !snapshot.window_selection;
    displayed = apps;
    latest = snapshot.*;
    c.gtk_widget_show_all(w);
    if (changed_app or leaving_windows) {
        stopPreviews();
        if (changed_app) delay = c.g_timeout_add(500, &reveal, null);
    }
    if (snapshot.window_selection) showing_previews = true;
    if (showing_previews) showPreviews();
    return 0;
}

test "application grouping counts windows without merging missing app IDs" {
    var snapshot: Snapshot = .{ .len = 4, .visible = true };
    @memcpy(snapshot.items[0].app_id[0..7], "Browser");
    @memcpy(snapshot.items[1].app_id[0..7], "Browser");
    snapshot.items[1].selected = true;
    const grouped = applications(&snapshot);
    try std.testing.expectEqual(@as(usize, 3), grouped.len);
    try std.testing.expectEqual(@as(usize, 2), grouped.items[0].count);
    try std.testing.expect(grouped.items[0].selected);
    const windows = previewItems(&snapshot);
    try std.testing.expectEqual(@as(usize, 2), windows.len);
    try std.testing.expect(!windows.items[0].selected and windows.items[1].selected);
}
fn create() void {
    const w = c.gtk_window_new(c.GTK_WINDOW_TOPLEVEL);
    window = w;
    if (c.gdk_screen_get_rgba_visual(c.gtk_widget_get_screen(w))) |visual| c.gtk_widget_set_visual(w, visual);
    c.gtk_widget_set_name(w, "desktop-switcher");
    c.gtk_window_set_decorated(cast(c.GtkWindow, w), 0);
    c.gtk_window_set_resizable(cast(c.GtkWindow, w), 0);
    c.gtk_layer_init_for_window(cast(c.GtkWindow, w));
    c.gtk_layer_set_namespace(cast(c.GtkWindow, w), "desktop-switcher");
    c.gtk_layer_set_layer(cast(c.GtkWindow, w), c.GTK_LAYER_SHELL_LAYER_OVERLAY);
    c.gtk_layer_set_keyboard_mode(cast(c.GtkWindow, w), c.GTK_LAYER_SHELL_KEYBOARD_MODE_NONE);
    // Center against the full output, as the compositor-owned popup did.
    c.gtk_layer_set_exclusive_zone(cast(c.GtkWindow, w), -1);
    if (!styled) {
        const provider = c.gtk_css_provider_new();
        defer c.g_object_unref(provider);
        _ = c.gtk_css_provider_load_from_data(provider, "window#desktop-switcher, window#desktop-switcher-windows { background: transparent; color: white; border: none; box-shadow: none; }" ++
            ".switcher-panel { background: #2e2e33; border: 1px solid rgba(255,255,255,0.02); border-radius: 28px; padding: 12px; }" ++
            "#desktop-switcher .switcher-panel { padding-bottom: 4px; }" ++
            ".switcher-item { padding: 6px; border-radius: 16px; }" ++
            ".switcher-selected { background: rgba(255,255,255,0.2); }" ++
            ".switcher-highlighted { background: #414149; }" ++
            ".switcher-item label { font-family: Adwaita Sans; font-size: 14.666px; margin: 0; padding: 0; }", -1, null);
        c.gtk_style_context_add_provider_for_screen(c.gtk_widget_get_screen(w), @ptrCast(provider), c.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
        styled = true;
    }
    row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 12);
    c.gtk_style_context_add_class(c.gtk_widget_get_style_context(row.?), "switcher-panel");
    c.gtk_container_add(cast(c.GtkContainer, w), row.?);
}
fn populate(snapshot: *const Snapshot) void {
    const screen = geometry();
    for ([_]c_int{ 96, 64, 48, 32, 22 }) |size| {
        icon_size = size;
        if (@as(c_int, @intCast(snapshot.len)) * (size + 31 + 12) - 12 + 26 <= screen.width) break;
    }
    for (snapshot.items[0..snapshot.len], 0..) |*item, index| {
        const wrapper = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 4);
        wrappers[index] = wrapper;
        const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
        boxes[index] = box;
        c.gtk_widget_set_size_request(box, icon_size + 31, icon_size + 31);
        const style = c.gtk_widget_get_style_context(box);
        c.gtk_style_context_add_class(style, "switcher-item");
        if (item.selected) c.gtk_style_context_add_class(style, "switcher-selected");
        const id = std.mem.sliceTo(&item.app_id, 0);
        const desktop_id = std.fmt.allocPrintSentinel(a, "{s}.desktop", .{id}, 0) catch @panic("switcher desktop id");
        defer a.free(desktop_id);
        const info = c.g_desktop_app_info_new(desktop_id);
        defer if (info) |app| c.g_object_unref(app);
        const image = if (info) |app| c.gtk_image_new_from_gicon(c.g_app_info_get_icon(@ptrCast(app)), c.GTK_ICON_SIZE_DIALOG) else c.gtk_image_new_from_icon_name("application-x-executable", c.GTK_ICON_SIZE_DIALOG);
        c.gtk_image_set_pixel_size(cast(c.GtkImage, image), icon_size);
        const label = c.gtk_label_new(if (info) |app| c.g_app_info_get_display_name(@ptrCast(app)) else &item.title);
        c.gtk_label_set_ellipsize(cast(c.GtkLabel, label), c.PANGO_ELLIPSIZE_END);
        c.gtk_label_set_max_width_chars(cast(c.GtkLabel, label), 1);
        c.gtk_box_pack_start(cast(c.GtkBox, box), image, 0, 0, 0);
        c.gtk_box_pack_start(cast(c.GtkBox, box), label, 0, 0, 0);
        c.gtk_box_pack_start(cast(c.GtkBox, wrapper), box, 0, 0, 0);
        const arrow = c.gtk_drawing_area_new();
        indicators[index] = arrow;
        c.gtk_widget_set_size_request(arrow, 8, 4);
        c.gtk_widget_set_halign(arrow, c.GTK_ALIGN_CENTER);
        _ = c.g_signal_connect_data(arrow, "draw", @ptrCast(&drawArrow), null, null, 0);
        c.gtk_box_pack_start(cast(c.GtkBox, wrapper), arrow, 0, 0, 0);
        c.gtk_box_pack_start(cast(c.GtkBox, row.?), wrapper, 0, 0, 0);
    }
}

fn geometry() c.GdkRectangle {
    var rect: c.GdkRectangle = .{ .x = 0, .y = 0, .width = 1280, .height = 720 };
    if (monitor) |output| c.gdk_monitor_get_geometry(output, &rect);
    return rect;
}
fn drawArrow(widget: *c.GtkWidget, cr: *c.cairo_t, _: c.gpointer) callconv(.c) c.gboolean {
    for (indicators[0..displayed.len], displayed.items[0..displayed.len]) |arrow, item| {
        if (arrow != widget) continue;
        if (item.count < 2 and !(item.selected and latest.window_selection)) return 0;
        const shade: u32 = if (item.selected) 255 else 204;
        const color: u32 = 0xff000000 | (shade << 16) | (shade << 8) | shade;
        var pixels: [8 * 4]u32 = @splat(0);
        for (0..4) |y| {
            const start = y;
            const end = 8 - y;
            for (start..end) |x| {
                pixels[y * 8 + x] = color;
            }
        }
        const surf = c.cairo_image_surface_create_for_data(@ptrCast(&pixels), c.CAIRO_FORMAT_ARGB32, 8, 4, 8 * 4);
        defer c.cairo_surface_destroy(surf);
        c.cairo_set_source_surface(cr, surf, 0, 0);
        c.cairo_paint(cr);
        break;
    }
    return 0;
}
fn stopPreviews() void {
    if (delay != 0) _ = c.g_source_remove(delay);
    if (ticker != 0) _ = c.g_source_remove(ticker);
    delay = 0;
    ticker = 0;
    showing_previews = false;
    if (preview_window) |pw| c.gtk_widget_hide(pw);
    if (client) |connection| connection.visible(false);
}
fn reveal(_: c.gpointer) callconv(.c) c.gboolean {
    delay = 0;
    if (latest.visible) {
        showing_previews = true;
        showPreviews();
    }
    return 0;
}
fn previewItems(snapshot: *const Snapshot) Snapshot {
    var result: Snapshot = .{ .visible = snapshot.visible, .window_selection = snapshot.window_selection };
    const active = selected(snapshot) orelse return result;
    for (snapshot.items[0..snapshot.len]) |*item| if (item == active or sameApp(item, active)) {
        result.items[result.len] = item.*;
        result.len += 1;
    };
    return result;
}
var preview_width: c_int = 0;
var preview_height: c_int = 0;
fn showPreviews() void {
    const items = previewItems(&latest);
    if (items.len == 0 or (items.len == 1 and !latest.window_selection)) {
        stopPreviews();
        return;
    }
    const screen = geometry();
    const count: c_int = @intCast(items.len);
    const thumb_width = @min(256, @max(48, @divTrunc(screen.width - 26 - (count - 1) * 12, count) - 16));
    const app_height = icon_size + 31 + 26;
    const panel_y = @divTrunc(screen.height - app_height, 2) + app_height + 24;
    const thumb_height = @min(256, @max(48, screen.height - panel_y - 26 - 16 - 6 - 19));
    if (preview_window == null) {
        const pw = c.gtk_window_new(c.GTK_WINDOW_TOPLEVEL);
        preview_window = pw;
        if (c.gdk_screen_get_rgba_visual(c.gtk_widget_get_screen(pw))) |visual| c.gtk_widget_set_visual(pw, visual);
        c.gtk_widget_set_name(pw, "desktop-switcher-windows");
        c.gtk_window_set_decorated(cast(c.GtkWindow, pw), 0);
        c.gtk_window_set_resizable(cast(c.GtkWindow, pw), 0);
        c.gtk_layer_init_for_window(cast(c.GtkWindow, pw));
        c.gtk_layer_set_namespace(cast(c.GtkWindow, pw), "desktop-switcher-windows");
        c.gtk_layer_set_layer(cast(c.GtkWindow, pw), c.GTK_LAYER_SHELL_LAYER_OVERLAY);
        c.gtk_layer_set_keyboard_mode(cast(c.GtkWindow, pw), c.GTK_LAYER_SHELL_KEYBOARD_MODE_NONE);
        c.gtk_layer_set_exclusive_zone(cast(c.GtkWindow, pw), -1);
        c.gtk_layer_set_anchor(cast(c.GtkWindow, pw), c.GTK_LAYER_SHELL_EDGE_TOP, 1);
        c.gtk_layer_set_anchor(cast(c.GtkWindow, pw), c.GTK_LAYER_SHELL_EDGE_LEFT, 1);
        preview_row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 12);
        c.gtk_style_context_add_class(c.gtk_widget_get_style_context(preview_row.?), "switcher-panel");
        c.gtk_container_add(cast(c.GtkContainer, pw), preview_row.?);
    }
    var same_items = previews.len == items.len and preview_width == thumb_width and preview_height == thumb_height;
    if (same_items) for (previews.items[0..previews.len], items.items[0..items.len]) |old, new| {
        if (!std.mem.eql(u8, &old.id, &new.id) or !std.mem.eql(u8, &old.title, &new.title)) {
            same_items = false;
            break;
        }
    };
    if (!same_items) {
        for (preview_boxes[0..previews.len]) |box| c.gtk_widget_destroy(box);
        for (items.items[0..items.len], 0..) |*item, index| {
            const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 6);
            preview_boxes[index] = box;
            c.gtk_style_context_add_class(c.gtk_widget_get_style_context(box), "switcher-item");
            const image = c.gtk_drawing_area_new();
            preview_images[index] = image;
            c.gtk_widget_set_size_request(image, thumb_width + 4, thumb_height + 4);
            _ = c.g_signal_connect_data(image, "draw", @ptrCast(&drawPreview), null, null, 0);
            const label = c.gtk_label_new(&item.title);
            c.gtk_label_set_ellipsize(cast(c.GtkLabel, label), c.PANGO_ELLIPSIZE_END);
            c.gtk_label_set_max_width_chars(cast(c.GtkLabel, label), 1);
            c.gtk_box_pack_start(cast(c.GtkBox, box), image, 0, 0, 0);
            c.gtk_box_pack_start(cast(c.GtkBox, box), label, 0, 0, 0);
            c.gtk_box_pack_start(cast(c.GtkBox, preview_row.?), box, 0, 0, 0);
        }
    }
    previews = items;
    preview_width = thumb_width;
    preview_height = thumb_height;
    for (preview_boxes[0..items.len], items.items[0..items.len]) |box, item| {
        const style = c.gtk_widget_get_style_context(box);
        if (latest.window_selection and item.selected) c.gtk_style_context_add_class(style, "switcher-selected") else c.gtk_style_context_remove_class(style, "switcher-selected");
    }
    var active_index: c_int = 0;
    for (displayed.items[0..displayed.len], 0..) |item, i| if (item.selected) {
        active_index = @intCast(i);
        break;
    };
    const panel_width = count * (thumb_width + 16) + (count - 1) * 12 + 26;
    const app_width = @as(c_int, @intCast(displayed.len)) * (icon_size + 43) - 12 + 26;
    const x = @divTrunc(screen.width - app_width, 2) + 13 + active_index * (icon_size + 43) + @divTrunc(icon_size + 31, 2) - @divTrunc(panel_width, 2);
    c.gtk_layer_set_monitor(cast(c.GtkWindow, preview_window.?), monitor);
    c.gtk_layer_set_margin(cast(c.GtkWindow, preview_window.?), c.GTK_LAYER_SHELL_EDGE_LEFT, @max(0, @min(x, screen.width - panel_width)));
    c.gtk_layer_set_margin(cast(c.GtkWindow, preview_window.?), c.GTK_LAYER_SHELL_EDGE_TOP, panel_y);
    c.gtk_widget_show_all(preview_window.?);
    if (client == null) client = capture.Client.create(null, &captureChanged) catch null;
    if (client) |connection| {
        connection.refresh();
        connection.visible(true);
        connection.tick();
        if (ticker == 0) ticker = c.g_timeout_add(100, &captureTick, null);
    }
}
fn captureChanged(_: ?*anyopaque) void {
    for (preview_images[0..previews.len]) |image| c.gtk_widget_queue_draw(image);
}
fn captureTick(_: c.gpointer) callconv(.c) c.gboolean {
    if (client) |connection| connection.tick();
    return 1;
}
fn drawPreview(widget: *c.GtkWidget, cr: *c.cairo_t, _: c.gpointer) callconv(.c) c.gboolean {
    const connection = client orelse return 0;
    for (preview_images[0..previews.len], previews.items[0..previews.len]) |image, item| {
        if (image != widget) continue;
        for (connection.windows.items) |view| {
            if (view.id == null or !std.mem.eql(u8, std.mem.span(view.id), std.mem.sliceTo(&item.id, 0))) continue;
            const img = view.image orelse return 0;
            const width_i = img.width;
            const height_i = img.height;
            if (width_i == 0 or height_i == 0) return 0;
            const width: f64 = @floatFromInt(width_i);
            const height: f64 = @floatFromInt(height_i);
            const scale = @min(@as(f64, @floatFromInt(preview_width)) / width, @as(f64, @floatFromInt(preview_height)) / height);
            const ox = (@as(f64, @floatFromInt(c.gtk_widget_get_allocated_width(widget))) - width * scale) / 2;
            const oy = (@as(f64, @floatFromInt(c.gtk_widget_get_allocated_height(widget))) - height * scale) / 2;

            c.cairo_save(cr);
            defer c.cairo_restore(cr);
            c.cairo_translate(cr, ox, oy);
            c.cairo_scale(cr, scale, scale);

            const surface = c.cairo_image_surface_create_for_data(
                @ptrCast(@alignCast(img.pixels.ptr)),
                c.CAIRO_FORMAT_ARGB32,
                @intCast(width_i),
                @intCast(height_i),
                @intCast(img.stride * 4),
            ) orelse return 0;
            defer c.cairo_surface_destroy(surface);

            c.cairo_set_source_surface(cr, surface, 0, 0);
            c.cairo_paint(cr);
            return 0;
        }
    }
    return 0;
}

test "switcher preserves its surface and icons while selection changes and draws transparent corners" {
    if (c.gtk_init_check(null, null) == 0) return error.PrivateDisplayRequired;
    defer deinit();
    var snapshot: Snapshot = .{ .len = 3, .visible = true };
    @memcpy(snapshot.items[0].title[0..5], "First");
    @memcpy(snapshot.items[1].title[0..6], "Second");
    @memcpy(snapshot.items[1].app_id[0..7], "Browser");
    @memcpy(snapshot.items[2].app_id[0..7], "Browser");
    @memcpy(snapshot.items[2].title[0..5], "Third");
    snapshot.items[0].selected = true;
    publish(snapshot);
    // Allow GTK to configure and allocate the real layer surface.
    const u = @import("desktop-util.zig");
    for (0..30) |_| {
        while (c.g_main_context_iteration(null, 0) != 0) {}
        u.sleep(10 * std.time.ns_per_ms);
    }
    const original_window = window.?;
    const original_surface = c.gtk_widget_get_window(original_window);
    const original_box = boxes[0];
    const children = c.gtk_container_get_children(cast(c.GtkContainer, original_box));
    defer c.g_list_free(children);
    const original_icon = children.*.data;
    snapshot.items[0].selected = false;
    snapshot.items[1].selected = true;
    publish(snapshot);
    while (c.g_main_context_iteration(null, 0) != 0) {}
    try std.testing.expectEqual(original_window, window.?);
    try std.testing.expectEqual(original_surface, c.gtk_widget_get_window(window.?));
    try std.testing.expectEqual(original_box, boxes[0]);
    const updated_children = c.gtk_container_get_children(cast(c.GtkContainer, boxes[0]));
    defer c.g_list_free(updated_children);
    try std.testing.expectEqual(original_icon, updated_children.*.data);
    try std.testing.expect(c.gtk_style_context_has_class(c.gtk_widget_get_style_context(boxes[0]), "switcher-selected") == 0);
    try std.testing.expect(c.gtk_style_context_has_class(c.gtk_widget_get_style_context(boxes[1]), "switcher-selected") != 0);

    const width = c.gtk_widget_get_allocated_width(window.?);
    const height = c.gtk_widget_get_allocated_height(window.?);
    try std.testing.expectEqual(@as(c_int, 292), width);
    try std.testing.expectEqual(@as(c_int, 153), height);
    for (0..2) |index| {
        const arrow_surface = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, 8, 4);
        defer c.cairo_surface_destroy(arrow_surface);
        const arrow_cr = c.cairo_create(arrow_surface);
        defer c.cairo_destroy(arrow_cr);
        _ = drawArrow(indicators[index], arrow_cr.?, null);
        c.cairo_surface_flush(arrow_surface);
        const arrow_pixels = c.cairo_image_surface_get_data(arrow_surface);
        const arrow_center: *align(1) const u32 = @ptrCast(arrow_pixels + 8 * 4 + 4 * 4);
        try std.testing.expectEqual(@as(u32, if (index == 0) 0 else 255), arrow_center.* >> 24);
    }
    const surface = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, width, height);
    defer c.cairo_surface_destroy(surface);
    const cr = c.cairo_create(surface);
    defer c.cairo_destroy(cr);
    const Draw = struct {
        extern fn gtk_widget_draw(widget: *c.GtkWidget, context: ?*c.cairo_t) void;
    };
    Draw.gtk_widget_draw(window.?, cr);
    c.cairo_surface_flush(surface);
    const stride: usize = @intCast(c.cairo_image_surface_get_stride(surface));
    const pixels = c.cairo_image_surface_get_data(surface);
    // ARGB32 is native endian: read u32 values so alpha checks are portable.
    for ([_]usize{ 0, (@as(usize, @intCast(width)) - 1) * 4, (@as(usize, @intCast(height)) - 1) * stride, (@as(usize, @intCast(height)) - 1) * stride + (@as(usize, @intCast(width)) - 1) * 4 }) |offset| {
        const pixel: *align(1) const u32 = @ptrCast(pixels + offset);
        try std.testing.expectEqual(@as(u32, 0), pixel.* >> 24);
    }
    // Allow Cairo's small antialiasing fringe near the curved edges.
    const panel_curve: *align(1) const u32 = @ptrCast(pixels + 20 * 4);
    try std.testing.expect(panel_curve.* >> 24 <= 4);
    const center: *align(1) const u32 = @ptrCast(pixels + @as(usize, @intCast(@divTrunc(height, 2))) * stride + @as(usize, @intCast(@divTrunc(width, 2))) * 4);
    try std.testing.expectEqual(@as(u32, 255), center.* >> 24);

    const item_surface = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, c.gtk_widget_get_allocated_width(boxes[1]), c.gtk_widget_get_allocated_height(boxes[1]));
    defer c.cairo_surface_destroy(item_surface);
    const item_cr = c.cairo_create(item_surface);
    defer c.cairo_destroy(item_cr);
    Draw.gtk_widget_draw(boxes[1], item_cr);
    c.cairo_surface_flush(item_surface);
    const item_stride: usize = @intCast(c.cairo_image_surface_get_stride(item_surface));
    const item_pixels = c.cairo_image_surface_get_data(item_surface);
    const item_corner: *align(1) const u32 = @ptrCast(item_pixels + 5 * item_stride + 2 * 4);
    try std.testing.expect(item_corner.* >> 24 <= 4);
    const item_top: *align(1) const u32 = @ptrCast(item_pixels + 16 * 4);
    try std.testing.expect(item_top.* >> 24 > 0);

    publish(.{});
    while (c.g_main_context_iteration(null, 0) != 0) {}
    try std.testing.expect(c.gtk_widget_get_visible(window.?) == 0);
    publish(snapshot);
    while (c.g_main_context_iteration(null, 0) != 0) {}
    try std.testing.expectEqual(original_window, window.?);
    try std.testing.expectEqual(original_box, boxes[0]);
}
