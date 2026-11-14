//! Native, input-transparent Wayland presentation for the application switcher.
const std = @import("std");
const c = @import("desktop-gtk.zig");
const native = @import("desktop-surface.zig");
const capture = @import("desktop-capture.zig");
const raster = @import("desktop-raster.zig");
const fonts = @import("desktop-text.zig");
const cast = c.__zig.cast;
const a = std.heap.page_allocator;
pub const Item = struct {
    id: [256:0]u8 = @splat(0),
    app_id: [256:0]u8 = @splat(0),
    title: [256:0]u8 = @splat(0),
    selected: bool = false,
    count: usize = 1,
};
pub const Snapshot = struct { items: [64]Item = @splat(.{}), len: usize = 0, visible: bool = false, window_selection: bool = false, output_x: c_int = 0, output_y: c_int = 0 };
var connection: ?*native.Client = null;
var monitor: ?*native.Output = null;
var window: ?*native.Surface = null;
var preview_window: ?*native.Surface = null;
var displayed: Snapshot = .{};
var latest: Snapshot = .{};
var previews: Snapshot = .{};
var client: ?*capture.Client = null;
var delay: c.guint = 0;
var ticker: c.guint = 0;
var showing_previews = false;
var icon_size: i32 = 96;
var asset_scale: u32 = 0;
var icons: [64]?*c.GdkPixbuf = @splat(null);
var labels: [64]?[:0]u8 = @splat(null);
var label_masks: [64]?fonts.Mask = @splat(null);
var preview_masks: [64]?fonts.Mask = @splat(null);
var preview_mask_items: Snapshot = .{};
var preview_mask_width: i32 = 0;
var preview_mask_scale: u32 = 0;
var renderer: fonts.Renderer = .{};
var preview_width: i32 = 0;
var preview_height: i32 = 0;

// GLib's idle queue is thread safe; presentation stays on the main thread.
pub fn publish(snapshot: Snapshot) void {
    const copy = a.create(Snapshot) catch return;
    copy.* = snapshot;
    _ = c.g_idle_add(&update, copy);
}
pub fn deinit() void {
    stopPreviews();
    if (client) |value| value.destroy();
    client = null;
    if (connection) |value| value.destroy();
    connection = null;
    window = null;
    preview_window = null;
    monitor = null;
    clearAssets();
    renderer.deinit();
    displayed = .{};
    latest = .{};
    previews = .{};
}
fn clearAssets() void {
    for (&icons, &labels, &label_masks) |*icon, *label, *mask| {
        if (icon.*) |value| c.g_object_unref(value);
        if (label.*) |value| a.free(value);
        if (mask.*) |value| value.deinit(a);
        icon.* = null;
        label.* = null;
        mask.* = null;
    }
    asset_scale = 0;
}
fn outputAdded(_: ?*anyopaque, _: *native.Output) void {}
fn outputRemoved(_: ?*anyopaque, output: *native.Output) void {
    if (monitor != output) return;
    stopPreviews();
    if (window) |value| value.destroy();
    if (preview_window) |value| value.destroy();
    window = null;
    preview_window = null;
    monitor = null;
}
fn outputChanged(_: ?*anyopaque, output: *native.Output) void {
    if (monitor == output and latest.visible) present(&latest) catch |err| std.log.warn("switcher layout: {s}", .{@errorName(err)});
}
fn update(data: c.gpointer) callconv(.c) c.gboolean {
    const snapshot = cast(Snapshot, data);
    defer a.destroy(snapshot);
    present(snapshot) catch |err| std.log.warn("switcher: {s}", .{@errorName(err)});
    return 0;
}
fn present(snapshot: *const Snapshot) !void {
    if (!snapshot.visible or snapshot.len == 0) {
        stopPreviews();
        latest = .{};
        if (window) |value| value.hide();
        return;
    }
    if (connection == null) {
        const value = try native.Client.create(.{ .added = &outputAdded, .removed = &outputRemoved, .changed = &outputChanged }, null);
        errdefer value.destroy();
        try value.start();
        connection = value;
    }
    var output: ?*native.Output = null;
    for (connection.?.outputs.items) |candidate| {
        if (output == null) output = candidate;
        if (snapshot.output_x >= candidate.x and snapshot.output_y >= candidate.y and @as(i64, snapshot.output_x) < @as(i64, candidate.x) + candidate.width() and @as(i64, snapshot.output_y) < @as(i64, candidate.y) + candidate.height()) {
            output = candidate;
            break;
        }
    }
    const target = output orelse return error.NoOutputs;
    const moved = monitor != target;
    if (moved) {
        stopPreviews();
        if (window) |value| value.destroy();
        if (preview_window) |value| value.destroy();
        window = null;
        preview_window = null;
        monitor = target;
    }
    const apps = applications(snapshot);
    var next_size: i32 = 22;
    for ([_]i32{ 96, 64, 48, 32, 22 }) |size| {
        next_size = size;
        if (@as(i32, @intCast(apps.len)) * (size + 43) + 14 <= target.width()) break;
    }
    var same_items = displayed.len == apps.len and icon_size == next_size and asset_scale == target.scale;
    if (same_items) for (displayed.items[0..displayed.len], apps.items[0..apps.len]) |old, new| {
        if (!std.mem.eql(u8, &old.app_id, &new.app_id) or !std.mem.eql(u8, &old.title, &new.title)) {
            same_items = false;
            break;
        }
    };
    icon_size = next_size;
    if (!same_items) loadAssets(&apps, target.scale);
    const old_selected = selected(&latest);
    const new_selected = selected(snapshot);
    const changed_app = moved or old_selected == null or new_selected == null or !sameApp(old_selected.?, new_selected.?);
    const leaving_windows = latest.window_selection and !snapshot.window_selection;
    displayed = apps;
    latest = snapshot.*;
    const width: u32 = @intCast(@as(i32, @intCast(apps.len)) * (icon_size + 43) + 14);
    const height: u32 = @intCast(icon_size + 57);
    if (window == null) window = try native.Surface.createPixels(target, .{ .namespace = "desktop-switcher", .layer = 3, .anchors = 0, .width = width, .height = height }, &draw, null);
    window.?.setLayout(width, height, 0, 0);
    try window.?.show();
    if (changed_app or leaving_windows) {
        stopPreviews();
        if (changed_app) delay = c.g_timeout_add(500, &reveal, null);
    }
    if (snapshot.window_selection) showing_previews = true;
    if (showing_previews) try showPreviews();
}
fn loadAssets(snapshot: *const Snapshot, scale: u32) void {
    clearAssets();
    const theme = c.gtk_icon_theme_new();
    defer c.g_object_unref(theme);
    if (c.g_getenv("DESKTOP_APPS_ICON_PATH")) |path| c.gtk_icon_theme_append_search_path(theme, path);
    c.gtk_icon_theme_set_custom_theme(theme, "Adwaita");
    for (snapshot.items[0..snapshot.len], 0..) |*item, i| {
        const id = std.fmt.allocPrintSentinel(a, "{s}.desktop", .{std.mem.sliceTo(&item.app_id, 0)}, 0) catch @panic("switcher desktop id");
        defer a.free(id);
        const info = c.g_desktop_app_info_new(id);
        defer if (info) |value| c.g_object_unref(value);
        const name: [*:0]const u8 = if (info) |value| c.g_app_info_get_display_name(@ptrCast(value)) else &item.title;
        labels[i] = a.dupeSentinel(u8, std.mem.span(name), 0) catch @panic("switcher label");
        label_masks[i] = makeLabel(labels[i].?, icon_size + 19, scale) catch null;
        const gicon = if (info) |value| c.g_app_info_get_icon(@ptrCast(value)) else null;
        const size = icon_size * @as(i32, @intCast(scale));
        const icon_info = if (gicon) |value| c.gtk_icon_theme_lookup_by_gicon(theme, value, size, 0) else null;
        defer if (icon_info) |value| c.g_object_unref(value);
        icons[i] = if (icon_info) |value| c.gtk_icon_info_load_icon(value, null) else c.gtk_icon_theme_load_icon(theme, "application-x-executable", size, 0, null);
    }
    asset_scale = scale;
}
fn makeLabel(value: [:0]const u8, width: i32, scale: u32) !fonts.Mask {
    return renderer.renderLayout(a, value, .{
        .size = 11.0 * 96.0 / 72.0 * @as(f64, @floatFromInt(scale)),
        .width = @as(u32, @intCast(@max(1, width))) * scale,
        .alignment = .center,
        .ellipsize = true,
        .origin = .top,
    });
}
fn clearPreviewLabels() void {
    for (&preview_masks) |*mask| {
        if (mask.*) |value| value.deinit(a);
        mask.* = null;
    }
    preview_mask_items = .{};
    preview_mask_width = 0;
    preview_mask_scale = 0;
}
fn preparePreviewLabels(items: *const Snapshot, scale: u32) void {
    var same = preview_mask_items.len == items.len and preview_mask_width == preview_width + 4 and preview_mask_scale == scale;
    if (same) for (items.items[0..items.len], preview_mask_items.items[0..items.len]) |current, cached| {
        if (!std.mem.eql(u8, &current.title, &cached.title)) {
            same = false;
            break;
        }
    };
    if (same) return;
    clearPreviewLabels();
    for (items.items[0..items.len], 0..) |*item, i| preview_masks[i] = makeLabel(std.mem.sliceTo(&item.title, 0), preview_width + 4, scale) catch null;
    preview_mask_items = items.*;
    preview_mask_width = preview_width + 4;
    preview_mask_scale = scale;
}
fn panel(canvas: raster.Canvas) void {
    const width = @as(f64, @floatFromInt(canvas.target.width)) / canvas.scale;
    const height = @as(f64, @floatFromInt(canvas.target.height)) / canvas.scale;
    const rect: raster.Rect = .{ .x = 0.5, .y = 0.5, .width = width - 1, .height = height - 1 };
    canvas.draw(&.{.{ .rounded_rect = .{ .rect = rect, .radius = 28 } }}, .{ .red = 46.0 / 255.0, .green = 46.0 / 255.0, .blue = 51.0 / 255.0 });
    canvas.draw(&.{.{ .rounded_stroke = .{ .rect = rect, .radius = 28 } }}, .{ .red = 1, .green = 1, .blue = 1, .alpha = 0.02 });
}
fn highlight(canvas: raster.Canvas, x: f64, width: f64, height: f64, active: bool, windows: bool) void {
    if (!active) return;
    const color: raster.Color = if (windows) .{ .red = 65.0 / 255.0, .green = 65.0 / 255.0, .blue = 73.0 / 255.0 } else .{ .red = 1, .green = 1, .blue = 1, .alpha = 0.2 };
    canvas.draw(&.{.{ .rounded_rect = .{ .rect = .{ .x = x, .y = 13, .width = width, .height = height }, .radius = 16 } }}, color);
}
fn paintLabel(canvas: raster.Canvas, value: ?fonts.Mask, x: f64, y: f64) void {
    const mask = value orelse return;
    raster.mask(canvas.target, .{ .x = @as(i32, @intFromFloat(x * canvas.scale)) + mask.left, .y = @as(i32, @intFromFloat(y * canvas.scale)) + mask.top, .width = mask.width, .height = mask.height }, mask.pixels, .{ .red = 1, .green = 1, .blue = 1 });
}
fn arrow(canvas: raster.Canvas, x: f64, y: f64, item: Item) void {
    if (item.count < 2 and !(item.selected and latest.window_selection)) return;
    const shade: f64 = if (item.selected) 1 else 0.8;
    canvas.draw(&.{.{ .polygon = &.{ .{ .x = x, .y = y }, .{ .x = x + 8, .y = y }, .{ .x = x + 4, .y = y + 4 } } }}, .{ .red = shade, .green = shade, .blue = shade });
}
const pixbufImage = c.__zig.pixbufImage;
fn draw(_: ?*anyopaque, buffer: native.Pixels) void {
    const scale = if (window) |value| value.output.scale else 1;
    const canvas: raster.Canvas = .{ .target = buffer, .scale = @floatFromInt(scale) };
    panel(canvas);
    for (displayed.items[0..displayed.len], 0..) |item, i| {
        const x: f64 = @floatFromInt(13 + i * @as(usize, @intCast(icon_size + 43)));
        const size: f64 = @floatFromInt(icon_size);
        const item_width = size + 31;
        highlight(canvas, x, item_width, item_width, item.selected, latest.window_selection);
        if (icons[i]) |icon| raster.blit(buffer, pixbufImage(icon), .{ .x = (x + (item_width - size) / 2) * canvas.scale, .y = 19 * canvas.scale, .width = size * canvas.scale, .height = size * canvas.scale }, null) catch |err| std.log.warn("switcher icon: {s}", .{@errorName(err)});
        paintLabel(canvas, label_masks[i], x + 6, 19 + size);
        arrow(canvas, x + (item_width - 8) / 2, 17 + item_width, item);
    }
}
fn stopPreviews() void {
    clearPreviewLabels();
    if (delay != 0) _ = c.g_source_remove(delay);
    if (ticker != 0) _ = c.g_source_remove(ticker);
    delay = 0;
    ticker = 0;
    showing_previews = false;
    if (preview_window) |value| value.hide();
    if (client) |value| value.visible(false);
}
fn reveal(_: c.gpointer) callconv(.c) c.gboolean {
    delay = 0;
    if (latest.visible) {
        showing_previews = true;
        showPreviews() catch |err| std.log.warn("switcher previews: {s}", .{@errorName(err)});
    }
    return 0;
}
fn showPreviews() !void {
    const items = previewItems(&latest);
    if (items.len == 0 or (items.len == 1 and !latest.window_selection)) {
        stopPreviews();
        return;
    }
    const output = monitor orelse return;
    const count: i32 = @intCast(items.len);
    const screen_width = output.width();
    const screen_height = output.height();
    preview_width = @min(256, @max(48, @divTrunc(screen_width - 26 - (count - 1) * 12, count) - 16));
    const app_height = icon_size + 57;
    const panel_y = @divTrunc(screen_height - app_height, 2) + app_height + 24;
    preview_height = @min(256, @max(48, screen_height - panel_y - 26 - 16 - 6 - 19));
    preparePreviewLabels(&items, output.scale);
    previews = items;
    var active_index: i32 = 0;
    for (displayed.items[0..displayed.len], 0..) |item, i| if (item.selected) {
        active_index = @intCast(i);
        break;
    };
    const panel_width = count * (preview_width + 16) + (count - 1) * 12 + 26;
    const panel_height = preview_height + 26 + 16 + 6 + 19;
    const app_width = @as(i32, @intCast(displayed.len)) * (icon_size + 43) + 14;
    const x = @divTrunc(screen_width - app_width, 2) + 13 + active_index * (icon_size + 43) + @divTrunc(icon_size + 31, 2) - @divTrunc(panel_width, 2);
    if (preview_window == null) preview_window = try native.Surface.createPixels(output, .{ .namespace = "desktop-switcher-windows", .layer = 3, .anchors = native.top | native.left, .width = @intCast(panel_width), .height = @intCast(panel_height) }, &drawPreviews, null);
    preview_window.?.setLayout(@intCast(panel_width), @intCast(panel_height), @max(0, @min(panel_y, screen_height - panel_height)), @max(0, @min(x, screen_width - panel_width)));
    try preview_window.?.show();
    if (client == null) client = capture.Client.create(null, &captureChanged) catch null;
    if (client) |value| {
        value.refresh();
        value.visible(true);
        value.tick();
        if (ticker == 0) ticker = c.g_timeout_add(100, &captureTick, null);
    }
}
fn captureChanged(_: ?*anyopaque) void {
    if (preview_window) |value| value.redraw();
}
fn captureTick(_: c.gpointer) callconv(.c) c.gboolean {
    if (client) |value| value.tick();
    return 1;
}
fn drawPreviews(_: ?*anyopaque, buffer: native.Pixels) void {
    const scale = if (preview_window) |value| value.output.scale else 1;
    const canvas: raster.Canvas = .{ .target = buffer, .scale = @floatFromInt(scale) };
    panel(canvas);
    for (previews.items[0..previews.len], 0..) |item, i| {
        const x: f64 = @floatFromInt(13 + i * @as(usize, @intCast(preview_width + 28)));
        highlight(canvas, x, @floatFromInt(preview_width + 16), @floatFromInt(preview_height + 41), latest.window_selection and item.selected, false);
        paintLabel(canvas, preview_masks[i], x + 6, @floatFromInt(23 + preview_height));
        const value = client orelse continue;
        for (value.windows.items) |view| {
            if (view.id == null or !std.mem.eql(u8, std.mem.span(view.id), std.mem.sliceTo(&item.id, 0))) continue;
            const image = view.image orelse break;
            const iw = image.width;
            const ih = image.height;
            const source = image.view();
            const ratio = @min(@as(f64, @floatFromInt(preview_width)) / @as(f64, @floatFromInt(iw)), @as(f64, @floatFromInt(preview_height)) / @as(f64, @floatFromInt(ih)));
            const w = @as(f64, @floatFromInt(iw)) * ratio;
            const h = @as(f64, @floatFromInt(ih)) * ratio;
            const pw: f64 = @floatFromInt(preview_width + 4);
            const ph: f64 = @floatFromInt(preview_height + 4);
            raster.blit(buffer, source, .{ .x = (x + 6 + (pw - w) / 2) * canvas.scale, .y = (19 + (ph - h) / 2) * canvas.scale, .width = w * canvas.scale, .height = h * canvas.scale }, .{ .x = @intFromFloat((x + 6) * canvas.scale), .y = @intFromFloat(19 * canvas.scale), .width = @intFromFloat(pw * canvas.scale), .height = @intFromFloat(ph * canvas.scale) }) catch |err| std.log.warn("switcher preview: {s}", .{@errorName(err)});
            break;
        }
    }
}
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
fn previewItems(snapshot: *const Snapshot) Snapshot {
    var result: Snapshot = .{ .visible = snapshot.visible, .window_selection = snapshot.window_selection };
    const active = selected(snapshot) orelse return result;
    for (snapshot.items[0..snapshot.len]) |*item| if (item == active or sameApp(item, active)) {
        result.items[result.len] = item.*;
        result.len += 1;
    };
    return result;
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

test "native switcher preserves its role and icons across selection changes" {
    // The shared capture client still resolves window icons through GDK.
    try std.testing.expect(c.gtk_init_check(null, null) != 0);
    const probe = @import("tests/desktop-surface-capture.zig");
    defer deinit();
    var snapshot: Snapshot = .{ .len = 3, .visible = true };
    @memcpy(snapshot.items[0].title[0..5], "First");
    @memcpy(snapshot.items[1].title[0..6], "Second");
    @memcpy(snapshot.items[1].app_id[0..7], "Browser");
    @memcpy(snapshot.items[2].app_id[0..7], "Browser");
    snapshot.items[0].selected = true;
    try present(&snapshot);
    probe.pump();
    const original_window = window.?;
    const original_role = original_window.role;
    const original_proxy = original_window.proxy;
    const original_icon = icons[0];
    const original_label = labels[0].?.ptr;
    const original_mask = label_masks[0].?.pixels.ptr;
    try std.testing.expect(original_icon != null);
    try std.testing.expectEqual(@as(usize, 0), connection.?.seats.items.len);
    try std.testing.expectEqual(@as(u32, 292), original_window.width);
    try std.testing.expectEqual(@as(u32, 153), original_window.height);
    snapshot.items[0].selected = false;
    snapshot.items[1].selected = true;
    try present(&snapshot);
    probe.pump();
    try std.testing.expectEqual(original_window, window.?);
    try std.testing.expectEqual(original_role, window.?.role);
    try std.testing.expectEqual(original_proxy, window.?.proxy);
    try std.testing.expectEqual(original_icon, icons[0]);
    try std.testing.expectEqual(original_label, labels[0].?.ptr);
    try std.testing.expectEqual(original_mask, label_masks[0].?.pixels.ptr);
    try std.testing.expect(!displayed.items[0].selected and displayed.items[1].selected);
    // Confirm the native layer is visible on the composed desktop.
    const frame = try probe.capture();
    defer frame.deinit();
    const x = (frame.width - window.?.width) / 2;
    const y = (frame.height - window.?.height) / 2;
    try std.testing.expectEqual(@as(u32, 0x2e2e33), frame.pixel(x + 145, y + 10));

    snapshot.window_selection = true;
    try present(&snapshot);
    probe.pump();
    try std.testing.expect(showing_previews and preview_window.?.configured);
    try std.testing.expectEqual(@as(usize, 2), previews.len);
    const preview_role = preview_window.?.role;
    snapshot.items[1].selected = false;
    snapshot.items[2].selected = true;
    try present(&snapshot);
    probe.pump();
    try std.testing.expectEqual(preview_role, preview_window.?.role);
    try std.testing.expect(!previews.items[0].selected and previews.items[1].selected);
    try std.testing.expectEqual(original_proxy, window.?.proxy);
    const output_name = std.mem.sliceTo(&monitor.?.label, 0);
    const outputs = @import("desktop-output.zig");
    defer outputs.run(&.{ "--output", output_name, "--scale", "1" }) catch {};
    try outputs.run(&.{ "--output", output_name, "--scale", "2" });
    probe.pump();
    try std.testing.expectEqual(@as(u32, 2), asset_scale);
    try std.testing.expectEqual(original_proxy, window.?.proxy);
    try std.testing.expect(window.?.buffers[0].?.width == window.?.width * 2 or (window.?.buffers[1] != null and window.?.buffers[1].?.width == window.?.width * 2));
    try outputs.run(&.{ "--output", output_name, "--scale", "1" });
    probe.pump();
    try std.testing.expectEqual(@as(u32, 1), asset_scale);
    const restored_icon = icons[0];
    try present(&.{});
    try std.testing.expect(window.?.role == null and preview_window.?.role == null);
    try std.testing.expectEqual(@as(c.guint, 0), ticker);
    try present(&snapshot);
    probe.pump();
    try std.testing.expectEqual(original_window, window.?);
    try std.testing.expectEqual(restored_icon, icons[0]);
}

test "Zig switcher panels retain transparent corners and group indicators" {
    var pixels: [292 * 153]u32 = @splat(0);
    const canvas: raster.Canvas = .{ .target = .{ .pixels = &pixels, .width = 292, .height = 153 }, .scale = 1 };
    panel(canvas);
    for ([_]usize{ 0, 291, 152 * 292, 153 * 292 - 1 }) |offset| try std.testing.expectEqual(@as(u32, 0), pixels[offset] >> 24);
    try std.testing.expectEqual(@as(u32, 0xff2e2e33), pixels[76 * 292 + 146]);
    @memset(&pixels, 0);
    arrow(canvas, 0, 0, .{ .count = 1 });
    arrow(canvas, 10, 0, .{ .count = 2 });
    try std.testing.expectEqual(@as(u32, 0), pixels[292 + 4] >> 24);
    try std.testing.expectEqual(@as(u32, 255), pixels[292 + 14] >> 24);
}

test "window preview rendering fits the captured image without stretching" {
    const saved_client = client;
    const saved_previews = previews;
    const saved_width = preview_width;
    const saved_height = preview_height;
    defer {
        client = saved_client;
        previews = saved_previews;
        preview_width = saved_width;
        preview_height = saved_height;
    }
    const green: [64 * 32]u32 = @splat(0xff00ff00);
    const image = try capture.Image.thumbnail(std.testing.allocator, .{ .pixels = std.mem.sliceAsBytes(&green), .width = 64, .height = 32, .stride = 64 * 4, .format = .argb });
    defer image.deinit(std.testing.allocator);
    var source: capture.Window = .{ .client = undefined, .handle = undefined, .id = @constCast("test-window"), .image = image };
    var sources = [_]*capture.Window{&source};
    var fake: capture.Client = .{ .display = undefined, .registry = undefined, .context = null, .changed = &captureChanged };
    fake.windows.items = &sources;
    fake.windows.capacity = 1;
    client = &fake;
    previews = .{ .len = 1 };
    @memcpy(previews.items[0].id[0..11], "test-window");
    @memcpy(previews.items[0].title[0..12], "Preview 🌍");
    preview_width = 128;
    preview_height = 128;
    var pixels: [170 * 195]u32 = @splat(0);
    preparePreviewLabels(&previews, 1);
    defer clearPreviewLabels();
    try std.testing.expect(preview_masks[0] != null);
    drawPreviews(null, .{ .pixels = &pixels, .width = 170, .height = 195 });
    try std.testing.expectEqual(@as(u32, 0xff00ff00), pixels[85 * 170 + 85]);
    try std.testing.expectEqual(@as(u32, 0xff2e2e33), pixels[25 * 170 + 85]);
    try std.testing.expectEqual(@as(u32, 0xff2e2e33), pixels[135 * 170 + 85]);
}

test "Zig switcher panels and highlights agree with Cairo at multiple scales" {
    const reference = struct {
        fn rounded(cr: *c.cairo_t, x: f64, y: f64, width: f64, height: f64, requested_radius: f64) void {
            const radius = @min(requested_radius, @min(width, height) / 2);
            c.cairo_new_sub_path(cr);
            c.cairo_arc(cr, x + width - radius, y + radius, radius, -std.math.pi / 2.0, 0);
            c.cairo_arc(cr, x + width - radius, y + height - radius, radius, 0, std.math.pi / 2.0);
            c.cairo_arc(cr, x + radius, y + height - radius, radius, std.math.pi / 2.0, std.math.pi);
            c.cairo_arc(cr, x + radius, y + radius, radius, std.math.pi, 3 * std.math.pi / 2.0);
            c.cairo_close_path(cr);
        }
        fn panel(cr: *c.cairo_t, width: f64, height: f64) void {
            rounded(cr, 0.5, 0.5, width - 1, height - 1, 28);
            c.cairo_set_source_rgb(cr, 46.0 / 255.0, 46.0 / 255.0, 51.0 / 255.0);
            c.cairo_fill(cr);
            rounded(cr, 0.5, 0.5, width - 1, height - 1, 28);
            c.cairo_set_source_rgba(cr, 1, 1, 1, 0.02);
            c.cairo_set_line_width(cr, 1);
            c.cairo_stroke(cr);
        }
        fn highlight(cr: *c.cairo_t, x: f64, width: f64, height: f64, active_tile: bool, windows: bool) void {
            if (!active_tile) return;
            rounded(cr, x, 13, width, height, 16);
            if (windows) c.cairo_set_source_rgb(cr, 65.0 / 255.0, 65.0 / 255.0, 73.0 / 255.0) else c.cairo_set_source_rgba(cr, 1, 1, 1, 0.2);
            c.cairo_fill(cr);
        }
    };
    for ([_]u32{ 1, 2, 3 }) |scale| {
        const width = 292 * scale;
        const height = 153 * scale;
        const pixels = try std.testing.allocator.alloc(u32, width * height);
        defer std.testing.allocator.free(pixels);
        const canvas: raster.Canvas = .{ .target = .{ .pixels = pixels, .width = width, .height = height }, .scale = @floatFromInt(scale) };
        const image = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, @intCast(width), @intCast(height)).?;
        defer c.cairo_surface_destroy(image);
        c.cairo_surface_set_device_scale(image, @floatFromInt(scale), @floatFromInt(scale));
        const cr = c.cairo_create(image).?;
        defer c.cairo_destroy(cr);
        for ([_]bool{ false, true }) |windows| {
            @memset(pixels, 0);
            c.cairo_set_operator(cr, c.CAIRO_OPERATOR_CLEAR);
            c.cairo_paint(cr);
            c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);
            panel(canvas);
            highlight(canvas, 13, 127, 127, true, windows);
            reference.panel(cr, 292, 153);
            reference.highlight(cr, 13, 127, 127, true, windows);
            c.cairo_surface_flush(image);
            const expected: [*]const u32 = @ptrCast(@alignCast(c.cairo_image_surface_get_data(image)));
            var total: u64 = 0;
            for (pixels, 0..) |pixel, i| inline for (.{ 0, 8, 16, 24 }) |shift| {
                const actual: i32 = @intCast((pixel >> shift) & 255);
                const wanted: i32 = @intCast((expected[i] >> shift) & 255);
                total += @abs(actual - wanted);
            };
            const mean = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(pixels.len * 4));
            if (mean > 0.5) std.debug.print("switcher scale={d}, windows={}: mean={d}\n", .{ scale, windows, mean });
            try std.testing.expect(mean <= 0.5);
        }
    }
}

test "native icon scaling preserves Cairo colors and alpha" {
    const icon = c.gdk_pixbuf_new(c.GDK_COLORSPACE_RGB, 1, 8, 7, 5).?;
    defer c.g_object_unref(icon);
    const source = pixbufImage(icon);
    const bytes = c.gdk_pixbuf_get_pixels(icon);
    var random: std.Random.DefaultPrng = .init(42);
    random.random().bytes(bytes[0..source.pixels.len]);
    const image = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, 32, 32).?;
    defer c.cairo_surface_destroy(image);
    const cr = c.cairo_create(image).?;
    defer c.cairo_destroy(cr);
    var pixels: [32 * 32]u32 = undefined;
    for ([_][2]u32{ .{ 7, 5 }, .{ 13, 9 }, .{ 6, 4 }, .{ 5, 3 }, .{ 3, 2 } }) |size| {
        @memset(&pixels, 0xff2e2e33);
        try raster.blit(.{ .pixels = &pixels, .width = 32, .height = 32 }, source, .{ .x = 4, .y = 4, .width = @floatFromInt(size[0]), .height = @floatFromInt(size[1]) }, null);
        c.cairo_set_source_rgb(cr, 46.0 / 255.0, 46.0 / 255.0, 51.0 / 255.0);
        c.cairo_paint(cr);
        c.cairo_save(cr);
        c.cairo_translate(cr, 4, 4);
        c.cairo_scale(cr, @as(f64, @floatFromInt(size[0])) / 7, @as(f64, @floatFromInt(size[1])) / 5);
        c.gdk_cairo_set_source_pixbuf(cr, icon, 0, 0);
        c.cairo_paint(cr);
        c.cairo_restore(cr);
        c.cairo_surface_flush(image);
        const expected: [*]const u32 = @ptrCast(@alignCast(c.cairo_image_surface_get_data(image)));
        for (4..4 + size[1]) |y| for (4..4 + size[0]) |x| inline for (.{ 0, 8, 16, 24 }) |shift| {
            const actual: i32 = @intCast((pixels[y * 32 + x] >> shift) & 255);
            const wanted: i32 = @intCast((expected[y * 32 + x] >> shift) & 255);
            if (@abs(actual - wanted) > 4) std.debug.print("icon size={d}x{d} at {d},{d}: actual={d}, expected={d}\n", .{ size[0], size[1], x, y, actual, wanted });
            try std.testing.expect(@abs(actual - wanted) <= 4);
        };
    }
}
