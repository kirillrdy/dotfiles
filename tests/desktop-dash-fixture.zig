//! Actual native dash rendering, icon caching, interaction states and HiDPI.
const std = @import("std");
const desktop = @import("desktop");
const native = desktop.dash_view;
const c = desktop.gtk;
extern fn cairo_surface_write_to_png(*c.cairo_surface_t, [*:0]const u8) c_int;

pub fn main() !void {
    c.gtk_init(null, null);
    if (c.g_getenv("DESKTOP_PANEL_ICON_PATH")) |path| c.gtk_icon_theme_append_search_path(c.gtk_icon_theme_get_default(), path);
    var view: native.View = .{};
    defer view.deinit();
    for ([_]struct { title: [:0]const u8, icon: [:0]const u8 }{
        .{ .title = "Terminal", .icon = "utilities-terminal" },
        .{ .title = "Files", .icon = "system-file-manager" },
        .{ .title = "Browser", .icon = "web-browser" },
    }, 0..) |fixture, i| {
        const key = c.g_key_file_new();
        defer c.g_key_file_unref(key);
        const source = try std.fmt.allocPrintSentinel(std.heap.page_allocator, "[Desktop Entry]\nType=Application\nName={s}\nExec=true\nIcon={s}\n", .{ fixture.title, fixture.icon }, 0);
        defer std.heap.page_allocator.free(source);
        try std.testing.expect(c.g_key_file_load_from_data(key, source, source.len, 0, null) != 0);
        const app = c.g_desktop_app_info_new_from_keyfile(key).?;
        defer c.g_object_unref(app);
        try view.add(fixture.title, @ptrCast(app), if (i == 0) "terminal-id" else null, null);
    }
    try view.add("Show Applications", null, null, null);
    view.items.items[3].show_apps = true;
    view.relayout(1280, 720);
    view.focus = 3;
    view.navigate(1);
    try std.testing.expectEqual(@as(usize, 0), view.focus);
    view.navigate(-1);
    try std.testing.expectEqual(@as(usize, 3), view.focus);
    view.keyboard_focus = false;
    for ([_]u32{ 1, 2 }) |scale| {
        const width = view.layout.width * scale;
        const height = view.layout.height * scale;
        const surface = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, @intCast(width), @intCast(height)).?;
        defer c.cairo_surface_destroy(surface);
        const data: [*]u32 = @ptrCast(@alignCast(c.cairo_image_surface_get_data(surface)));
        const pixels = data[0 .. width * height];
        const target: native.Buffer = .{ .pixels = pixels, .width = width, .height = height };
        try view.paint(target, scale);
        const normal = try std.heap.page_allocator.dupe(u32, pixels);
        defer std.heap.page_allocator.free(normal);
        const icon = view.items.items[0].pixels;
        try std.testing.expect(icon != null);
        try view.paint(target, scale);
        try std.testing.expectEqual(icon, view.items.items[0].pixels);
        try std.testing.expectEqualSlices(u32, normal, pixels);
        try snapshot(surface, scale, "normal");
        view.hover = 0;
        try view.paint(target, scale);
        try std.testing.expect(!std.mem.eql(u32, normal, pixels));
        const hovered = try std.heap.page_allocator.dupe(u32, pixels);
        defer std.heap.page_allocator.free(hovered);
        try snapshot(surface, scale, "hover");
        view.pressed = 0;
        try view.paint(target, scale);
        try std.testing.expect(!std.mem.eql(u32, hovered, pixels));
        try snapshot(surface, scale, "press");
        view.pressed = null;
        view.hover = null;
        view.keyboard_focus = true;
        view.focus = 0;
        try view.paint(target, scale);
        try std.testing.expect(!std.mem.eql(u32, normal, pixels));
        try snapshot(surface, scale, "focus");
        view.keyboard_focus = false;
        view.apps_mode = true;
        try view.paint(target, scale);
        try std.testing.expect(!std.mem.eql(u32, normal, pixels));
        try snapshot(surface, scale, "checked");
        view.apps_mode = false;
        try view.prepareTooltip(0, scale);
        try std.testing.expect(view.tooltip_mask.?.logical_width < 360 * scale);
        try std.testing.expectEqual(@as(?usize, 0), view.tooltip_index);
        try tooltipSnapshot(&view, scale);
        try view.prepareTooltip(2, scale);
        try std.testing.expectEqual(@as(?usize, 2), view.tooltip_index);
    }
    view.separator = 2;
    view.relayout(1280, 720);
    try std.testing.expectEqual(@as(u32, 285), view.layout.width);
    std.debug.print("desktop-dash: GNOME geometry, icon caching, hover/press/focus, checked state, navigation, tooltips and HiDPI passed\n", .{});
}
fn tooltipSnapshot(view: *native.View, scale: u32) !void {
    const width = view.tooltip_mask.?.logical_width + 26 * scale;
    const height = view.tooltip_mask.?.logical_height + 14 * scale;
    const surface = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, @intCast(width), @intCast(height)).?;
    defer c.cairo_surface_destroy(surface);
    const data: [*]u32 = @ptrCast(@alignCast(c.cairo_image_surface_get_data(surface)));
    view.paintTooltip(.{ .pixels = data[0 .. width * height], .width = width, .height = height }, scale);
    try std.testing.expectEqual(@as(u32, 0), data[0]);
    const alpha = data[(height / 2) * width + 3 * scale] >> 24;
    try std.testing.expect(alpha >= 229 and alpha <= 231);
    try snapshot(surface, scale, "tooltip");
}
fn snapshot(surface: *c.cairo_surface_t, scale: u32, state: []const u8) !void {
    const root = c.g_getenv("DESKTOP_DASH_SCREENSHOTS") orelse return;
    const path = try std.fmt.allocPrintSentinel(std.heap.page_allocator, "{s}/dash-{s}-{d}x.png", .{ root, state, scale }, 0);
    defer std.heap.page_allocator.free(path);
    c.cairo_surface_mark_dirty(surface);
    try std.testing.expectEqual(@as(c_int, 0), cairo_surface_write_to_png(surface, path));
}
