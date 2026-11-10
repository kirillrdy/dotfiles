//! Activities pixels; window hosting, discovery and interaction live elsewhere.
const raster = @import("desktop-raster.zig");
const Rect = raster.Rect;
const Canvas = raster.Canvas;

fn physical(canvas: Canvas, rect: Rect) Rect {
    return .{ .x = (rect.x + canvas.origin.x) * canvas.scale, .y = (rect.y + canvas.origin.y) * canvas.scale, .width = rect.width * canvas.scale, .height = rect.height * canvas.scale };
}

fn image(canvas: Canvas, source: raster.Image, rect: Rect, clip: ?Rect, radius: f64, opacity: f64) void {
    raster.blitWithOptions(canvas.target, source, physical(canvas, rect), .{
        .shape = if (clip) |value| physical(canvas, value).shape(radius * canvas.scale) else null,
        .opacity = opacity,
    }) catch {};
}

pub fn miniature(canvas: Canvas, source: ?raster.Image, rect: Rect, clip: Rect) void {
    if (source) |pixels| image(canvas, pixels, rect, clip, 0, 1) else {
        const x = @max(rect.x, clip.x);
        const y = @max(rect.y, clip.y);
        const right = @min(rect.x + rect.width, clip.x + clip.width);
        const bottom = @min(rect.y + rect.height, clip.y + clip.height);
        if (right > x and bottom > y) canvas.draw(&.{(Rect{ .x = x, .y = y, .width = right - x, .height = bottom - y }).shape(0)}, .{ .red = 0.3, .green = 0.3, .blue = 0.33 });
    }
}

pub fn workspace(canvas: Canvas, rect: Rect, wallpaper: ?raster.Image) void {
    canvas.draw(&.{rect.shape(30)}, .{ .red = 0.015, .green = 0.235, .blue = 0.53 });
    if (wallpaper) |pixels| {
        const iw: f64 = @floatFromInt(pixels.width);
        const ih: f64 = @floatFromInt(pixels.height);
        const scale = @max(rect.width / iw, rect.height / ih);
        image(canvas, pixels, .{ .x = rect.x + (rect.width - iw * scale) / 2, .y = rect.y + (rect.height - ih * scale) / 2, .width = iw * scale, .height = ih * scale }, rect, 30, 1);
    }
}

pub fn window(canvas: Canvas, rect: Rect, source: ?raster.Image, icon: ?raster.Image, hovered: bool, ease: f64) void {
    canvas.draw(&.{(Rect{ .x = rect.x - 3, .y = rect.y - 2, .width = rect.width + 6, .height = rect.height + 8 }).shape(9)}, raster.Color.rgb(0, 0.3));
    if (source) |pixels| image(canvas, pixels, rect, rect, 8, 1) else canvas.draw(&.{rect.shape(8)}, .{ .red = 0.3, .green = 0.3, .blue = 0.33 });
    if (hovered) {
        canvas.draw(&.{rect.stroke(8, 2)}, raster.Color.rgb(0xffffff, 1));
        const x = rect.x + rect.width;
        canvas.draw(&.{.{ .circle = .{ .center = .{ .x = x, .y = rect.y }, .radius = 16 } }}, .{ .red = 0.3, .green = 0.3, .blue = 0.33 });
        canvas.draw(&.{
            .{ .line = .{ .start = .{ .x = x - 4, .y = rect.y - 4 }, .end = .{ .x = x + 4, .y = rect.y + 4 }, .radius = 1 } },
            .{ .line = .{ .start = .{ .x = x + 4, .y = rect.y - 4 }, .end = .{ .x = x - 4, .y = rect.y + 4 }, .radius = 1 } },
        }, raster.Color.rgb(0xffffff, 1));
    }
    if (icon) |pixels| {
        const rect_icon: Rect = .{ .x = rect.x + rect.width / 2 - 32, .y = rect.y + rect.height - 44, .width = 64, .height = 64 };
        image(canvas, pixels, rect_icon, null, 0, ease);
    }
}
