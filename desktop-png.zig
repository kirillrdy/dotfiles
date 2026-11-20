//! PNG encoding of native-endian XRGB/ARGB capture pixels and decoding of any
//! standard PNG to premultiplied ARGB, using Zig's zlib; no Cairo or libpng.
const std = @import("std");

pub const Image = struct {
    pixels: []const u8,
    width: u32,
    height: u32,
    stride: usize,
    y_invert: bool = false,
    /// Keep premultiplied alpha as straight RGBA instead of encoding opaque RGB.
    alpha: bool = false,
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

/// Captures are opaque unless `alpha` is set: ignore the high byte, including
/// XRGB's undefined bits.
/// Keep only a filtered row and the compressor window in addition to the output.
pub fn encode(allocator: std.mem.Allocator, image: Image) ![]u8 {
    if (image.width == 0 or image.height == 0 or image.width > 16384 or image.height > 16384) return error.InvalidImage;
    const pixel_bytes = try std.math.mul(usize, image.width, 4);
    const required = try std.math.add(usize, try std.math.mul(usize, image.height - 1, image.stride), pixel_bytes);
    if (image.stride < pixel_bytes or image.pixels.len < required) return error.InvalidImage;
    const channels: usize = if (image.alpha) 4 else 3;
    const row = try allocator.alloc(u8, @as(usize, image.width) * channels + 1);
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
        var previous: [4]u8 = @splat(0);
        for (0..image.width) |x| {
            const pixel = std.mem.readInt(u32, source[x * 4 ..][0..4], @import("builtin").cpu.arch.endian());
            const alpha = if (image.alpha) pixel >> 24 else 255;
            var rgba: [4]u8 = .{ 0, 0, 0, @intCast(alpha) };
            if (alpha != 0) for (rgba[0..3], [_]u5{ 16, 8, 0 }) |*value, shift| {
                value.* = @intCast(@min(255, (((pixel >> shift) & 255) * 255 + alpha / 2) / alpha));
            };
            for (rgba[0..channels], 0..) |value, channel| row[1 + x * channels + channel] = value -% previous[channel];
            previous = rgba;
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
    header[9] = if (image.alpha) 6 else 2; // Eight-bit RGBA or RGB.
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

/// Premultiplied native-endian ARGB pixels with a stride of `width * 4`.
pub const Decoded = struct {
    pixels: []align(@alignOf(u32)) u8,
    width: u32,
    height: u32,
};

pub const signature = "\x89PNG\r\n\x1a\n";
const max_side = 16384;
const max_pixels = 64 << 20;

const Header = struct {
    width: u32,
    height: u32,
    depth: u8,
    color: u8,
    interlaced: bool,

    fn channels(self: Header) u8 {
        return switch (self.color) {
            0, 3 => 1,
            2 => 3,
            4 => 2,
            6 => 4,
            else => unreachable,
        };
    }
    fn bitsPerPixel(self: Header) usize {
        return @as(usize, self.channels()) * self.depth;
    }
    fn rowBytes(self: Header, width: usize) usize {
        return (width * self.bitsPerPixel() + 7) / 8;
    }
};

const Pass = struct { x: u8, y: u8, dx: u8, dy: u8 };
const adam7 = [_]Pass{
    .{ .x = 0, .y = 0, .dx = 8, .dy = 8 },
    .{ .x = 4, .y = 0, .dx = 8, .dy = 8 },
    .{ .x = 0, .y = 4, .dx = 4, .dy = 8 },
    .{ .x = 2, .y = 0, .dx = 4, .dy = 4 },
    .{ .x = 0, .y = 2, .dx = 2, .dy = 4 },
    .{ .x = 1, .y = 0, .dx = 2, .dy = 2 },
    .{ .x = 0, .y = 1, .dx = 1, .dy = 2 },
};
const progressive = [_]Pass{.{ .x = 0, .y = 0, .dx = 1, .dy = 1 }};

fn passSize(full: u32, start: u8, step: u8) usize {
    if (full <= start) return 0;
    return (full - start + step - 1) / step;
}

/// Reads the dimensions from the IHDR chunk, which must come first.
pub fn dimensions(data: []const u8) ?[2]u32 {
    if (data.len < 24 or !std.mem.startsWith(u8, data, signature) or !std.mem.eql(u8, data[12..16], "IHDR")) return null;
    const width = std.mem.readInt(u32, data[16..20], .big);
    const height = std.mem.readInt(u32, data[20..24], .big);
    if (width == 0 or height == 0 or width > max_side or height > max_side) return null;
    return .{ width, height };
}

/// Decodes every standard color type, bit depth and interlace method.
/// Ancillary chunks other than tRNS are ignored, including gamma.
pub fn decode(allocator: std.mem.Allocator, data: []const u8) !Decoded {
    if (!std.mem.startsWith(u8, data, signature)) return error.InvalidImage;
    var header: ?Header = null;
    var palette: [256][4]u8 = @splat(.{ 0, 0, 0, 255 });
    var palette_len: usize = 0;
    var key: ?[3]u16 = null;
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(allocator);
    var rest = data[signature.len..];
    while (true) {
        if (rest.len < 12) return error.InvalidImage;
        const len = std.mem.readInt(u32, rest[0..4], .big);
        if (len > rest.len - 12) return error.InvalidImage;
        const kind = rest[4..8];
        const body = rest[8..][0..len];
        rest = rest[12 + len ..];
        if (header == null and !std.mem.eql(u8, kind, "IHDR")) return error.InvalidImage;
        if (std.mem.eql(u8, kind, "IHDR")) {
            if (len != 13 or header != null) return error.InvalidImage;
            const value: Header = .{
                .width = std.mem.readInt(u32, body[0..4], .big),
                .height = std.mem.readInt(u32, body[4..8], .big),
                .depth = body[8],
                .color = body[9],
                .interlaced = body[12] == 1,
            };
            const valid_depth = switch (value.color) {
                0 => value.depth == 1 or value.depth == 2 or value.depth == 4 or value.depth == 8 or value.depth == 16,
                3 => value.depth == 1 or value.depth == 2 or value.depth == 4 or value.depth == 8,
                2, 4, 6 => value.depth == 8 or value.depth == 16,
                else => false,
            };
            if (!valid_depth or body[10] != 0 or body[11] != 0 or body[12] > 1) return error.InvalidImage;
            if (value.width == 0 or value.height == 0 or value.width > max_side or value.height > max_side) return error.InvalidImage;
            if (@as(u64, value.width) * value.height > max_pixels) return error.InvalidImage;
            header = value;
        } else if (std.mem.eql(u8, kind, "PLTE")) {
            if (len % 3 != 0 or len / 3 > 256) return error.InvalidImage;
            palette_len = len / 3;
            for (0..palette_len) |i| palette[i] = .{ body[i * 3], body[i * 3 + 1], body[i * 3 + 2], 255 };
        } else if (std.mem.eql(u8, kind, "tRNS")) {
            switch (header.?.color) {
                3 => for (body[0..@min(len, 256)], 0..) |alpha, i| {
                    palette[i][3] = alpha;
                },
                0 => if (len >= 2) {
                    const gray = std.mem.readInt(u16, body[0..2], .big);
                    key = .{ gray, gray, gray };
                },
                2 => if (len >= 6) {
                    key = .{ std.mem.readInt(u16, body[0..2], .big), std.mem.readInt(u16, body[2..4], .big), std.mem.readInt(u16, body[4..6], .big) };
                },
                else => {},
            }
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(allocator, body);
        } else if (std.mem.eql(u8, kind, "IEND")) {
            break;
        }
    }
    const h = header orelse return error.InvalidImage;
    if (h.color == 3 and palette_len == 0) return error.InvalidImage;
    const passes: []const Pass = if (h.interlaced) &adam7 else &progressive;
    var expected: usize = 0;
    for (passes) |pass| {
        const pw = passSize(h.width, pass.x, pass.dx);
        const ph = passSize(h.height, pass.y, pass.dy);
        if (pw != 0) expected += ph * (1 + h.rowBytes(pw));
    }
    var input: std.Io.Reader = .fixed(idat.items);
    var inflate: std.compress.flate.Decompress = .init(&input, .zlib, &.{});
    const raw = inflate.reader.allocRemaining(allocator, .limited(expected + 1)) catch |err| switch (err) {
        error.StreamTooLong => return error.InvalidImage,
        error.OutOfMemory => return error.OutOfMemory,
        error.ReadFailed => return error.InvalidImage,
    };
    defer allocator.free(raw);
    if (raw.len < expected) return error.InvalidImage;

    const stride = @as(usize, h.width) * 4;
    const pixels = try allocator.alignedAlloc(u8, .of(u32), stride * h.height);
    errdefer allocator.free(pixels);
    const output = std.mem.bytesAsSlice(u32, pixels);
    const bpp = @max(1, h.bitsPerPixel() / 8);
    var offset: usize = 0;
    for (passes) |pass| {
        const pw = passSize(h.width, pass.x, pass.dx);
        const ph = passSize(h.height, pass.y, pass.dy);
        if (pw == 0 or ph == 0) continue;
        const row_bytes = h.rowBytes(pw);
        var previous: []const u8 = &.{};
        for (0..ph) |row| {
            const filter = raw[offset];
            const line = raw[offset + 1 ..][0..row_bytes];
            offset += 1 + row_bytes;
            try unfilter(filter, line, previous, bpp);
            previous = line;
            const y = pass.y + row * pass.dy;
            // Fast path: 8-bit RGBA or RGB rows of a non-interlaced image.
            if (pass.dx == 1 and h.depth == 8 and (h.color == 6 or (h.color == 2 and key == null))) {
                const out = output[y * h.width ..][0..pw];
                if (h.color == 6) rgbaRow(out, line) else rgbRow(out, line);
                continue;
            }
            for (0..pw) |column| {
                const x = pass.x + column * pass.dx;
                output[y * h.width + x] = decodePixel(h, line, column, &palette, palette_len, key);
            }
        }
    }
    return .{ .pixels = pixels, .width = h.width, .height = h.height };
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

fn unfilter(filter: u8, line: []u8, previous: []const u8, bpp: usize) !void {
    for (line, 0..) |*value, i| {
        const left: u8 = if (i >= bpp) line[i - bpp] else 0;
        const up: u8 = if (previous.len > 0) previous[i] else 0;
        const corner: u8 = if (previous.len > 0 and i >= bpp) previous[i - bpp] else 0;
        value.* +%= switch (filter) {
            0 => 0,
            1 => left,
            2 => up,
            3 => @intCast((@as(u16, left) + up) / 2),
            4 => paeth(left, up, corner),
            else => return error.InvalidImage,
        };
    }
}

fn sample(h: Header, line: []const u8, index: usize) u16 {
    return switch (h.depth) {
        16 => std.mem.readInt(u16, line[index * 2 ..][0..2], .big),
        8 => line[index],
        else => blk: {
            const bit = index * h.depth;
            const shift: u3 = @intCast(8 - h.depth - bit % 8);
            break :blk (line[bit / 8] >> shift) & ((@as(u8, 1) << @intCast(h.depth)) - 1);
        },
    };
}

fn to8(h: Header, value: u16) u32 {
    return switch (h.depth) {
        16 => value >> 8,
        8 => value,
        else => @as(u32, value) * 255 / ((@as(u32, 1) << @intCast(h.depth)) - 1),
    };
}

fn decodePixel(h: Header, line: []const u8, column: usize, palette: *const [256][4]u8, palette_len: usize, key: ?[3]u16) u32 {
    const channels = h.channels();
    var rgba: [4]u32 = .{ 0, 0, 0, 255 };
    switch (h.color) {
        3 => {
            const index = sample(h, line, column);
            if (index >= palette_len) return 0;
            for (&rgba, palette[index]) |*out, value| out.* = value;
        },
        0, 4 => {
            const gray = sample(h, line, column * channels);
            rgba[0] = to8(h, gray);
            rgba[1] = rgba[0];
            rgba[2] = rgba[0];
            if (h.color == 4) rgba[3] = to8(h, sample(h, line, column * channels + 1));
            if (key) |k| if (gray == k[0]) return 0;
        },
        2, 6 => {
            var raw: [3]u16 = undefined;
            for (&raw, 0..) |*value, i| value.* = sample(h, line, column * channels + i);
            for (rgba[0..3], raw) |*out, value| out.* = to8(h, value);
            if (h.color == 6) rgba[3] = to8(h, sample(h, line, column * channels + 3));
            if (key) |k| if (std.mem.eql(u16, &raw, &k)) return 0;
        },
        else => unreachable,
    }
    const alpha = rgba[3];
    if (alpha == 0) return 0;
    var result = alpha << 24;
    for (rgba[0..3], [_]u5{ 16, 8, 0 }) |value, shift| result |= ((value * alpha + 127) / 255) << shift;
    return result;
}

test "PNG decoding round-trips encoded premultiplied pixels" {
    const a = std.testing.allocator;
    const source = [_]u32{ 0xff102030, 0x80400000, 0x00000000, 0xffffffff, 0x40102030, 0xff000000 };
    for ([_]bool{ true, false }) |alpha| {
        const encoded = try encode(a, .{ .pixels = std.mem.sliceAsBytes(&source), .width = 3, .height = 2, .stride = 12, .alpha = alpha });
        defer a.free(encoded);
        try std.testing.expectEqual([2]u32{ 3, 2 }, dimensions(encoded).?);
        const decoded = try decode(a, encoded);
        defer a.free(decoded.pixels);
        const words = std.mem.bytesAsSlice(u32, decoded.pixels);
        for (source, words) |expected, actual| {
            if (!alpha) {
                try std.testing.expectEqual(@as(u32, 0xff), actual >> 24);
                continue;
            }
            // Un-premultiplying and premultiplying again may round by one.
            for ([_]u5{ 24, 16, 8, 0 }) |shift| {
                const e: i32 = @intCast((expected >> shift) & 255);
                const g: i32 = @intCast((actual >> shift) & 255);
                try std.testing.expect(@abs(e - g) <= 1);
            }
        }
    }
}

test "PNG decoding handles palettes, low bit depths, transparency keys and interlacing" {
    const a = std.testing.allocator;
    // 2x2 one-bit palette image, Adam7 interlaced, palette entry 1 transparent.
    // Generated with Python zlib: rows "\x00\x40" each (pixels 0,1 / 0,1) split into passes.
    var raw: std.Io.Writer.Allocating = .init(a);
    defer raw.deinit();
    // Pass 1: pixel (0,0) = 0. Pass 6: pixel (1,0) = 1. Pass 7: row 1 = 0,1.
    try raw.writer.writeAll(&.{ 0, 0x00, 0, 0x80, 0, 0x40 });
    var zlib = try std.Io.Writer.Allocating.initCapacity(a, 64);
    defer zlib.deinit();
    const window = try a.alloc(u8, std.compress.flate.max_window_len);
    defer a.free(window);
    var compressor = try std.compress.flate.Compress.init(&zlib.writer, window, .zlib, .default);
    try compressor.writer.writeAll(raw.written());
    try compressor.finish();
    var file: std.Io.Writer.Allocating = .init(a);
    defer file.deinit();
    try file.writer.writeAll(signature);
    try chunk(&file.writer, "IHDR", &.{ 0, 0, 0, 2, 0, 0, 0, 2, 1, 3, 0, 0, 1 });
    try chunk(&file.writer, "PLTE", &.{ 255, 0, 0, 0, 0, 255 });
    try chunk(&file.writer, "tRNS", &.{ 255, 0 });
    try chunk(&file.writer, "IDAT", zlib.written());
    try chunk(&file.writer, "IEND", "");
    const decoded = try decode(a, file.written());
    defer a.free(decoded.pixels);
    try std.testing.expectEqualSlices(u32, &.{ 0xffff0000, 0, 0xffff0000, 0 }, std.mem.bytesAsSlice(u32, decoded.pixels));
    try std.testing.expectError(error.InvalidImage, decode(a, file.written()[0..40]));
    try std.testing.expectError(error.InvalidImage, decode(a, "not a png"));
}

/// Straight 8-bit RGBA to premultiplied ARGB, exact x * a / 255 rounding.
fn rgbaRow(out: []u32, line: []const u8) void {
    @setRuntimeSafety(false);
    for (out, 0..) |*pixel, i| {
        const p = line[i * 4 ..][0..4];
        const alpha: u32 = p[3];
        if (alpha == 255) {
            pixel.* = 0xff000000 | (@as(u32, p[0]) << 16) | (@as(u32, p[1]) << 8) | p[2];
        } else if (alpha == 0) {
            pixel.* = 0;
        } else {
            pixel.* = (alpha << 24) | (((@as(u32, p[0]) * alpha + 127) / 255) << 16) | (((@as(u32, p[1]) * alpha + 127) / 255) << 8) | ((@as(u32, p[2]) * alpha + 127) / 255);
        }
    }
}

fn rgbRow(out: []u32, line: []const u8) void {
    @setRuntimeSafety(false);
    for (out, 0..) |*pixel, i| {
        const p = line[i * 3 ..][0..3];
        pixel.* = 0xff000000 | (@as(u32, p[0]) << 16) | (@as(u32, p[1]) << 8) | p[2];
    }
}
