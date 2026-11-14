//! Frozen Cairo reference for the Activities pixel renderer.
const std = @import("std");
const c = @import("../desktop-gtk.zig");
const raster = @import("../desktop-raster.zig");
const text = @import("../desktop-text.zig");
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
        c.cairo_rectangle(cr, 0, 0, r.w, r.h);
        c.cairo_clip(cr);
        if (image) |pixels| {
            // Borrow capture storage only for this draw; no Cairo object owns it.
            const surface = c.cairo_image_surface_create_for_data(pixels.pixels.ptr, c.CAIRO_FORMAT_ARGB32, @intCast(pixels.width), @intCast(pixels.height), @intCast(pixels.stride)) orelse return;
            defer c.cairo_surface_destroy(surface);
            if (c.cairo_surface_status(surface) != c.CAIRO_STATUS_SUCCESS) return;
            c.cairo_scale(cr, r.w / @as(f64, @floatFromInt(pixels.width)), r.h / @as(f64, @floatFromInt(pixels.height)));
            c.cairo_set_source_surface(cr, surface, 0, 0);
            c.cairo_pattern_set_extend(c.cairo_get_source(cr), c.CAIRO_EXTEND_PAD);
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
            c.cairo_pattern_set_extend(c.cairo_get_source(cr), c.CAIRO_EXTEND_PAD);
            c.cairo_paint(cr);
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

test "native buffer overview preserves wallpaper crops and workspace clipping" {
    const a = std.testing.allocator;
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
    const miniature: Rect = .{ .x = -4, .y = 156, .w = 80, .h = 40 };
    const clip: Rect = .{ .x = 12, .y = 160, .w = 55, .h = 30 };
    for ([_]u32{ 1, 2 }) |scale| for ([_]f64{ 0, 0.45, 1 }) |ease| for ([_]bool{ false, true }) |available| {
        const width = 260 * scale;
        const height = 200 * scale;
        const pixels = try a.alloc(u32, width * height);
        defer a.free(pixels);
        @memset(pixels, 0xff222226);
        const canvas: raster.Canvas = .{ .target = .{ .pixels = pixels, .width = width, .height = height }, .scale = @floatFromInt(scale) };
        view.workspaceCard(canvas, rect(workspace), if (available) wallpaper else null, 30, false, false);
        view.miniatureRounded(canvas, if (available) image.view() else null, rect(miniature), rect(clip), 0, false);
        const surface = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, @intCast(width), @intCast(height)).?;
        defer c.cairo_surface_destroy(surface);
        const cr = c.cairo_create(surface).?;
        defer c.cairo_destroy(cr);
        c.cairo_scale(cr, @floatFromInt(scale), @floatFromInt(scale));
        c.cairo_set_source_rgb(cr, 34.0 / 255.0, 34.0 / 255.0, 38.0 / 255.0);
        c.cairo_paint(cr);
        reference.workspace(cr, workspace, if (available) wallpaper else null);
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

test "workspace corners grow with overview progress from an unrounded desktop" {
    const a = std.testing.allocator;
    for ([_]u32{ 1, 2 }) |scale| {
        const width = 90 * scale;
        const height = 60 * scale;
        const pixels = try a.alloc(u32, width * height);
        defer a.free(pixels);
        const canvas: raster.Canvas = .{ .target = .{ .pixels = pixels, .width = width, .height = height }, .scale = @floatFromInt(scale) };
        const bounds: raster.Rect = .{ .width = 90, .height = 60 };
        for ([_]f64{ 0, 0.5, 1 }) |progress| {
            @memset(pixels, 0);
            view.workspaceProgress(canvas, bounds, null, progress, true);
            try std.testing.expectEqual(@as(u32, 255), pixels[(30 * scale) * width + 45 * scale] >> 24);
            // Outside rounded corners, only translucent black drop shadow may remain; never the blue card fill.
            if (progress == 0) {
                try std.testing.expectEqual(@as(u32, 255), pixels[0] >> 24);
            } else {
                try std.testing.expect((pixels[0] & 0x00ffffff) == 0);
                try std.testing.expect((pixels[0] >> 24) < 64);
            }
            // Outside the fully rounded corner, only the outer drop shadow may appear (never the blue card fill).
            if (progress < 1) {
                try std.testing.expectEqual(@as(u32, 255), pixels[(5 * scale) * width + 5 * scale] >> 24);
            } else {
                const corner = pixels[(5 * scale) * width + 5 * scale];
                try std.testing.expect((corner & 0x00ffffff) == 0);
                try std.testing.expect((corner >> 24) < 64);
            }
        }
    }
}

test "hovered window expands without white border and paints close states, caption pill, icon shadow and indicator" {
    const a = std.testing.allocator;
    const width: u32 = 300;
    const height: u32 = 240;
    const pixels = try a.alloc(u32, width * height);
    defer a.free(pixels);
    const canvas: raster.Canvas = .{ .target = .{ .pixels = pixels, .width = width, .height = height }, .scale = 1 };

    const icon = c.gdk_pixbuf_new(c.GDK_COLORSPACE_RGB, 1, 8, 64, 64).?;
    defer c.g_object_unref(icon);
    const icon_stride: usize = @intCast(c.gdk_pixbuf_get_rowstride(icon));
    const icon_bytes = c.gdk_pixbuf_get_pixels(icon);
    for (0..64) |y| for (0..64) |x| {
        const offset = y * icon_stride + x * 4;
        icon_bytes[offset] = 80;
        icon_bytes[offset + 1] = 150;
        icon_bytes[offset + 2] = 240;
        icon_bytes[offset + 3] = 255;
    };

    var renderer: text.Renderer = .{};
    defer renderer.deinit();
    const mask = try renderer.renderLayout(a, "Test Caption", .{ .font = "Adwaita Sans Bold", .size = 14.6666666667, .dpi = 96, .line_height = 19, .origin = .top });
    defer mask.deinit(a);

    const win: raster.Rect = .{ .x = 60, .y = 40, .width = 160, .height = 100 };
    const expanded = view.previewRect(win, true, 1);
    try std.testing.expectEqual(@as(f64, 55), expanded.x);
    try std.testing.expectEqual(@as(f64, 36.875), expanded.y);
    try std.testing.expectEqual(@as(f64, 170), expanded.width);
    try std.testing.expectEqual(@as(f64, 106.25), expanded.height);

    // Normal vs hover vs pressed close button fill.
    const states = [_]struct { state: view.WindowState, expected_r: u8 }{
        .{ .state = .{ .hovered = true, .ease = 1, .caption = .{ .mask = mask, .scale = 1 }, .bounds_width = 180 }, .expected_r = 63 },
        .{ .state = .{ .hovered = true, .close_hovered = true, .ease = 1, .caption = .{ .mask = mask, .scale = 1 }, .bounds_width = 180 }, .expected_r = 80 },
        .{ .state = .{ .hovered = true, .close_pressed = true, .ease = 1, .caption = .{ .mask = mask, .scale = 1 }, .bounds_width = 180 }, .expected_r = 94 },
    };
    const close_r = view.closeButtonRect(expanded);
    const close_sample_x: usize = @intFromFloat(close_r.x + 8);
    const close_sample_y: usize = @intFromFloat(close_r.y + view.close_button_radius);
    for (states) |entry| {
        @memset(pixels, 0xff222226);
        view.window(canvas, win, null, icon, entry.state);
        // No white hover border stroke along bottom/left edges of preview.
        try std.testing.expect(pixels[@as(usize, @intFromFloat(expanded.y + expanded.height - 2)) * width + @as(usize, @intFromFloat(expanded.x + 20))] != 0xffffffff);
        try std.testing.expect(pixels[@as(usize, @intFromFloat(expanded.y + 40)) * width + @as(usize, @intFromFloat(expanded.x))] != 0xffffffff);
        // Icon drop shadow darkens area just beneath 64px icon (icon bottom is at expanded.y + expanded.height + 19.2).
        const shadow_px = pixels[@as(usize, @intFromFloat(expanded.y + expanded.height + 22)) * width + @as(usize, @intFromFloat(expanded.x + expanded.width / 2))];
        try std.testing.expect(((shadow_px >> 16) & 255) < 34);
        // Caption pill sits 6px below icon bottom and is darker than background #222226.
        const pill_px = pixels[@as(usize, @intFromFloat(expanded.y + expanded.height + 34)) * width + @as(usize, @intFromFloat(expanded.x + 48))];
        try std.testing.expect(((pill_px >> 16) & 255) < 20);
        // Close button matches expected GNOME RGB state.
        const close_px = pixels[close_sample_y * width + close_sample_x];
        const r_chan: u8 = @intCast((close_px >> 16) & 255);
        try std.testing.expect(@abs(@as(i32, r_chan) - @as(i32, entry.expected_r)) <= 3);
    }

    // Active workspace thumbnail indicator draws border only (center remains transparent).
    @memset(pixels, 0);
    view.thumbnailIndicator(canvas, .{ .x = 20, .y = 20, .width = 86, .height = 52 });
    try std.testing.expectEqual(@as(u32, 0), pixels[46 * width + 63]);
    try std.testing.expectEqual(@as(u32, 0xff3584e4), pixels[19 * width + 63]);

    // Workspace card paints soft outer drop shadow beyond card rect.
    @memset(pixels, 0xff222226);
    view.workspaceCard(canvas, .{ .x = 40, .y = 30, .width = 160, .height = 100 }, null, 12, true, false);
    const card_shadow = pixels[134 * width + 120];
    try std.testing.expect(((card_shadow >> 16) & 255) < 34);
}

test "tiny wallpaper stays opaque and uniformly colored when enlarged" {
    const a = std.testing.allocator;
    var source: [4]u32 = @splat(0xff142850);
    const wallpaper = c.cairo_image_surface_create_for_data(@ptrCast(&source), c.CAIRO_FORMAT_ARGB32, 2, 2, 8).?;
    defer c.cairo_surface_destroy(wallpaper);
    const pixels = try a.alloc(u32, 200 * 120);
    defer a.free(pixels);
    @memset(pixels, 0);
    const canvas: raster.Canvas = .{ .target = .{ .pixels = pixels, .width = 200, .height = 120 }, .scale = 1 };
    view.workspaceCard(canvas, .{ .width = 200, .height = 120 }, wallpaper, 30, false, false);
    for ([_]usize{ 2 * 200 + 100, 60 * 200 + 2, 60 * 200 + 100, 60 * 200 + 197, 117 * 200 + 100 }) |i| try std.testing.expectEqual(@as(u32, 0xff142850), pixels[i]);
}

test "window previews retain client corners and do not add a second frame" {
    for ([_]u32{ 1, 2 }) |scale| {
        const width = 240 * scale;
        const height = 180 * scale;
        const pixels = try std.testing.allocator.alloc(u32, width * height);
        defer std.testing.allocator.free(pixels);
        @memset(pixels, 0);
        var source: [4]u32 = @splat(0xffaabbcc);
        const captured: raster.Image = .{ .pixels = std.mem.sliceAsBytes(&source), .width = 2, .height = 2, .stride = 8, .format = .argb };
        view.window(.{ .target = .{ .pixels = pixels, .width = width, .height = height }, .scale = @floatFromInt(scale) }, .{ .x = 40, .y = 40, .width = 120, .height = 80 }, captured, null, .{});
        try std.testing.expectEqual(@as(u32, 0), pixels[39 * scale * width + 40 * scale]);
        try std.testing.expectEqual(@as(u32, 255), pixels[40 * scale * width + 40 * scale] >> 24);
        try std.testing.expectEqual(@as(u32, 0), pixels[80 * scale * width + 170 * scale]);
    }
}
