//! Native capture requests on the broker's GLib context.
const std = @import("std");
const c = @import("desktop-gtk.zig");
const libc = @import("desktop-libc.zig");
const sc = @import("desktop-screenshot.zig");
const png = @import("desktop-png.zig");
const font = @import("desktop-font.zig");
const protocols = sc.protocols;
const cast = c.__zig.cast;
pub const Completion = *const fn (?*anyopaque, u32, ?*c.GVariant) void;

pub const Image = struct {
    width: u32,
    height: u32,
    stride: usize,
    pixels: []u8,
    allocator: std.mem.Allocator,
    rc: usize = 1,

    pub fn ref(self: *Image) *Image {
        self.rc += 1;
        return self;
    }
    pub fn unref(self: *Image) void {
        self.rc -= 1;
        if (self.rc == 0) {
            self.allocator.free(self.pixels);
            self.allocator.destroy(self);
        }
    }
};

/// A private Wayland connection keeps capture traffic off GTK's event queue.
pub const Capture = struct {
    allocator: std.mem.Allocator,
    client: sc.WaylandClient,
    frame: ?sc.FrameCapture = null,
    source: c.guint = 0,
    timeout: c.guint = 0,
    image: ?*Image = null,
    callback: *const fn (?*anyopaque, ?*Image) void,
    data: ?*anyopaque,

    pub fn create(allocator: std.mem.Allocator, name: []const u8, cursor: bool, callback: *const fn (?*anyopaque, ?*Image) void, data: ?*anyopaque) !*Capture {
        const self = try allocator.create(Capture);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .client = undefined, .callback = callback, .data = data };
        try self.client.init(allocator);
        errdefer self.client.deinit();
        try self.next(name, cursor);
        return self;
    }
    pub fn next(self: *Capture, name: []const u8, cursor: bool) !void {
        self.clearFrame();
        const mgr = self.client.screencopy_mgr orelse return error.NoScreencopy;
        var output: ?*sc.Output = null;
        for (self.client.outputs.items) |*item| if (item.available and std.mem.eql(u8, std.mem.sliceTo(&item.name, 0), name)) {
            output = item;
            break;
        };
        const target = output orelse return error.OutputUnavailable;
        self.frame = .{
            .shm = self.client.shm orelse return error.NoShm,
            .frame = protocols.zwlr_screencopy_manager_v1_capture_output(mgr, @intFromBool(cursor), target.wl_out) orelse return error.CaptureFailed,
        };
        _ = protocols.zwlr_screencopy_frame_v1_add_listener(self.frame.?.frame, &sc.FrameCapture.listener, &self.frame.?);
        _ = c.wl_display_flush(self.client.display);
        self.source = c.g_unix_fd_add(c.wl_display_get_fd(self.client.display), c.G_IO_IN | c.G_IO_ERR | c.G_IO_HUP, &dispatch, self);
        self.timeout = c.g_timeout_add_seconds(10, &expired, self);
    }
    fn clearFrame(self: *Capture) void {
        if (self.image) |img| img.unref();
        self.image = null;
        if (self.frame) |frame| {
            protocols.zwlr_screencopy_frame_v1_destroy(frame.frame);
            if (frame.buffer) |buffer| c.wl_buffer_destroy(buffer);
            if (frame.memory) |memory| _ = libc.munmap(memory, frame.length);
        }
        self.frame = null;
    }
    pub fn destroy(self: *Capture) void {
        if (self.source != 0) _ = c.g_source_remove(self.source);
        if (self.timeout != 0) _ = c.g_source_remove(self.timeout);
        self.clearFrame();
        self.client.deinit();
        self.allocator.destroy(self);
    }
    fn expired(data: ?*anyopaque) callconv(.c) c_int {
        const self = cast(Capture, data);
        self.timeout = 0;
        if (self.source != 0) _ = c.g_source_remove(self.source);
        self.source = 0;
        self.callback(self.data, null);
        return 0;
    }
    fn dispatch(_: c_int, condition: c.GIOCondition, data: ?*anyopaque) callconv(.c) c_int {
        const self = cast(Capture, data);
        const ok = condition & (c.G_IO_ERR | c.G_IO_HUP) == 0 and c.wl_display_dispatch(self.client.display) >= 0;
        if (ok) _ = c.wl_display_flush(self.client.display);
        const frame = &self.frame.?;
        if (ok and !frame.done and !frame.failed) return 1;
        self.source = 0;
        if (self.timeout != 0) _ = c.g_source_remove(self.timeout);
        self.timeout = 0;
        if (ok and frame.done and !frame.failed) self.image = image(self.allocator, frame) catch null;
        self.callback(self.data, self.image);
        return 0;
    }
};

/// Normalize XRGB/ARGB and bottom-up buffers to an opaque RGB image.
pub fn image(allocator: std.mem.Allocator, frame: *const sc.FrameCapture) !*Image {
    if (frame.memory == null or frame.width == 0 or frame.height == 0 or frame.stride < frame.width * 4 or frame.length < @as(usize, frame.stride) * frame.height) return error.InvalidFrame;
    if (frame.format != c.WL_SHM_FORMAT_XRGB8888 and frame.format != c.WL_SHM_FORMAT_ARGB8888) return error.UnsupportedFormat;
    const stride = @as(usize, frame.width) * 4;
    const pixels = try allocator.alloc(u8, stride * frame.height);
    errdefer allocator.free(pixels);
    for (0..frame.height) |y| {
        const source_y = if (frame.y_invert) frame.height - 1 - y else y;
        @memcpy(pixels[y * stride ..][0..stride], frame.memory.?[source_y * frame.stride ..][0..stride]);
    }
    const self = try allocator.create(Image);
    self.* = .{
        .width = frame.width,
        .height = frame.height,
        .stride = stride,
        .pixels = pixels,
        .allocator = allocator,
    };
    return self;
}

pub const Picked = struct { name: [:0]const u8, monitor: ?*c.GdkMonitor, width: i32, height: i32 };
/// Consent and output selection are shared by screenshots and screencasts.
pub const Picker = struct {
    allocator: std.mem.Allocator,
    client: sc.WaylandClient,
    window: *c.GtkWidget,
    combo: *c.GtkWidget,
    area: ?*c.GtkWidget = null,
    callback: *const fn (?*anyopaque, ?Picked, bool) void,
    data: ?*anyopaque,

    pub fn create(allocator: std.mem.Allocator, app: [:0]const u8, parent: [:0]const u8, title: [:0]const u8, interactive: bool, callback: *const fn (?*anyopaque, ?Picked, bool) void, data: ?*anyopaque) !*Picker {
        if (c.gtk_init_check(null, null) == 0) return error.DisplayUnavailable;
        const self = try allocator.create(Picker);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .client = undefined, .window = undefined, .combo = undefined, .callback = callback, .data = data };
        try self.client.init(allocator);
        errdefer self.client.deinit();
        if (self.client.screencopy_mgr == null or self.client.outputs.items.len == 0) return error.CaptureUnavailable;
        self.window = c.gtk_dialog_new_with_buttons(title, null, 0, @as([*:0]const u8, "_Cancel"), c.GTK_RESPONSE_CANCEL, @as([*:0]const u8, "_Share"), c.GTK_RESPONSE_OK, @as(?*anyopaque, null));
        const content = c.gtk_dialog_get_content_area(cast(c.GtkDialog, self.window));
        c.gtk_container_set_border_width(cast(c.GtkContainer, content), 18);
        c.gtk_box_set_spacing(cast(c.GtkBox, content), 12);
        c.gtk_box_pack_start(cast(c.GtkBox, content), c.gtk_label_new(app), 0, 0, 0);
        self.combo = c.gtk_combo_box_text_new();
        for (self.client.outputs.items) |*output| c.gtk_combo_box_text_append(cast(c.GtkComboBoxText, self.combo), &output.name, &output.name);
        c.gtk_combo_box_set_active(cast(c.GtkComboBox, self.combo), 0);
        c.gtk_box_pack_start(cast(c.GtkBox, content), self.combo, 0, 0, 0);
        if (interactive) {
            self.area = c.gtk_check_button_new_with_label("Select an area");
            c.gtk_box_pack_start(cast(c.GtkBox, content), self.area.?, 0, 0, 0);
        }
        c.gtk_window_set_title(cast(c.GtkWindow, self.window), title);
        c.gtk_window_set_modal(cast(c.GtkWindow, self.window), 1);
        c.gtk_dialog_set_default_response(cast(c.GtkDialog, self.window), c.GTK_RESPONSE_CANCEL);
        _ = c.g_signal_connect_data(self.window, "response", @ptrCast(&responded), self, null, 0);
        c.gtk_widget_show_all(self.window);
        @import("desktop-portal-window.zig").parentTo(self.window, allocator, parent);
        return self;
    }
    pub fn destroy(self: *Picker) void {
        _ = c.g_signal_handlers_disconnect_matched(self.window, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
        c.gtk_widget_destroy(self.window);
        self.client.deinit();
        self.allocator.destroy(self);
    }
    fn responded(_: *c.GtkDialog, response: c_int, data: ?*anyopaque) callconv(.c) void {
        const self = cast(Picker, data);
        c.gtk_widget_hide(self.window);
        if (response != c.GTK_RESPONSE_OK) {
            self.callback(self.data, null, false);
            return;
        }
        const id = c.gtk_combo_box_get_active_id(cast(c.GtkComboBox, self.combo));
        if (id == null) {
            self.callback(self.data, null, false);
            return;
        }
        for (self.client.outputs.items) |*output| if (std.mem.eql(u8, std.mem.sliceTo(&output.name, 0), std.mem.span(id))) {
            const display = c.gdk_display_get_default();
            var monitor: ?*c.GdkMonitor = null;
            var rect: c.GdkRectangle = undefined;
            var index: c_int = 0;
            while (index < c.gdk_display_get_n_monitors(display)) : (index += 1) {
                const candidate = c.gdk_display_get_monitor(display, index);
                c.gdk_monitor_get_geometry(candidate, &rect);
                if (rect.x == output.x and rect.y == output.y) {
                    monitor = candidate;
                    break;
                }
            }
            if (monitor == null) {
                self.callback(self.data, null, false);
                return;
            }
            self.callback(self.data, .{ .name = std.mem.span(id), .monitor = monitor, .width = rect.width, .height = rect.height }, self.area != null and c.gtk_toggle_button_get_active(cast(c.GtkToggleButton, self.area.?)) != 0);
            return;
        };
        self.callback(self.data, null, false);
    }
};

pub const Operation = struct {
    allocator: std.mem.Allocator,
    picker: ?*Picker = null,
    capture: ?*Capture = null,
    overlay: ?*c.GtkWidget = null,
    timer: c.guint = 0,
    name: ?[:0]u8 = null,
    point: bool,
    region: ?sc.Rect = null,
    width: i32 = 0,
    height: i32 = 0,
    start_x: f64 = 0,
    start_y: f64 = 0,
    current_x: f64 = 0,
    current_y: f64 = 0,
    dragging: bool = false,
    callback: Completion,
    data: ?*anyopaque,

    pub fn create(allocator: std.mem.Allocator, app: [:0]const u8, parent: [:0]const u8, method: []const u8, options: *c.GVariant, callback: Completion, data: ?*anyopaque) !*Operation {
        var interactive = false;
        for ([_][*:0]const u8{ "interactive", "modal" }) |option_key| {
            const value = c.g_variant_lookup_value(options, option_key, null);
            defer if (value != null) c.g_variant_unref(value);
            if (value != null and !std.mem.eql(u8, std.mem.span(c.g_variant_get_type_string(value)), "b")) return error.InvalidScreenshotOptions;
        }
        const hint = c.g_variant_lookup_value(options, "interactive", null);
        if (hint != null) {
            interactive = c.g_variant_get_boolean(hint) != 0;
            c.g_variant_unref(hint);
        }
        const self = try allocator.create(Operation);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .point = std.mem.eql(u8, method, "PickColor"), .callback = callback, .data = data };
        self.picker = try Picker.create(allocator, app, parent, if (self.point) "Pick a color" else "Share a screenshot", interactive and !self.point, &picked, self);
        const modal = c.g_variant_lookup_value(options, "modal", null);
        if (modal != null) {
            c.gtk_window_set_modal(cast(c.GtkWindow, self.picker.?.window), c.g_variant_get_boolean(modal));
            c.g_variant_unref(modal);
        }
        return self;
    }
    pub fn destroy(self: *Operation) void {
        if (self.timer != 0) _ = c.g_source_remove(self.timer);
        if (self.capture) |capture| capture.destroy();
        if (self.picker) |picker| picker.destroy();
        if (self.overlay) |window| c.gtk_widget_destroy(window);
        if (self.name) |name| self.allocator.free(name);
        self.allocator.destroy(self);
    }
    fn picked(data: ?*anyopaque, output: ?Picked, area: bool) void {
        const self = cast(Operation, data);
        const chosen = output orelse return self.finish(1, null);
        self.name = self.allocator.dupeSentinel(u8, chosen.name, 0) catch return self.finish(2, null);
        self.width = chosen.width;
        self.height = chosen.height;
        if (area or self.point) {
            const window = c.gtk_window_new(c.GTK_WINDOW_TOPLEVEL);
            self.overlay = window;
            c.gtk_layer_init_for_window(cast(c.GtkWindow, window));
            c.gtk_layer_set_monitor(cast(c.GtkWindow, window), chosen.monitor);
            c.gtk_layer_set_layer(cast(c.GtkWindow, window), c.GTK_LAYER_SHELL_LAYER_OVERLAY);
            c.gtk_layer_set_keyboard_mode(cast(c.GtkWindow, window), c.GTK_LAYER_SHELL_KEYBOARD_MODE_EXCLUSIVE);
            for ([_]c_uint{ c.GTK_LAYER_SHELL_EDGE_TOP, c.GTK_LAYER_SHELL_EDGE_BOTTOM, c.GTK_LAYER_SHELL_EDGE_LEFT, c.GTK_LAYER_SHELL_EDGE_RIGHT }) |edge| c.gtk_layer_set_anchor(cast(c.GtkWindow, window), edge, 1);
            c.gtk_widget_set_app_paintable(window, 1);
            if (c.gdk_screen_get_rgba_visual(c.gtk_widget_get_screen(window))) |visual| c.gtk_widget_set_visual(window, visual);
            c.gtk_widget_add_events(window, c.GDK_BUTTON_PRESS_MASK | c.GDK_BUTTON_RELEASE_MASK | c.GDK_KEY_PRESS_MASK | c.GDK_POINTER_MOTION_MASK);
            _ = c.g_signal_connect_data(window, "draw", @ptrCast(&draw), self, null, 0);
            _ = c.g_signal_connect_data(window, "button-press-event", @ptrCast(&press), self, null, 0);
            _ = c.g_signal_connect_data(window, "button-release-event", @ptrCast(&release), self, null, 0);
            _ = c.g_signal_connect_data(window, "key-press-event", @ptrCast(&key), self, null, 0);
            _ = c.g_signal_connect_data(window, "motion-notify-event", @ptrCast(&motion), self, null, 0);
            c.gtk_widget_show_all(window);
            if (c.gtk_widget_get_window(window)) |gdk_window| {
                if (c.gdk_cursor_new_from_name(c.gdk_window_get_display(gdk_window), "crosshair")) |cursor| {
                    c.gdk_window_set_cursor(gdk_window, cursor);
                    c.g_object_unref(cursor);
                }
            }
        } else self.schedule();
    }
    fn draw(widget: *c.GtkWidget, cr: *c.cairo_t, data: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast(Operation, data);
        const w_i = c.gtk_widget_get_allocated_width(widget);
        const h_i = c.gtk_widget_get_allocated_height(widget);
        if (w_i <= 0 or h_i <= 0) return 1;
        const width: usize = @intCast(w_i);
        const height: usize = @intCast(h_i);
        const total = width * height;
        const pixels = self.allocator.alloc(u32, total) catch return 1;
        defer self.allocator.free(pixels);

        @memset(pixels, 0x59000000);

        if (self.dragging and !self.point) {
            const rx: usize = @intCast(@max(0, @min(width - 1, @as(usize, @intFromFloat(@min(self.start_x, self.current_x))))));
            const ry: usize = @intCast(@max(0, @min(height - 1, @as(usize, @intFromFloat(@min(self.start_y, self.current_y))))));
            const rw: usize = @intCast(@min(width - rx, @as(usize, @intFromFloat(@abs(self.current_x - self.start_x)))));
            const rh: usize = @intCast(@min(height - ry, @as(usize, @intFromFloat(@abs(self.current_y - self.start_y)))));
            for (ry..ry + rh) |y| {
                @memset(pixels[y * width + rx ..][0..rw], 0x00000000);
            }
            const blue = 0xff3584e4;
            for (0..2) |b| {
                if (ry + b < height) {
                    for (rx..rx + rw) |x| pixels[(ry + b) * width + x] = blue;
                }
                if (ry + rh > b and ry + rh - 1 - b < height) {
                    for (rx..rx + rw) |x| pixels[(ry + rh - 1 - b) * width + x] = blue;
                }
                for (ry..ry + rh) |y| {
                    if (rx + b < width) pixels[y * width + (rx + b)] = blue;
                    if (rx + rw > b and rx + rw - 1 - b < width) pixels[y * width + (rx + rw - 1 - b)] = blue;
                }
            }
        }

        const msg = if (self.point) "Click to pick a color. Esc to cancel." else "Drag to select an area. Esc to cancel.";
        font.drawText(pixels.ptr, width, 32, 40, msg, 1, 0xffffffff);

        const surf = c.cairo_image_surface_create_for_data(@ptrCast(pixels.ptr), c.CAIRO_FORMAT_ARGB32, @intCast(width), @intCast(height), @intCast(width * 4));
        defer c.cairo_surface_destroy(surf);
        c.cairo_set_source_surface(cr, surf, 0, 0);
        c.cairo_paint(cr);
        return 1;
    }
    fn motion(_: *c.GtkWidget, event: ?*c.GdkEvent, data: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast(Operation, data);
        if (self.dragging) {
            _ = c.gdk_event_get_coords(event, &self.current_x, &self.current_y);
            c.gtk_widget_queue_draw(self.overlay.?);
        }
        return 1;
    }
    fn press(_: *c.GtkWidget, event: ?*c.GdkEvent, data: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast(Operation, data);
        var button: c.guint = 0;
        _ = c.gdk_event_get_button(event, &button);
        if (button == 1) {
            _ = c.gdk_event_get_coords(event, &self.start_x, &self.start_y);
            self.current_x = self.start_x;
            self.current_y = self.start_y;
            self.dragging = true;
        } else self.finish(1, null);
        return 1;
    }
    fn release(_: *c.GtkWidget, event: ?*c.GdkEvent, data: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast(Operation, data);
        if (!self.dragging) return 1;
        var x: f64 = 0;
        var y: f64 = 0;
        _ = c.gdk_event_get_coords(event, &x, &y);
        self.dragging = false;
        const rect = sc.Rect{ .x = @intFromFloat(if (self.point) x else @min(x, self.start_x)), .y = @intFromFloat(if (self.point) y else @min(y, self.start_y)), .w = if (self.point) 1 else @intFromFloat(@abs(x - self.start_x)), .h = if (self.point) 1 else @intFromFloat(@abs(y - self.start_y)) };
        if (rect.w <= 0 or rect.h <= 0) {
            self.finish(1, null);
            return 1;
        }
        self.region = rect;
        c.gtk_widget_hide(self.overlay.?);
        self.schedule();
        return 1;
    }
    fn key(_: *c.GtkWidget, event: ?*c.GdkEvent, data: ?*anyopaque) callconv(.c) c.gboolean {
        var value: c.guint = 0;
        _ = c.gdk_event_get_keyval(event, &value);
        if (value == c.GDK_KEY_Escape) cast(Operation, data).finish(1, null);
        return 1;
    }
    fn schedule(self: *Operation) void {
        self.timer = c.g_timeout_add(150, &startCapture, self);
    }
    fn startCapture(data: ?*anyopaque) callconv(.c) c_int {
        const self = cast(Operation, data);
        self.timer = 0;
        self.capture = Capture.create(self.allocator, self.name.?, false, &captured, self) catch {
            self.finish(2, null);
            return 0;
        };
        return 0;
    }
    fn captured(data: ?*anyopaque, source: ?*Image) void {
        const self = cast(Operation, data);
        const img = source orelse return self.finish(2, null);
        const width: i32 = @intCast(img.width);
        const height: i32 = @intCast(img.height);
        var x: i32 = 0;
        var y: i32 = 0;
        var w = width;
        var h = height;
        if (self.region) |region| {
            // GTK selection coordinates are logical; screencopy pixels are physical.
            x = @intCast(@divFloor(@as(i64, region.x) * width, self.width));
            y = @intCast(@divFloor(@as(i64, region.y) * height, self.height));
            w = @intCast(@divFloor(@as(i64, region.w) * width, self.width));
            h = @intCast(@divFloor(@as(i64, region.h) * height, self.height));
            x = std.math.clamp(x, 0, width - 1);
            y = std.math.clamp(y, 0, height - 1);
            w = std.math.clamp(w, 1, width - x);
            h = std.math.clamp(h, 1, height - y);
        }
        const results = c.g_variant_builder_new(@ptrCast(@as([*:0]const u8, "a{sv}")));
        defer c.g_variant_builder_unref(results);
        if (self.point) {
            const pixels: [*]const u8 = img.pixels.ptr;
            const stride: usize = img.stride;
            const pixel = std.mem.readInt(u32, pixels[@as(usize, @intCast(y)) * stride + @as(usize, @intCast(x)) * 4 ..][0..4], @import("builtin").cpu.arch.endian());
            c.g_variant_builder_add(results, "{sv}", @as([*:0]const u8, "color"), c.g_variant_new("(ddd)", @as(f64, @floatFromInt((pixel >> 16) & 255)) / 255, @as(f64, @floatFromInt((pixel >> 8) & 255)) / 255, @as(f64, @floatFromInt(pixel & 255)) / 255));
        } else {
            const crop_w: usize = @intCast(w);
            const crop_h: usize = @intCast(h);
            const crop_buf = self.allocator.alloc(u8, crop_w * crop_h * 4) catch return self.finish(2, null);
            defer self.allocator.free(crop_buf);
            const src_pixels: [*]const u8 = img.pixels.ptr;
            const src_stride: usize = img.stride;
            for (0..crop_h) |cy| {
                const sy: usize = @intCast(y + @as(i32, @intCast(cy)));
                const sx: usize = @intCast(x);
                @memcpy(crop_buf[cy * crop_w * 4 .. (cy + 1) * crop_w * 4], src_pixels[sy * src_stride + sx * 4 .. sy * src_stride + (sx + crop_w) * 4]);
            }
            const png_bytes = png.encode(self.allocator, .{
                .pixels = crop_buf,
                .width = @intCast(crop_w),
                .height = @intCast(crop_h),
                .stride = @intCast(crop_w * 4),
                .alpha = false,
                .y_invert = false,
            }) catch return self.finish(2, null);
            defer self.allocator.free(png_bytes);

            const filename = std.fmt.allocPrintSentinel(self.allocator, "{s}/desktop-screenshot-XXXXXX", .{c.g_get_user_runtime_dir()}, 0) catch return self.finish(2, null);
            defer self.allocator.free(filename);
            const fd = c.g_mkstemp(filename);
            if (fd < 0) return self.finish(2, null);
            defer _ = libc.close(fd);
            if (libc.write(fd, png_bytes.ptr, png_bytes.len) != png_bytes.len) {
                _ = libc.unlink(filename);
                return self.finish(2, null);
            }
            const uri = c.g_filename_to_uri(filename, null, null);
            if (uri == null) {
                _ = libc.unlink(filename);
                return self.finish(2, null);
            }
            defer c.g_free(uri);
            c.g_variant_builder_add(results, "{sv}", @as([*:0]const u8, "uri"), c.g_variant_new("s", uri));
        }
        self.finish(0, c.g_variant_builder_end(results));
    }
    fn finish(self: *Operation, code: u32, results: ?*c.GVariant) void {
        self.callback(self.data, code, results orelse c.g_variant_new_array(@ptrCast(@as([*:0]const u8, "{sv}")), null, 0));
    }
};

test "capture images normalize inverted rows and preserve padding and RGB channels" {
    var pixels = [_]u32{ 0x00ff0000, 0x0000ff00, 0xdeadbeef, 0x000000ff, 0x00ffffff, 0xdeadbeef };
    const frame = sc.FrameCapture{
        .shm = undefined,
        .frame = undefined,
        .format = c.WL_SHM_FORMAT_XRGB8888,
        .width = 2,
        .height = 2,
        .stride = 12,
        .memory = @ptrCast(&pixels),
        .length = @sizeOf(@TypeOf(pixels)),
        .y_invert = true,
    };
    const img = try image(std.testing.allocator, &frame);
    defer img.unref();
    const bytes = img.pixels.ptr;
    const stride: usize = img.stride;
    const endian = @import("builtin").cpu.arch.endian();
    try std.testing.expectEqual(@as(u32, 0xff), std.mem.readInt(u32, bytes[0..4], endian) & 0xffffff);
    try std.testing.expectEqual(@as(u32, 0xffffff), std.mem.readInt(u32, bytes[4..8], endian) & 0xffffff);
    try std.testing.expectEqual(@as(u32, 0xff0000), std.mem.readInt(u32, bytes[stride..][0..4], endian) & 0xffffff);
    var invalid = frame;
    invalid.length -= 1;
    try std.testing.expectError(error.InvalidFrame, image(std.testing.allocator, &invalid));
    invalid = frame;
    invalid.stride = 4;
    try std.testing.expectError(error.InvalidFrame, image(std.testing.allocator, &invalid));
    invalid = frame;
    invalid.format = 0xdeadbeef;
    try std.testing.expectError(error.UnsupportedFormat, image(std.testing.allocator, &invalid));
}
