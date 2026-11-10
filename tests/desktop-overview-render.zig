//! Frozen Cairo reference for the Activities pixel renderer.
const std = @import("std");
const c = @import("../desktop-gtk.zig");
const raster = @import("../desktop-raster.zig");
const view = @import("../desktop-overview-view.zig");
const Image = @import("../desktop-image.zig").Image;
const capture = @import("../desktop-capture.zig");
const Rect = capture.Rect;

const reference = struct {
    fn rounded(cr: *c.cairo_t, r: Rect, radius: f64) void {
        const rad = @max(0, @min(radius, @min(r.w, r.h) / 2));
        c.cairo_new_sub_path(cr);
        c.cairo_arc(cr, r.x + r.w - rad, r.y + rad, rad, -std.math.pi / 2.0, 0);
        c.cairo_arc(cr, r.x + r.w - rad, r.y + r.h - rad, rad, 0, std.math.pi / 2.0);
        c.cairo_arc(cr, r.x + rad, r.y + r.h - rad, rad, std.math.pi / 2.0, std.math.pi);
        c.cairo_arc(cr, r.x + rad, r.y + rad, rad, std.math.pi, 1.5 * std.math.pi);
        c.cairo_close_path(cr);
    }
    fn drawImage(cr: *c.cairo_t, image: ?capture.Image, r: Rect, opacity: f64) void {
        c.cairo_save(cr);
        defer c.cairo_restore(cr);
        c.cairo_translate(cr, r.x, r.y);
        if (image) |pixels| {
            // Borrow capture storage only for this draw; no Cairo object owns it.
            const surface = c.cairo_image_surface_create_for_data(pixels.pixels.ptr, c.CAIRO_FORMAT_ARGB32, @intCast(pixels.width), @intCast(pixels.height), @intCast(pixels.stride)) orelse return;
            defer c.cairo_surface_destroy(surface);
            if (c.cairo_surface_status(surface) != c.CAIRO_STATUS_SUCCESS) return;
            c.cairo_scale(cr, r.w / @as(f64, @floatFromInt(pixels.width)), r.h / @as(f64, @floatFromInt(pixels.height)));
            c.cairo_set_source_surface(cr, surface, 0, 0);
            c.cairo_paint_with_alpha(cr, opacity);
        } else {
            c.cairo_rectangle(cr, 0, 0, r.w, r.h);
            c.cairo_set_source_rgb(cr, 0.3, 0.3, 0.33);
            c.cairo_fill(cr);
        }
    }
    fn workspace(cr: *c.cairo_t, r: Rect, wallpaper: ?*c.cairo_surface_t) void {
        c.cairo_save(cr);
        defer c.cairo_restore(cr);
        rounded(cr, r, 30);
        c.cairo_clip(cr);
        c.cairo_set_source_rgb(cr, 0.015, 0.235, 0.53);
        c.cairo_paint(cr);
        if (wallpaper) |image| {
            const iw: f64 = @floatFromInt(c.cairo_image_surface_get_width(image));
            const ih: f64 = @floatFromInt(c.cairo_image_surface_get_height(image));
            const scale = @max(r.w / iw, r.h / ih);
            c.cairo_translate(cr, r.x + (r.w - iw * scale) / 2, r.y + (r.h - ih * scale) / 2);
            c.cairo_scale(cr, scale, scale);
            c.cairo_set_source_surface(cr, image, 0, 0);
            c.cairo_paint(cr);
        }
    }
    fn window(cr: *c.cairo_t, r: Rect, captured: ?Image, icon_image: ?*c.GdkPixbuf, hovered: bool, ease: f64) void {
        rounded(cr, .{ .x = r.x - 3, .y = r.y - 2, .w = r.w + 6, .h = r.h + 8 }, 9);
        c.cairo_set_source_rgba(cr, 0, 0, 0, 0.3);
        c.cairo_fill(cr);
        c.cairo_save(cr);
        rounded(cr, r, 8);
        c.cairo_clip(cr);
        drawImage(cr, captured, r, 1);
        c.cairo_restore(cr);
        if (hovered) {
            rounded(cr, r, 8);
            c.cairo_set_source_rgb(cr, 1, 1, 1);
            c.cairo_set_line_width(cr, 2);
            c.cairo_stroke(cr);
            c.cairo_arc(cr, r.x + r.w, r.y, 16, 0, 2 * std.math.pi);
            c.cairo_set_source_rgb(cr, 0.3, 0.3, 0.33);
            c.cairo_fill(cr);
            c.cairo_set_source_rgb(cr, 1, 1, 1);
            c.cairo_set_line_width(cr, 2);
            c.cairo_move_to(cr, r.x + r.w - 4, r.y - 4);
            c.cairo_line_to(cr, r.x + r.w + 4, r.y + 4);
            c.cairo_move_to(cr, r.x + r.w + 4, r.y - 4);
            c.cairo_line_to(cr, r.x + r.w - 4, r.y + 4);
            c.cairo_stroke(cr);
        }
        if (icon_image) |icon| {
            c.cairo_save(cr);
            c.cairo_translate(cr, r.x + r.w / 2 - 32, r.y + r.h - 44);
            c.cairo_scale(cr, 64 / @as(f64, @floatFromInt(c.gdk_pixbuf_get_width(icon))), 64 / @as(f64, @floatFromInt(c.gdk_pixbuf_get_height(icon))));
            c.gdk_cairo_set_source_pixbuf(cr, icon, 0, 0);
            c.cairo_paint_with_alpha(cr, ease);
            c.cairo_restore(cr);
        }
    }
};

fn rect(value: Rect) raster.Rect {
    return .{ .x = value.x, .y = value.y, .width = value.w, .height = value.h };
}

fn compare(expected: []const u32, actual: []const u32, scale: u32, ease: f64) !void {
    var total: u64 = 0;
    var differing: usize = 0;
    for (expected, actual) |left, right| {
        var worst: u32 = 0;
        inline for (.{ 0, 8, 16, 24 }) |shift| {
            const delta = @abs(@as(i32, @intCast((left >> shift) & 255)) - @as(i32, @intCast((right >> shift) & 255)));
            total += delta;
            worst = @max(worst, delta);
        }
        if (worst > 32) differing += 1;
    }
    const mean = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(actual.len * 4));
    // Signed-distance antialiasing differs at curved edges. Broad color,
    // opacity, crop or layout changes must fail rather than hide in that allowance.
    if (mean > 1.4 or differing > actual.len / 100) {
        std.debug.print("overview reference scale={} ease={d}: mean={d} differing={}/{}\n", .{ scale, ease, mean, differing, actual.len });
        return error.OverviewPixelsDiffer;
    }
}

test "Zig overview agrees with Cairo for wallpaper crops, previews, hover, fades and workspace clipping" {
    const a = std.testing.allocator;
    const icon = c.gdk_pixbuf_new(c.GDK_COLORSPACE_RGB, 1, 8, 7, 5).?;
    defer c.g_object_unref(icon);
    const icon_stride: usize = @intCast(c.gdk_pixbuf_get_rowstride(icon));
    const icon_bytes = c.gdk_pixbuf_get_pixels(icon);
    for (0..5) |y| for (0..7) |x| {
        const offset = y * icon_stride + x * 4;
        icon_bytes[offset] = @intCast(x * 35);
        icon_bytes[offset + 1] = @intCast(y * 55);
        icon_bytes[offset + 2] = 180;
        icon_bytes[offset + 3] = @intCast(80 + x * 20);
    };
    var words: [11 * 9]u32 = undefined;
    for (&words, 0..) |*word, i| {
        const alpha: u32 = @intCast(128 + i % 128);
        word.* = (alpha << 24) | ((@as(u32, @intCast(i * 7 % 256)) * alpha / 255) << 16) | ((@as(u32, @intCast(i * 13 % 256)) * alpha / 255) << 8) | (alpha / 2);
    }
    const image = try Image.thumbnail(a, .{ .pixels = std.mem.sliceAsBytes(&words), .width = 11, .height = 9, .stride = 44, .format = .argb });
    defer image.deinit(a);
    const wallpaper = c.cairo_image_surface_create_for_data(image.pixels.ptr, c.CAIRO_FORMAT_ARGB32, 11, 9, 44).?;
    defer c.cairo_surface_destroy(wallpaper);
    const workspace: Rect = .{ .x = 10.25, .y = 8.75, .w = 240, .h = 138 };
    const window: Rect = .{ .x = 50.25, .y = 40.5, .w = 150, .h = 78 };
    const miniature: Rect = .{ .x = -4, .y = 156, .w = 80, .h = 40 };
    const clip: Rect = .{ .x = 12, .y = 160, .w = 55, .h = 30 };
    for ([_]u32{ 1, 2 }) |scale| for ([_]f64{ 0, 0.45, 1 }) |ease| for ([_]bool{ false, true }) |available| {
        const width = 260 * scale;
        const height = 200 * scale;
        const pixels = try a.alloc(u32, width * height);
        defer a.free(pixels);
        @memset(pixels, 0xff222226);
        const canvas: raster.Canvas = .{ .target = .{ .pixels = pixels, .width = width, .height = height }, .scale = @floatFromInt(scale) };
        view.workspace(canvas, rect(workspace), if (available) image.view() else null);
        view.window(canvas, rect(window), if (available) image.view() else null, c.__zig.pixbufImage(icon), ease != 0, ease);
        view.miniature(canvas, if (available) image.view() else null, rect(miniature), rect(clip));
        const surface = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, @intCast(width), @intCast(height)).?;
        defer c.cairo_surface_destroy(surface);
        const cr = c.cairo_create(surface).?;
        defer c.cairo_destroy(cr);
        c.cairo_scale(cr, @floatFromInt(scale), @floatFromInt(scale));
        c.cairo_set_source_rgb(cr, 34.0 / 255.0, 34.0 / 255.0, 38.0 / 255.0);
        c.cairo_paint(cr);
        reference.workspace(cr, workspace, if (available) wallpaper else null);
        reference.window(cr, window, if (available) image else null, icon, ease != 0, ease);
        c.cairo_save(cr);
        c.cairo_rectangle(cr, clip.x, clip.y, clip.w, clip.h);
        c.cairo_clip(cr);
        reference.drawImage(cr, if (available) image else null, miniature, 1);
        c.cairo_restore(cr);
        c.cairo_surface_flush(surface);
        const expected: [*]const u32 = @ptrCast(@alignCast(c.cairo_image_surface_get_data(surface)));
        try compare(expected[0 .. width * height], pixels, scale, ease);
    };
}
