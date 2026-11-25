//! Native-endian ARGB shared-memory drawing, independent of Cairo and GTK.
const std = @import("std");
const vec = @import("desktop-path.zig");

pub const Buffer = struct {
    pixels: []u32,
    width: u32,
    height: u32,
};

pub const Point = struct { x: f64, y: f64 };
pub const Color = struct {
    red: f64,
    green: f64,
    blue: f64,
    alpha: f64 = 1,

    pub fn rgb(value: u32, alpha: f64) Color {
        return .{
            .red = @as(f64, @floatFromInt((value >> 16) & 255)) / 255,
            .green = @as(f64, @floatFromInt((value >> 8) & 255)) / 255,
            .blue = @as(f64, @floatFromInt(value & 255)) / 255,
            .alpha = alpha,
        };
    }
};
pub fn hex(value: u32) Color {
    return Color.rgb(value, 1);
}
pub const Region = struct { x: i32, y: i32, width: u32, height: u32 };
/// An integer rectangle in logical pixels, as reported for text-input carets.
pub const IntRect = struct { x: c_int = 0, y: c_int = 0, width: c_int = 0, height: c_int = 0 };

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
pub fn colorPixel(color: Color, coverage: f64) u32 {
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
pub const Rect = struct {
    x: f64 = 0,
    y: f64 = 0,
    width: f64 = 0,
    height: f64 = 0,

    pub fn contains(self: Rect, x: f64, y: f64) bool {
        return x >= self.x and y >= self.y and x < self.x + self.width and y < self.y + self.height;
    }
    pub fn shape(self: Rect, radius: f64) Shape {
        return .{ .rounded_rect = .{ .rect = self, .radius = radius } };
    }
    pub fn stroke(self: Rect, radius: f64, width: f64) Shape {
        return .{ .rounded_stroke = .{ .rect = self, .radius = radius, .width = width } };
    }
};
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
    pub fn distance(self: Shape, p: Point) f64 {
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
    return (if (x > 0 and y > 0) length(x, y) else @max(x, y)) - radius;
}

const ScanlineSpan = struct {
    outer_x0: usize,
    inner_x0: usize,
    inner_x1: usize,
    outer_x1: usize,
};

/// Exact outer (coverage > 0) and inner (coverage == 1) pixel column ranges for a rounded rect on scanline `py`.
fn roundedScanlineSpan(cx: f64, cy: f64, half_w: f64, half_h: f64, rad: f64, margin: f64, py: f64, origin_x: f64, scale: f64, clip_x0: usize, clip_x1: usize) ?ScanlineSpan {
    const dy = @abs(py - cy) - half_h + rad;
    const outer_r = rad + margin;
    if (dy >= outer_r) return null;
    const outer_half = if (dy <= 0) half_w + margin else half_w - rad + @sqrt(@max(0, outer_r * outer_r - dy * dy));
    const max_f: f64 = @floatFromInt(clip_x1);
    const outer_x0: usize = @max(clip_x0, @as(usize, @intFromFloat(std.math.clamp(@floor((cx - outer_half + origin_x) * scale), 0, max_f))));
    const outer_x1: usize = @min(clip_x1, @as(usize, @intFromFloat(std.math.clamp(@ceil((cx + outer_half + origin_x) * scale), 0, max_f))));
    if (outer_x1 <= outer_x0) return null;
    const inner_r = rad - margin;
    const inner_half: f64 = if (dy <= -margin)
        half_w - margin
    else if (inner_r > 0 and dy < inner_r)
        half_w - rad + (if (dy <= 0) inner_r else @sqrt(@max(0, inner_r * inner_r - dy * dy)))
    else
        -1;
    if (inner_half <= 0) return .{ .outer_x0 = outer_x0, .inner_x0 = outer_x1, .inner_x1 = outer_x1, .outer_x1 = outer_x1 };
    // Pixel x has center (x + 0.5) / scale - origin_x; require center strictly inside [cx - inner_half, cx + inner_half].
    const inner_x0: usize = @min(outer_x1, @max(outer_x0, @as(usize, @intFromFloat(std.math.clamp(@ceil((cx - inner_half + origin_x) * scale - 0.5), 0, max_f)))));
    const inner_x1: usize = @min(outer_x1, @max(inner_x0, @as(usize, @intFromFloat(std.math.clamp(@floor((cx + inner_half + origin_x) * scale - 0.5) + 1, 0, max_f)))));
    return .{ .outer_x0 = outer_x0, .inner_x0 = inner_x0, .inner_x1 = inner_x1, .outer_x1 = outer_x1 };
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
        const solid = colorPixel(color, 1);
        if (solid == 0) return;
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
        if (shapes.len == 1) switch (shapes[0]) {
            .polygon => |pts| if (pts.len <= 256) {
                self.drawPolygon(pts, color, solid, x0, y0, x1, y1);
                return;
            },
            .rounded => |r| {
                self.drawRoundedRect(r, @min(r.width, r.height) / 2, color, solid, x0, y0, x1, y1, null);
                return;
            },
            .rounded_rect => |v| {
                self.drawRoundedRect(v.rect, v.radius, color, solid, x0, y0, x1, y1, null);
                return;
            },
            .circle => |v| {
                self.drawRoundedRect(.{ .x = v.center.x - v.radius, .y = v.center.y - v.radius, .width = 2 * v.radius, .height = 2 * v.radius }, v.radius, color, solid, x0, y0, x1, y1, null);
                return;
            },
            .rounded_stroke => |v| {
                self.drawRoundedStroke(v.rect, v.radius, v.width, color, solid, x0, y0, x1, y1);
                return;
            },
            else => {},
        };
        for (y0..y1) |y| for (x0..x1) |x| {
            const p: Point = .{ .x = (@as(f64, @floatFromInt(x)) + 0.5) / self.scale - self.origin.x, .y = (@as(f64, @floatFromInt(y)) + 0.5) / self.scale - self.origin.y };
            var distance = std.math.inf(f64);
            for (shapes) |shape| distance = @min(distance, shape.distance(p));
            const coverage = std.math.clamp(0.5 - distance * self.scale, 0, 1);
            if (coverage == 0) continue;
            const dest = &self.target.pixels[y * self.target.width + x];
            dest.* = if (coverage >= 1) (if (solid >> 24 == 255) solid else over(dest.*, solid)) else over(dest.*, colorPixel(color, coverage));
        };
    }

    /// Draw a rounded rectangle, optionally skipping pixels strictly inside `occlude`
    /// (for shadows painted beneath an opaque rounded card).
    pub fn drawRoundedExcluded(self: Canvas, rect: Rect, requested_radius: f64, color: Color, occlude: struct { rect: Rect, radius: f64 }) void {
        if (color.alpha <= 0 or rect.width <= 0 or rect.height <= 0) return;
        const solid = colorPixel(color, 1);
        if (solid == 0) return;
        const width: f64 = @floatFromInt(self.target.width);
        const height: f64 = @floatFromInt(self.target.height);
        const x0: usize = @intFromFloat(std.math.clamp(@floor((rect.x + self.origin.x) * self.scale - 1), 0, width));
        const y0: usize = @intFromFloat(std.math.clamp(@floor((rect.y + self.origin.y) * self.scale - 1), 0, height));
        const x1: usize = @intFromFloat(std.math.clamp(@ceil((rect.x + rect.width + self.origin.x) * self.scale + 1), 0, width));
        const y1: usize = @intFromFloat(std.math.clamp(@ceil((rect.y + rect.height + self.origin.y) * self.scale + 1), 0, height));
        self.drawRoundedRect(rect, requested_radius, color, solid, x0, y0, x1, y1, .{ .rect = occlude.rect, .radius = occlude.radius });
    }

    fn drawRoundedRect(self: Canvas, rect: Rect, requested_radius: f64, color: Color, solid: u32, x0: usize, y0: usize, x1: usize, y1: usize, occlude: ?struct { rect: Rect, radius: f64 }) void {
        const rad = @max(0, @min(requested_radius, @min(rect.width, rect.height) / 2));
        const margin = 0.5 / self.scale;
        const cx = rect.x + rect.width / 2;
        const cy = rect.y + rect.height / 2;
        const half_w = rect.width / 2;
        const half_h = rect.height / 2;
        const occ_rad = if (occlude) |o| @max(0, @min(o.radius, @min(o.rect.width, o.rect.height) / 2)) else 0;
        for (y0..y1) |y| {
            const py = (@as(f64, @floatFromInt(y)) + 0.5) / self.scale - self.origin.y;
            const span = roundedScanlineSpan(cx, cy, half_w, half_h, rad, margin, py, self.origin.x, self.scale, x0, x1) orelse continue;
            const row = self.target.pixels[y * self.target.width ..];
            // Left antialiased fringe
            for (span.outer_x0..span.inner_x0) |x| {
                const px = (@as(f64, @floatFromInt(x)) + 0.5) / self.scale - self.origin.x;
                const cov = std.math.clamp(0.5 - roundedDistance(rect, rad, .{ .x = px, .y = py }) * self.scale, 0, 1);
                if (cov > 0) row[x] = if (cov >= 1) (if (solid >> 24 == 255) solid else over(row[x], solid)) else over(row[x], colorPixel(color, cov));
            }
            // Full-coverage interior, optionally split around an opaque occluder
            if (span.inner_x1 > span.inner_x0) {
                if (occlude) |o| {
                    if (roundedScanlineSpan(o.rect.x + o.rect.width / 2, o.rect.y + o.rect.height / 2, o.rect.width / 2, o.rect.height / 2, occ_rad, margin, py, self.origin.x, self.scale, span.inner_x0, span.inner_x1)) |hole| {
                        if (hole.inner_x1 > hole.inner_x0) {
                            if (hole.inner_x0 > span.inner_x0) vec.overSolid(row[span.inner_x0..hole.inner_x0], solid);
                            if (span.inner_x1 > hole.inner_x1) vec.overSolid(row[hole.inner_x1..span.inner_x1], solid);
                        } else {
                            vec.overSolid(row[span.inner_x0..span.inner_x1], solid);
                        }
                    } else {
                        vec.overSolid(row[span.inner_x0..span.inner_x1], solid);
                    }
                } else {
                    vec.overSolid(row[span.inner_x0..span.inner_x1], solid);
                }
            }
            // Right antialiased fringe
            for (span.inner_x1..span.outer_x1) |x| {
                const px = (@as(f64, @floatFromInt(x)) + 0.5) / self.scale - self.origin.x;
                const cov = std.math.clamp(0.5 - roundedDistance(rect, rad, .{ .x = px, .y = py }) * self.scale, 0, 1);
                if (cov > 0) row[x] = if (cov >= 1) (if (solid >> 24 == 255) solid else over(row[x], solid)) else over(row[x], colorPixel(color, cov));
            }
        }
    }

    fn drawRoundedStroke(self: Canvas, rect: Rect, requested_radius: f64, stroke_width: f64, color: Color, solid: u32, x0: usize, y0: usize, x1: usize, y1: usize) void {
        const rad = @max(0, @min(requested_radius, @min(rect.width, rect.height) / 2));
        const half_stroke = stroke_width / 2;
        const margin = 0.5 / self.scale;
        const cx = rect.x + rect.width / 2;
        const cy = rect.y + rect.height / 2;
        const half_w = rect.width / 2;
        const half_h = rect.height / 2;
        for (y0..y1) |y| {
            const py = (@as(f64, @floatFromInt(y)) + 0.5) / self.scale - self.origin.y;
            const dy = @abs(py - cy) - half_h + rad;
            const outer_r = rad + half_stroke + margin;
            if (dy >= outer_r) continue;
            const outer_half = if (dy <= 0) half_w + half_stroke + margin else half_w - rad + @sqrt(@max(0, outer_r * outer_r - dy * dy));
            const row_x0: usize = @max(x0, @as(usize, @intFromFloat(std.math.clamp(@floor((cx - outer_half + self.origin.x) * self.scale), 0, @as(f64, @floatFromInt(x1))))));
            const row_x1: usize = @min(x1, @as(usize, @intFromFloat(std.math.clamp(@ceil((cx + outer_half + self.origin.x) * self.scale), 0, @as(f64, @floatFromInt(x1))))));
            if (row_x1 <= row_x0) continue;
            const row = self.target.pixels[y * self.target.width ..];
            // Skip the empty interior when the stroke doesn't reach it.
            const inner_r = rad - half_stroke - margin;
            const hole_half: f64 = if (dy <= -half_stroke - margin)
                half_w - half_stroke - margin
            else if (inner_r > 0 and dy < inner_r)
                half_w - rad + (if (dy <= 0) inner_r else @sqrt(@max(0, inner_r * inner_r - dy * dy)))
            else
                -1;
            const ranges = if (hole_half > 0) blk: {
                const hole_x0: usize = @min(row_x1, @max(row_x0, @as(usize, @intFromFloat(std.math.clamp(@ceil((cx - hole_half + self.origin.x) * self.scale), 0, @as(f64, @floatFromInt(row_x1)))))));
                const hole_x1: usize = @min(row_x1, @max(hole_x0, @as(usize, @intFromFloat(std.math.clamp(@floor((cx + hole_half + self.origin.x) * self.scale), 0, @as(f64, @floatFromInt(row_x1)))))));
                break :blk [2][2]usize{ .{ row_x0, hole_x0 }, .{ hole_x1, row_x1 } };
            } else [2][2]usize{ .{ row_x0, row_x1 }, .{ 0, 0 } };
            for (ranges) |seg| for (seg[0]..seg[1]) |x| {
                const px = (@as(f64, @floatFromInt(x)) + 0.5) / self.scale - self.origin.x;
                const dist = @abs(roundedDistance(rect, rad, .{ .x = px, .y = py })) - half_stroke;
                const cov = std.math.clamp(0.5 - dist * self.scale, 0, 1);
                if (cov > 0) row[x] = if (cov >= 1) (if (solid >> 24 == 255) solid else over(row[x], solid)) else over(row[x], colorPixel(color, cov));
            };
        }
    }

    /// Resolve polygon interiors once per scanline and evaluate antialiasing
    /// only within half a device pixel of an edge. Bounded scratch storage also
    /// keeps long stepped panel charts independent of allocation and image size.
    fn drawPolygon(self: Canvas, points: []const Point, color: Color, solid: u32, x0: usize, y0: usize, x1: usize, y1: usize) void {
        const limit = 0.5 / self.scale;
        var crossings: [256]f64 = undefined;
        var distances: [256]f64 = undefined;
        for (y0..y1) |y| {
            const py = (@as(f64, @floatFromInt(y)) + 0.5) / self.scale - self.origin.y;
            var count: usize = 0;
            var last = points[points.len - 1];
            for (points) |next| {
                if ((next.y > py) != (last.y > py)) {
                    crossings[count] = (last.x - next.x) * (py - next.y) / (last.y - next.y) + next.x;
                    count += 1;
                }
                last = next;
            }
            std.mem.sort(f64, crossings[0..count], {}, std.sort.asc(f64));
            var crossing: usize = 0;
            var start = x0;
            while (start < x1) {
                const end = @min(start + distances.len, x1);
                @memset(distances[0 .. end - start], limit);
                last = points[points.len - 1];
                for (points) |next| {
                    if (py >= @min(last.y, next.y) - limit and py <= @max(last.y, next.y) + limit) {
                        const left_edge: usize = @intFromFloat(std.math.clamp(@floor((@min(last.x, next.x) - limit + self.origin.x) * self.scale), @as(f64, @floatFromInt(start)), @as(f64, @floatFromInt(end))));
                        const right_edge: usize = @intFromFloat(std.math.clamp(@ceil((@max(last.x, next.x) + limit + self.origin.x) * self.scale), @as(f64, @floatFromInt(start)), @as(f64, @floatFromInt(end))));
                        for (left_edge..right_edge) |x| {
                            const p: Point = .{ .x = (@as(f64, @floatFromInt(x)) + 0.5) / self.scale - self.origin.x, .y = py };
                            distances[x - start] = @min(distances[x - start], segmentDistance(p, last, next));
                        }
                    }
                    last = next;
                }
                for (start..end) |x| {
                    const px = (@as(f64, @floatFromInt(x)) + 0.5) / self.scale - self.origin.x;
                    while (crossing < count and crossings[crossing] <= px) crossing += 1;
                    const inside = (count - crossing) % 2 != 0;
                    const distance = distances[x - start] * self.scale;
                    const coverage = std.math.clamp(0.5 + (if (inside) distance else -distance), 0, 1);
                    if (coverage == 0) continue;
                    const dest = &self.target.pixels[y * self.target.width + x];
                    dest.* = if (coverage >= 1) (if (solid >> 24 == 255) solid else over(dest.*, solid)) else over(dest.*, colorPixel(color, coverage));
                }
                start = end;
            }
        }
    }
};
pub fn rounded(canvas: Canvas, rect: Rect, radius: f64, value: u32) void {
    canvas.draw(&.{rect.shape(radius)}, hex(value));
}

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

test "polygon edge culling preserves coverage for concave, crossing and stepped outlines" {
    const outlines = [_][]const Point{
        &.{ .{ .x = 0.25, .y = 0.5 }, .{ .x = 7.5, .y = 1.25 }, .{ .x = 2.5, .y = 3 }, .{ .x = 7.75, .y = 7.5 }, .{ .x = 0.5, .y = 6.5 } },
        &.{ .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, .{ .x = 8, .y = 0 }, .{ .x = 0, .y = 8 } },
        &.{ .{ .x = 0, .y = 8 }, .{ .x = 0, .y = 2 }, .{ .x = 1, .y = 2 }, .{ .x = 1, .y = 6 }, .{ .x = 3, .y = 6 }, .{ .x = 3, .y = 1 }, .{ .x = 6, .y = 1 }, .{ .x = 6, .y = 8 } },
        &.{ .{ .x = -10, .y = -1 }, .{ .x = 660, .y = 6 }, .{ .x = 300, .y = 20 }, .{ .x = 520, .y = 28 }, .{ .x = -10, .y = 28 } },
    };
    for (outlines) |points| for ([_]f64{ 0.75, 1, 1.625, 2, 3 }) |scale| {
        const shape: Shape = .{ .polygon = points };
        var pixels: [768 * 32]u32 = @splat(0x80402010);
        const color: Color = .{ .red = 0.25, .green = 0.75, .blue = 1, .alpha = 0.7 };
        const canvas: Canvas = .{ .target = .{ .pixels = &pixels, .width = 768, .height = 32 }, .scale = scale, .origin = .{ .x = 1, .y = 1 } };
        canvas.draw(&.{shape}, color);
        for (0..32) |y| for (0..768) |x| {
            const p: Point = .{ .x = (@as(f64, @floatFromInt(x)) + 0.5) / scale - 1, .y = (@as(f64, @floatFromInt(y)) + 0.5) / scale - 1 };
            // Unculled signed-distance reference, including all polygon edges.
            var nearest = std.math.inf(f64);
            var inside = false;
            var last = points[points.len - 1];
            for (points) |next| {
                nearest = @min(nearest, segmentDistance(p, last, next));
                if ((next.y > p.y) != (last.y > p.y) and p.x < (last.x - next.x) * (p.y - next.y) / (last.y - next.y) + next.x) inside = !inside;
                last = next;
            }
            const expected = std.math.clamp(0.5 - (if (inside) -nearest else nearest) * scale, 0, 1);
            try std.testing.expectEqual(over(0x80402010, colorPixel(color, expected)), pixels[y * 768 + x]);
        };
    };
}

/// Byte RGB/RGBA or native-endian premultiplied ARGB/XRGB, with row padding.
pub const Image = struct {
    pixels: []const u8,
    width: u32,
    height: u32,
    stride: usize,
    format: enum { rgb, rgba, argb, xrgb, abgr, xbgr },

    fn bytesPerPixel(self: Image) usize {
        return if (self.format == .rgb) 3 else 4;
    }
    pub fn validate(self: Image) !void {
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
    if (image.format == .argb or image.format == .xrgb or image.format == .abgr or image.format == .xbgr) {
        const word = std.mem.readInt(u32, image.pixels[offset..][0..4], @import("builtin").cpu.arch.endian());
        const swapped = image.format == .abgr or image.format == .xbgr;
        const is_opaque = image.format == .xrgb or image.format == .xbgr;
        return .{ if (swapped) word & 255 else (word >> 16) & 255, (word >> 8) & 255, if (swapped) (word >> 16) & 255 else word & 255, if (is_opaque) 255 else word >> 24 };
    }
    const rgb = image.pixels[offset..][0..3];
    const alpha: u32 = if (image.format == .rgba) image.pixels[offset + 3] else 255;
    // Premultiply before interpolation to keep invisible RGB out of the edges.
    return .{ (@as(u32, rgb[0]) * alpha + 127) / 255, (@as(u32, rgb[1]) * alpha + 127) / 255, (@as(u32, rgb[2]) * alpha + 127) / 255, alpha };
}

pub const Filter = enum { good, bilinear };
pub const Extend = enum { none, pad };

fn edgePixel(image: Image, x: i64, y: i64, extend: Extend) [4]u32 {
    if (extend == .none) {
        if (x < 0 or y < 0 or x >= image.width or y >= image.height) return @splat(0);
        return pixel(image, @intCast(x), @intCast(y));
    }
    const cx: usize = @intCast(std.math.clamp(x, 0, @as(i64, image.width) - 1));
    const cy: usize = @intCast(std.math.clamp(y, 0, @as(i64, image.height) - 1));
    return pixel(image, cx, cy);
}

fn sampleImage(image: Image, x: f64, y: f64, extend: Extend) u32 {
    if (extend == .none and (x < -1 or y < -1 or x >= @as(f64, @floatFromInt(image.width)) or y >= @as(f64, @floatFromInt(image.height)))) return 0;
    const sx = @floor(x);
    const sy = @floor(y);
    const ix: i64 = @intFromFloat(sx);
    const iy: i64 = @intFromFloat(sy);
    const fx: u32 = @intFromFloat((x - sx) * 256);
    const fy: u32 = @intFromFloat((y - sy) * 256);
    const a = edgePixel(image, ix, iy, extend);
    const b = edgePixel(image, ix + 1, iy, extend);
    const c = edgePixel(image, ix, iy + 1, extend);
    const d = edgePixel(image, ix + 1, iy + 1, extend);
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
    fn weight(self: FilterAxis, position: i64) f64 {
        const index: f64 = @floatFromInt(position);
        if (!self.area) return @max(0, 1 - @abs(index - self.center));
        const start = self.center + 0.5 - self.step / 2;
        const end = self.center + 0.5 + self.step / 2;
        return @max(0, @min(index + 1, end) - @max(index, start)) / self.step;
    }
};

fn filteredImage(image: Image, x: f64, y: f64, step_x: f64, step_y: f64, filter: Filter, extend: Extend) u32 {
    if (filter == .bilinear or (step_x <= 4.0 / 3.0 and step_y <= 4.0 / 3.0)) return sampleImage(image, x, y, extend);
    const horizontal = FilterAxis.init(x, step_x);
    const vertical = FilterAxis.init(y, step_y);
    const x0 = if (extend == .none) std.math.clamp(horizontal.first, 0, @as(i64, image.width)) else horizontal.first;
    const x1 = if (extend == .none) std.math.clamp(horizontal.last, 0, @as(i64, image.width)) else horizontal.last;
    const y0 = if (extend == .none) std.math.clamp(vertical.first, 0, @as(i64, image.height)) else vertical.first;
    const y1 = if (extend == .none) std.math.clamp(vertical.last, 0, @as(i64, image.height)) else vertical.last;
    var sum: [4]f64 = @splat(0);
    var sy = y0;
    while (sy < y1) : (sy += 1) {
        const wy = vertical.weight(sy);
        if (wy <= 0) continue;
        var sx = x0;
        while (sx < x1) : (sx += 1) {
            const weight = wy * horizontal.weight(sx);
            if (weight <= 0) continue;
            const value = edgePixel(image, sx, sy, extend);
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
/// Source edges are transparent by default, or clamped with `.extend = .pad`.
/// Destination coordinates and the optional clip are in physical pixels.
pub fn blit(target: Buffer, image: Image, destination: Rect, clip: ?Region) !void {
    return blitWithOptions(target, image, destination, .{ .clip = clip });
}

pub const BlitOptions = struct {
    clip: ?Region = null,
    /// Antialiased clipping shape in physical pixel coordinates.
    shape: ?Shape = null,
    opacity: f64 = 1,
    filter: Filter = .good,
    extend: Extend = .none,
};

test "image opacity and rounded clipping preserve premultiplication and adjacent pixels" {
    const word: [16]u32 = @splat(0xffff0000);
    var pixels: [16]u32 = @splat(0xff000000);
    const target: Buffer = .{ .pixels = &pixels, .width = 4, .height = 4 };
    const image: Image = .{ .pixels = std.mem.sliceAsBytes(&word), .width = 4, .height = 4, .stride = 16, .format = .argb };
    const destination: Rect = .{ .width = 4, .height = 4 };
    try blitWithOptions(target, image, destination, .{ .opacity = 0 });
    for (pixels) |value| try std.testing.expectEqual(@as(u32, 0xff000000), value);
    try blitWithOptions(target, image, destination, .{ .opacity = 0.5, .shape = destination.shape(2), .clip = .{ .x = 1, .y = 1, .width = 2, .height = 2 } });
    try std.testing.expectEqual(@as(u32, 0xff800000), pixels[5]);
    try std.testing.expectEqual(@as(u32, 0xff000000), pixels[0]);
    try std.testing.expectError(error.InvalidImage, blitWithOptions(target, image, destination, .{ .opacity = std.math.nan(f64) }));
    // Pad extend keeps edges opaque under both bilinear and area downscaling.
    var small: [4]u32 = @splat(0);
    const big: [64]u32 = @splat(0xff112233);
    const big_img: Image = .{ .pixels = std.mem.sliceAsBytes(&big), .width = 8, .height = 8, .stride = 32, .format = .argb };
    for ([_]Filter{ .bilinear, .good }) |filter| {
        @memset(&small, 0);
        try blitWithOptions(.{ .pixels = &small, .width = 2, .height = 2 }, big_img, .{ .width = 2, .height = 2 }, .{ .filter = filter, .extend = .pad });
        for (small) |p| try std.testing.expectEqual(@as(u32, 0xff112233), p);
    }
}

pub fn blitWithOptions(target: Buffer, image: Image, destination: Rect, options: BlitOptions) !void {
    try image.validate();
    if (!std.math.isFinite(options.opacity) or options.opacity < 0 or options.opacity > 1) return error.InvalidImage;
    if (!std.math.isFinite(destination.x) or !std.math.isFinite(destination.y) or !std.math.isFinite(destination.width) or !std.math.isFinite(destination.height) or destination.width < 0.001 or destination.height < 0.001) return error.InvalidImage;
    if (target.pixels.len < try std.math.mul(usize, target.width, target.height)) return error.InvalidImage;
    if (options.opacity == 0) return;
    const width: f64 = @floatFromInt(target.width);
    const height: f64 = @floatFromInt(target.height);
    var x0: usize = @intFromFloat(std.math.clamp(if (options.extend == .pad) @ceil(destination.x - 0.5) else @floor(destination.x), 0, width));
    var y0: usize = @intFromFloat(std.math.clamp(if (options.extend == .pad) @ceil(destination.y - 0.5) else @floor(destination.y), 0, height));
    var x1: usize = @intFromFloat(std.math.clamp(if (options.extend == .pad) @ceil(destination.x + destination.width - 0.5) else @ceil(destination.x + destination.width), 0, width));
    var y1: usize = @intFromFloat(std.math.clamp(if (options.extend == .pad) @ceil(destination.y + destination.height - 0.5) else @ceil(destination.y + destination.height), 0, height));
    if (options.clip) |rect| {
        x0 = @max(x0, @as(usize, @intCast(std.math.clamp(@as(i64, rect.x), 0, target.width))));
        y0 = @max(y0, @as(usize, @intCast(std.math.clamp(@as(i64, rect.y), 0, target.height))));
        x1 = @min(x1, @as(usize, @intCast(std.math.clamp(@as(i64, rect.x) + rect.width, 0, target.width))));
        y1 = @min(y1, @as(usize, @intCast(std.math.clamp(@as(i64, rect.y) + rect.height, 0, target.height))));
    }
    if (x1 <= x0 or y1 <= y0) return;
    const step_x = @as(f64, @floatFromInt(image.width)) / destination.width;
    const step_y = @as(f64, @floatFromInt(image.height)) / destination.height;
    if (image.format == .argb and image.stride % 4 == 0 and @intFromPtr(image.pixels.ptr) % 4 == 0) {
        if (step_x == 1 and step_y == 1 and destination.x == @floor(destination.x) and destination.y == @floor(destination.y)) {
            blitArgbAligned(target, image, destination, x0, y0, x1, y1, options);
            return;
        }
        const use_bilinear = options.filter == .bilinear or (step_x <= 4.0 / 3.0 and step_y <= 4.0 / 3.0);
        if (use_bilinear) {
            blitArgbBilinear(target, image, destination, x0, y0, x1, y1, step_x, step_y, options);
            return;
        }
        if (step_x <= 32 and step_y <= 32) {
            blitArgbArea(target, image, destination, x0, y0, x1, y1, step_x, step_y, options);
            return;
        }
    }
    for (y0..y1) |y| for (x0..x1) |x| {
        const sx = (@as(f64, @floatFromInt(x)) + 0.5 - destination.x) * step_x - 0.5;
        const sy = (@as(f64, @floatFromInt(y)) + 0.5 - destination.y) * step_y - 0.5;
        const coverage = options.opacity * if (options.shape) |shape| std.math.clamp(0.5 - shape.distance(.{ .x = @as(f64, @floatFromInt(x)) + 0.5, .y = @as(f64, @floatFromInt(y)) + 0.5 }), 0, 1) else @as(f64, 1);
        if (coverage == 0) continue;
        const dest = &target.pixels[y * target.width + x];
        const sample = filteredImage(image, sx, sy, step_x, step_y, options.filter, options.extend);
        if (coverage >= 1) {
            dest.* = over(dest.*, sample);
            continue;
        }
        var source: u32 = 0;
        inline for (.{ 0, 8, 16, 24 }) |shift| {
            const channel: u32 = @intFromFloat(@round(@as(f64, @floatFromInt((sample >> shift) & 255)) * coverage));
            source |= channel << shift;
        }
        dest.* = over(dest.*, source);
    };
}

const BilinearTap = struct { first: u32, w0: u16, w1: u16, count: u8 };

fn bilinearTap(center: f64, size: u32, extend: Extend) BilinearTap {
    const f = center - 0.5;
    const fl = @floor(f);
    const w1: u16 = @intFromFloat(@round((f - fl) * 256));
    const limit: f64 = @floatFromInt(size);
    const size_i: i64 = size;
    var x0: i64 = @intFromFloat(std.math.clamp(fl, -2, limit + 1));
    var x1: i64 = x0 + 1;
    var weight0: u16 = 256 - w1;
    var weight1: u16 = w1;
    if (extend == .none) {
        if (x0 < 0 or x0 >= size_i) weight0 = 0;
        if (x1 < 0 or x1 >= size_i) weight1 = 0;
    }
    x0 = std.math.clamp(x0, 0, size_i - 1);
    x1 = std.math.clamp(x1, 0, size_i - 1);
    if (x0 == x1) return .{ .first = @intCast(x0), .count = if (weight0 + weight1 > 0) 1 else 0, .w0 = weight0 + weight1, .w1 = 0 };
    return .{ .first = @intCast(x0), .count = 2, .w0 = weight0, .w1 = weight1 };
}

inline fn mixPair(a: u32, b: u32, wa: u32, wb: u32) u32 {
    const rb = (((a & 0x00ff00ff) *% wa +% (b & 0x00ff00ff) *% wb +% 0x00800080) >> 8) & 0x00ff00ff;
    const ag = ((((a >> 8) & 0x00ff00ff) *% wa +% ((b >> 8) & 0x00ff00ff) *% wb +% 0x00800080) >> 8) & 0x00ff00ff;
    return rb | (ag << 8);
}

fn blendRows(out: []u32, top: []const u32, bottom: []const u32, w0: u32, w1: u32) void {
    @setRuntimeSafety(false);
    if (w1 == 0 and w0 == 256) return @memcpy(out, top);
    const Lanes = @Vector(16, u16);
    const Bytes = @Vector(16, u8);
    const a: Lanes = @splat(@intCast(w0));
    const b: Lanes = @splat(@intCast(w1));
    const half: Lanes = @splat(128);
    var i: usize = 0;
    while (i + 4 <= out.len) : (i += 4) {
        const t: Lanes = @as(Bytes, @bitCast(top[i..][0..4].*));
        const u: Lanes = @as(Bytes, @bitCast(bottom[i..][0..4].*));
        const v = (t *% a +% u *% b +% half) >> @splat(8);
        out[i..][0..4].* = @bitCast(@as(Bytes, @truncate(v)));
    }
    while (i < out.len) : (i += 1) out[i] = mixPair(top[i], bottom[i], w0, w1);
}

fn blendRowsMulti(out: []u32, src_pixels: [*]const u32, src_stride: usize, first_y: usize, row_count: usize, weights: []const u16, src_x0: usize) void {
    @setRuntimeSafety(false);
    if (row_count == 1 and weights[0] == 256) {
        @memcpy(out, src_pixels[first_y * src_stride + src_x0 ..][0..out.len]);
        return;
    }
    const Lanes = @Vector(16, u16);
    const Bytes = @Vector(16, u8);
    const half: Lanes = @splat(128);
    var i: usize = 0;
    while (i + 4 <= out.len) : (i += 4) {
        var acc: Lanes = half;
        for (0..row_count) |ry| {
            const w: Lanes = @splat(weights[ry]);
            const row = src_pixels[(first_y + ry) * src_stride + src_x0 + i ..];
            const t: Lanes = @as(Bytes, @bitCast(row[0..4].*));
            acc +%= t *% w;
        }
        out[i..][0..4].* = @bitCast(@as(Bytes, @truncate(acc >> @splat(8))));
    }
    while (i < out.len) : (i += 1) {
        var acc: [4]u32 = .{ 128, 128, 128, 128 };
        for (0..row_count) |ry| {
            const w: u32 = weights[ry];
            const px = src_pixels[(first_y + ry) * src_stride + src_x0 + i];
            inline for (0..4) |ch| acc[ch] += ((px >> (8 * ch)) & 255) * w;
        }
        var res: u32 = 0;
        inline for (0..4) |ch| res |= @as(u32, @min(255, acc[ch] >> 8)) << @as(u5, 8 * ch);
        out[i] = res;
    }
}

fn shapeRoundedRect(shape: Shape) ?struct { rect: Rect, rad: f64 } {
    return switch (shape) {
        .rounded => |r| .{ .rect = r, .rad = @max(0, @min(r.width, r.height) / 2) },
        .rounded_rect => |v| .{ .rect = v.rect, .rad = @max(0, @min(v.radius, @min(v.rect.width, v.rect.height) / 2)) },
        .circle => |v| .{ .rect = .{ .x = v.center.x - v.radius, .y = v.center.y - v.radius, .width = 2 * v.radius, .height = 2 * v.radius }, .rad = @max(0, v.radius) },
        else => null,
    };
}

fn compositeBlitRow(dest_row: []u32, out_row: []const u32, tx0: usize, tx1: usize, y: usize, options: BlitOptions, opacity_255: u32) void {
    const shape = options.shape orelse {
        vec.overSpan(dest_row[tx0..tx1], out_row[0 .. tx1 - tx0], opacity_255);
        return;
    };
    const py = @as(f64, @floatFromInt(y)) + 0.5;
    if (shapeRoundedRect(shape)) |rr| {
        const span = roundedScanlineSpan(rr.rect.x + rr.rect.width / 2, rr.rect.y + rr.rect.height / 2, rr.rect.width / 2, rr.rect.height / 2, rr.rad, 0.5, py, 0, 1, tx0, tx1) orelse return;
        for (span.outer_x0..span.inner_x0) |x| {
            const cov = options.opacity * std.math.clamp(0.5 - roundedDistance(rr.rect, rr.rad, .{ .x = @as(f64, @floatFromInt(x)) + 0.5, .y = py }), 0, 1);
            if (cov > 0) {
                const f: u32 = @intFromFloat(@round(cov * 255));
                if (f > 0) dest_row[x] = vec.over(dest_row[x], if (f == 255) out_row[x - tx0] else vec.fade(out_row[x - tx0], f));
            }
        }
        if (span.inner_x1 > span.inner_x0) {
            vec.overSpan(dest_row[span.inner_x0..span.inner_x1], out_row[span.inner_x0 - tx0 .. span.inner_x1 - tx0], opacity_255);
        }
        for (span.inner_x1..span.outer_x1) |x| {
            const cov = options.opacity * std.math.clamp(0.5 - roundedDistance(rr.rect, rr.rad, .{ .x = @as(f64, @floatFromInt(x)) + 0.5, .y = py }), 0, 1);
            if (cov > 0) {
                const f: u32 = @intFromFloat(@round(cov * 255));
                if (f > 0) dest_row[x] = vec.over(dest_row[x], if (f == 255) out_row[x - tx0] else vec.fade(out_row[x - tx0], f));
            }
        }
        return;
    }
    for (tx0..tx1) |x| {
        const cov = options.opacity * std.math.clamp(0.5 - shape.distance(.{ .x = @as(f64, @floatFromInt(x)) + 0.5, .y = py }), 0, 1);
        if (cov > 0) {
            const f: u32 = @intFromFloat(@round(cov * 255));
            if (f > 0) dest_row[x] = vec.over(dest_row[x], if (f == 255) out_row[x - tx0] else vec.fade(out_row[x - tx0], f));
        }
    }
}

/// Unscaled, pixel-aligned blit. Bilinear taps there carry weights 256/0, so
/// the sampled row is exactly the source row; skip sampling and composite it.
fn blitArgbAligned(target: Buffer, image: Image, destination: Rect, x0: usize, y0: usize, x1: usize, y1: usize, options: BlitOptions) void {
    @setRuntimeSafety(false);
    const opacity_255: u32 = @intFromFloat(@round(options.opacity * 255));
    if (opacity_255 == 0) return;
    const src_pixels: [*]const u32 = @ptrCast(@alignCast(image.pixels.ptr));
    const src_stride = image.stride / 4;
    const dx: i64 = @intFromFloat(destination.x);
    const dy: i64 = @intFromFloat(destination.y);
    const sx: usize = @intCast(@as(i64, @intCast(x0)) - dx);
    for (y0..y1) |y| {
        const sy: usize = @intCast(@as(i64, @intCast(y)) - dy);
        compositeBlitRow(target.pixels[y * target.width ..], src_pixels[sy * src_stride + sx ..][0 .. x1 - x0], x0, x1, y, options, opacity_255);
    }
}

test "aligned unscaled blit matches the bilinear path exactly, including offsets, clips, shapes and opacity" {
    var source: [7 * 5]u32 = undefined;
    for (&source, 0..) |*value, i| {
        const alpha: u32 = @intCast((i * 37) % 256);
        const channel = alpha * @as(u32, @intCast(i % 3 + 1)) / 3;
        value.* = alpha << 24 | channel << 16 | (alpha / 2) << 8 | channel / 2;
    }
    const image: Image = .{ .pixels = std.mem.sliceAsBytes(&source), .width = 7, .height = 5, .stride = 28, .format = .argb };
    const cases = [_]struct { destination: Rect, options: BlitOptions }{
        .{ .destination = .{ .x = 2, .y = 1, .width = 7, .height = 5 }, .options = .{} },
        .{ .destination = .{ .x = -3, .y = -2, .width = 7, .height = 5 }, .options = .{ .opacity = 0.6 } },
        .{ .destination = .{ .x = 5, .y = 4, .width = 7, .height = 5 }, .options = .{ .clip = .{ .x = 6, .y = 4, .width = 3, .height = 2 } } },
        .{ .destination = .{ .x = 1, .y = 1, .width = 7, .height = 5 }, .options = .{ .shape = (Rect{ .x = 1, .y = 1, .width = 7, .height = 5 }).shape(2), .opacity = 0.8 } },
    };
    for (cases) |case| {
        var fast: [10 * 8]u32 = undefined;
        var slow: [10 * 8]u32 = undefined;
        for (&fast, &slow, 0..) |*f, *s, i| {
            f.* = 0xff000000 | @as(u32, @intCast(i * 3));
            s.* = f.*;
        }
        const target_fast: Buffer = .{ .pixels = &fast, .width = 10, .height = 8 };
        const target_slow: Buffer = .{ .pixels = &slow, .width = 10, .height = 8 };
        try blitWithOptions(target_fast, image, case.destination, case.options);
        // Reproduce the bounds blitWithOptions computes, then force the bilinear path.
        const d = case.destination;
        var x0: usize = @intFromFloat(std.math.clamp(@floor(d.x), 0, 10));
        var y0: usize = @intFromFloat(std.math.clamp(@floor(d.y), 0, 8));
        var x1: usize = @intFromFloat(std.math.clamp(@ceil(d.x + d.width), 0, 10));
        var y1: usize = @intFromFloat(std.math.clamp(@ceil(d.y + d.height), 0, 8));
        if (case.options.clip) |c| {
            x0 = @max(x0, @as(usize, @intCast(c.x)));
            y0 = @max(y0, @as(usize, @intCast(c.y)));
            x1 = @min(x1, @as(usize, @intCast(c.x + @as(i32, @intCast(c.width)))));
            y1 = @min(y1, @as(usize, @intCast(c.y + @as(i32, @intCast(c.height)))));
        }
        blitArgbBilinear(target_slow, image, d, x0, y0, x1, y1, 1, 1, case.options);
        try std.testing.expectEqualSlices(u32, &slow, &fast);
    }
}

fn blitArgbBilinear(target: Buffer, image: Image, destination: Rect, x0: usize, y0: usize, x1: usize, y1: usize, step_x: f64, step_y: f64, options: BlitOptions) void {
    @setRuntimeSafety(false);
    const src_pixels: [*]const u32 = @ptrCast(@alignCast(image.pixels.ptr));
    const src_stride = image.stride / 4;
    const opacity_255: u32 = @intFromFloat(@round(options.opacity * 255));
    if (opacity_255 == 0) return;

    const tile_max = 512;
    const scratch_max = 2048;
    var col_first: [tile_max]u32 = undefined;
    var col_w0: [tile_max]u16 = undefined;
    var col_w1: [tile_max]u16 = undefined;
    var row_scratch: [scratch_max]u32 = undefined;
    var out_row: [tile_max]u32 = undefined;

    const Lanes = @Vector(16, u16);
    const Bytes = @Vector(16, u8);
    const spread: @Vector(16, i32) = .{ 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3 };
    const half: Lanes = @splat(128);
    const last_x = image.width - 1;

    // Limit tile width so its source X span fits inside row_scratch.
    const max_tile_by_step: usize = if (step_x > 1) @max(1, @as(usize, @intFromFloat(@floor(@as(f64, scratch_max - 4) / step_x)))) else tile_max;
    const tile_step = @min(tile_max, max_tile_by_step);

    var tx0 = x0;
    while (tx0 < x1) {
        const tx1 = @min(tx0 + tile_step, x1);
        const tile_len = tx1 - tx0;
        var min_src_x: u32 = last_x;
        var max_src_x: u32 = 0;
        for (0..tile_len) |i| {
            const center = (@as(f64, @floatFromInt(tx0 + i)) + 0.5 - destination.x) * step_x;
            const tap = bilinearTap(center, image.width, options.extend);
            col_first[i] = tap.first;
            col_w0[i] = tap.w0;
            col_w1[i] = tap.w1;
            min_src_x = @min(min_src_x, tap.first);
            max_src_x = @max(max_src_x, @min(tap.first + 1, last_x));
        }
        const src_len = max_src_x - min_src_x + 1;
        const last_rel = src_len - 1;

        for (y0..y1) |y| {
            const cy = (@as(f64, @floatFromInt(y)) + 0.5 - destination.y) * step_y;
            const ytap = bilinearTap(cy, image.height, options.extend);
            if (ytap.count == 0) continue;
            const r0 = src_pixels[@as(usize, ytap.first) * src_stride + min_src_x ..];
            const r1 = if (ytap.count == 2) src_pixels[(@as(usize, ytap.first) + 1) * src_stride + min_src_x ..] else r0;
            blendRows(row_scratch[0..src_len], r0[0..src_len], r1[0..src_len], ytap.w0, if (ytap.count == 2) ytap.w1 else 0);

            var k: usize = 0;
            while (k + 4 <= tile_len) : (k += 4) {
                var left: [4]u32 = undefined;
                var right: [4]u32 = undefined;
                var wl: @Vector(4, u16) = undefined;
                var wr: @Vector(4, u16) = undefined;
                inline for (0..4) |j| {
                    const rx = col_first[k + j] - min_src_x;
                    left[j] = row_scratch[rx];
                    right[j] = row_scratch[@min(rx + 1, last_rel)];
                    wl[j] = col_w0[k + j];
                    wr[j] = col_w1[k + j];
                }
                const a: Lanes = @as(Bytes, @bitCast(left));
                const b: Lanes = @as(Bytes, @bitCast(right));
                const v = (a *% @shuffle(u16, wl, undefined, spread) +% b *% @shuffle(u16, wr, undefined, spread) +% half) >> @splat(8);
                out_row[k..][0..4].* = @bitCast(@as(Bytes, @truncate(v)));
            }
            while (k < tile_len) : (k += 1) {
                const rx = col_first[k] - min_src_x;
                out_row[k] = mixPair(row_scratch[rx], row_scratch[@min(rx + 1, last_rel)], col_w0[k], col_w1[k]);
            }

            compositeBlitRow(target.pixels[y * target.width ..], out_row[0..tile_len], tx0, tx1, y, options, opacity_255);
        }
        tx0 = tx1;
    }
}

const AreaTap = struct {
    first: u32,
    count: u8,
    weights: [36]u16,

    fn init(center: f64, step: f64, size: u32, extend: Extend) AreaTap {
        if (step <= 4.0 / 3.0) {
            const bt = bilinearTap(center, size, extend);
            var w: [36]u16 = @splat(0);
            w[0] = bt.w0;
            w[1] = bt.w1;
            return .{ .first = bt.first, .count = bt.count, .weights = w };
        }
        const limit: f64 = @floatFromInt(size);
        const lo = center - step / 2;
        const hi = center + step / 2;
        const first_f = @floor(lo);
        var raw: [36]f64 = undefined;
        var n: usize = 0;
        var pos = first_f;
        while (pos < hi and n < 36) : (pos += 1) {
            raw[n] = @max(0, @min(pos + 1, hi) - @max(pos, lo));
            n += 1;
        }
        var base: ?i32 = null;
        var last: i32 = 0;
        var resolved: [36]f64 = @splat(0);
        var total: f64 = 0;
        for (raw[0..n], 0..) |w, tap_idx| {
            var index = first_f + @as(f64, @floatFromInt(tap_idx));
            if (index < 0 or index >= limit) {
                if (extend == .none) continue;
                index = std.math.clamp(index, 0, limit - 1);
            }
            const idx: i32 = @intFromFloat(index);
            const b = base orelse blk: {
                base = idx;
                break :blk idx;
            };
            const slot: usize = @intCast(idx - b);
            if (slot < 36) resolved[slot] += w;
            last = idx;
            total += w;
        }
        var out: AreaTap = .{ .first = @intCast(base orelse 0), .count = 0, .weights = @splat(0) };
        if (base == null or total <= 0) return out;
        const count: usize = @intCast(@min(@as(i32, 36), last - base.? + 1));
        out.count = @intCast(count);
        const divisor: f64 = if (extend == .none) step else total;
        var sum: u32 = 0;
        for (0..count) |k| {
            const w: u16 = @intFromFloat(@round(resolved[k] / divisor * 256));
            out.weights[k] = w;
            sum += w;
        }
        if (count > 0 and (extend == .pad or sum > 256)) {
            var heaviest: usize = 0;
            for (1..count) |k| if (out.weights[k] > out.weights[heaviest]) {
                heaviest = k;
            };
            const target_sum: u32 = if (extend == .pad) 256 else @min(sum, 256);
            out.weights[heaviest] = @intCast(@as(i32, out.weights[heaviest]) + @as(i32, @intCast(target_sum)) - @as(i32, @intCast(sum)));
        }
        return out;
    }
};

fn blitArgbArea(target: Buffer, image: Image, destination: Rect, x0: usize, y0: usize, x1: usize, y1: usize, step_x: f64, step_y: f64, options: BlitOptions) void {
    @setRuntimeSafety(false);
    const src_pixels: [*]const u32 = @ptrCast(@alignCast(image.pixels.ptr));
    const src_stride = image.stride / 4;
    const opacity_255: u32 = @intFromFloat(@round(options.opacity * 255));
    if (opacity_255 == 0) return;

    const tile_max = 256;
    const scratch_max = 2048;
    var col_taps: [tile_max]AreaTap = undefined;
    var row_scratch: [scratch_max]u32 = undefined;
    var out_row: [tile_max]u32 = undefined;

    const max_tile_by_step: usize = @max(1, @as(usize, @intFromFloat(@floor(@as(f64, scratch_max - 40) / @max(1.0, step_x)))));
    const tile_step = @min(tile_max, max_tile_by_step);

    var tx0 = x0;
    while (tx0 < x1) {
        const tx1 = @min(tx0 + tile_step, x1);
        const tile_len = tx1 - tx0;
        var min_src_x: u32 = image.width - 1;
        var max_src_x: u32 = 0;
        for (0..tile_len) |i| {
            const center = (@as(f64, @floatFromInt(tx0 + i)) + 0.5 - destination.x) * step_x;
            col_taps[i] = AreaTap.init(center, step_x, image.width, options.extend);
            if (col_taps[i].count > 0) {
                min_src_x = @min(min_src_x, col_taps[i].first);
                max_src_x = @max(max_src_x, col_taps[i].first + col_taps[i].count - 1);
            }
        }
        const src_len: usize = if (max_src_x >= min_src_x) max_src_x - min_src_x + 1 else 0;
        if (src_len == 0) {
            tx0 = tx1;
            continue;
        }

        for (y0..y1) |y| {
            const cy = (@as(f64, @floatFromInt(y)) + 0.5 - destination.y) * step_y;
            const ytap = AreaTap.init(cy, step_y, image.height, options.extend);
            if (ytap.count == 0) continue;
            blendRowsMulti(row_scratch[0..src_len], src_pixels, src_stride, ytap.first, ytap.count, ytap.weights[0..ytap.count], min_src_x);

            for (0..tile_len) |i| {
                const ct = &col_taps[i];
                if (ct.count == 0) {
                    out_row[i] = 0;
                    continue;
                }
                const rx = ct.first - min_src_x;
                if (ct.count == 2) {
                    out_row[i] = mixPair(row_scratch[rx], row_scratch[rx + 1], ct.weights[0], ct.weights[1]);
                } else {
                    var acc: [4]u32 = .{ 128, 128, 128, 128 };
                    for (0..ct.count) |k| {
                        const w: u32 = ct.weights[k];
                        const px = row_scratch[rx + k];
                        inline for (0..4) |ch| acc[ch] += ((px >> (8 * ch)) & 255) * w;
                    }
                    var res: u32 = 0;
                    inline for (0..4) |ch| res |= @as(u32, @min(255, acc[ch] >> 8)) << @as(u5, 8 * ch);
                    out_row[i] = res;
                }
            }

            compositeBlitRow(target.pixels[y * target.width ..], out_row[0..tile_len], tx0, tx1, y, options, opacity_255);
        }
        tx0 = tx1;
    }
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
