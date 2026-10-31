//! One input-transparent background layer per monitor, sharing a decoded image.
const native = @import("desktop-surface.zig");
const std = @import("std");
const c = @import("desktop-gtk.zig");
const allocator = std.heap.page_allocator;

const cast = c.__zig.cast;

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

const Background = struct {
    surface: *native.Surface,
    image: *c.GdkPixbuf, // Owned by App; shared across outputs.

    fn create(output: *native.Output, image: *c.GdkPixbuf) !*Background {
        const self = try allocator.create(Background);
        errdefer allocator.destroy(self);
        self.* = .{ .surface = try native.Surface.create(output, .{
            .namespace = "desktop-wallpaper",
            .layer = 0,
            .anchors = native.top | native.bottom | native.left | native.right,
        }, &draw, self), .image = image };
        errdefer self.surface.destroy();
        try self.surface.show();
        return self;
    }
    fn draw(data: ?*anyopaque, cr: *c.cairo_t, width: f64, height: f64) void {
        paint(cr, cast(Background, data).image, width, height);
    }
    fn destroy(self: *Background) void {
        self.surface.destroy();
        allocator.destroy(self);
    }
};

const App = struct {
    image: *c.GdkPixbuf,
    backgrounds: std.ArrayList(*Background) = .empty,

    fn add(data: ?*anyopaque, output: *native.Output) void {
        const self = cast(App, data);
        const background = Background.create(output, self.image) catch |err| {
            std.log.err("wallpaper: {s}", .{@errorName(err)});
            return;
        };
        self.backgrounds.append(allocator, background) catch @panic("out of memory");
    }
    fn remove(data: ?*anyopaque, output: *native.Output) void {
        const self = cast(App, data);
        for (self.backgrounds.items, 0..) |background, i| if (background.surface.output == output) {
            _ = self.backgrounds.orderedRemove(i);
            background.destroy();
            return;
        };
    }
};

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
            // sampling past the source edge when GTK doubles the buffer scale.
            try std.testing.expectEqual(@as(u32, 0xff00ff00), data[row + 1]);
        }
    }
}

test "background layer paints wallpaper pixels on the desktop" {
    const capture = @import("tests/desktop-surface-capture.zig");
    try std.testing.expect(c.gtk_init_check(null, null) != 0);
    const image = c.gdk_pixbuf_new(c.GDK_COLORSPACE_RGB, 0, 8, 2, 2).?;
    defer c.g_object_unref(image);
    const pixels = c.gdk_pixbuf_get_pixels(image);
    const stride: usize = @intCast(c.gdk_pixbuf_get_rowstride(image));
    for (0..2) |y| for (0..2) |x| {
        pixels[y * stride + x * 3 ..][0..3].* = .{ 20, 40, 80 };
    };
    var app: App = .{ .image = image };
    const native_client = try native.Client.create(.{ .added = &App.add, .removed = &App.remove }, &app);
    defer native_client.destroy();
    defer {
        for (app.backgrounds.items) |background| background.destroy();
        app.backgrounds.deinit(allocator);
    }
    try native_client.start();
    const Probe = struct {
        var paints: usize = 0;
        fn draw(data: ?*anyopaque, cr: *c.cairo_t, width: f64, height: f64) void {
            paints += 1;
            Background.draw(data, cr, width, height);
        }
    };
    Probe.paints = 0;
    for (app.backgrounds.items) |background| background.surface.paint = &Probe.draw;
    capture.pump();
    try std.testing.expectEqual(@as(usize, 1), app.backgrounds.items.len);
    try std.testing.expect(app.backgrounds.items[0].surface.configured);
    try std.testing.expect(app.backgrounds.items[0].surface.buffers[0] != null);
    try std.testing.expectEqual(@as(usize, 1), Probe.paints);
    const frame = try capture.capture();
    defer frame.deinit();
    for ([_][2]u32{ .{ 1, 1 }, .{ frame.width / 2, frame.height / 2 }, .{ frame.width - 2, frame.height - 2 } }) |point| {
        try std.testing.expectEqual(@as(u32, 0x142850), frame.pixel(point[0], point[1]));
    }
}

pub const Service = struct {
    app: App,
    client: *native.Client,

    pub fn create(path: [:0]const u8) !*Service {
        const decoded = c.gdk_pixbuf_new_from_file(path, null) orelse return error.InvalidImage;
        defer c.g_object_unref(decoded);
        const image = c.gdk_pixbuf_apply_embedded_orientation(decoded) orelse return error.InvalidImage;
        errdefer c.g_object_unref(image);
        const self = try allocator.create(Service);
        self.* = .{ .app = .{ .image = image }, .client = undefined };
        errdefer allocator.destroy(self);
        self.client = try native.Client.create(.{ .added = &App.add, .removed = &App.remove }, &self.app);
        errdefer self.client.destroy();
        try self.client.start();
        return self;
    }

    pub fn destroy(self: *Service) void {
        for (self.app.backgrounds.items) |background| background.destroy();
        self.app.backgrounds.deinit(allocator);
        self.client.destroy();
        c.g_object_unref(self.app.image);
        allocator.destroy(self);
    }
};
