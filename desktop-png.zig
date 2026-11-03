//! Opaque PNG encoding of native-endian XRGB/ARGB capture pixels.
//! Uses Zig's zlib compressor; no Cairo or libpng encoding dependency.
const std = @import("std");

pub const Image = struct {
    pixels: []const u8,
    width: u32,
    height: u32,
    stride: usize,
    y_invert: bool = false,
};

fn chunk(output: *std.Io.Writer, kind: *const [4]u8, data: []const u8) !void {
    if (data.len > std.math.maxInt(u31)) return error.ImageTooLarge;
    try output.writeInt(u32, @intCast(data.len), .big);
    try output.writeAll(kind);
    try output.writeAll(data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    try output.writeInt(u32, crc.final(), .big);
}

/// Captures are opaque: ignore the high byte, including XRGB's undefined bits.
/// Keep only a filtered row and the compressor window in addition to the output.
pub fn encode(allocator: std.mem.Allocator, image: Image) ![]u8 {
    if (image.width == 0 or image.height == 0 or image.width > 16384 or image.height > 16384) return error.InvalidImage;
    const pixel_bytes = try std.math.mul(usize, image.width, 4);
    const required = try std.math.add(usize, try std.math.mul(usize, image.height - 1, image.stride), pixel_bytes);
    if (image.stride < pixel_bytes or image.pixels.len < required) return error.InvalidImage;
    const row = try allocator.alloc(u8, @as(usize, image.width) * 3 + 1);
    defer allocator.free(row);
    const window = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(window);
    var compressed = try std.Io.Writer.Allocating.initCapacity(allocator, 4096);
    defer compressed.deinit();
    var compressor = try std.compress.flate.Compress.init(&compressed.writer, window, .zlib, .default);
    for (0..image.height) |y| {
        const source_y = if (image.y_invert) image.height - 1 - y else y;
        const source = image.pixels[source_y * image.stride ..][0..pixel_bytes];
        row[0] = 1; // Sub filter compresses horizontal runs without a second row.
        var previous: [3]u8 = @splat(0);
        for (0..image.width) |x| {
            const pixel = std.mem.readInt(u32, source[x * 4 ..][0..4], @import("builtin").cpu.arch.endian());
            const rgb: [3]u8 = .{ @truncate(pixel >> 16), @truncate(pixel >> 8), @truncate(pixel) };
            for (rgb, 0..) |value, channel| row[1 + x * 3 + channel] = value -% previous[channel];
            previous = rgb;
        }
        try compressor.writer.writeAll(row);
    }
    try compressor.finish();

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try output.writer.writeAll("\x89PNG\r\n\x1a\n");
    var header: [13]u8 = @splat(0);
    std.mem.writeInt(u32, header[0..4], image.width, .big);
    std.mem.writeInt(u32, header[4..8], image.height, .big);
    header[8] = 8;
    header[9] = 2; // Eight-bit RGB, no alpha.
    try chunk(&output.writer, "IHDR", &header);
    // Bound chunk sizes independently of the compressed image dimensions.
    var remaining: []const u8 = compressed.written();
    while (remaining.len > 0) {
        const size = @min(remaining.len, 65536);
        try chunk(&output.writer, "IDAT", remaining[0..size]);
        remaining = remaining[size..];
    }
    try chunk(&output.writer, "IEND", "");
    return output.toOwnedSlice();
}

test "PNG rejects empty, truncated, short-stride and oversized images" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidImage, encode(a, .{ .pixels = &.{}, .width = 0, .height = 1, .stride = 0 }));
    try std.testing.expectError(error.InvalidImage, encode(a, .{ .pixels = &.{}, .width = 1, .height = 1, .stride = 4 }));
    try std.testing.expectError(error.InvalidImage, encode(a, .{ .pixels = &.{ 0, 0, 0, 0 }, .width = 1, .height = 1, .stride = 3 }));
    try std.testing.expectError(error.InvalidImage, encode(a, .{ .pixels = &.{}, .width = 16385, .height = 1, .stride = 65540 }));
}
