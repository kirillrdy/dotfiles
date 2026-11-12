//! UI helpers kept separate from the C ABI declarations.
const c = @import("desktop-gtk.zig");
const std = @import("std");
const raster = @import("desktop-raster.zig");
pub fn cast(comptime T: type, ptr: anytype) *T {
    return @ptrCast(@alignCast(ptr));
}
pub const eq = @import("desktop-util.zig").eq;
pub fn parentTo(widget: *c.GtkWidget, allocator: std.mem.Allocator, parent: [:0]const u8) void {
    const display = c.gdk_display_get_default();
    const window = c.gtk_widget_get_window(widget) orelse return;
    if (std.mem.startsWith(u8, parent, "wayland:") and c.g_type_check_instance_is_a(cast(c.GTypeInstance, display), c.gdk_wayland_display_get_type()) != 0) {
        const handle = allocator.dupeSentinel(u8, parent[8..], 0) catch return;
        defer allocator.free(handle);
        _ = c.gdk_wayland_window_set_transient_for_exported(window, handle);
    }
}
pub fn paintCairo(cr: *c.cairo_t, logical_width: u32, logical_height: u32, scale: u32, context: anytype, comptime drawFn: anytype) !void {
    const width = @max(1, logical_width) * scale;
    const height = @max(1, logical_height) * scale;
    const image = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, @intCast(width), @intCast(height)) orelse return error.ImageAllocation;
    defer c.cairo_surface_destroy(image);
    if (c.cairo_surface_status(image) != 0) return error.ImageAllocation;
    const pixels: [*]u32 = @ptrCast(@alignCast(c.cairo_image_surface_get_data(image)));
    const buffer = raster.Buffer{ .pixels = pixels[0 .. width * height], .width = width, .height = height };
    const Return = @typeInfo(@TypeOf(drawFn)).@"fn".return_type.?;
    if (@typeInfo(Return) == .error_union) try drawFn(context, buffer) else drawFn(context, buffer);
    c.cairo_surface_mark_dirty(image);
    c.cairo_surface_set_device_scale(image, @floatFromInt(scale), @floatFromInt(scale));
    c.cairo_set_source_surface(cr, image, 0, 0);
    c.cairo_paint(cr);
}
pub fn pixbufImage(pixbuf: *c.GdkPixbuf) raster.Image {
    const width: u32 = @intCast(c.gdk_pixbuf_get_width(pixbuf));
    const height: u32 = @intCast(c.gdk_pixbuf_get_height(pixbuf));
    const stride: usize = @intCast(c.gdk_pixbuf_get_rowstride(pixbuf));
    const channels: u32 = @intCast(c.gdk_pixbuf_get_n_channels(pixbuf));
    return .{
        .pixels = c.gdk_pixbuf_get_pixels(pixbuf)[0 .. (height - 1) * stride + width * channels],
        .width = width,
        .height = height,
        .stride = stride,
        .format = if (channels == 4) .rgba else .rgb,
    };
}
pub fn blitPixbuf(canvas: raster.Canvas, pixbuf: *c.GdkPixbuf, rect: raster.Rect) void {
    raster.blit(canvas.target, pixbufImage(pixbuf), .{
        .x = (rect.x + canvas.origin.x) * canvas.scale,
        .y = (rect.y + canvas.origin.y) * canvas.scale,
        .width = rect.width * canvas.scale,
        .height = rect.height * canvas.scale,
    }, null) catch {};
}
pub fn pixbufAlphaMask(allocator: std.mem.Allocator, pixbuf: *c.GdkPixbuf, out_width: *u32, out_height: *u32) ![]u8 {
    const width: u32 = @intCast(@max(0, c.gdk_pixbuf_get_width(pixbuf)));
    const height: u32 = @intCast(@max(0, c.gdk_pixbuf_get_height(pixbuf)));
    const stride: usize = @intCast(c.gdk_pixbuf_get_rowstride(pixbuf));
    const channels: usize = @intCast(c.gdk_pixbuf_get_n_channels(pixbuf));
    const source = c.gdk_pixbuf_get_pixels(pixbuf);
    const mask = try allocator.alloc(u8, @as(usize, width) * height);
    for (0..height) |y| for (0..width) |x| {
        mask[y * width + x] = if (channels >= 4) source[y * stride + x * channels + 3] else source[y * stride + x * channels];
    };
    out_width.* = width;
    out_height.* = height;
    return mask;
}
pub fn dispatchWayland(display: ?*c.wl_display) bool {
    const libc = @import("desktop-libc.zig");
    while (c.wl_display_prepare_read(display) != 0) {
        if (c.wl_display_dispatch_pending(display) < 0) return false;
    }
    if (c.wl_display_read_events(display) < 0 and libc.__errno_location().* != @backingInt(std.c.E.AGAIN)) return false;
    return c.wl_display_dispatch_pending(display) >= 0;
}
