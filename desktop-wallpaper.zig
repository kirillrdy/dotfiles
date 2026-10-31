//! Native Wayland backgrounds sharing a decoded image; GTK owns no windows here.
const std = @import("std");
const c = @import("desktop-gtk.zig");
const allocator = std.heap.page_allocator;

const surfaces = @import("desktop-surface.zig");

fn paint(cr: *c.cairo_t, image: *c.GdkPixbuf, width: f64, height: f64) void {
    if (width <= 0 or height <= 0) return;
    const iw: f64 = @floatFromInt(c.gdk_pixbuf_get_width(image));
    const ih: f64 = @floatFromInt(c.gdk_pixbuf_get_height(image));
    const scale = @max(width / iw, height / ih);
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    c.cairo_rectangle(cr, 0, 0, width, height);
    c.cairo_clip(cr);
    c.cairo_set_source_rgb(cr, 0, 0, 0);
    c.cairo_paint(cr);
    c.cairo_translate(cr, (width - iw * scale) / 2, (height - ih * scale) / 2);
    c.cairo_scale(cr, scale, scale);
    c.gdk_cairo_set_source_pixbuf(cr, image, 0, 0);
    c.cairo_pattern_set_filter(c.cairo_get_source(cr), c.CAIRO_FILTER_BILINEAR);
    c.cairo_pattern_set_extend(c.cairo_get_source(cr), c.CAIRO_EXTEND_PAD);
    c.cairo_paint(cr);
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
            const surface = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, 4 * scale, 4 * scale).?;
            defer c.cairo_surface_destroy(surface);
            c.cairo_surface_set_device_scale(surface, @floatFromInt(scale), @floatFromInt(scale));
            const cr = c.cairo_create(surface).?;
            defer c.cairo_destroy(cr);
            paint(cr, image, 4, 4);
            c.cairo_surface_flush(surface);
            const data: [*]const u32 = @ptrCast(@alignCast(c.cairo_image_surface_get_data(surface)));
            const row: usize = @intCast(@divTrunc(c.cairo_image_surface_get_stride(surface), 4));
            const mid: usize = @intCast(2 * scale);
            try std.testing.expectEqual(@as(u32, 0xff00ff00), data[mid * row + mid]);
            // Opaque green at opposite corners also catches letterboxing and
            // sampling past the source edge when the output doubles the buffer scale.
            try std.testing.expectEqual(@as(u32, 0xff00ff00), data[row + 1]);
        }
    }
}

pub const Service = struct {
    image: *c.GdkPixbuf,
    client: *surfaces.Client = undefined,
    reader: c.guint = 0,
    writer: c.guint = 0,

    fn draw(context: ?*anyopaque, frame: surfaces.Frame) !void {
        const self: *Service = @ptrCast(@alignCast(context));
        const image = c.cairo_image_surface_create_for_data(frame.pixels, c.CAIRO_FORMAT_RGB24, frame.layout.width, frame.layout.height, frame.layout.stride) orelse return error.ImageSurfaceFailed;
        defer c.cairo_surface_destroy(image);
        if (c.cairo_surface_status(image) != c.CAIRO_STATUS_SUCCESS) return error.ImageSurfaceFailed;
        c.cairo_surface_set_device_scale(image, @floatFromInt(frame.scale), @floatFromInt(frame.scale));
        const cr = c.cairo_create(image) orelse return error.ImageSurfaceFailed;
        defer c.cairo_destroy(cr);
        paint(cr, self.image, @floatFromInt(frame.width), @floatFromInt(frame.height));
        c.cairo_surface_flush(image);
        if (c.cairo_status(cr) != c.CAIRO_STATUS_SUCCESS or c.cairo_surface_status(image) != c.CAIRO_STATUS_SUCCESS) return error.ImageSurfaceFailed;
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
        self.reader = c.g_unix_fd_add(c.wl_display_get_fd(self.client.display), c.G_IO_IN | c.G_IO_ERR | c.G_IO_HUP, readable, self);
        if (self.reader == 0) return error.EventSourceFailed;
        errdefer _ = c.g_source_remove(self.reader);
        try self.flush();
        return self;
    }

    fn flush(self: *Service) !void {
        if (!try self.client.flush() and self.writer == 0) {
            self.writer = c.g_unix_fd_add(c.wl_display_get_fd(self.client.display), c.G_IO_OUT | c.G_IO_ERR | c.G_IO_HUP, writable, self);
            if (self.writer == 0) return error.EventSourceFailed;
        }
    }
    fn failed(self: *Service, err: anyerror) void {
        std.log.err("wallpaper: {s}", .{@errorName(err)});
        if (self.reader != 0) _ = c.g_source_remove(self.reader);
        if (self.writer != 0) _ = c.g_source_remove(self.writer);
        self.reader = 0;
        self.writer = 0;
    }
    fn readable(_: c_int, condition: c.GIOCondition, data: ?*anyopaque) callconv(.c) c.gboolean {
        const self: *Service = @ptrCast(@alignCast(data));
        if (condition & (c.G_IO_ERR | c.G_IO_HUP) != 0) {
            self.failed(error.WaylandDisconnected);
            return 0;
        }
        self.client.dispatch() catch |err| {
            self.failed(err);
            return 0;
        };
        self.flush() catch |err| {
            self.failed(err);
            return 0;
        };
        return 1;
    }
    fn writable(_: c_int, condition: c.GIOCondition, data: ?*anyopaque) callconv(.c) c.gboolean {
        const self: *Service = @ptrCast(@alignCast(data));
        if (condition & (c.G_IO_ERR | c.G_IO_HUP) != 0) {
            self.failed(error.WaylandDisconnected);
            return 0;
        }
        const flushed = self.client.flush() catch |err| {
            self.failed(err);
            return 0;
        };
        if (!flushed) return 1;
        self.writer = 0;
        return 0;
    }

    pub fn destroy(self: *Service) void {
        if (self.reader != 0) _ = c.g_source_remove(self.reader);
        if (self.writer != 0) _ = c.g_source_remove(self.writer);
        self.client.destroy();
        c.g_object_unref(self.image);
        allocator.destroy(self);
    }
};
