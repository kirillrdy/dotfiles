//! OSD pixels and symbolic icons rendered in Zig into premultiplied ARGB buffers.
const std = @import("std");
const surface = @import("desktop-surface.zig");
pub const Kind = enum { volume, microphone, brightness };
pub const Config = struct {
    width: u16 = 240,
    height: u16 = 50,
    bottom_margin_percent: u8 = 6,
    duration_ms: u16 = 1500,
    background: [4]u8 = .{ 46, 46, 51, 255 },
    foreground: [4]u8 = .{ 255, 255, 255, 255 },
    border: [4]u8 = .{ 255, 255, 255, 5 },
    trough: [4]u8 = .{ 255, 255, 255, 26 },
    muted_opacity: f32 = 0.5,

    pub fn validate(self: Config) !void {
        if (self.height < 32 or self.height > 128 or self.width < self.height + 80 or self.width > 1024 or
            self.bottom_margin_percent > 40 or self.duration_ms < 100 or self.duration_ms > 10000 or
            !std.math.isFinite(self.muted_opacity) or self.muted_opacity < 0 or self.muted_opacity > 1) return error.InvalidOsdConfig;
    }
};

const Point = struct { x: f32, y: f32 };
fn length(x: f32, y: f32) f32 {
    return @sqrt(x * x + y * y);
}
fn segment(p: Point, from: Point, to: Point) f32 {
    const dx = to.x - from.x;
    const dy = to.y - from.y;
    const t = std.math.clamp(((p.x - from.x) * dx + (p.y - from.y) * dy) / (dx * dx + dy * dy), 0, 1);
    return length(p.x - from.x - t * dx, p.y - from.y - t * dy);
}
fn rounded(p: Point, x: f32, y: f32, w: f32, h: f32, radius: f32) f32 {
    if (w <= 0 or h <= 0) return std.math.inf(f32);
    const r = @min(radius, @min(w, h) / 2);
    const dx = @abs(p.x - x - w / 2) - w / 2 + r;
    const dy = @abs(p.y - y - h / 2) - h / 2 + r;
    return length(@max(dx, 0), @max(dy, 0)) + @min(@max(dx, dy), 0) - r;
}
fn cone(p: Point) f32 {
    const points = [_]Point{ .{ .x = 6, .y = 9 }, .{ .x = 12, .y = 4 }, .{ .x = 12, .y = 20 }, .{ .x = 6, .y = 15 } };
    var distance = std.math.inf(f32);
    var inside = true;
    for (points, 0..) |from, i| {
        const to = points[(i + 1) % points.len];
        distance = @min(distance, segment(p, from, to));
        inside = inside and (to.x - from.x) * (p.y - from.y) - (to.y - from.y) * (p.x - from.x) >= 0;
    }
    return if (inside) -distance else distance;
}
fn icon(p: Point, kind: Kind, percent: f64, muted: bool) f32 {
    var distance: f32 = std.math.inf(f32);
    switch (kind) {
        .volume => {
            distance = @min(rounded(p, 2, 9, 5, 6, 1), cone(p));
            if (muted or percent == 0) {
                distance = @min(distance, segment(p, .{ .x = 16, .y = 8 }, .{ .x = 22, .y = 16 }) - 0.8);
                distance = @min(distance, segment(p, .{ .x = 16, .y = 16 }, .{ .x = 22, .y = 8 }) - 0.8);
            } else {
                for ([_]f32{ 6, 9, 12 }, 0..) |r, i| {
                    if ((i == 1 and percent < 33) or (i == 2 and percent < 66)) continue;
                    const dx = p.x - 9;
                    const dy = p.y - 12;
                    distance = @min(distance, @max(@abs(length(dx, dy) - r) - 0.8, @abs(dy) - dx));
                }
            }
        },
        .microphone => {
            distance = rounded(p, 8, 2, 8, 13, 4);
            distance = @min(distance, @max(@abs(length(p.x - 12, p.y - 10) - 7) - 0.8, 10 - p.y));
            distance = @min(distance, segment(p, .{ .x = 5, .y = 8 }, .{ .x = 5, .y = 10 }) - 0.8);
            distance = @min(distance, segment(p, .{ .x = 19, .y = 8 }, .{ .x = 19, .y = 10 }) - 0.8);
            distance = @min(distance, segment(p, .{ .x = 12, .y = 17 }, .{ .x = 12, .y = 22 }) - 0.8);
            distance = @min(distance, segment(p, .{ .x = 8, .y = 22 }, .{ .x = 16, .y = 22 }) - 0.8);
            if (muted) distance = @min(distance, segment(p, .{ .x = 3, .y = 3 }, .{ .x = 22, .y = 22 }) - 0.8);
        },
        .brightness => {
            distance = @abs(length(p.x - 12, p.y - 12) - 4) - 0.8;
            const directions = [_]Point{ .{ .x = 1, .y = 0 }, .{ .x = 0.7071, .y = 0.7071 }, .{ .x = 0, .y = 1 }, .{ .x = -0.7071, .y = 0.7071 }, .{ .x = -1, .y = 0 }, .{ .x = -0.7071, .y = -0.7071 }, .{ .x = 0, .y = -1 }, .{ .x = 0.7071, .y = -0.7071 } };
            for (directions) |d| distance = @min(distance, segment(p, .{ .x = 12 + d.x * 8, .y = 12 + d.y * 8 }, .{ .x = 12 + d.x * 11, .y = 12 + d.y * 11 }) - 0.8);
        },
    }
    return distance;
}
fn blend(destination: u32, color: [4]u8, amount: f32) u32 {
    const alpha: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(color[3])) * std.math.clamp(amount, 0, 1)));
    const inverse = 255 - alpha;
    const a = alpha + (((destination >> 24) & 255) * inverse + 127) / 255;
    const r = (@as(u32, color[0]) * alpha + 127) / 255 + (((destination >> 16) & 255) * inverse + 127) / 255;
    const g = (@as(u32, color[1]) * alpha + 127) / 255 + (((destination >> 8) & 255) * inverse + 127) / 255;
    const b = (@as(u32, color[2]) * alpha + 127) / 255 + ((destination & 255) * inverse + 127) / 255;
    return (a << 24) | (r << 16) | (g << 8) | b;
}
fn coverage(distance: f32, scale: f32) f32 {
    return std.math.clamp(0.5 - distance * scale, 0, 1);
}

pub fn paint(frame: surface.Frame, config: Config, kind: Kind, percent: f64, muted: bool) void {
    const scale: f32 = @floatFromInt(frame.scale);
    const width: f32 = @floatFromInt(frame.width);
    const height: f32 = @floatFromInt(frame.height);
    const bar_width = @max(0, width - 80);
    const fraction: f32 = if (std.math.isFinite(percent)) @floatCast(std.math.clamp(percent / 100, 0, 1)) else 0;
    const opacity: f32 = if (muted) config.muted_opacity else 1;
    const pixels: [*]u32 = @ptrCast(@alignCast(frame.pixels));
    const stride: usize = @intCast(@divTrunc(frame.layout.stride, 4));
    for (0..@intCast(frame.layout.height)) |y| {
        for (0..@intCast(frame.layout.width)) |x| {
            const point = Point{ .x = (@as(f32, @floatFromInt(x)) + 0.5) / scale, .y = (@as(f32, @floatFromInt(y)) + 0.5) / scale };
            const outer = rounded(point, 0, 0, width, height, height / 2);
            var pixel = blend(0, config.background, coverage(outer, scale));
            const inner = rounded(point, 1, 1, width - 2, height - 2, height / 2 - 1);
            pixel = blend(pixel, config.border, coverage(@max(outer, -inner), scale));
            pixel = blend(pixel, config.trough, opacity * coverage(rounded(point, 56, height / 2 - 3, bar_width, 6, 3), scale));
            pixel = blend(pixel, config.foreground, opacity * coverage(rounded(point, 56, height / 2 - 3, bar_width * fraction, 6, 3), scale));
            pixel = blend(pixel, config.foreground, opacity * coverage(icon(.{ .x = point.x - 20, .y = point.y - (height - 24) / 2 }, kind, percent, muted), scale));
            pixels[y * stride + x] = pixel;
        }
    }
}

test "OSD config rejects unsafe dimensions and invalid opacity" {
    try (Config{}).validate();
    try std.testing.expectError(error.InvalidOsdConfig, (Config{ .width = 80 }).validate());
    try std.testing.expectError(error.InvalidOsdConfig, (Config{ .height = 0 }).validate());
    try std.testing.expectError(error.InvalidOsdConfig, (Config{ .duration_ms = 0 }).validate());
    try std.testing.expectError(error.InvalidOsdConfig, (Config{ .muted_opacity = std.math.nan(f32) }).validate());
}

test "OSD pixels preserve transparent corners, progress, muted contrast and distinct icons at both scales" {
    const config = Config{};
    for ([_]i32{ 1, 2 }) |scale| {
        const layout = try surface.Layout.init(config.width, config.height, scale);
        const pixels = try std.testing.allocator.alloc(u32, layout.size / 4);
        defer std.testing.allocator.free(pixels);
        const frame = surface.Frame{ .pixels = @ptrCast(pixels.ptr), .layout = layout, .width = config.width, .height = config.height, .scale = scale };
        const stride: usize = @intCast(layout.width);
        const s: usize = @intCast(scale);
        paint(frame, config, .volume, 50, false);
        try std.testing.expectEqual(@as(u32, 0), pixels[0]);
        try std.testing.expectEqual(@as(u32, 0xffffffff), pixels[25 * s * stride + 80 * s]);
        try std.testing.expect(pixels[25 * s * stride + 200 * s] != 0xffffffff);
        const volume = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(pixels));
        paint(frame, config, .microphone, 50, false);
        const microphone = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(pixels));
        try std.testing.expect(volume != microphone);
        paint(frame, config, .brightness, 50, false);
        try std.testing.expect(microphone != std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(pixels)));
        paint(frame, config, .volume, 50, true);
        try std.testing.expect(pixels[25 * s * stride + 80 * s] != 0xffffffff);
        for (pixels) |pixel| {
            const alpha = pixel >> 24;
            try std.testing.expect(((pixel >> 16) & 255) <= alpha and ((pixel >> 8) & 255) <= alpha and (pixel & 255) <= alpha);
        }
    }
}
