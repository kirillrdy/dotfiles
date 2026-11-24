//! Offscreen pixel checks for the Activities renderer.
const std = @import("std");
const raster = @import("../desktop-raster.zig");
const text = @import("../desktop-text.zig");
const view = @import("../desktop-overview-view.zig");
const Image = @import("../desktop-image.zig").Image;

test "GPU preview corner masks match rounded content over the cached background" {
    const allocator = std.testing.allocator;
    const color = [_]u32{0xffee3311};
    for ([_]u32{ 1, 2 }) |scale| {
        const width = 100 * scale;
        const height = 80 * scale;
        const foreground = try allocator.alloc(u32, width * height);
        defer allocator.free(foreground);
        const expected = try allocator.alloc(u32, width * height);
        defer allocator.free(expected);
        @memset(foreground, 0);
        @memset(expected, 0xff222226);
        const bounds: raster.Rect = .{ .x = 10, .y = 12, .width = 80, .height = 55 };
        view.roundedMask(.{ .target = .{ .pixels = foreground, .width = width, .height = height }, .scale = @floatFromInt(scale) }, bounds, 12, 1);
        view.miniatureRounded(.{ .target = .{ .pixels = expected, .width = width, .height = height }, .scale = @floatFromInt(scale) }, .{
            .pixels = std.mem.sliceAsBytes(&color),
            .width = 1,
            .height = 1,
            .stride = 4,
            .format = .argb,
        }, bounds, bounds, 12, false);
        for (expected, foreground, 0..) |reference_pixel, mask_pixel, i| {
            const x = i % width;
            const y = i / width;
            const inside = x >= 10 * scale and x < 90 * scale and y >= 12 * scale and y < 67 * scale;
            const actual = raster.over(if (inside) color[0] else 0xff222226, mask_pixel);
            inline for (.{ 0, 8, 16, 24 }) |shift| {
                const difference = @abs(@as(i32, @intCast((actual >> shift) & 255)) - @as(i32, @intCast((reference_pixel >> shift) & 255)));
                try std.testing.expect(difference <= 2);
            }
        }
        @memset(foreground, 0);
        @memset(expected, 0xff222226);
        view.workspaceCard(.{ .target = .{ .pixels = expected, .width = width, .height = height }, .scale = @floatFromInt(scale) }, bounds, null, 12, true, false);
        view.roundedMaskShadow(.{ .target = .{ .pixels = foreground, .width = width, .height = height }, .scale = @floatFromInt(scale) }, bounds, 12);
        const corner_pixel = (12 * scale) * width + 10 * scale;
        try std.testing.expectEqual(expected[corner_pixel], foreground[corner_pixel]);
    }
}

test "strip corner masks fade with the overview controls" {
    var pixels: [40 * 40]u32 = @splat(0);
    const canvas: raster.Canvas = .{ .target = .{ .pixels = &pixels, .width = 40, .height = 40 }, .scale = 1 };
    const bounds: raster.Rect = .{ .x = 4, .y = 4, .width = 32, .height = 32 };
    view.roundedMask(canvas, bounds, 12, 0);
    for (pixels) |pixel| try std.testing.expectEqual(@as(u32, 0), pixel);
    view.roundedMask(canvas, bounds, 12, 0.5);
    const corner = pixels[4 * 40 + 4];
    try std.testing.expect(corner >> 24 > 0x60 and corner >> 24 < 0xa0);
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

    var rgb: [64 * 64 * 3]u8 = undefined;
    for (0..64 * 64) |i| rgb[i * 3 ..][0..3].* = .{ 80, 150, 240 };
    const icon = try Image.normalize(a, .{ .pixels = &rgb, .width = 64, .height = 64, .stride = 64 * 3, .format = .rgb });
    defer icon.deinit(a);

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
    view.thumbnailIndicator(canvas, .{ .x = 20, .y = 20, .width = 86, .height = 52 }, 1);
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
    const pixels = try a.alloc(u32, 200 * 120);
    defer a.free(pixels);
    @memset(pixels, 0);
    const canvas: raster.Canvas = .{ .target = .{ .pixels = pixels, .width = 200, .height = 120 }, .scale = 1 };
    view.workspaceCard(canvas, .{ .width = 200, .height = 120 }, .{ .pixels = std.mem.sliceAsBytes(&source), .width = 2, .height = 2, .stride = 8, .format = .argb }, 30, false, false);
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
