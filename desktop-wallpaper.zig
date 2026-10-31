//! Native Wayland backgrounds with Zig scaling and a shared decoded image.
const std = @import("std");
const allocator = std.heap.page_allocator;

const libc = @import("desktop-libc.zig");
const surfaces = @import("desktop-surface.zig");
const Loop = @import("desktop-surface-loop.zig").Loop;
const png = @import("desktop-png.zig");
pub const DecodedImage = png.DecodedImage;

fn decodePpm(a: std.mem.Allocator, bytes: []const u8) !DecodedImage {
    var pos: usize = 2; // skip "P6"
    const nextToken = struct {
        fn get(b: []const u8, p: *usize) ?[]const u8 {
            while (p.* < b.len) {
                const ch = b[p.*];
                if (ch == '#') {
                    while (p.* < b.len and b[p.*] != '\n') p.* += 1;
                } else if (ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n') {
                    p.* += 1;
                } else break;
            }
            if (p.* >= b.len) return null;
            const start = p.*;
            while (p.* < b.len and b[p.*] != ' ' and b[p.*] != '\t' and b[p.*] != '\r' and b[p.*] != '\n' and b[p.*] != '#') p.* += 1;
            return b[start..p.*];
        }
    }.get;

    const w_str = nextToken(bytes, &pos) orelse return error.InvalidPpm;
    const h_str = nextToken(bytes, &pos) orelse return error.InvalidPpm;
    const max_str = nextToken(bytes, &pos) orelse return error.InvalidPpm;
    const width = std.fmt.parseInt(u32, w_str, 10) catch return error.InvalidPpm;
    const height = std.fmt.parseInt(u32, h_str, 10) catch return error.InvalidPpm;
    const max_val = std.fmt.parseInt(u32, max_str, 10) catch return error.InvalidPpm;
    if (max_val != 255 or width == 0 or height == 0) return error.InvalidPpm;

    if (pos >= bytes.len) return error.InvalidPpm;
    pos += 1;
    const total_pixels = @as(usize, width) * height * 3;
    if (bytes.len - pos < total_pixels) return error.TruncatedPpm;

    const pixels = try a.alloc(u8, total_pixels);
    @memcpy(pixels, bytes[pos .. pos + total_pixels]);

    return DecodedImage{
        .pixels = pixels,
        .width = width,
        .height = height,
        .channels = 3,
        .stride = width * 3,
    };
}

pub fn loadImage(a: std.mem.Allocator, path: [:0]const u8) !DecodedImage {
    const fd = libc.open(path.ptr, libc.O_RDONLY | libc.O_CLOEXEC, @as(c_uint, 0));
    if (fd < 0) return error.FileNotFound;
    defer _ = libc.close(fd);

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(a);

    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const rc = libc.read(fd, &buf, buf.len);
        if (rc < 0) return error.ReadFailed;
        if (rc == 0) break;
        try list.appendSlice(a, buf[0..@intCast(rc)]);
    }

    if (list.items.len >= 8 and std.mem.eql(u8, list.items[0..8], "\x89PNG\r\n\x1a\n")) {
        return png.decode(a, list.items);
    } else if (list.items.len >= 3 and list.items[0] == 'P' and list.items[1] == '6') {
        return decodePpm(a, list.items);
    } else {
        return error.UnsupportedImageFormat;
    }
}

fn paint(frame: surfaces.Frame, image: *const DecodedImage) void {
    const iw: usize = image.width;
    const ih: usize = image.height;
    const channels: usize = image.channels;
    const source_stride: usize = image.stride;
    const source = image.pixels;
    const width: usize = @intCast(frame.layout.width);
    const height: usize = @intCast(frame.layout.height);
    const stride: usize = @intCast(@divTrunc(frame.layout.stride, 4));
    const pixels: [*]u32 = @ptrCast(@alignCast(frame.pixels));
    const sw: f64 = @floatFromInt(iw);
    const sh: f64 = @floatFromInt(ih);
    const dw: f64 = @floatFromInt(width);
    const dh: f64 = @floatFromInt(height);
    const scale = @max(dw / sw, dh / sh);
    for (0..height) |y| {
        // Sample pixel centers and clamp to the image edges, so scaling never
        // introduces a black border. Center cropping is done in buffer pixels.
        const sy = std.math.clamp((@as(f64, @floatFromInt(y)) + 0.5 - dh / 2) / scale + sh / 2 - 0.5, 0, sh - 1);
        const y0: usize = @intFromFloat(sy);
        const y1 = @min(y0 + 1, ih - 1);
        const fy = sy - @as(f64, @floatFromInt(y0));
        for (0..width) |x| {
            const sx = std.math.clamp((@as(f64, @floatFromInt(x)) + 0.5 - dw / 2) / scale + sw / 2 - 0.5, 0, sw - 1);
            const x0: usize = @intFromFloat(sx);
            const x1 = @min(x0 + 1, iw - 1);
            const fx = sx - @as(f64, @floatFromInt(x0));
            const offsets = [4]usize{ y0 * source_stride + x0 * channels, y0 * source_stride + x1 * channels, y1 * source_stride + x0 * channels, y1 * source_stride + x1 * channels };
            const weights = [4]f64{ (1 - fx) * (1 - fy), fx * (1 - fy), (1 - fx) * fy, fx * fy };
            var pixel: u32 = 0xff000000;
            for (0..3) |channel| {
                var value: f64 = 0;
                for (offsets, weights) |offset, weight| {
                    // Premultiply before interpolation to avoid colored fringes
                    // around transparent pixels; composite over opaque black.
                    const alpha: f64 = if (channels == 4) @as(f64, @floatFromInt(source[offset + 3])) / 255 else 1;
                    value += @as(f64, @floatFromInt(source[offset + channel])) * alpha * weight;
                }
                const component: u32 = @intFromFloat(@round(std.math.clamp(value, 0, 255)));
                pixel |= component << @as(u5, @intCast((2 - channel) * 8));
            }
            pixels[y * stride + x] = pixel;
        }
    }
}

test "fill crops the center of wide and tall images at both buffer scales" {
    for ([_]bool{ false, true }) |vertical| {
        const iw: u32 = if (vertical) 4 else 12;
        const ih: u32 = if (vertical) 12 else 4;
        const stride: usize = iw * 3;
        const pixels = try std.testing.allocator.alloc(u8, stride * ih);
        defer std.testing.allocator.free(pixels);
        for (0..ih) |y| for (0..iw) |x| {
            const band = (if (vertical) y else x) / 4;
            for (0..3) |channel| pixels[y * stride + x * 3 + channel] = if (channel == band) 255 else 0;
        };
        var image = DecodedImage{ .pixels = pixels, .width = iw, .height = ih, .channels = 3, .stride = stride };
        for ([_]i32{ 1, 2 }) |scale| {
            const layout = try surfaces.Layout.init(4, 4, scale);
            const data = try std.testing.allocator.alloc(u32, layout.size / 4);
            defer std.testing.allocator.free(data);
            paint(.{ .pixels = @ptrCast(data.ptr), .layout = layout, .width = 4, .height = 4, .scale = scale }, &image);
            const row: usize = @intCast(layout.width);
            const mid: usize = @intCast(2 * scale);
            try std.testing.expectEqual(@as(u32, 0xff00ff00), data[mid * row + mid]);
            // Opaque green at opposite corners also catches letterboxing and
            // sampling past the source edge when the output doubles the buffer scale.
            try std.testing.expectEqual(@as(u32, 0xff00ff00), data[row + 1]);
        }
    }
}

test "wallpaper interpolation premultiplies alpha, pads edges, and preserves row padding" {
    var source = [_]u8{ 255, 0, 0, 0, 0, 255, 0, 255 };
    var image = DecodedImage{ .pixels = &source, .width = 2, .height = 1, .channels = 4, .stride = 8 };
    var pixels: [10]u32 = @splat(0xdeadbeef);
    paint(.{
        .pixels = @ptrCast(&pixels),
        .layout = .{ .width = 4, .height = 2, .stride = 20, .size = 40 },
        .width = 4,
        .height = 2,
        .scale = 1,
    }, &image);
    const expected = [_]u32{ 0xff000000, 0xff004000, 0xff00bf00, 0xff00ff00, 0xdeadbeef };
    try std.testing.expectEqualSlices(u32, &expected, pixels[0..5]);
    try std.testing.expectEqualSlices(u32, &expected, pixels[5..10]);
}

test "single pixel wallpaper fills a larger buffer without reading past its edges" {
    var source = [_]u8{ 12, 34, 56 };
    var image = DecodedImage{ .pixels = &source, .width = 1, .height = 1, .channels = 3, .stride = 3 };
    var pixels: [6]u32 = undefined;
    const layout = try surfaces.Layout.init(3, 2, 1);
    paint(.{ .pixels = @ptrCast(&pixels), .layout = layout, .width = 3, .height = 2, .scale = 1 }, &image);
    for (pixels) |pixel| try std.testing.expectEqual(@as(u32, 0xff0c2238), pixel);
}

pub const Service = struct {
    image: DecodedImage,
    client: *surfaces.Client = undefined,
    loop: Loop = .{},

    fn draw(context: ?*anyopaque, frame: surfaces.Frame) !void {
        const self: *Service = @ptrCast(@alignCast(context));
        paint(frame, &self.image);
    }

    pub fn create(path: [:0]const u8) !*Service {
        const image = try loadImage(allocator, path);
        const self = try allocator.create(Service);
        errdefer allocator.destroy(self);
        self.* = .{ .image = image };
        self.client = try surfaces.Client.create(.{ .namespace = "desktop-wallpaper" }, self, draw);
        errdefer self.client.destroy();
        try self.loop.start(self.client, "wallpaper");
        return self;
    }

    pub fn destroy(self: *Service) void {
        self.loop.stop();
        self.client.destroy();
        self.image.deinit(allocator);
        allocator.destroy(self);
    }
};
