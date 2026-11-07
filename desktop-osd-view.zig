//! Native Zig OSD rendering.
const std = @import("std");
const c = @import("desktop-gtk.zig");
const raster = @import("desktop-raster.zig");
pub const Kind = enum { volume, microphone, brightness };

pub const Theme = struct {
    background: raster.Color = .{ .red = 46.0 / 255.0, .green = 46.0 / 255.0, .blue = 51.0 / 255.0, .alpha = 1 },
    foreground: raster.Color = .{ .red = 1, .green = 1, .blue = 1, .alpha = 1 },
    track: raster.Color = .{ .red = 1, .green = 1, .blue = 1, .alpha = 0.1 },
    fill: raster.Color = .{ .red = 1, .green = 1, .blue = 1, .alpha = 1 },
    border_color: raster.Color = .{ .red = 1, .green = 1, .blue = 1, .alpha = 0.02 },
    border: c.GtkBorder = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 },
    padding: c.GtkBorder = .{ .left = 18, .right = 18, .top = 12, .bottom = 12 },
    bar_margin: c.GtkBorder = .{ .right = 6 },
    bar_width: u32 = 160,
    bar_height: u32 = 6,

    pub fn width(self: Theme) u32 {
        return @as(u32, @intCast(self.border.left + self.border.right + self.padding.left + self.padding.right + self.bar_margin.left + self.bar_margin.right)) + 24 + 12 + self.bar_width;
    }
    pub fn height(self: Theme) u32 {
        return @as(u32, @intCast(self.border.top + self.border.bottom + self.padding.top + self.padding.bottom)) + @max(24, self.bar_height + @as(u32, @intCast(self.bar_margin.top + self.bar_margin.bottom)));
    }
};

fn rgba(value: raster.Color, opacity: f64) raster.Color {
    return .{ .red = value.red, .green = value.green, .blue = value.blue, .alpha = value.alpha * opacity };
}
fn capsule(canvas: raster.Canvas, value: raster.Color, opacity: f64, x: f64, y: f64, width: f64, height: f64) void {
    if (width <= 0 or height <= 0) return;
    canvas.draw(&.{.{ .rounded = .{ .x = x, .y = y, .width = width, .height = height } }}, rgba(value, opacity));
}

pub fn paint(target: raster.Buffer, scale: u32, theme: Theme, kind: Kind, percent: f64, muted: bool) void {
    const width = @as(f64, @floatFromInt(target.width)) / @as(f64, @floatFromInt(scale));
    const height = @as(f64, @floatFromInt(target.height)) / @as(f64, @floatFromInt(scale));
    const canvas: raster.Canvas = .{ .target = target, .scale = @floatFromInt(scale) };
    const level = if (std.math.isFinite(percent)) std.math.clamp(percent, 0, 100) else 0;
    capsule(canvas, theme.border_color, 1, 0, 0, width, height);
    capsule(canvas, theme.background, 1, @floatFromInt(theme.border.left), @floatFromInt(theme.border.top), width - @as(f64, @floatFromInt(theme.border.left + theme.border.right)), height - @as(f64, @floatFromInt(theme.border.top + theme.border.bottom)));
    const opacity: f64 = if (muted) 0.5 else 1;
    const x: f64 = @floatFromInt(theme.border.left + theme.padding.left);
    const bar_x = x + 24 + 12 + @as(f64, @floatFromInt(theme.bar_margin.left));
    const bar_y = (height - @as(f64, @floatFromInt(theme.bar_height)) + @as(f64, @floatFromInt(theme.bar_margin.top - theme.bar_margin.bottom))) / 2;
    capsule(canvas, theme.track, opacity, bar_x, bar_y, @floatFromInt(theme.bar_width), @floatFromInt(theme.bar_height));
    capsule(canvas, theme.fill, opacity, bar_x, bar_y, @as(f64, @floatFromInt(theme.bar_width)) * level / 100, @floatFromInt(theme.bar_height));
    icon(.{ .target = target, .scale = canvas.scale, .origin = .{ .x = x, .y = (height - 24) / 2 } }, rgba(theme.foreground, opacity), kind, level, muted);
}

fn line(x0: f64, y0: f64, x1: f64, y1: f64) raster.Shape {
    return .{ .line = .{ .start = .{ .x = x0, .y = y0 }, .end = .{ .x = x1, .y = y1 } } };
}
fn icon(canvas: raster.Canvas, foreground: raster.Color, kind: Kind, percent: f64, muted: bool) void {
    switch (kind) {
        .brightness => {
            canvas.draw(&.{.{ .circle = .{ .center = .{ .x = 12, .y = 12 }, .radius = 4 } }}, foreground);
            var rays: [8]raster.Shape = undefined;
            for (&rays, 0..) |*ray, i| {
                const angle = @as(f64, @floatFromInt(i)) * std.math.pi / 4;
                ray.* = line(12 + @cos(angle) * 7, 12 + @sin(angle) * 7, 12 + @cos(angle) * 10, 12 + @sin(angle) * 10);
            }
            canvas.draw(&rays, foreground);
        },
        .microphone => {
            canvas.draw(&.{.{ .rounded = .{ .x = 8, .y = 2, .width = 8, .height = 12 } }}, foreground);
            canvas.draw(&.{ .{ .arc = .{ .center = .{ .x = 12, .y = 10 }, .radius = 7, .start = 0, .end = std.math.pi } }, line(12, 17, 12, 22), line(8, 22, 16, 22) }, foreground);
        },
        .volume => {
            canvas.draw(&.{.{ .polygon = &.{ .{ .x = 3, .y = 9 }, .{ .x = 7, .y = 9 }, .{ .x = 12, .y = 4 }, .{ .x = 12, .y = 20 }, .{ .x = 7, .y = 15 }, .{ .x = 3, .y = 15 } } }}, foreground);
            if (!muted and percent > 0) for ([_]f64{ 5, 8, 11 }, 0..) |radius, i| {
                if (i > 0 and percent < @as(f64, @floatFromInt(i)) * 33) break;
                canvas.draw(&.{.{ .arc = .{ .center = .{ .x = 11, .y = 12 }, .radius = radius, .start = -std.math.pi / 3.0, .end = std.math.pi / 3.0 } }}, foreground);
            };
        },
    }
    if (muted) canvas.draw(&.{line(3, 3, 21, 21)}, foreground);
}

test "Zig OSD has transparent corners, distinct progress, and muted feedback at both scales" {
    const theme: Theme = .{};
    for ([_]u32{ 1, 2 }) |scale| {
        const width = theme.width() * scale;
        const height = theme.height() * scale;
        const pixels = try std.testing.allocator.alloc(u32, width * height);
        defer std.testing.allocator.free(pixels);
        for ([_]bool{ false, true }) |muted| {
            @memset(pixels, 0);
            paint(.{ .pixels = pixels, .width = width, .height = height }, scale, theme, .volume, 50, muted);
            const row: usize = 25 * scale;
            try std.testing.expectEqual(@as(u32, 0), pixels[0]);
            const filled = pixels[row * width + 65 * scale];
            const empty = pixels[row * width + 195 * scale];
            try std.testing.expect((filled & 255) > (empty & 255));
            if (!muted) try std.testing.expectEqual(@as(u32, 0xffffffff), filled) else try std.testing.expect((filled & 255) < 255);
        }
    }
}

test "Zig OSD agrees with Cairo for every icon, level, mute state and scale" {
    const reference = struct {
        fn source(cr: *c.cairo_t, color: raster.Color, opacity: f64) void {
            c.cairo_set_source_rgba(cr, color.red, color.green, color.blue, color.alpha * opacity);
        }
        fn cairoCapsule(cr: *c.cairo_t, x: f64, y: f64, width: f64, height: f64) void {
            if (width <= 0 or height <= 0) return;
            const radius = @min(width, height) / 2;
            c.cairo_new_sub_path(cr);
            c.cairo_arc(cr, x + width - radius, y + radius, radius, -std.math.pi / 2.0, 0);
            c.cairo_arc(cr, x + width - radius, y + height - radius, radius, 0, std.math.pi / 2.0);
            c.cairo_arc(cr, x + radius, y + height - radius, radius, std.math.pi / 2.0, std.math.pi);
            c.cairo_arc(cr, x + radius, y + radius, radius, std.math.pi, 3 * std.math.pi / 2.0);
            c.cairo_close_path(cr);
            c.cairo_fill(cr);
        }
        fn draw(cr: *c.cairo_t, theme: Theme, kind: Kind, percent: f64, muted: bool, width: f64, height: f64) void {
            source(cr, theme.border_color, 1);
            cairoCapsule(cr, 0, 0, width, height);
            source(cr, theme.background, 1);
            cairoCapsule(cr, @floatFromInt(theme.border.left), @floatFromInt(theme.border.top), width - @as(f64, @floatFromInt(theme.border.left + theme.border.right)), height - @as(f64, @floatFromInt(theme.border.top + theme.border.bottom)));
            const opacity: f64 = if (muted) 0.5 else 1;
            const x: f64 = @floatFromInt(theme.border.left + theme.padding.left);
            const bar_x = x + 24 + 12 + @as(f64, @floatFromInt(theme.bar_margin.left));
            const bar_y = (height - @as(f64, @floatFromInt(theme.bar_height)) + @as(f64, @floatFromInt(theme.bar_margin.top - theme.bar_margin.bottom))) / 2;
            source(cr, theme.track, opacity);
            cairoCapsule(cr, bar_x, bar_y, @floatFromInt(theme.bar_width), @floatFromInt(theme.bar_height));
            source(cr, theme.fill, opacity);
            cairoCapsule(cr, bar_x, bar_y, @as(f64, @floatFromInt(theme.bar_width)) * std.math.clamp(percent, 0, 100) / 100, @floatFromInt(theme.bar_height));
            c.cairo_save(cr);
            defer c.cairo_restore(cr);
            c.cairo_translate(cr, x, (height - 24) / 2);
            source(cr, theme.foreground, opacity);
            c.cairo_set_line_width(cr, 2);
            c.cairo_set_line_cap(cr, 1);
            switch (kind) {
                .brightness => {
                    c.cairo_arc(cr, 12, 12, 4, 0, 2 * std.math.pi);
                    c.cairo_fill(cr);
                    for (0..8) |i| {
                        const angle = @as(f64, @floatFromInt(i)) * std.math.pi / 4;
                        c.cairo_move_to(cr, 12 + @cos(angle) * 7, 12 + @sin(angle) * 7);
                        c.cairo_line_to(cr, 12 + @cos(angle) * 10, 12 + @sin(angle) * 10);
                    }
                    c.cairo_stroke(cr);
                },
                .microphone => {
                    cairoCapsule(cr, 8, 2, 8, 12);
                    c.cairo_arc(cr, 12, 10, 7, 0, std.math.pi);
                    c.cairo_move_to(cr, 12, 17);
                    c.cairo_line_to(cr, 12, 22);
                    c.cairo_move_to(cr, 8, 22);
                    c.cairo_line_to(cr, 16, 22);
                    c.cairo_stroke(cr);
                },
                .volume => {
                    c.cairo_move_to(cr, 3, 9);
                    c.cairo_line_to(cr, 7, 9);
                    c.cairo_line_to(cr, 12, 4);
                    c.cairo_line_to(cr, 12, 20);
                    c.cairo_line_to(cr, 7, 15);
                    c.cairo_line_to(cr, 3, 15);
                    c.cairo_close_path(cr);
                    c.cairo_fill(cr);
                    if (!muted and percent > 0) for ([_]f64{ 5, 8, 11 }, 0..) |radius, i| {
                        if (i > 0 and percent < @as(f64, @floatFromInt(i)) * 33) break;
                        c.cairo_new_sub_path(cr);
                        c.cairo_arc(cr, 11, 12, radius, -std.math.pi / 3.0, std.math.pi / 3.0);
                        c.cairo_stroke(cr);
                    };
                },
            }
            if (muted) {
                c.cairo_move_to(cr, 3, 3);
                c.cairo_line_to(cr, 21, 21);
                c.cairo_stroke(cr);
            }
        }
    };
    const alternate: Theme = .{
        .background = .{ .red = 0.1, .green = 0.3, .blue = 0.2, .alpha = 0.6 },
        .foreground = .{ .red = 0.9, .green = 0.2, .blue = 0.7, .alpha = 0.8 },
        .fill = .{ .red = 0.1, .green = 0.8, .blue = 0.5, .alpha = 0.7 },
        .border = .{ .left = 2, .right = 3, .top = 2, .bottom = 1 },
        .bar_height = 9,
    };
    for ([_]Theme{ .{}, alternate }) |theme| for ([_]u32{ 1, 2, 3 }) |scale| {
        const width = theme.width() * scale;
        const height = theme.height() * scale;
        const image = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, @intCast(width), @intCast(height)).?;
        defer c.cairo_surface_destroy(image);
        c.cairo_surface_set_device_scale(image, @floatFromInt(scale), @floatFromInt(scale));
        const cr = c.cairo_create(image).?;
        defer c.cairo_destroy(cr);
        const actual = try std.testing.allocator.alloc(u32, width * height);
        defer std.testing.allocator.free(actual);
        for ([_]Kind{ .volume, .microphone, .brightness }) |kind| for ([_]f64{ 0, 50, 100 }) |percent| for ([_]bool{ false, true }) |muted| {
            @memset(actual, 0);
            paint(.{ .pixels = actual, .width = width, .height = height }, scale, theme, kind, percent, muted);
            c.cairo_set_operator(cr, c.CAIRO_OPERATOR_CLEAR);
            c.cairo_paint(cr);
            c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);
            reference.draw(cr, theme, kind, percent, muted, @floatFromInt(theme.width()), @floatFromInt(theme.height()));
            c.cairo_surface_flush(image);
            const expected: [*]const u32 = @ptrCast(@alignCast(c.cairo_image_surface_get_data(image)));
            const stride: usize = @intCast(@divTrunc(c.cairo_image_surface_get_stride(image), 4));
            var total: u64 = 0;
            var icon_total: u64 = 0;
            var icon_count: u64 = 0;
            const left: usize = @as(usize, @intCast(theme.border.left + theme.padding.left)) * scale;
            const top: usize = (theme.height() - 24) * scale / 2;
            for (0..height) |y| for (0..width) |x| {
                inline for (.{ 0, 8, 16, 24 }) |shift| {
                    const want: i32 = @intCast((expected[y * stride + x] >> shift) & 255);
                    const got: i32 = @intCast((actual[y * width + x] >> shift) & 255);
                    const difference = @abs(want - got);
                    total += difference;
                    if (x >= left and x < left + 24 * scale and y >= top and y < top + 24 * scale) {
                        icon_total += difference;
                        icon_count += 1;
                    }
                }
            };
            const mean = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(width * height * 4));
            const icon_mean = @as(f64, @floatFromInt(icon_total)) / @as(f64, @floatFromInt(icon_count));
            if (mean > 1.5 or icon_mean > 5) std.debug.print("OSD {s} {d}% muted={} scale={d}: mean={d}, icon={d}\n", .{ @tagName(kind), percent, muted, scale, mean, icon_mean });
            try std.testing.expect(mean <= 1.5);
            try std.testing.expect(icon_mean <= 5);
        };
    };
}
