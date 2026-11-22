//! The desktop's only image decoder. PNG and SVG are decoded in Zig and
//! painted into owned premultiplied ARGB images. Release results with `free`.
const std = @import("std");
const png = @import("desktop-png.zig");
const svg = @import("desktop-svg.zig");
const vec = @import("desktop-path.zig");
pub const Image = @import("desktop-image.zig").Image;
pub const Symbolic = svg.Symbolic;
pub const Color = svg.Color;

const max_side = 8192;
const max_encoded = 64 << 20;

const Source = union(enum) {
    png: png.Decoded,
    svg: *svg.Document,

    fn open(allocator: std.mem.Allocator, data: []const u8) ?Source {
        if (std.mem.startsWith(u8, data, png.signature)) return .{ .png = png.decode(allocator, data) catch return null };
        return .{ .svg = svg.Document.parse(allocator, data) catch return null };
    }

    fn close(self: Source, allocator: std.mem.Allocator) void {
        switch (self) {
            .png => |image| allocator.free(image.pixels),
            .svg => |doc| doc.deinit(),
        }
    }

    fn size(self: Source) ?[2]u32 {
        const natural: [2]f64 = switch (self) {
            .png => |image| .{ @floatFromInt(image.width), @floatFromInt(image.height) },
            .svg => |doc| doc.size() orelse return null,
        };
        const width = natural[0];
        const height = natural[1];
        if (!(width >= 0.5 and height >= 0.5 and width <= max_side and height <= max_side)) return null;
        return .{ @intFromFloat(@ceil(width - 0.001)), @intFromFloat(@ceil(height - 0.001)) };
    }

    fn render(self: Source, allocator: std.mem.Allocator, width: u32, height: u32, options: svg.Options) ?Image {
        switch (self) {
            .png => |image| return @import("desktop-image.zig").resample(allocator, .{ .pixels = image.pixels, .width = image.width, .height = image.height, .stride = @as(usize, image.width) * 4 }, width, height) catch null,
            .svg => |doc| {
                const image = create(allocator, width, height) catch return null;
                @memset(image.pixels, 0);
                doc.render(allocator, vec.Target.fromBytes(image.pixels, width, height, image.stride), options) catch {
                    free(allocator, image);
                    return null;
                };
                return image;
            },
        }
    }
};

/// Fits a natural size into a `size` square, keeping its aspect ratio.
fn fit(natural: [2]u32, size: u32) [2]u32 {
    const width: f64 = @floatFromInt(natural[0]);
    const height: f64 = @floatFromInt(natural[1]);
    const box: f64 = @floatFromInt(size);
    if (width >= height) return .{ size, @max(1, @as(u32, @intFromFloat(height * box / width + 0.5))) };
    return .{ @max(1, @as(u32, @intFromFloat(width * box / height + 0.5))), size };
}

fn decodeWith(allocator: std.mem.Allocator, data: []const u8, size: ?u32, options: svg.Options) ?Image {
    if (size) |side| if (side == 0 or side > max_side) return null;
    const source = Source.open(allocator, data) orelse return null;
    defer source.close(allocator);
    const natural = source.size() orelse return null;
    const target = if (size) |side| fit(natural, side) else natural;
    return source.render(allocator, target[0], target[1], options);
}

/// Decodes PNG or SVG bytes at their natural size, or scaled to fit a `size` square.
pub fn bytes(allocator: std.mem.Allocator, data: []const u8, size: ?u32) ?Image {
    return decodeWith(allocator, data, size, .{});
}

/// Renders a symbolic SVG icon recolored with GTK's palette, faded by `opacity`.
pub fn symbolic(allocator: std.mem.Allocator, data: []const u8, size: u32, palette: Symbolic, opacity: f64) ?Image {
    return decodeWith(allocator, data, size, .{ .symbolic = palette, .opacity = std.math.clamp(opacity, 0, 1) });
}

/// Reads a whole image file, bounded by the decoder's input limit.
pub fn read(allocator: std.mem.Allocator, path: []const u8) ?[]const u8 {
    return @import("desktop-paths.zig").readFile(allocator, path, max_encoded) catch null;
}

/// Decodes a PNG or SVG file at its natural size, or scaled to fit a `size` square.
pub fn file(allocator: std.mem.Allocator, path: [*:0]const u8, size: ?u32) ?Image {
    const data = read(allocator, std.mem.span(path)) orelse return null;
    defer allocator.free(data);
    return bytes(allocator, data, size);
}

/// Reads the natural dimensions of encoded PNG or SVG bytes.
pub fn dimensions(allocator: std.mem.Allocator, data: []const u8) ?[2]u32 {
    if (std.mem.startsWith(u8, data, png.signature)) return png.dimensions(data);
    const source = Source.open(allocator, data) orelse return null;
    defer source.close(allocator);
    return source.size();
}

pub fn clone(allocator: std.mem.Allocator, image: Image) ?Image {
    const pixels = allocator.alignedAlloc(u8, .of(u32), image.pixels.len) catch return null;
    @memcpy(pixels, image.pixels);
    return .{ .pixels = pixels, .width = image.width, .height = image.height, .stride = image.stride };
}

pub fn free(allocator: std.mem.Allocator, image: Image) void {
    image.deinit(allocator);
}

/// Allocates an uninitialized image for tests and generated content.
pub fn create(allocator: std.mem.Allocator, width: u32, height: u32) !Image {
    const stride = @as(usize, width) * 4;
    return .{ .pixels = try allocator.alignedAlloc(u8, .of(u32), stride * height), .width = width, .height = height, .stride = stride };
}

test "decoded PNGs are premultiplied ARGB scaled to the requested square" {
    const allocator = std.testing.allocator;
    const pixels: [8]u32 = @splat(0x80800000);
    const data = try @import("desktop-png.zig").encode(std.testing.allocator, .{ .pixels = std.mem.sliceAsBytes(&pixels), .width = 4, .height = 2, .stride = 16, .alpha = true });
    defer std.testing.allocator.free(data);
    try std.testing.expectEqual([2]u32{ 4, 2 }, dimensions(allocator, data).?);
    const image = bytes(allocator, data, 8) orelse return error.Decode;
    defer free(allocator, image);
    try std.testing.expectEqual(@as(u32, 8), image.width);
    try std.testing.expectEqual(@as(u32, 4), image.height);
    for (std.mem.bytesAsSlice(u32, image.pixels)) |pixel| try std.testing.expectEqual(@as(u32, 0x80800000), pixel);
    const copy = clone(allocator, image) orelse return error.OutOfMemory;
    defer free(allocator, copy);
    try std.testing.expectEqualSlices(u8, image.pixels, copy.pixels);
    try std.testing.expectEqual(@as(?Image, null), bytes(allocator, data[0 .. data.len - 20], null));
}

test "SVGs render at their intrinsic or viewBox size and fit a requested square" {
    const allocator = std.testing.allocator;
    const sized = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"6\" height=\"3\"><rect width=\"6\" height=\"3\" fill=\"#00f\"/></svg>";
    try std.testing.expectEqual([2]u32{ 6, 3 }, dimensions(allocator, sized).?);
    const natural = bytes(allocator, sized, null) orelse return error.Decode;
    defer free(allocator, natural);
    try std.testing.expectEqual(@as(u32, 6), natural.width);
    try std.testing.expectEqual(@as(u32, 0xff0000ff), std.mem.bytesAsSlice(u32, natural.pixels)[0]);
    const boxed = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 2 4\"><rect width=\"2\" height=\"4\"/></svg>";
    const scaled = bytes(allocator, boxed, 16) orelse return error.Decode;
    defer free(allocator, scaled);
    try std.testing.expectEqual([2]u32{ 8, 16 }, [2]u32{ scaled.width, scaled.height });
    try std.testing.expectEqual(@as(?Image, null), bytes(allocator, "not an image", 16));
}

test "PNG resampling averages when shrinking and pads edges when growing" {
    const allocator = std.testing.allocator;
    var pixels = [_]u32{ 0xff000000, 0xffffffff, 0xff000000, 0xffffffff };
    const resample = @import("desktop-image.zig").resample;
    const shrunk = try resample(allocator, .{ .pixels = std.mem.sliceAsBytes(&pixels), .width = 4, .height = 1, .stride = 16 }, 2, 1);
    defer free(allocator, shrunk);
    for (std.mem.bytesAsSlice(u32, shrunk.pixels)) |pixel| try std.testing.expectEqual(@as(u32, 0xff808080), pixel);
    var single = [_]u32{0xff00ff00};
    const grown = try resample(allocator, .{ .pixels = std.mem.sliceAsBytes(&single), .width = 1, .height = 1, .stride = 4 }, 3, 3);
    defer free(allocator, grown);
    for (std.mem.bytesAsSlice(u32, grown.pixels)) |pixel| try std.testing.expectEqual(@as(u32, 0xff00ff00), pixel);
}
