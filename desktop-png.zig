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

pub const DecodedImage = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    channels: u8,
    stride: usize,

    pub fn deinit(self: *DecodedImage, a: std.mem.Allocator) void {
        a.free(self.pixels);
    }
};

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i32, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

pub fn decode(a: std.mem.Allocator, bytes: []const u8) !DecodedImage {
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) {
        return error.InvalidSignature;
    }

    var width: u32 = 0;
    var height: u32 = 0;
    var bit_depth: u8 = 0;
    var color_type: u8 = 0;
    var channels: u8 = 0;
    var idat_chunks: std.ArrayList(u8) = .empty;
    defer idat_chunks.deinit(a);

    var offset: usize = 8;
    while (offset + 12 <= bytes.len) {
        const chunk_len = std.mem.readInt(u32, bytes[offset..][0..4], .big);
        const chunk_type = bytes[offset + 4 .. offset + 8];
        const data_start = offset + 8;
        const data_end = data_start + chunk_len;
        if (data_end + 4 > bytes.len) return error.TruncatedChunk;

        var crc = std.hash.Crc32.init();
        crc.update(chunk_type);
        crc.update(bytes[data_start..data_end]);
        const expected_crc = std.mem.readInt(u32, bytes[data_end..][0..4], .big);
        if (crc.final() != expected_crc) return error.CorruptChunk;

        if (std.mem.eql(u8, chunk_type, "IHDR")) {
            if (chunk_len < 13) return error.InvalidHeader;
            width = std.mem.readInt(u32, bytes[data_start..][0..4], .big);
            height = std.mem.readInt(u32, bytes[data_start + 4 ..][0..4], .big);
            bit_depth = bytes[data_start + 8];
            color_type = bytes[data_start + 9];
            const compression = bytes[data_start + 10];
            const filter = bytes[data_start + 11];
            const interlace = bytes[data_start + 12];

            if (width == 0 or height == 0 or width > 16384 or height > 16384) return error.InvalidDimensions;
            if (bit_depth != 8) return error.UnsupportedBitDepth;
            if (compression != 0 or filter != 0) return error.UnsupportedFormat;
            if (interlace != 0) return error.UnsupportedInterlacing;

            channels = switch (color_type) {
                0 => 1,
                2 => 3,
                6 => 4,
                else => return error.UnsupportedColorType,
            };
        } else if (std.mem.eql(u8, chunk_type, "IDAT")) {
            try idat_chunks.appendSlice(a, bytes[data_start..data_end]);
        } else if (std.mem.eql(u8, chunk_type, "IEND")) {
            break;
        }

        offset = data_end + 4;
    }

    if (width == 0 or height == 0 or channels == 0) return error.MissingHeader;
    if (idat_chunks.items.len == 0) return error.MissingData;

    const row_bytes = @as(usize, width) * channels;
    const decompressed_len = (row_bytes + 1) * height;
    const raw = try a.alloc(u8, decompressed_len);
    defer a.free(raw);

    var in_reader: std.Io.Reader = .fixed(idat_chunks.items);
    var flate_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress = std.compress.flate.Decompress.init(&in_reader, .zlib, &flate_buffer);
    try decompress.reader.readSliceAll(raw);

    const out_stride = row_bytes;
    const pixels = try a.alloc(u8, out_stride * height);
    errdefer a.free(pixels);

    const bpp = channels;
    for (0..height) |y| {
        const row_start = y * (row_bytes + 1);
        const filter_type = raw[row_start];
        const row_data = raw[row_start + 1 .. row_start + 1 + row_bytes];
        const out_row = pixels[y * out_stride .. (y + 1) * out_stride];
        const prev_row = if (y > 0) pixels[(y - 1) * out_stride .. y * out_stride] else null;

        switch (filter_type) {
            0 => {
                @memcpy(out_row, row_data);
            },
            1 => {
                for (0..row_bytes) |i| {
                    const left = if (i >= bpp) out_row[i - bpp] else 0;
                    out_row[i] = row_data[i] +% left;
                }
            },
            2 => {
                for (0..row_bytes) |i| {
                    const up = if (prev_row) |p| p[i] else 0;
                    out_row[i] = row_data[i] +% up;
                }
            },
            3 => {
                for (0..row_bytes) |i| {
                    const left: u32 = if (i >= bpp) out_row[i - bpp] else 0;
                    const up: u32 = if (prev_row) |p| p[i] else 0;
                    out_row[i] = row_data[i] +% @as(u8, @intCast((left + up) / 2));
                }
            },
            4 => {
                for (0..row_bytes) |i| {
                    const left = if (i >= bpp) out_row[i - bpp] else 0;
                    const up = if (prev_row) |p| p[i] else 0;
                    const up_left = if (prev_row != null and i >= bpp) prev_row.?[i - bpp] else 0;
                    out_row[i] = row_data[i] +% paeth(left, up, up_left);
                }
            },
            else => return error.InvalidFilter,
        }
    }

    return DecodedImage{
        .pixels = pixels,
        .width = width,
        .height = height,
        .channels = channels,
        .stride = out_stride,
    };
}

test "PNG decode roundtrips through encode" {
    const a = std.testing.allocator;
    const pixels = [_]u32{ 0xff112233, 0xff445566, 0xff778899, 0xffaabbcc };
    const encoded = try encode(a, .{
        .pixels = std.mem.sliceAsBytes(&pixels),
        .width = 2,
        .height = 2,
        .stride = 8,
        .alpha = false,
    });
    defer a.free(encoded);

    var decoded = try decode(a, encoded);
    defer decoded.deinit(a);

    try std.testing.expectEqual(@as(u32, 2), decoded.width);
    try std.testing.expectEqual(@as(u32, 2), decoded.height);
    try std.testing.expectEqual(@as(u8, 3), decoded.channels);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc }, decoded.pixels);
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
