//! The desktop's only image decoder. Cairo reads PNG and librsvg renders SVG;
//! both paint into owned premultiplied ARGB images. Release results with `free`.
const std = @import("std");
const c = @import("desktop-glib.zig");
pub const Image = @import("desktop-image.zig").Image;

pub const allocator = std.heap.c_allocator;

pub const api = struct {
    pub const RsvgHandle = opaque {};
    pub const RsvgRectangle = extern struct { x: f64, y: f64, width: f64, height: f64 };
    pub const RsvgUnit = c_uint;
    pub const RsvgLength = extern struct { length: f64, unit: RsvgUnit };
    pub extern fn rsvg_handle_new_from_data([*c]const c.guint8, c.gsize, [*c][*c]c.GError) ?*RsvgHandle;
    pub extern fn rsvg_handle_get_intrinsic_size_in_pixels(?*RsvgHandle, [*c]f64, [*c]f64) c.gboolean;
    pub extern fn rsvg_handle_get_intrinsic_dimensions(?*RsvgHandle, [*c]c.gboolean, [*c]RsvgLength, [*c]c.gboolean, [*c]RsvgLength, [*c]c.gboolean, [*c]RsvgRectangle) void;
    pub extern fn rsvg_handle_render_document(?*RsvgHandle, ?*c.cairo_t, [*c]const RsvgRectangle, [*c][*c]c.GError) c.gboolean;
    pub const CAIRO_STATUS_READ_ERROR: c_int = 10;
    pub const cairo_read_func_t = ?*const fn (?*anyopaque, [*c]u8, c_uint) callconv(.c) c.cairo_status_t;
    pub extern fn cairo_image_surface_create_from_png_stream(cairo_read_func_t, ?*anyopaque) ?*c.cairo_surface_t;
    pub extern fn g_input_stream_read(?*c.GInputStream, ?*anyopaque, c.gsize, [*c]c.GCancellable, [*c][*c]c.GError) c.gssize;
};

const max_side = 8192;
const max_encoded = 64 << 20;
const png_signature = "\x89PNG\r\n\x1a\n";

const Source = union(enum) {
    png: *c.cairo_surface_t,
    svg: *api.RsvgHandle,

    fn open(data: []const u8) ?Source {
        if (std.mem.startsWith(u8, data, png_signature)) {
            var input = data;
            const surface = api.cairo_image_surface_create_from_png_stream(&readPng, @ptrCast(&input)) orelse return null;
            if (c.cairo_surface_status(surface) != 0) {
                c.cairo_surface_destroy(surface);
                return null;
            }
            return .{ .png = surface };
        }
        return .{ .svg = api.rsvg_handle_new_from_data(data.ptr, data.len, null) orelse return null };
    }

    fn close(self: Source) void {
        switch (self) {
            .png => |surface| c.cairo_surface_destroy(surface),
            .svg => |handle| c.g_object_unref(handle),
        }
    }

    fn size(self: Source) ?[2]u32 {
        var width: f64 = 0;
        var height: f64 = 0;
        switch (self) {
            .png => |surface| {
                width = @floatFromInt(c.cairo_image_surface_get_width(surface));
                height = @floatFromInt(c.cairo_image_surface_get_height(surface));
            },
            .svg => |handle| if (api.rsvg_handle_get_intrinsic_size_in_pixels(handle, &width, &height) == 0) {
                // Without absolute width and height, the viewBox gives the natural size.
                var has_viewbox: c.gboolean = 0;
                var viewbox: api.RsvgRectangle = undefined;
                api.rsvg_handle_get_intrinsic_dimensions(handle, null, null, null, null, &has_viewbox, &viewbox);
                if (has_viewbox == 0) return null;
                width = viewbox.width;
                height = viewbox.height;
            },
        }
        if (!(width >= 0.5 and height >= 0.5 and width <= max_side and height <= max_side)) return null;
        return .{ @intFromFloat(@ceil(width - 0.001)), @intFromFloat(@ceil(height - 0.001)) };
    }

    fn render(self: Source, width: u32, height: u32) ?Image {
        const image = create(width, height) catch return null;
        @memset(image.pixels, 0);
        const surface = c.cairo_image_surface_create_for_data(image.pixels.ptr, c.CAIRO_FORMAT_ARGB32, @intCast(width), @intCast(height), @intCast(image.stride));
        defer c.cairo_surface_destroy(surface);
        const cr = c.cairo_create(surface);
        defer c.cairo_destroy(cr);
        const drawn = switch (self) {
            .png => |png| blk: {
                const natural = self.size().?;
                c.cairo_scale(cr, @as(f64, @floatFromInt(width)) / @as(f64, @floatFromInt(natural[0])), @as(f64, @floatFromInt(height)) / @as(f64, @floatFromInt(natural[1])));
                c.cairo_set_source_surface(cr, png, 0, 0);
                c.cairo_pattern_set_extend(c.cairo_get_source(cr), c.CAIRO_EXTEND_PAD);
                c.cairo_pattern_set_filter(c.cairo_get_source(cr), c.CAIRO_FILTER_GOOD);
                c.cairo_paint(cr);
                break :blk true;
            },
            .svg => |handle| blk: {
                const viewport: api.RsvgRectangle = .{ .x = 0, .y = 0, .width = @floatFromInt(width), .height = @floatFromInt(height) };
                break :blk api.rsvg_handle_render_document(handle, cr, &viewport, null) != 0;
            },
        };
        c.cairo_surface_flush(surface);
        if (!drawn or c.cairo_status(cr) != 0) {
            free(image);
            return null;
        }
        return image;
    }
};

fn readPng(closure: ?*anyopaque, data: [*c]u8, length: c_uint) callconv(.c) c.cairo_status_t {
    const input: *[]const u8 = @ptrCast(@alignCast(closure.?));
    if (input.len < length) return api.CAIRO_STATUS_READ_ERROR;
    @memcpy(data[0..length], input.*[0..length]);
    input.* = input.*[length..];
    return 0;
}

/// Fits a natural size into a `size` square, keeping its aspect ratio.
fn fit(natural: [2]u32, size: u32) [2]u32 {
    const width: f64 = @floatFromInt(natural[0]);
    const height: f64 = @floatFromInt(natural[1]);
    const box: f64 = @floatFromInt(size);
    if (width >= height) return .{ size, @max(1, @as(u32, @intFromFloat(height * box / width + 0.5))) };
    return .{ @max(1, @as(u32, @intFromFloat(width * box / height + 0.5))), size };
}

/// Decodes PNG or SVG bytes at their natural size, or scaled to fit a `size` square.
pub fn bytes(data: []const u8, size: ?u32) ?Image {
    if (size) |side| if (side == 0 or side > max_side) return null;
    const source = Source.open(data) orelse return null;
    defer source.close();
    const natural = source.size() orelse return null;
    const target = if (size) |side| fit(natural, side) else natural;
    return source.render(target[0], target[1]);
}

/// Decodes a PNG or SVG file at its natural size, or scaled to fit a `size` square.
pub fn file(path: [*:0]const u8, size: ?u32) ?Image {
    var data: [*c]u8 = null;
    var len: c.gsize = 0;
    if (c.g_file_get_contents(path, &data, &len, null) == 0) return null;
    defer c.g_free(data);
    return bytes(data[0..len], size);
}

/// Decodes a PNG or SVG stream scaled to fit a `size` square.
pub fn stream(input: *c.GInputStream, size: u32) ?Image {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(allocator);
    while (true) {
        data.ensureUnusedCapacity(allocator, 64 << 10) catch return null;
        const unused = data.unusedCapacitySlice();
        const read = api.g_input_stream_read(input, unused.ptr, unused.len, null, null);
        if (read < 0) return null;
        if (read == 0) break;
        data.items.len += @intCast(read);
        if (data.items.len > max_encoded) return null;
    }
    return bytes(data.items, size);
}

/// Reads the natural dimensions of encoded PNG or SVG bytes.
pub fn dimensions(data: []const u8) ?[2]u32 {
    if (std.mem.startsWith(u8, data, png_signature)) {
        // The IHDR chunk always comes first and holds the big-endian size.
        if (data.len < 24 or !std.mem.eql(u8, data[12..16], "IHDR")) return null;
        const width = std.mem.readInt(u32, data[16..20], .big);
        const height = std.mem.readInt(u32, data[20..24], .big);
        if (width == 0 or height == 0 or width > max_side or height > max_side) return null;
        return .{ width, height };
    }
    const source = Source.open(data) orelse return null;
    defer source.close();
    return source.size();
}

pub fn clone(image: Image) ?Image {
    const pixels = allocator.alignedAlloc(u8, .of(u32), image.pixels.len) catch return null;
    @memcpy(pixels, image.pixels);
    return .{ .pixels = pixels, .width = image.width, .height = image.height, .stride = image.stride };
}

pub fn free(image: Image) void {
    image.deinit(allocator);
}

/// Allocates an uninitialized image for tests and generated content.
pub fn create(width: u32, height: u32) !Image {
    const stride = @as(usize, width) * 4;
    return .{ .pixels = try allocator.alignedAlloc(u8, .of(u32), stride * height), .width = width, .height = height, .stride = stride };
}

test "decoded PNGs are premultiplied ARGB scaled to the requested square" {
    const pixels: [8]u32 = @splat(0x80800000);
    const data = try @import("desktop-png.zig").encode(std.testing.allocator, .{ .pixels = std.mem.sliceAsBytes(&pixels), .width = 4, .height = 2, .stride = 16, .alpha = true });
    defer std.testing.allocator.free(data);
    try std.testing.expectEqual([2]u32{ 4, 2 }, dimensions(data).?);
    const image = bytes(data, 8) orelse return error.Decode;
    defer free(image);
    try std.testing.expectEqual(@as(u32, 8), image.width);
    try std.testing.expectEqual(@as(u32, 4), image.height);
    for (std.mem.bytesAsSlice(u32, image.pixels)) |pixel| try std.testing.expectEqual(@as(u32, 0x80800000), pixel);
    const copy = clone(image) orelse return error.OutOfMemory;
    defer free(copy);
    try std.testing.expectEqualSlices(u8, image.pixels, copy.pixels);
    try std.testing.expectEqual(@as(?Image, null), bytes(data[0 .. data.len - 20], null));
}

test "SVGs render at their intrinsic or viewBox size and fit a requested square" {
    const sized = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"6\" height=\"3\"><rect width=\"6\" height=\"3\" fill=\"#00f\"/></svg>";
    try std.testing.expectEqual([2]u32{ 6, 3 }, dimensions(sized).?);
    const natural = bytes(sized, null) orelse return error.Decode;
    defer free(natural);
    try std.testing.expectEqual(@as(u32, 6), natural.width);
    try std.testing.expectEqual(@as(u32, 0xff0000ff), std.mem.bytesAsSlice(u32, natural.pixels)[0]);
    const boxed = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 2 4\"><rect width=\"2\" height=\"4\"/></svg>";
    const scaled = bytes(boxed, 16) orelse return error.Decode;
    defer free(scaled);
    try std.testing.expectEqual([2]u32{ 8, 16 }, [2]u32{ scaled.width, scaled.height });
    try std.testing.expectEqual(@as(?Image, null), bytes("not an image", 16));
}
