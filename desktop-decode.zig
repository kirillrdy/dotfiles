//! The desktop's only image decoder. GdkPixbuf and its SVG loader turn files and
//! encoded bytes into owned premultiplied ARGB images; no other module sees a
//! GdkPixbuf. Release results with `free`.
const std = @import("std");
const c = @import("desktop-glib.zig");
pub const Image = @import("desktop-image.zig").Image;

pub const allocator = std.heap.c_allocator;

pub const api = struct {
    pub const GdkPixbuf = opaque {};
    pub const GdkPixbufFormat = opaque {};
    pub const GdkColorspace = c_uint;
    pub const GDK_COLORSPACE_RGB: c_int = 0;
    pub extern fn gdk_pixbuf_get_pixels(?*const GdkPixbuf) [*c]u8;
    pub extern fn gdk_pixbuf_get_width(?*const GdkPixbuf) c_int;
    pub extern fn gdk_pixbuf_get_height(?*const GdkPixbuf) c_int;
    pub extern fn gdk_pixbuf_get_rowstride(?*const GdkPixbuf) c_int;
    pub extern fn gdk_pixbuf_get_n_channels(?*const GdkPixbuf) c_int;
    pub extern fn gdk_pixbuf_new(GdkColorspace, c.gboolean, c_int, c_int, c_int) ?*GdkPixbuf;
    pub extern fn gdk_pixbuf_new_from_file([*c]const u8, [*c][*c]c.GError) ?*GdkPixbuf;
    pub extern fn gdk_pixbuf_new_from_file_at_scale([*c]const u8, c_int, c_int, c.gboolean, [*c][*c]c.GError) ?*GdkPixbuf;
    pub extern fn gdk_pixbuf_new_from_stream_at_scale(?*c.GInputStream, c_int, c_int, c.gboolean, [*c]c.GCancellable, [*c][*c]c.GError) ?*GdkPixbuf;
    pub extern fn gdk_pixbuf_apply_embedded_orientation(?*GdkPixbuf) ?*GdkPixbuf;
    pub extern fn gdk_pixbuf_get_file_info([*c]const u8, [*c]c_int, [*c]c_int) ?*GdkPixbufFormat;
    pub extern fn gdk_pixbuf_save_to_bufferv(?*GdkPixbuf, [*c][*c]u8, [*c]c.gsize, [*c]const u8, [*c][*c]u8, [*c][*c]u8, [*c][*c]c.GError) c.gboolean;
};
extern "c" fn g_memory_input_stream_new_from_data(*const anyopaque, isize, c.GDestroyNotify) ?*c.GInputStream;

/// Converts and releases a decoded pixbuf.
fn take(pixbuf: ?*api.GdkPixbuf) ?Image {
    const image = pixbuf orelse return null;
    defer c.g_object_unref(image);
    const width: u32 = @intCast(api.gdk_pixbuf_get_width(image));
    const height: u32 = @intCast(api.gdk_pixbuf_get_height(image));
    const stride: usize = @intCast(api.gdk_pixbuf_get_rowstride(image));
    const channels: u32 = @intCast(api.gdk_pixbuf_get_n_channels(image));
    if (width == 0 or height == 0 or (channels != 3 and channels != 4)) return null;
    return Image.normalize(allocator, .{
        .pixels = api.gdk_pixbuf_get_pixels(image)[0 .. (height - 1) * stride + width * channels],
        .width = width,
        .height = height,
        .stride = stride,
        .format = if (channels == 4) .rgba else .rgb,
    }) catch null;
}

/// Decodes a file at its natural size, applying any embedded orientation.
pub fn file(path: [*:0]const u8) ?Image {
    const decoded = api.gdk_pixbuf_new_from_file(path, null) orelse return null;
    defer c.g_object_unref(decoded);
    return take(api.gdk_pixbuf_apply_embedded_orientation(decoded));
}

/// Decodes a file scaled to fit a square of `size` pixels, keeping its aspect ratio.
pub fn fileAt(path: [*:0]const u8, size: u32) ?Image {
    return take(api.gdk_pixbuf_new_from_file_at_scale(path, @intCast(size), @intCast(size), 1, null));
}

/// Decodes a stream scaled to fit a square of `size` pixels, keeping its aspect ratio.
pub fn stream(input: *c.GInputStream, size: u32) ?Image {
    return take(api.gdk_pixbuf_new_from_stream_at_scale(input, @intCast(size), @intCast(size), 1, null, null));
}

/// Decodes encoded bytes scaled to fit a square of `size` pixels.
pub fn bytes(data: []const u8, size: u32) ?Image {
    const input = g_memory_input_stream_new_from_data(data.ptr, @intCast(data.len), null) orelse return null;
    defer c.g_object_unref(input);
    return stream(input, size);
}

/// Reads an image's natural dimensions without decoding its pixels.
pub fn dimensions(path: [*:0]const u8) ?[2]u32 {
    var width: c_int = 0;
    var height: c_int = 0;
    if (api.gdk_pixbuf_get_file_info(path, &width, &height) == null or width <= 0 or height <= 0) return null;
    return .{ @intCast(width), @intCast(height) };
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

test "decoded images are premultiplied ARGB scaled to the requested square" {
    const source = api.gdk_pixbuf_new(api.GDK_COLORSPACE_RGB, 1, 8, 4, 2) orelse return error.OutOfMemory;
    defer c.g_object_unref(source);
    const stride: usize = @intCast(api.gdk_pixbuf_get_rowstride(source));
    const pixels = api.gdk_pixbuf_get_pixels(source);
    for (0..2) |y| for (0..4) |x| @memcpy(pixels[y * stride + x * 4 ..][0..4], &[_]u8{ 255, 0, 0, 128 });
    var data: [*c]u8 = null;
    var len: c.gsize = 0;
    try std.testing.expect(api.gdk_pixbuf_save_to_bufferv(source, &data, &len, "png", null, null, null) != 0);
    defer c.g_free(data);
    const image = bytes(data[0..len], 8) orelse return error.Decode;
    defer free(image);
    try std.testing.expectEqual(@as(u32, 8), image.width);
    try std.testing.expectEqual(@as(u32, 4), image.height);
    try std.testing.expectEqual(@as(u32, 0x80800000), std.mem.bytesAsSlice(u32, image.pixels)[0]);
    const copy = clone(image) orelse return error.OutOfMemory;
    defer free(copy);
    try std.testing.expectEqualSlices(u8, image.pixels, copy.pixels);
}
