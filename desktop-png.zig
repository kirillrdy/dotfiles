//! PNG encoding for native-endian Wayland ARGB/XRGB shared-memory buffers.
const std = @import("std");

pub const Image = struct {
    pixels: []const u8,
    width: u32,
    height: u32,
    stride: u32,
    alpha: bool = false,
    y_invert: bool = false,
};

fn chunk(writer: *std.Io.Writer, kind: *const [4]u8, bytes: []const u8) !void {
    try writer.writeInt(u32, @intCast(bytes.len), .big);
    try writer.writeAll(kind);
    try writer.writeAll(bytes);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(bytes);
    try writer.writeInt(u32, crc.final(), .big);
}

pub fn encode(a: std.mem.Allocator, image: Image) ![]u8 {
    if (image.width == 0 or image.height == 0 or image.width > 16384 or image.height > 16384 or
        @as(u64, image.width) * 4 > image.stride or @as(u64, image.stride) * image.height > image.pixels.len)
        return error.InvalidImage;
    const channels: usize = if (image.alpha) 4 else 3;
    const row = try a.alloc(u8, @as(usize, image.width) * channels + 1);
    defer a.free(row);
    const history = try a.alloc(u8, std.compress.flate.max_window_len);
    defer a.free(history);
    var compressed: std.Io.Writer.Allocating = try .initCapacity(a, 4096);
    defer compressed.deinit();
    var compressor = try std.compress.flate.Compress.init(&compressed.writer, history, .zlib, .fastest);
    for (0..image.height) |y| {
        const source_y = if (image.y_invert) image.height - 1 - y else y;
        const source = image.pixels[source_y * image.stride ..][0 .. @as(usize, image.width) * 4];
        row[0] = 1; // Sub filter: compress gradients without a second image buffer.
        var previous: [4]u8 = @splat(0);
        for (0..image.width) |x| {
            const pixel = std.mem.readInt(u32, source[x * 4 ..][0..4], @import("builtin").target.cpu.arch.endian());
            const alpha: u32 = if (image.alpha) pixel >> 24 else 255;
            for (0..channels) |channel| {
                const value: u8 = if (channel == 3) @intCast(alpha) else blk: {
                    const premultiplied = (pixel >> @as(u5, @intCast((2 - channel) * 8))) & 255;
                    // Wayland ARGB is premultiplied; PNG stores straight alpha.
                    break :blk if (alpha == 0) 0 else @intCast(@min(255, (premultiplied * 255 + alpha / 2) / alpha));
                };
                row[1 + x * channels + channel] = value -% previous[channel];
                previous[channel] = value;
            }
        }
        try compressor.writer.writeAll(row);
    }
    try compressor.finish();
    var png: std.Io.Writer.Allocating = .init(a);
    defer png.deinit();
    try png.writer.writeAll("\x89PNG\r\n\x1a\n");
    var header: [13]u8 = @splat(0);
    std.mem.writeInt(u32, header[0..4], image.width, .big);
    std.mem.writeInt(u32, header[4..8], image.height, .big);
    header[8] = 8;
    header[9] = if (image.alpha) 6 else 2;
    try chunk(&png.writer, "IHDR", &header);
    // Keep individual chunks bounded, even for very large noisy captures.
    var remaining = compressed.written();
    while (remaining.len > 0) {
        const count = @min(remaining.len, 64 * 1024);
        try chunk(&png.writer, "IDAT", remaining[0..count]);
        remaining = remaining[count..];
    }
    try chunk(&png.writer, "IEND", "");
    return png.toOwnedSlice();
}

test "PNG encoder rejects empty, truncated and invalid-stride images" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidImage, encode(a, .{ .pixels = "", .width = 0, .height = 1, .stride = 4 }));
    try std.testing.expectError(error.InvalidImage, encode(a, .{ .pixels = "1234", .width = 2, .height = 1, .stride = 4 }));
    try std.testing.expectError(error.InvalidImage, encode(a, .{ .pixels = "1234", .width = 1, .height = 2, .stride = 4 }));
}

test "PNG encoder writes signature and image header" {
    const pixels = [_]u32{0xff123456};
    const bytes = try encode(std.testing.allocator, .{ .pixels = std.mem.sliceAsBytes(&pixels), .width = 1, .height = 1, .stride = 4 });
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("\x89PNG\r\n\x1a\n", bytes[0..8]);
    try std.testing.expectEqualStrings("IHDR", bytes[12..16]);
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, bytes[16..20], .big));
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, bytes[20..24], .big));
}
