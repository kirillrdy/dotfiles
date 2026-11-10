//! Owned opaque native-endian RGB pixels, independent of toolkit objects.
const std = @import("std");
const png = @import("desktop-png.zig");

pub const Image = struct {
    pixels: []u8,
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
        const pixels = try allocator.alloc(u8, stride * source.height);
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
