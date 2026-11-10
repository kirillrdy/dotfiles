//! Activities compositing into native Wayland buffers, using Cairo's optimized
//! filters and path rasterization for the opening and workspace animations.
const std = @import("std");
const c = @import("desktop-gtk.zig");
const raster = @import("desktop-raster.zig");
const Rect = raster.Rect;
const Canvas = raster.Canvas;

// Borrow the destination only for this draw. Native Wayland retains ownership
// of the shared-memory buffer; no GTK window or persistent Cairo storage is used.
const Context = struct {
    surface: *c.cairo_surface_t,
    cr: *c.cairo_t,

    fn init(canvas: Canvas) ?Context {
        const surface = c.cairo_image_surface_create_for_data(@ptrCast(canvas.target.pixels.ptr), c.CAIRO_FORMAT_ARGB32, @intCast(canvas.target.width), @intCast(canvas.target.height), @intCast(canvas.target.width * 4)) orelse return null;
        if (c.cairo_surface_status(surface) != c.CAIRO_STATUS_SUCCESS) {
            c.cairo_surface_destroy(surface);
            return null;
        }
        const cr = c.cairo_create(surface) orelse {
            c.cairo_surface_destroy(surface);
            return null;
        };
        c.cairo_scale(cr, canvas.scale, canvas.scale);
        c.cairo_translate(cr, canvas.origin.x, canvas.origin.y);
        return .{ .surface = surface, .cr = cr };
    }
    fn deinit(self: Context) void {
        c.cairo_destroy(self.cr);
        c.cairo_surface_flush(self.surface);
        c.cairo_surface_destroy(self.surface);
    }
};

pub fn miniature(canvas: Canvas, source: ?raster.Image, rect: Rect, clip: Rect, animated: bool) void {
    const context = Context.init(canvas) orelse return;
    defer context.deinit();
    c.cairo_rectangle(context.cr, clip.x, clip.y, clip.width, clip.height);
    c.cairo_clip(context.cr);
    drawImage(context.cr, source, rect, 1, animated);
}

fn rounded(cr: *c.cairo_t, r: Rect, radius: f64) void {
    const rad = @max(0, @min(radius, @min(r.width, r.height) / 2));
    c.cairo_new_sub_path(cr);
    c.cairo_arc(cr, r.x + r.width - rad, r.y + rad, rad, -std.math.pi / 2.0, 0);
    c.cairo_arc(cr, r.x + r.width - rad, r.y + r.height - rad, rad, 0, std.math.pi / 2.0);
    c.cairo_arc(cr, r.x + rad, r.y + r.height - rad, rad, std.math.pi / 2.0, std.math.pi);
    c.cairo_arc(cr, r.x + rad, r.y + rad, rad, std.math.pi, 1.5 * std.math.pi);
    c.cairo_close_path(cr);
}
fn drawImage(cr: *c.cairo_t, image: ?raster.Image, r: Rect, opacity: f64, animated: bool) void {
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    c.cairo_translate(cr, r.x, r.y);
    if (image) |pixels| {
        std.debug.assert(pixels.format == .argb);
        // Borrow capture storage only for this draw; no Cairo object owns it.
        const surface = c.cairo_image_surface_create_for_data(@constCast(pixels.pixels.ptr), c.CAIRO_FORMAT_ARGB32, @intCast(pixels.width), @intCast(pixels.height), @intCast(pixels.stride)) orelse return;
        defer c.cairo_surface_destroy(surface);
        if (c.cairo_surface_status(surface) != c.CAIRO_STATUS_SUCCESS) return;
        c.cairo_scale(cr, r.width / @as(f64, @floatFromInt(pixels.width)), r.height / @as(f64, @floatFromInt(pixels.height)));
        c.cairo_set_source_surface(cr, surface, 0, 0);
        if (animated) c.cairo_pattern_set_filter(c.cairo_get_source(cr), c.CAIRO_FILTER_BILINEAR);
        c.cairo_paint_with_alpha(cr, opacity);
    } else {
        c.cairo_rectangle(cr, 0, 0, r.width, r.height);
        c.cairo_set_source_rgb(cr, 0.3, 0.3, 0.33);
        c.cairo_fill(cr);
    }
}
pub fn workspace(canvas: Canvas, r: Rect, wallpaper: ?*c.cairo_surface_t, animated: bool) void {
    const context = Context.init(canvas) orelse return;
    defer context.deinit();
    const cr = context.cr;
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    rounded(cr, r, 30);
    c.cairo_clip(cr);
    c.cairo_set_source_rgb(cr, 0.015, 0.235, 0.53);
    c.cairo_paint(cr);
    if (wallpaper) |image| {
        const iw: f64 = @floatFromInt(c.cairo_image_surface_get_width(image));
        const ih: f64 = @floatFromInt(c.cairo_image_surface_get_height(image));
        const scale = @max(r.width / iw, r.height / ih);
        c.cairo_translate(cr, r.x + (r.width - iw * scale) / 2, r.y + (r.height - ih * scale) / 2);
        c.cairo_scale(cr, scale, scale);
        c.cairo_set_source_surface(cr, image, 0, 0);
        if (animated) c.cairo_pattern_set_filter(c.cairo_get_source(cr), c.CAIRO_FILTER_BILINEAR);
        c.cairo_paint(cr);
    }
}
pub fn window(canvas: Canvas, r: Rect, captured: ?raster.Image, icon_image: ?*c.GdkPixbuf, hovered: bool, ease: f64, animated: bool) void {
    const context = Context.init(canvas) orelse return;
    defer context.deinit();
    const cr = context.cr;
    rounded(cr, .{ .x = r.x - 3, .y = r.y - 2, .width = r.width + 6, .height = r.height + 8 }, 9);
    c.cairo_set_source_rgba(cr, 0, 0, 0, 0.3);
    c.cairo_fill(cr);
    c.cairo_save(cr);
    rounded(cr, r, 8);
    c.cairo_clip(cr);
    drawImage(cr, captured, r, 1, animated);
    c.cairo_restore(cr);
    if (hovered) {
        rounded(cr, r, 8);
        c.cairo_set_source_rgb(cr, 1, 1, 1);
        c.cairo_set_line_width(cr, 2);
        c.cairo_stroke(cr);
        c.cairo_arc(cr, r.x + r.width, r.y, 16, 0, 2 * std.math.pi);
        c.cairo_set_source_rgb(cr, 0.3, 0.3, 0.33);
        c.cairo_fill(cr);
        c.cairo_set_source_rgb(cr, 1, 1, 1);
        c.cairo_set_line_width(cr, 2);
        c.cairo_move_to(cr, r.x + r.width - 4, r.y - 4);
        c.cairo_line_to(cr, r.x + r.width + 4, r.y + 4);
        c.cairo_move_to(cr, r.x + r.width + 4, r.y - 4);
        c.cairo_line_to(cr, r.x + r.width - 4, r.y + 4);
        c.cairo_stroke(cr);
    }
    if (icon_image) |icon| {
        c.cairo_save(cr);
        c.cairo_translate(cr, r.x + r.width / 2 - 32, r.y + r.height - 44);
        c.cairo_scale(cr, 64 / @as(f64, @floatFromInt(c.gdk_pixbuf_get_width(icon))), 64 / @as(f64, @floatFromInt(c.gdk_pixbuf_get_height(icon))));
        c.gdk_cairo_set_source_pixbuf(cr, icon, 0, 0);
        c.cairo_paint_with_alpha(cr, ease);
        c.cairo_restore(cr);
    }
}
