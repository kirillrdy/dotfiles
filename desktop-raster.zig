//! Native-endian ARGB shared-memory drawing, independent of Cairo and GTK.
const std = @import("std");

pub const Buffer = struct {
    pixels: []u32,
    width: u32,
    height: u32,
};

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
