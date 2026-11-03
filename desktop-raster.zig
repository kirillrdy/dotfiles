//! Native-endian ARGB shared-memory drawing, independent of Cairo and GTK.
const std = @import("std");

pub const Buffer = struct {
    pixels: []u32,
    width: u32,
    height: u32,
};

pub const Point = struct { x: f64, y: f64 };
pub const Color = struct { red: f64, green: f64, blue: f64, alpha: f64 = 1 };
pub const Rect = struct { x: f64, y: f64, width: f64, height: f64 };
pub const Shape = union(enum) {
    rounded: Rect,
    circle: struct { center: Point, radius: f64 },
    line: struct { start: Point, end: Point, radius: f64 = 1 },
    /// Counterclockwise arc, with a sweep of at most pi and round caps.
    arc: struct { center: Point, radius: f64, start: f64, end: f64, stroke: f64 = 1 },
    polygon: []const Point,

    fn bounds(self: Shape) Rect {
        return switch (self) {
            .rounded => |r| r,
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
            .rounded => |v| blk: {
                const radius = @min(v.width, v.height) / 2;
                const x = @abs(p.x - v.x - v.width / 2) - v.width / 2 + radius;
                const y = @abs(p.y - v.y - v.height / 2) - v.height / 2 + radius;
                break :blk length(@max(x, 0), @max(y, 0)) + @min(@max(x, y), 0) - radius;
            },
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
            const alpha: u32 = @intFromFloat(@round(std.math.clamp(color.alpha, 0, 1) * coverage * 255));
            if (alpha == 0) continue;
            const dest = &self.target.pixels[y * self.target.width + x];
            var result: u32 = 0;
            inline for (.{ 0, 8, 16, 24 }, .{ color.blue, color.green, color.red, @as(f64, 1) }) |shift, channel| {
                const source: u32 = @intFromFloat(@round(std.math.clamp(channel, 0, 1) * @as(f64, @floatFromInt(alpha))));
                const value = source + (((dest.* >> shift) & 255) * (255 - alpha) + 127) / 255;
                result |= @as(u32, @min(value, 255)) << shift;
            }
            dest.* = result;
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

/// RGB or straight-alpha RGBA, with optional padding between rows.
pub const Image = struct {
    pixels: []const u8,
    width: u32,
    height: u32,
    stride: usize,
    channels: enum(u3) { rgb = 3, rgba = 4 },
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

fn pixel(image: Image, x: usize, y: usize) [3]u32 {
    const offset = y * image.stride + x * @backingInt(image.channels);
    const rgb = image.pixels[offset..][0..3];
    const alpha: u32 = if (image.channels == .rgba) image.pixels[offset + 3] else 255;
    // Premultiply before interpolation to keep invisible RGB out of the edges.
    return .{ (@as(u32, rgb[0]) * alpha + 127) / 255, (@as(u32, rgb[1]) * alpha + 127) / 255, (@as(u32, rgb[2]) * alpha + 127) / 255 };
}

/// Center-crop to fill the physical buffer, bilinearly sample with padded edges,
/// and composite over opaque black. Physical dimensions include output scaling.
pub fn cover(target: Buffer, image: Image) !void {
    if (image.width == 0 or image.height == 0 or target.width == 0 or target.height == 0) return error.InvalidImage;
    const row_size = try std.math.mul(usize, image.width, @backingInt(image.channels));
    const required = try std.math.add(usize, try std.math.mul(usize, image.height - 1, image.stride), row_size);
    const size = try std.math.mul(usize, target.width, target.height);
    if (image.stride < row_size or image.pixels.len < required or target.pixels.len < size) return error.InvalidImage;
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
    const image: Image = .{ .pixels = &.{ 255, 0, 0, 255, 0, 255, 0, 0 }, .width = 2, .height = 1, .stride = 8, .channels = .rgba };
    var pixels: [8]u32 = undefined;
    try cover(.{ .pixels = &pixels, .width = 4, .height = 2 }, image);
    try std.testing.expectEqualSlices(u32, &.{ 0xffff0000, 0xffbf0000, 0xff400000, 0xff000000 }, pixels[0..4]);
    try std.testing.expectEqualSlices(u32, pixels[0..4], pixels[4..8]);
}

test "bilinear fill rejects invalid source and destination bounds" {
    var pixels: [1]u32 = undefined;
    const target: Buffer = .{ .pixels = &pixels, .width = 1, .height = 1 };
    var image: Image = .{ .pixels = &.{ 1, 2, 3 }, .width = 1, .height = 1, .stride = 3, .channels = .rgb };
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
