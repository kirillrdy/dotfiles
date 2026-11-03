//! Native-endian ARGB shared-memory drawing, independent of Cairo and GTK.
const std = @import("std");

pub const Buffer = struct {
    pixels: []u32,
    width: u32,
    height: u32,
};

pub const Point = struct { x: f64, y: f64 };
pub const Color = struct { red: f64, green: f64, blue: f64, alpha: f64 = 1 };
pub const Region = struct { x: i32, y: i32, width: u32, height: u32 };

/// Composite a premultiplied ARGB source over a premultiplied destination.
pub fn over(destination: u32, source: u32) u32 {
    const remaining = 255 - (source >> 24);
    var result: u32 = 0;
    inline for (.{ 0, 8, 16, 24 }) |shift| {
        const channel = ((source >> shift) & 255) + (((destination >> shift) & 255) * remaining + 127) / 255;
        result |= @as(u32, @min(channel, 255)) << shift;
    }
    return result;
}
fn colorPixel(color: Color, coverage: f64) u32 {
    const alpha: u32 = @intFromFloat(@round(std.math.clamp(color.alpha, 0, 1) * coverage * 255));
    var result = alpha << 24;
    inline for (.{ 0, 8, 16 }, .{ color.blue, color.green, color.red }) |shift, channel| {
        const value: u32 = @intFromFloat(@round(std.math.clamp(channel, 0, 1) * @as(f64, @floatFromInt(alpha))));
        result |= value << shift;
    }
    return result;
}

/// Clip integer pixel rectangles, including source replacement for clear holes.
pub fn fill(target: Buffer, rect: Region, pixel_value: u32, operation: enum { source, over }) void {
    const x0: usize = @intCast(std.math.clamp(@as(i64, rect.x), 0, target.width));
    const y0: usize = @intCast(std.math.clamp(@as(i64, rect.y), 0, target.height));
    const x1: usize = @intCast(std.math.clamp(@as(i64, rect.x) + rect.width, 0, target.width));
    const y1: usize = @intCast(std.math.clamp(@as(i64, rect.y) + rect.height, 0, target.height));
    for (y0..y1) |y| {
        const row = target.pixels[y * target.width + x0 .. y * target.width + x1];
        if (operation == .source or pixel_value >> 24 == 255) @memset(row, pixel_value) else for (row) |*dest| dest.* = over(dest.*, pixel_value);
    }
}

/// Composite a grayscale mask, preserving clipping and premultiplied alpha.
pub fn mask(target: Buffer, rect: Region, coverage: []const u8, color: Color) void {
    std.debug.assert(coverage.len == @as(usize, rect.width) * rect.height);
    const x0: usize = @intCast(std.math.clamp(-@as(i64, rect.x), 0, rect.width));
    const y0: usize = @intCast(std.math.clamp(-@as(i64, rect.y), 0, rect.height));
    const x1: usize = @intCast(std.math.clamp(@as(i64, target.width) - rect.x, 0, rect.width));
    const y1: usize = @intCast(std.math.clamp(@as(i64, target.height) - rect.y, 0, rect.height));
    for (y0..y1) |y| for (x0..x1) |x| {
        const alpha = coverage[y * rect.width + x];
        if (alpha == 0) continue;
        const dest_x: usize = @intCast(@as(i64, rect.x) + @as(i64, @intCast(x)));
        const dest_y: usize = @intCast(@as(i64, rect.y) + @as(i64, @intCast(y)));
        const dest = &target.pixels[dest_y * target.width + dest_x];
        dest.* = over(dest.*, colorPixel(color, @as(f64, @floatFromInt(alpha)) / 255));
    };
}

test "rectangle replacement clears holes while masks clip and blend alpha" {
    var pixels: [8]u32 = @splat(0x12345678);
    const target: Buffer = .{ .pixels = pixels[1..7], .width = 3, .height = 2 };
    fill(target, .{ .x = -1, .y = -1, .width = 5, .height = 4 }, 0x80000000, .source);
    fill(target, .{ .x = 1, .y = 0, .width = 1, .height = 2 }, 0, .source);
    mask(target, .{ .x = -1, .y = -1, .width = 3, .height = 3 }, &.{ 0, 0, 0, 0, 255, 128, 0, 0, 0 }, .{ .red = 1, .green = 1, .blue = 1 });
    try std.testing.expectEqualSlices(u32, &.{ 0x12345678, 0xffffffff, 0x80808080, 0x80000000, 0x80000000, 0, 0x80000000, 0x12345678 }, &pixels);
    mask(target, .{ .x = 20, .y = 20, .width = 1, .height = 1 }, &.{255}, .{ .red = 1, .green = 0, .blue = 0 });
    try std.testing.expectEqual(@as(u32, 0x12345678), pixels[7]);
}
pub const Rect = struct { x: f64, y: f64, width: f64, height: f64 };
pub const Shape = union(enum) {
    rounded: Rect,
    rounded_rect: struct { rect: Rect, radius: f64 },
    rounded_stroke: struct { rect: Rect, radius: f64, width: f64 = 1 },
    circle: struct { center: Point, radius: f64 },
    line: struct { start: Point, end: Point, radius: f64 = 1 },
    /// Counterclockwise arc, with a sweep of at most pi and round caps.
    arc: struct { center: Point, radius: f64, start: f64, end: f64, stroke: f64 = 1 },
    polygon: []const Point,

    fn bounds(self: Shape) Rect {
        return switch (self) {
            .rounded => |r| r,
            .rounded_rect => |v| v.rect,
            .rounded_stroke => |v| .{ .x = v.rect.x - v.width / 2, .y = v.rect.y - v.width / 2, .width = v.rect.width + v.width, .height = v.rect.height + v.width },
            .circle => |v| .{ .x = v.center.x - v.radius, .y = v.center.y - v.radius, .width = 2 * v.radius, .height = 2 * v.radius },
            .arc => |v| .{ .x = v.center.x - v.radius - v.stroke, .y = v.center.y - v.radius - v.stroke, .width = 2 * (v.radius + v.stroke), .height = 2 * (v.radius + v.stroke) },
            .line => |v| .{ .x = @min(v.start.x, v.end.x) - v.radius, .y = @min(v.start.y, v.end.y) - v.radius, .width = @abs(v.end.x - v.start.x) + 2 * v.radius, .height = @abs(v.end.y - v.start.y) + 2 * v.radius },
            .polygon => |points| blk: {
                var low = points[0];
                var high = low;
                for (points[1..]) |p| {
                    low = .{ .x = @min(low.x, p.x), .y = @min(low.y, p.y) };
                    high = .{ .x = @max(high.x, p.x), .y = @max(high.y, p.y) };
                }
                break :blk .{ .x = low.x, .y = low.y, .width = high.x - low.x, .height = high.y - low.y };
            },
        };
    }
    fn distance(self: Shape, p: Point) f64 {
        return switch (self) {
            .rounded => |v| roundedDistance(v, @min(v.width, v.height) / 2, p),
            .rounded_rect => |v| roundedDistance(v.rect, v.radius, p),
            .rounded_stroke => |v| @abs(roundedDistance(v.rect, v.radius, p)) - v.width / 2,
            .circle => |v| length(p.x - v.center.x, p.y - v.center.y) - v.radius,
            .line => |v| segmentDistance(p, v.start, v.end) - v.radius,
            .arc => |v| blk: {
                const x = p.x - v.center.x;
                const y = p.y - v.center.y;
                const start: Point = .{ .x = @cos(v.start), .y = @sin(v.start) };
                const end: Point = .{ .x = @cos(v.end), .y = @sin(v.end) };
                // Within the arc's angular interval, the closest point is radial.
                if (start.x * y - start.y * x >= -0.0000001 and x * end.y - y * end.x >= -0.0000001)
                    break :blk @abs(length(x, y) - v.radius) - v.stroke;
                break :blk @min(length(x - start.x * v.radius, y - start.y * v.radius), length(x - end.x * v.radius, y - end.y * v.radius)) - v.stroke;
            },
            .polygon => |points| blk: {
                var inside = false;
                var nearest = std.math.inf(f64);
                var last = points[points.len - 1];
                for (points) |next| {
                    nearest = @min(nearest, segmentDistance(p, last, next));
                    if ((next.y > p.y) != (last.y > p.y) and p.x < (last.x - next.x) * (p.y - next.y) / (last.y - next.y) + next.x) inside = !inside;
                    last = next;
                }
                break :blk if (inside) -nearest else nearest;
            },
        };
    }
};

fn roundedDistance(rect: Rect, requested: f64, p: Point) f64 {
    const radius = @min(requested, @min(rect.width, rect.height) / 2);
    const x = @abs(p.x - rect.x - rect.width / 2) - rect.width / 2 + radius;
    const y = @abs(p.y - rect.y - rect.height / 2) - rect.height / 2 + radius;
    return length(@max(x, 0), @max(y, 0)) + @min(@max(x, y), 0) - radius;
}

fn length(x: f64, y: f64) f64 {
    return @sqrt(x * x + y * y);
}
fn segmentDistance(p: Point, start: Point, end: Point) f64 {
    const dx = end.x - start.x;
    const dy = end.y - start.y;
    const squared = dx * dx + dy * dy;
    const t = if (squared == 0) 0 else std.math.clamp(((p.x - start.x) * dx + (p.y - start.y) * dy) / squared, 0, 1);
    return length(p.x - start.x - t * dx, p.y - start.y - t * dy);
}

/// Antialiased shapes in logical coordinates, composited into premultiplied ARGB.
pub const Canvas = struct {
    target: Buffer,
    scale: f64,
    origin: Point = .{ .x = 0, .y = 0 },

    /// Shapes in one call form a single fill/stroke, including at intersections.
    pub fn draw(self: Canvas, shapes: []const Shape, color: Color) void {
        if (shapes.len == 0 or color.alpha <= 0) return;
        var bounds = shapes[0].bounds();
        for (shapes[1..]) |shape| {
            const next = shape.bounds();
            const right = @max(bounds.x + bounds.width, next.x + next.width);
            const bottom = @max(bounds.y + bounds.height, next.y + next.height);
            const x = @min(bounds.x, next.x);
            const y = @min(bounds.y, next.y);
            bounds = .{ .x = x, .y = y, .width = right - x, .height = bottom - y };
        }
        const width: f64 = @floatFromInt(self.target.width);
        const height: f64 = @floatFromInt(self.target.height);
        const x0: usize = @intFromFloat(std.math.clamp(@floor((bounds.x + self.origin.x) * self.scale - 1), 0, width));
        const y0: usize = @intFromFloat(std.math.clamp(@floor((bounds.y + self.origin.y) * self.scale - 1), 0, height));
        const x1: usize = @intFromFloat(std.math.clamp(@ceil((bounds.x + bounds.width + self.origin.x) * self.scale + 1), 0, width));
        const y1: usize = @intFromFloat(std.math.clamp(@ceil((bounds.y + bounds.height + self.origin.y) * self.scale + 1), 0, height));
        for (y0..y1) |y| for (x0..x1) |x| {
            const p: Point = .{ .x = (@as(f64, @floatFromInt(x)) + 0.5) / self.scale - self.origin.x, .y = (@as(f64, @floatFromInt(y)) + 0.5) / self.scale - self.origin.y };
            var distance = std.math.inf(f64);
            for (shapes) |shape| distance = @min(distance, shape.distance(p));
            const coverage = std.math.clamp(0.5 - distance * self.scale, 0, 1);
            if (coverage == 0) continue;
            const dest = &self.target.pixels[y * self.target.width + x];
            dest.* = over(dest.*, colorPixel(color, coverage));
        };
    }
};

test "shape strokes blend once at intersections and preserve premultiplied alpha" {
    var pixels: [16]u32 = @splat(0);
    const canvas: Canvas = .{ .target = .{ .pixels = &pixels, .width = 4, .height = 4 }, .scale = 1 };
    canvas.draw(&.{
        .{ .line = .{ .start = .{ .x = 0, .y = 2 }, .end = .{ .x = 4, .y = 2 } } },
        .{ .line = .{ .start = .{ .x = 2, .y = 0 }, .end = .{ .x = 2, .y = 4 } } },
    }, .{ .red = 1, .green = 0, .blue = 0, .alpha = 0.5 });
    try std.testing.expectEqual(@as(u32, 0x80800000), pixels[5]);
    canvas.draw(&.{.{ .circle = .{ .center = .{ .x = 2, .y = 2 }, .radius = 3 } }}, .{ .red = 0, .green = 0, .blue = 1, .alpha = 0.5 });
    try std.testing.expectEqual(@as(u32, 0xc0400080), pixels[5]);
    for (pixels) |value| {
        inline for (.{ 0, 8, 16 }) |shift| try std.testing.expect(((value >> shift) & 255) <= value >> 24);
    }
}

test "shape bounds clip offscreen drawing without touching adjacent memory" {
    var pixels: [6]u32 = @splat(0x12345678);
    const canvas: Canvas = .{ .target = .{ .pixels = pixels[1..5], .width = 2, .height = 2 }, .scale = 2 };
    canvas.draw(&.{.{ .rounded = .{ .x = -10, .y = -10, .width = 30, .height = 30 } }}, .{ .red = 1, .green = 1, .blue = 1 });
    try std.testing.expectEqualSlices(u32, &.{ 0x12345678, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0x12345678 }, &pixels);
    canvas.draw(&.{.{ .circle = .{ .center = .{ .x = -20, .y = -20 }, .radius = 1 } }}, .{ .red = 0, .green = 0, .blue = 0 });
    try std.testing.expectEqual(@as(u32, 0xffffffff), pixels[1]);
}

test "combined shape bounds retain every direction regardless of draw order" {
    var pixels: [100]u32 = @splat(0);
    const canvas: Canvas = .{ .target = .{ .pixels = &pixels, .width = 10, .height = 10 }, .scale = 1 };
    var shapes = [_]Shape{
        .{ .circle = .{ .center = .{ .x = 8.5, .y = 8.5 }, .radius = 0.75 } },
        .{ .circle = .{ .center = .{ .x = 1.5, .y = 1.5 }, .radius = 0.75 } },
    };
    for (0..2) |_| {
        @memset(&pixels, 0);
        canvas.draw(&shapes, .{ .red = 1, .green = 1, .blue = 1 });
        try std.testing.expectEqual(@as(u32, 0xffffffff), pixels[11]);
        try std.testing.expectEqual(@as(u32, 0xffffffff), pixels[88]);
        std.mem.swap(Shape, &shapes[0], &shapes[1]);
    }
}

/// Byte RGB/RGBA or native-endian premultiplied ARGB/XRGB, with row padding.
pub const Image = struct {
    pixels: []const u8,
    width: u32,
    height: u32,
    stride: usize,
    format: enum { rgb, rgba, argb, xrgb },

    fn bytesPerPixel(self: Image) usize {
        return if (self.format == .rgb) 3 else 4;
    }
    fn validate(self: Image) !void {
        if (self.width == 0 or self.height == 0) return error.InvalidImage;
        const row_size = try std.math.mul(usize, self.width, self.bytesPerPixel());
        const required = try std.math.add(usize, try std.math.mul(usize, self.height - 1, self.stride), row_size);
        if (self.stride < row_size or self.pixels.len < required) return error.InvalidImage;
    }
};

/// The 24-logical-pixel selection cursor at an integer Wayland buffer scale.
pub fn crosshair(pixels: []u32, scale: u32) void {
    std.debug.assert(scale >= 1 and scale <= 8);
    const size = 24 * scale;
    std.debug.assert(pixels.len == size * size);
    @memset(pixels, 0);
    for ([_]u32{ 2, 1 }, 0..) |half_width, layer| {
        const color: u32 = if (layer == 0) 0xff000000 else 0xffffffff;
        const low = (12 - half_width) * scale;
        const high = (12 + half_width) * scale;
        for (2 * scale..22 * scale) |axis| for (low..high) |cross| {
            pixels[axis * size + cross] = color;
            pixels[cross * size + axis] = color;
        };
    }
}

const Sample = struct {
    first: usize,
    second: usize,
    fraction: u32,

    fn at(coordinate: f64, extent: u32) Sample {
        const position = std.math.clamp(coordinate, 0, @as(f64, @floatFromInt(extent - 1)));
        const first: usize = @intFromFloat(position);
        return .{
            .first = first,
            .second = @min(first + 1, extent - 1),
            .fraction = @intFromFloat((position - @as(f64, @floatFromInt(first))) * 256),
        };
    }
};

fn pixel(image: Image, x: usize, y: usize) [4]u32 {
    const offset = y * image.stride + x * image.bytesPerPixel();
    if (image.format == .argb or image.format == .xrgb) {
        const word = std.mem.readInt(u32, image.pixels[offset..][0..4], @import("builtin").cpu.arch.endian());
        return .{ (word >> 16) & 255, (word >> 8) & 255, word & 255, if (image.format == .xrgb) 255 else word >> 24 };
    }
    const rgb = image.pixels[offset..][0..3];
    const alpha: u32 = if (image.format == .rgba) image.pixels[offset + 3] else 255;
    // Premultiply before interpolation to keep invisible RGB out of the edges.
    return .{ (@as(u32, rgb[0]) * alpha + 127) / 255, (@as(u32, rgb[1]) * alpha + 127) / 255, (@as(u32, rgb[2]) * alpha + 127) / 255, alpha };
}

fn transparentPixel(image: Image, x: i64, y: i64) [4]u32 {
    if (x < 0 or y < 0 or x >= image.width or y >= image.height) return @splat(0);
    return pixel(image, @intCast(x), @intCast(y));
}

fn sampleImage(image: Image, x: f64, y: f64) u32 {
    if (x < -1 or y < -1 or x >= @as(f64, @floatFromInt(image.width)) or y >= @as(f64, @floatFromInt(image.height))) return 0;
    const sx = @floor(x);
    const sy = @floor(y);
    const ix: i64 = @intFromFloat(sx);
    const iy: i64 = @intFromFloat(sy);
    const fx: u32 = @intFromFloat((x - sx) * 256);
    const fy: u32 = @intFromFloat((y - sy) * 256);
    const a = transparentPixel(image, ix, iy);
    const b = transparentPixel(image, ix + 1, iy);
    const c = transparentPixel(image, ix, iy + 1);
    const d = transparentPixel(image, ix + 1, iy + 1);
    var result: u32 = 0;
    inline for (.{ 16, 8, 0, 24 }, 0..) |shift, i| {
        const top = a[i] * (256 - fx) + b[i] * fx;
        const bottom = c[i] * (256 - fx) + d[i] * fx;
        const value = (top * (256 - fy) + bottom * fy + 32768) >> 16;
        result |= value << shift;
    }
    return result;
}

const FilterAxis = struct {
    center: f64,
    step: f64,
    area: bool,
    first: i64,
    last: i64,

    fn init(center: f64, step: f64) FilterAxis {
        // Cairo's GOOD filter switches to area averaging below 3/4 scale.
        const area = step > 4.0 / 3.0;
        const start = if (area) center + 0.5 - step / 2 else @floor(center);
        const end = if (area) center + 0.5 + step / 2 else start + 2;
        return .{ .center = center, .step = step, .area = area, .first = @intFromFloat(@floor(start)), .last = @intFromFloat(@ceil(end)) };
    }
    fn weight(self: FilterAxis, position: usize) f64 {
        const index: f64 = @floatFromInt(position);
        if (!self.area) return @max(0, 1 - @abs(index - self.center));
        const start = self.center + 0.5 - self.step / 2;
        const end = self.center + 0.5 + self.step / 2;
        return @max(0, @min(index + 1, end) - @max(index, start)) / self.step;
    }
};

fn filteredImage(image: Image, x: f64, y: f64, step_x: f64, step_y: f64) u32 {
    if (step_x <= 4.0 / 3.0 and step_y <= 4.0 / 3.0) return sampleImage(image, x, y);
    const horizontal = FilterAxis.init(x, step_x);
    const vertical = FilterAxis.init(y, step_y);
    const x0: usize = @intCast(std.math.clamp(horizontal.first, 0, image.width));
    const x1: usize = @intCast(std.math.clamp(horizontal.last, 0, image.width));
    const y0: usize = @intCast(std.math.clamp(vertical.first, 0, image.height));
    const y1: usize = @intCast(std.math.clamp(vertical.last, 0, image.height));
    var sum: [4]f64 = @splat(0);
    for (y0..y1) |sy| {
        const wy = vertical.weight(sy);
        for (x0..x1) |sx| {
            const weight = wy * horizontal.weight(sx);
            const value = pixel(image, sx, sy);
            for (&sum, value) |*channel, sample| channel.* += @as(f64, @floatFromInt(sample)) * weight;
        }
    }
    var result: u32 = 0;
    inline for (.{ 16, 8, 0, 24 }, 0..) |shift, i| {
        const value: u32 = @intFromFloat(@round(std.math.clamp(sum[i], 0, 255)));
        result |= value << shift;
    }
    return result;
}

/// Scale and composite with bilinear magnification and area minification.
/// Source edges are transparent, including under partially covered filters.
/// Destination coordinates and the optional clip are in physical pixels.
pub fn blit(target: Buffer, image: Image, destination: Rect, clip: ?Region) !void {
    try image.validate();
    if (!std.math.isFinite(destination.x) or !std.math.isFinite(destination.y) or !std.math.isFinite(destination.width) or !std.math.isFinite(destination.height) or destination.width < 0.001 or destination.height < 0.001) return error.InvalidImage;
    if (target.pixels.len < try std.math.mul(usize, target.width, target.height)) return error.InvalidImage;
    const width: f64 = @floatFromInt(target.width);
    const height: f64 = @floatFromInt(target.height);
    var x0: usize = @intFromFloat(std.math.clamp(@floor(destination.x), 0, width));
    var y0: usize = @intFromFloat(std.math.clamp(@floor(destination.y), 0, height));
    var x1: usize = @intFromFloat(std.math.clamp(@ceil(destination.x + destination.width), 0, width));
    var y1: usize = @intFromFloat(std.math.clamp(@ceil(destination.y + destination.height), 0, height));
    if (clip) |rect| {
        x0 = @max(x0, @as(usize, @intCast(std.math.clamp(@as(i64, rect.x), 0, target.width))));
        y0 = @max(y0, @as(usize, @intCast(std.math.clamp(@as(i64, rect.y), 0, target.height))));
        x1 = @min(x1, @as(usize, @intCast(std.math.clamp(@as(i64, rect.x) + rect.width, 0, target.width))));
        y1 = @min(y1, @as(usize, @intCast(std.math.clamp(@as(i64, rect.y) + rect.height, 0, target.height))));
    }
    if (x1 <= x0 or y1 <= y0) return;
    const step_x = @as(f64, @floatFromInt(image.width)) / destination.width;
    const step_y = @as(f64, @floatFromInt(image.height)) / destination.height;
    for (y0..y1) |y| for (x0..x1) |x| {
        const sx = (@as(f64, @floatFromInt(x)) + 0.5 - destination.x) * step_x - 0.5;
        const sy = (@as(f64, @floatFromInt(y)) + 0.5 - destination.y) * step_y - 0.5;
        const dest = &target.pixels[y * target.width + x];
        dest.* = over(dest.*, filteredImage(image, sx, sy, step_x, step_y));
    };
}

test "image compositing preserves premultiplied alpha and ignores unused XRGB bits" {
    var pixels: [1]u32 = .{0xff000000};
    const target: Buffer = .{ .pixels = &pixels, .width = 1, .height = 1 };
    const rect: Rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 };
    try blit(target, .{ .pixels = &.{ 255, 0, 0, 128 }, .width = 1, .height = 1, .stride = 4, .format = .rgba }, rect, null);
    try std.testing.expectEqual(@as(u32, 0xff800000), pixels[0]);
    var word = [_]u32{0x80800000};
    pixels[0] = 0xff000000;
    try blit(target, .{ .pixels = std.mem.sliceAsBytes(&word), .width = 1, .height = 1, .stride = 4, .format = .argb }, rect, null);
    try std.testing.expectEqual(@as(u32, 0xff800000), pixels[0]);
    word[0] = 0x00112233;
    try blit(target, .{ .pixels = std.mem.sliceAsBytes(&word), .width = 1, .height = 1, .stride = 4, .format = .xrgb }, rect, null);
    try std.testing.expectEqual(@as(u32, 0xff112233), pixels[0]);
}

test "image compositing respects destination clips and transparent source edges" {
    var pixels: [3]u32 = @splat(0xff000000);
    const target: Buffer = .{ .pixels = &pixels, .width = 3, .height = 1 };
    const image: Image = .{ .pixels = &.{ 255, 0, 0 }, .width = 1, .height = 1, .stride = 3, .format = .rgb };
    try blit(target, image, .{ .x = 0, .y = 0, .width = 3, .height = 1 }, .{ .x = 1, .y = 0, .width = 1, .height = 1 });
    try std.testing.expectEqualSlices(u32, &.{ 0xff000000, 0xffff0000, 0xff000000 }, &pixels);
    try blit(target, image, .{ .x = 10, .y = 0, .width = 3, .height = 1 }, null);
    try std.testing.expectEqual(@as(u32, 0xff000000), pixels[2]);
    var scaled: [4]u32 = @splat(0);
    try blit(.{ .pixels = &scaled, .width = 2, .height = 2 }, image, .{ .x = 0, .y = 0, .width = 2, .height = 2 }, null);
    try std.testing.expectEqual(@as(u32, 0x8f8f0000), scaled[0]);
}

/// Center-crop to fill the physical buffer, bilinearly sample with padded edges,
/// and composite over opaque black. Physical dimensions include output scaling.
pub fn cover(target: Buffer, image: Image) !void {
    try image.validate();
    if (target.width == 0 or target.height == 0) return error.InvalidImage;
    const size = try std.math.mul(usize, target.width, target.height);
    if (target.pixels.len < size) return error.InvalidImage;
    const iw: f64 = @floatFromInt(image.width);
    const ih: f64 = @floatFromInt(image.height);
    const width: f64 = @floatFromInt(target.width);
    const height: f64 = @floatFromInt(target.height);
    const step = @min(iw / width, ih / height);
    const start_x = (iw - width * step) / 2 + step / 2 - 0.5;
    const start_y = (ih - height * step) / 2 + step / 2 - 0.5;
    for (0..target.height) |y| {
        const sy = Sample.at(start_y + @as(f64, @floatFromInt(y)) * step, image.height);
        for (0..target.width) |x| {
            const sx = Sample.at(start_x + @as(f64, @floatFromInt(x)) * step, image.width);
            const top_left = pixel(image, sx.first, sy.first);
            const top_right = pixel(image, sx.second, sy.first);
            const bottom_left = pixel(image, sx.first, sy.second);
            const bottom_right = pixel(image, sx.second, sy.second);
            var rgb: [3]u32 = undefined;
            for (&rgb, 0..) |*channel, i| {
                const top = top_left[i] * (256 - sx.fraction) + top_right[i] * sx.fraction;
                const bottom = bottom_left[i] * (256 - sx.fraction) + bottom_right[i] * sx.fraction;
                channel.* = (top * (256 - sy.fraction) + bottom * sy.fraction + 32768) >> 16;
            }
            target.pixels[y * target.width + x] = 0xff000000 | (rgb[0] << 16) | (rgb[1] << 8) | rgb[2];
        }
    }
}

test "bilinear fill premultiplies alpha before sampling and pads source edges" {
    const image: Image = .{ .pixels = &.{ 255, 0, 0, 255, 0, 255, 0, 0 }, .width = 2, .height = 1, .stride = 8, .format = .rgba };
    var pixels: [8]u32 = undefined;
    try cover(.{ .pixels = &pixels, .width = 4, .height = 2 }, image);
    try std.testing.expectEqualSlices(u32, &.{ 0xffff0000, 0xffbf0000, 0xff400000, 0xff000000 }, pixels[0..4]);
    try std.testing.expectEqualSlices(u32, pixels[0..4], pixels[4..8]);
}

test "bilinear fill rejects invalid source and destination bounds" {
    var pixels: [1]u32 = undefined;
    const target: Buffer = .{ .pixels = &pixels, .width = 1, .height = 1 };
    var image: Image = .{ .pixels = &.{ 1, 2, 3 }, .width = 1, .height = 1, .stride = 3, .format = .rgb };
    try cover(target, image);
    try std.testing.expectEqual(@as(u32, 0xff010203), pixels[0]);
    image.stride = 2;
    try std.testing.expectError(error.InvalidImage, cover(target, image));
    image.stride = 3;
    image.pixels = &.{ 1, 2 };
    try std.testing.expectError(error.InvalidImage, cover(target, image));
    image.pixels = &.{ 1, 2, 3 };
    try std.testing.expectError(error.InvalidImage, cover(.{ .pixels = &pixels, .width = 2, .height = 1 }, image));
    image.width = 0;
    try std.testing.expectError(error.InvalidImage, cover(target, image));
}
