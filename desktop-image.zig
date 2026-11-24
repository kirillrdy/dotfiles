//! Owned native-endian premultiplied ARGB pixels, independent of toolkit objects.
const std = @import("std");
const png = @import("desktop-png.zig");
const raster = @import("desktop-raster.zig");

pub const Image = struct {
    pixels: []align(@alignOf(u32)) u8,
    width: u32,
    height: u32,
    stride: usize,

    /// Copies padded or bottom-up capture rows and makes every pixel opaque.
    /// The caller owns the returned storage, including when passed to callbacks.
    pub fn copy(allocator: std.mem.Allocator, source: png.Image) !Image {
        if (source.width == 0 or source.height == 0 or source.width > 16384 or source.height > 16384) return error.InvalidFrame;
        const stride = @as(usize, source.width) * 4;
        const required = std.math.mul(usize, source.stride, source.height) catch return error.InvalidFrame;
        if (source.stride < stride or source.pixels.len < required) return error.InvalidFrame;
        const pixels = try allocator.alignedAlloc(u8, .of(u32), stride * source.height);
        const endian = @import("builtin").cpu.arch.endian();
        for (0..source.height) |y| {
            const source_y = if (source.y_invert) source.height - 1 - y else y;
            const row = pixels[y * stride ..][0..stride];
            @memcpy(row, source.pixels[source_y * source.stride ..][0..stride]);
            for (0..source.width) |x| {
                const pixel = row[x * 4 ..][0..4];
                std.mem.writeInt(u32, pixel, std.mem.readInt(u32, pixel, endian) | 0xff000000, endian);
            }
        }
        return .{ .pixels = pixels, .width = source.width, .height = source.height, .stride = stride };
    }

    /// Normalize capture rows without filtering pixels that already line up.
    pub fn normalize(allocator: std.mem.Allocator, source: raster.Image) !Image {
        if (source.width > 8192 or source.height > 8192) return error.InvalidImage;
        try source.validate();
        const stride = @as(usize, source.width) * 4;
        const pixels = try allocator.alignedAlloc(u8, .of(u32), stride * source.height);
        const endian = @import("builtin").cpu.arch.endian();
        for (0..source.height) |y| {
            const row = pixels[y * stride ..][0..stride];
            const input = source.pixels[y * source.stride ..];
            if (source.format == .argb) {
                @memcpy(row, input[0..stride]);
                continue;
            }
            const words = std.mem.bytesAsSlice(u32, row);
            for (words, 0..) |*word, x| {
                word.* = switch (source.format) {
                    .argb => unreachable,
                    .xrgb => std.mem.readInt(u32, input[x * 4 ..][0..4], endian) | 0xff000000,
                    .abgr, .xbgr => blk: {
                        const value = std.mem.readInt(u32, input[x * 4 ..][0..4], endian);
                        const alpha = if (source.format == .xbgr) 0xff000000 else value & 0xff000000;
                        break :blk alpha | ((value & 255) << 16) | (value & 0xff00) | ((value >> 16) & 255);
                    },
                    .rgb, .rgba => blk: {
                        const bytes: usize = if (source.format == .rgb) 3 else 4;
                        const rgb = input[x * bytes ..][0..bytes];
                        const alpha: u32 = if (source.format == .rgba) rgb[3] else 255;
                        break :blk (alpha << 24) | (((@as(u32, rgb[0]) * alpha + 127) / 255) << 16) |
                            (((@as(u32, rgb[1]) * alpha + 127) / 255) << 8) | ((@as(u32, rgb[2]) * alpha + 127) / 255);
                    },
                };
            }
        }
        return .{ .pixels = pixels, .width = source.width, .height = source.height, .stride = stride };
    }

    /// Scale a capture into independent storage, retaining its premultiplied alpha.
    pub fn thumbnail(allocator: std.mem.Allocator, source: raster.Image) !Image {
        if (source.width == 0 or source.height == 0 or source.width > 8192 or source.height > 8192) return error.InvalidImage;
        if (@max(source.width, source.height) <= 1024) return normalize(allocator, source);
        const ratio = @min(1.0, 1024.0 / @as(f64, @floatFromInt(@max(source.width, source.height))));
        const width: u32 = @max(1, @as(u32, @intFromFloat(@as(f64, @floatFromInt(source.width)) * ratio)));
        const height: u32 = @max(1, @as(u32, @intFromFloat(@as(f64, @floatFromInt(source.height)) * ratio)));
        const pixels = try allocator.alignedAlloc(u8, .of(u32), @as(usize, width) * height * 4);
        errdefer allocator.free(pixels);
        @memset(pixels, 0);
        try raster.blit(.{ .pixels = std.mem.bytesAsSlice(u32, pixels), .width = width, .height = height }, source, .{ .width = @floatFromInt(width), .height = @floatFromInt(height) }, null);
        return .{ .pixels = pixels, .width = width, .height = height, .stride = @as(usize, width) * 4 };
    }

    pub fn view(self: Image) raster.Image {
        return .{ .pixels = self.pixels, .width = self.width, .height = self.height, .stride = self.stride, .format = .argb };
    }

    /// Packed straight-alpha RGBA bytes, as used by notification image data.
    pub fn straightRgba(self: Image, allocator: std.mem.Allocator) ![]u8 {
        const out = try allocator.alloc(u8, @as(usize, self.width) * self.height * 4);
        const endian = @import("builtin").cpu.arch.endian();
        for (0..self.height) |y| for (0..self.width) |x| {
            const pixel = std.mem.readInt(u32, self.pixels[y * self.stride + x * 4 ..][0..4], endian);
            const alpha = pixel >> 24;
            const rgba = out[(y * self.width + x) * 4 ..][0..4];
            for (rgba[0..3], [_]u5{ 16, 8, 0 }) |*channel, shift| {
                channel.* = if (alpha == 0) 0 else @intCast(@min(255, (((pixel >> shift) & 255) * 255 + alpha / 2) / alpha));
            }
            rgba[3] = @intCast(alpha);
        };
        return out;
    }

    pub fn deinit(self: Image, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
};

test "owned captures normalize padding, inversion and alpha independently of source lifetime" {
    const a = std.testing.allocator;
    var source = [_]u32{ 0x00ff0000, 0x8000ff00, 0xdeadbeef, 0x000000ff, 0x12ffffff, 0xdeadbeef };
    const image = try Image.copy(a, .{ .pixels = std.mem.sliceAsBytes(&source), .width = 2, .height = 2, .stride = 12, .y_invert = true });
    defer image.deinit(a);
    const top_down = try Image.copy(a, .{ .pixels = std.mem.sliceAsBytes(&source), .width = 2, .height = 2, .stride = 12 });
    defer top_down.deinit(a);
    @memset(&source, 0);
    try std.testing.expectEqual(@as(usize, 8), image.stride);
    const expected = [_]u32{ 0xff0000ff, 0xffffffff, 0xffff0000, 0xff00ff00 };
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&expected), image.pixels);
    const expected_top_down = [_]u32{ 0xffff0000, 0xff00ff00, 0xff0000ff, 0xffffffff };
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&expected_top_down), top_down.pixels);
}

test "owned captures reject invalid dimensions, stride, truncated storage and overflow" {
    const a = std.testing.allocator;
    for ([_]png.Image{
        .{ .pixels = &.{}, .width = 0, .height = 1, .stride = 0 },
        .{ .pixels = &.{}, .width = 16385, .height = 1, .stride = 65540 },
        .{ .pixels = &.{ 0, 0, 0, 0 }, .width = 2, .height = 1, .stride = 4 },
        .{ .pixels = &.{ 0, 0, 0 }, .width = 1, .height = 1, .stride = 4 },
        .{ .pixels = &.{}, .width = 1, .height = 2, .stride = std.math.maxInt(usize) },
    }) |source| try std.testing.expectError(error.InvalidFrame, Image.copy(a, source));
}

test "window thumbnails preserve alpha and normalize RGB and BGR without modifying capture memory" {
    const a = std.testing.allocator;
    for ([_]raster.Image{
        .{ .pixels = &.{}, .width = 1, .height = 1, .stride = 8, .format = .argb },
        .{ .pixels = &.{}, .width = 1, .height = 1, .stride = 8, .format = .abgr },
        .{ .pixels = &.{}, .width = 1, .height = 1, .stride = 8, .format = .xrgb },
        .{ .pixels = &.{}, .width = 1, .height = 1, .stride = 8, .format = .xbgr },
    }) |source_template| {
        const swapped = source_template.format == .abgr or source_template.format == .xbgr;
        const is_opaque = source_template.format == .xrgb or source_template.format == .xbgr;
        var words = [_]u32{ if (swapped) 0x80204060 else 0x80604020, 0xdeadbeef };
        var source = source_template;
        source.pixels = std.mem.sliceAsBytes(&words);
        const image = try Image.thumbnail(a, source);
        defer image.deinit(a);
        const expected: u32 = if (is_opaque) 0xff604020 else 0x80604020;
        try std.testing.expectEqual(expected, std.mem.bytesAsSlice(u32, image.pixels)[0]);
        try std.testing.expectEqual(if (swapped) @as(u32, 0x80204060) else @as(u32, 0x80604020), words[0]);
        try std.testing.expectEqual(@as(u32, 0xdeadbeef), words[1]);
    }
}

test "window thumbnails bound dimensions and retain independent pixels after source replacement" {
    const a = std.testing.allocator;
    const words = try a.alloc(u32, 2048 * 2);
    defer a.free(words);
    @memset(words, 0xff00ff00);
    const source: raster.Image = .{ .pixels = std.mem.sliceAsBytes(words), .width = 2048, .height = 2, .stride = 2048 * 4, .format = .argb };
    const image = try Image.thumbnail(a, source);
    defer image.deinit(a);
    @memset(words, 0xffff0000);
    try std.testing.expectEqual(@as(u32, 1024), image.width);
    try std.testing.expectEqual(@as(u32, 1), image.height);
    try std.testing.expectEqual(@as(u32, 0xff00ff00), std.mem.bytesAsSlice(u32, image.pixels)[512]);
    var invalid = source;
    invalid.pixels = &.{};
    try std.testing.expectError(error.InvalidImage, Image.thumbnail(a, invalid));
}

test "capture normalization handles padded byte formats and rejects incomplete rows" {
    const allocator = std.testing.allocator;
    const rgb = try Image.normalize(allocator, .{
        .pixels = &.{ 255, 0, 0, 0xde, 0, 0, 255 },
        .width = 1,
        .height = 2,
        .stride = 4,
        .format = .rgb,
    });
    defer rgb.deinit(allocator);
    try std.testing.expectEqualSlices(u32, &.{ 0xffff0000, 0xff0000ff }, std.mem.bytesAsSlice(u32, rgb.pixels));
    const rgba = try Image.normalize(allocator, .{
        .pixels = &.{ 255, 128, 0, 128, 255, 128, 0, 0 },
        .width = 2,
        .height = 1,
        .stride = 8,
        .format = .rgba,
    });
    defer rgba.deinit(allocator);
    try std.testing.expectEqualSlices(u32, &.{ 0x80804000, 0 }, std.mem.bytesAsSlice(u32, rgba.pixels));
    try std.testing.expectError(error.InvalidImage, Image.normalize(allocator, .{
        .pixels = &.{ 255, 0, 0, 0xde, 0, 0 },
        .width = 1,
        .height = 2,
        .stride = 4,
        .format = .rgb,
    }));
}
/// Per-axis filter taps: box averaging when shrinking, bilinear when growing,
/// with edges padded from the nearest source pixel.
const Taps = struct {
    first: []u32,
    weights: [][]f32,

    fn init(a: std.mem.Allocator, source: u32, target: u32) !Taps {
        const first = try a.alloc(u32, target);
        const weights = try a.alloc([]f32, target);
        const scale = @as(f64, @floatFromInt(source)) / @as(f64, @floatFromInt(target));
        const last: f64 = @floatFromInt(source - 1);
        for (0..target) |i| {
            const fi: f64 = @floatFromInt(i);
            if (scale > 1) {
                const lo = fi * scale;
                const hi = @min((fi + 1) * scale, @as(f64, @floatFromInt(source)));
                const start: u32 = @intFromFloat(@floor(lo));
                const end: u32 = @intFromFloat(@min(@ceil(hi), @as(f64, @floatFromInt(source))));
                first[i] = start;
                weights[i] = try a.alloc(f32, end - start);
                for (weights[i], start..) |*w, k| {
                    const fk: f64 = @floatFromInt(k);
                    w.* = @floatCast((@min(fk + 1, hi) - @max(fk, lo)) / scale);
                }
            } else {
                const center = std.math.clamp((fi + 0.5) * scale - 0.5, 0, last);
                const start: u32 = @intFromFloat(@floor(center));
                const t: f32 = @floatCast(center - @floor(center));
                first[i] = start;
                if (start + 1 < source and t > 0) {
                    weights[i] = try a.dupe(f32, &.{ 1 - t, t });
                } else {
                    weights[i] = try a.dupe(f32, &.{1});
                }
            }
        }
        return .{ .first = first, .weights = weights };
    }
};

/// Area-averages when shrinking and interpolates bilinearly when growing,
/// padding edges from the nearest pixel, like Cairo's GOOD filter.
pub fn resample(allocator: std.mem.Allocator, source: Image, width: u32, height: u32) !Image {
    if (width == 0 or height == 0 or source.width == 0 or source.height == 0) return error.InvalidImage;
    const stride = @as(usize, width) * 4;
    const image: Image = .{ .pixels = try allocator.alignedAlloc(u8, .of(u32), stride * height), .width = width, .height = height, .stride = stride };
    errdefer image.deinit(allocator);
    const in_stride = source.stride / 4;
    const input = std.mem.bytesAsSlice(u32, source.pixels);
    const output = std.mem.bytesAsSlice(u32, image.pixels);
    if (width == source.width and height == source.height) {
        for (0..height) |y| @memcpy(output[y * width ..][0..width], input[y * in_stride ..][0..width]);
        return image;
    }
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const horizontal = try Taps.init(a, source.width, width);
    const vertical = try Taps.init(a, source.height, height);
    // Horizontal pass into premultiplied float channels.
    const rows = try a.alloc([4]f32, @as(usize, width) * source.height);
    for (0..source.height) |y| for (0..width) |x| {
        var sum: [4]f32 = @splat(0);
        for (horizontal.weights[x], horizontal.first[x]..) |w, k| {
            const pixel = input[y * in_stride + k];
            inline for (0..4) |channel| sum[channel] += w * @as(f32, @floatFromInt((pixel >> (24 - 8 * channel)) & 255));
        }
        rows[y * width + x] = sum;
    };
    for (0..height) |y| for (0..width) |x| {
        var sum: [4]f32 = @splat(0);
        for (vertical.weights[y], vertical.first[y]..) |w, k| {
            const value = rows[k * width + x];
            inline for (0..4) |channel| sum[channel] += w * value[channel];
        }
        var pixel: u32 = 0;
        inline for (0..4) |channel| pixel |= @as(u32, @intFromFloat(@round(std.math.clamp(sum[channel], 0, 255)))) << (24 - 8 * channel);
        output[y * width + x] = pixel;
    };
    return image;
}

test "resample averages wide downscales without truncation and propagates OOM" {
    const a = std.testing.allocator;
    var words: [128]u32 = undefined;
    @memset(words[0..64], 0xff000000);
    @memset(words[64..128], 0xffffffff);
    const source: Image = .{ .pixels = std.mem.sliceAsBytes(&words), .width = 128, .height = 1, .stride = 128 * 4 };
    const shrunk = try resample(a, source, 1, 1);
    defer shrunk.deinit(a);
    try std.testing.expectEqual(@as(u32, 0xff808080), std.mem.bytesAsSlice(u32, shrunk.pixels)[0]);

    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 1 });
    try std.testing.expectError(error.OutOfMemory, resample(failing.allocator(), source, 1, 1));
}
