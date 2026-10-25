//! One input-transparent background layer per monitor, sharing a decoded image.
const std = @import("std");
const c = @import("gtk");
const allocator = std.heap.page_allocator;

fn cast(comptime T: type, ptr: anytype) *T {
    return @ptrCast(@alignCast(ptr));
}

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
    window: *c.GtkWidget,
    monitor: *c.GdkMonitor,
    image: *c.GdkPixbuf, // Owned by App; shared across outputs.

    fn create(monitor: *c.GdkMonitor, image: *c.GdkPixbuf) *Background {
        const self = allocator.create(Background) catch @panic("out of memory");
        self.* = .{ .window = c.gtk_window_new(c.GTK_WINDOW_TOPLEVEL).?, .monitor = monitor, .image = image };
        _ = c.g_object_ref(monitor);
        const window = cast(c.GtkWindow, self.window);
        c.gtk_widget_set_name(self.window, "desktop-wallpaper");
        c.gtk_window_set_title(window, "Desktop Wallpaper");
        c.gtk_window_set_decorated(window, 0);
        c.gtk_window_set_accept_focus(window, 0);
        c.gtk_widget_set_app_paintable(self.window, 1);
        c.gtk_layer_init_for_window(window);
        c.gtk_layer_set_namespace(window, "desktop-wallpaper");
        c.gtk_layer_set_monitor(window, monitor);
        c.gtk_layer_set_layer(window, c.GTK_LAYER_SHELL_LAYER_BACKGROUND);
        for ([_]c.GtkLayerShellEdge{ c.GTK_LAYER_SHELL_EDGE_TOP, c.GTK_LAYER_SHELL_EDGE_BOTTOM, c.GTK_LAYER_SHELL_EDGE_LEFT, c.GTK_LAYER_SHELL_EDGE_RIGHT }) |edge| c.gtk_layer_set_anchor(window, edge, 1);
        // Cover the entire output, including the area behind the panel.
        c.gtk_layer_set_exclusive_zone(window, -1);
        c.gtk_layer_set_keyboard_mode(window, c.GTK_LAYER_SHELL_KEYBOARD_MODE_NONE);
        _ = c.g_signal_connect_data(self.window, "draw", @ptrCast(&draw), self, null, 0);
        _ = c.g_signal_connect_data(self.window, "realize", @ptrCast(&realized), null, null, 0);
        c.gtk_widget_show(self.window);
        return self;
    }

    fn realized(widget: *c.GtkWidget, _: c.gpointer) callconv(.c) void {
        const empty = c.cairo_region_create();
        defer c.cairo_region_destroy(empty);
        c.gtk_widget_input_shape_combine_region(widget, empty);
    }

    fn draw(widget: *c.GtkWidget, cr: *c.cairo_t, data: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Background, data);
        // GTK supplies logical dimensions and a Cairo context with the output's
        // buffer scale already applied, including after mode/scale changes.
        paint(cr, self.image, @floatFromInt(c.gtk_widget_get_allocated_width(widget)), @floatFromInt(c.gtk_widget_get_allocated_height(widget)));
        return 1;
    }

    fn destroy(self: *Background) void {
        c.gtk_widget_destroy(self.window);
        c.g_object_unref(self.monitor);
        allocator.destroy(self);
    }
};

const App = struct {
    image: *c.GdkPixbuf,
    backgrounds: std.ArrayList(*Background) = .empty,

    fn add(_: *c.GdkDisplay, monitor: *c.GdkMonitor, data: c.gpointer) callconv(.c) void {
        const self = cast(App, data);
        self.backgrounds.append(allocator, Background.create(monitor, self.image)) catch @panic("out of memory");
    }

    fn remove(_: *c.GdkDisplay, monitor: *c.GdkMonitor, data: c.gpointer) callconv(.c) void {
        const self = cast(App, data);
        for (self.backgrounds.items, 0..) |background, i| if (background.monitor == monitor) {
            _ = self.backgrounds.orderedRemove(i);
            background.destroy();
            return;
        };
    }
};

fn quit(_: c.gpointer) callconv(.c) c.gboolean {
    c.gtk_main_quit();
    return 1;
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const args = try init.minimal.args.toSlice(arena.allocator());
    if (args.len != 2) {
        std.debug.print("Usage: desktop-wallpaper IMAGE\n", .{});
        return error.InvalidArguments;
    }
    const path = try arena.allocator().dupeSentinel(u8, args[1], 0);
    var err: [*c]c.GError = null;
    const decoded = c.gdk_pixbuf_new_from_file(path, &err) orelse {
        std.debug.print("Cannot load wallpaper: {s}\n", .{err.*.message});
        c.g_clear_error(&err);
        return error.InvalidImage;
    };
    defer c.g_object_unref(decoded);
    const image = c.gdk_pixbuf_apply_embedded_orientation(decoded) orelse return error.InvalidImage;
    defer c.g_object_unref(image);
    _ = c.g_setenv("GDK_BACKEND", "wayland", 1);
    if (c.gtk_init_check(null, null) == 0) return error.NoWaylandDisplay;
    if (c.gtk_layer_is_supported() == 0) return error.LayerShellUnavailable;
    var app = App{ .image = image };
    const display = c.gdk_display_get_default().?;
    const added = c.g_signal_connect_data(display, "monitor-added", @ptrCast(&App.add), &app, null, 0);
    const removed = c.g_signal_connect_data(display, "monitor-removed", @ptrCast(&App.remove), &app, null, 0);
    defer {
        c.g_signal_handler_disconnect(display, added);
        c.g_signal_handler_disconnect(display, removed);
        for (app.backgrounds.items) |background| background.destroy();
        app.backgrounds.deinit(allocator);
    }
    var i: c_int = 0;
    while (i < c.gdk_display_get_n_monitors(display)) : (i += 1) App.add(display, c.gdk_display_get_monitor(display, i).?, &app);
    const term = c.g_unix_signal_add(c.SIGTERM, &quit, null);
    const interrupt = c.g_unix_signal_add(c.SIGINT, &quit, null);
    defer _ = c.g_source_remove(term);
    defer _ = c.g_source_remove(interrupt);
    c.gtk_main();
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
            // sampling past the source edge when GTK doubles the buffer scale.
            try std.testing.expectEqual(@as(u32, 0xff00ff00), data[row + 1]);
        }
    }
}
