//! Native Wayland backgrounds with Zig scaling and a shared decoded image.
const std = @import("std");
const c = @import("desktop-gtk.zig");
const allocator = std.heap.page_allocator;

const surfaces = @import("desktop-surface.zig");
const Loop = @import("desktop-surface-loop.zig").Loop;

fn paint(frame: surfaces.Frame, image: *c.GdkPixbuf) void {
    const iw: usize = @intCast(c.gdk_pixbuf_get_width(image));
    const ih: usize = @intCast(c.gdk_pixbuf_get_height(image));
    const channels: usize = @intCast(c.gdk_pixbuf_get_n_channels(image));
    const source_stride: usize = @intCast(c.gdk_pixbuf_get_rowstride(image));
    const source = c.gdk_pixbuf_get_pixels(image);
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
        const image = c.gdk_pixbuf_new(c.GDK_COLORSPACE_RGB, 0, 8, if (vertical) 4 else 12, if (vertical) 12 else 4).?;
        defer c.g_object_unref(image);
        const pixels = c.gdk_pixbuf_get_pixels(image);
        const stride: usize = @intCast(c.gdk_pixbuf_get_rowstride(image));
        const iw: usize = @intCast(c.gdk_pixbuf_get_width(image));
        const ih: usize = @intCast(c.gdk_pixbuf_get_height(image));
        for (0..ih) |y| for (0..iw) |x| {
            const band = (if (vertical) y else x) / 4;
            for (0..3) |channel| pixels[y * stride + x * 3 + channel] = if (channel == band) 255 else 0;
        };
        for ([_]c_int{ 1, 2 }) |scale| {
            const layout = try surfaces.Layout.init(4, 4, scale);
            const data = try std.testing.allocator.alloc(u32, layout.size / 4);
            defer std.testing.allocator.free(data);
            paint(.{ .pixels = @ptrCast(data.ptr), .layout = layout, .width = 4, .height = 4, .scale = scale }, image);
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
    const image = c.gdk_pixbuf_new(c.GDK_COLORSPACE_RGB, 1, 8, 2, 1).?;
    defer c.g_object_unref(image);
    const source = c.gdk_pixbuf_get_pixels(image);
    @memcpy(source[0..8], &[_]u8{ 255, 0, 0, 0, 0, 255, 0, 255 });
    var pixels: [10]u32 = @splat(0xdeadbeef);
    paint(.{
        .pixels = @ptrCast(&pixels),
        .layout = .{ .width = 4, .height = 2, .stride = 20, .size = 40 },
        .width = 4,
        .height = 2,
        .scale = 1,
    }, image);
    const expected = [_]u32{ 0xff000000, 0xff004000, 0xff00bf00, 0xff00ff00, 0xdeadbeef };
    try std.testing.expectEqualSlices(u32, &expected, pixels[0..5]);
    try std.testing.expectEqualSlices(u32, &expected, pixels[5..10]);
}

test "single pixel wallpaper fills a larger buffer without reading past its edges" {
    const image = c.gdk_pixbuf_new(c.GDK_COLORSPACE_RGB, 0, 8, 1, 1).?;
    defer c.g_object_unref(image);
    @memcpy(c.gdk_pixbuf_get_pixels(image)[0..3], &[_]u8{ 12, 34, 56 });
    var pixels: [6]u32 = undefined;
    const layout = try surfaces.Layout.init(3, 2, 1);
    paint(.{ .pixels = @ptrCast(&pixels), .layout = layout, .width = 3, .height = 2, .scale = 1 }, image);
    for (pixels) |pixel| try std.testing.expectEqual(@as(u32, 0xff0c2238), pixel);
}

pub const Service = struct {
    image: *c.GdkPixbuf,
    client: *surfaces.Client = undefined,
    loop: Loop = .{},

    fn draw(context: ?*anyopaque, frame: surfaces.Frame) !void {
        const self: *Service = @ptrCast(@alignCast(context));
        paint(frame, self.image);
    }

    pub fn create(path: [:0]const u8) !*Service {
        const decoded = c.gdk_pixbuf_new_from_file(path, null) orelse return error.InvalidImage;
        defer c.g_object_unref(decoded);
        const image = c.gdk_pixbuf_apply_embedded_orientation(decoded) orelse return error.InvalidImage;
        errdefer c.g_object_unref(image);
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
        c.g_object_unref(self.image);
        allocator.destroy(self);
    }
};
