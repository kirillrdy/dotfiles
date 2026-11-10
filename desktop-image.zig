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

    /// Scale a capture into independent storage, retaining its premultiplied alpha.
    pub fn thumbnail(allocator: std.mem.Allocator, source: raster.Image) !Image {
        if (source.width == 0 or source.height == 0 or source.width > 8192 or source.height > 8192) return error.InvalidImage;
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
