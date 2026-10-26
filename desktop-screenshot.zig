//! Wayland screenshot tool with region selection and clipboard support.
const std = @import("std");
pub const c = @import("gtk");

fn cast(comptime T: type, ptr: anytype) *T {
    return @ptrCast(@alignCast(ptr));
}

pub const Rect = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,

    pub fn parse(text: []const u8) ?Rect {
        const trimmed = std.mem.trim(u8, text, " \"'");
        const comma = std.mem.indexOfScalar(u8, trimmed, ',') orelse return null;
        const space = std.mem.indexOfScalar(u8, trimmed[comma + 1 ..], ' ') orelse return null;
        const x_str = trimmed[0..comma];
        const y_str = trimmed[comma + 1 .. comma + 1 + space];
        const size_str = std.mem.trim(u8, trimmed[comma + 1 + space + 1 ..], " ");

        const cross = std.mem.indexOfAny(u8, size_str, "xX ") orelse return null;
        const w_str = size_str[0..cross];
        const h_str = size_str[cross + 1 ..];

        const x = std.fmt.parseInt(i32, x_str, 10) catch return null;
        const y = std.fmt.parseInt(i32, y_str, 10) catch return null;
        const w = std.fmt.parseInt(i32, w_str, 10) catch return null;
        const h = std.fmt.parseInt(i32, h_str, 10) catch return null;
        if (w <= 0 or h <= 0) return null;
        return .{ .x = x, .y = y, .w = w, .h = h };
    }
};

pub const Options = struct {
    output_name: ?[]const u8 = null,
    geometry: ?Rect = null,
    scale: f64 = 1.0,
    clipboard: bool = false,
    interactive: bool = false,
    slurp_mode: bool = false,
    file_path: ?[]const u8 = null,
    save_default: bool = false,

    pub fn parse(args: []const []const u8) Options {
        var opt = Options{};
        const prog = if (args.len > 0) std.fs.path.basename(args[0]) else "";
        if (std.mem.eql(u8, prog, "slurp")) {
            opt.slurp_mode = true;
        }

        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--slurp")) {
                opt.slurp_mode = true;
            } else if (std.mem.eql(u8, arg, "--")) {
                if (i + 1 < args.len) {
                    i += 1;
                    opt.file_path = args[i];
                }
            } else if (std.mem.eql(u8, arg, "-o") and i + 1 < args.len) {
                i += 1;
                opt.output_name = args[i];
            } else if (std.mem.eql(u8, arg, "-g") and i + 1 < args.len) {
                i += 1;
                opt.geometry = Rect.parse(args[i]);
            } else if (std.mem.eql(u8, arg, "-s") and i + 1 < args.len) {
                i += 1;
                opt.scale = std.fmt.parseFloat(f64, args[i]) catch 1.0;
            } else if (std.mem.eql(u8, arg, "-t") and i + 1 < args.len) {
                i += 1;
                // ignore format
            } else if (std.mem.eql(u8, arg, "-f") and i + 1 < args.len) {
                i += 1;
                // ignore slurp format
            } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--clipboard")) {
                opt.clipboard = true;
            } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--interactive") or std.mem.eql(u8, arg, "--select")) {
                opt.interactive = true;
            } else if (std.mem.startsWith(u8, arg, "-")) {
                // Ignore other flags like -p, -or
                continue;
            } else {
                opt.file_path = arg;
            }
        }
        if (!opt.slurp_mode and opt.file_path == null) {
            opt.save_default = !opt.clipboard;
            if (opt.geometry == null) {
                opt.interactive = true;
                opt.clipboard = true;
            }
        }
        return opt;
    }
};

pub const PngBuffer = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) PngBuffer {
        return .{
            .allocator = allocator,
            .bytes = .empty,
        };
    }

    pub fn deinit(self: *PngBuffer) void {
        self.bytes.deinit(self.allocator);
    }

    pub fn writeCallback(closure: ?*anyopaque, data: [*c]const u8, length: c_uint) callconv(.c) c.cairo_status_t {
        const self: *PngBuffer = @ptrCast(@alignCast(closure));
        self.bytes.appendSlice(self.allocator, data[0..length]) catch return c.CAIRO_STATUS_WRITE_ERROR;
        return c.CAIRO_STATUS_SUCCESS;
    }
};

fn writeStdout(_: ?*anyopaque, data: [*c]const u8, length: c_uint) callconv(.c) c.cairo_status_t {
    const written = c.write(c.STDOUT_FILENO, data, length);
    if (written < 0 or @as(c_uint, @intCast(written)) != length) return c.CAIRO_STATUS_WRITE_ERROR;
    return c.CAIRO_STATUS_SUCCESS;
}

pub const Output = struct {
    wl_out: *c.wl_output,
    name: [64:0]u8 = @splat(0),
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    scale: i32 = 1,
};

pub const WaylandClient = struct {
    allocator: std.mem.Allocator,
    display: *c.wl_display,
    registry: *c.wl_registry,
    shm: ?*c.wl_shm = null,
    screencopy_mgr: ?*c.zwlr_screencopy_manager_v1 = null,
    data_control_mgr: ?*c.zwlr_data_control_manager_v1 = null,
    seat: ?*c.wl_seat = null,
    outputs: std.ArrayList(Output) = .empty,

    pub fn connect(allocator: std.mem.Allocator) !WaylandClient {
        const display = c.wl_display_connect(null) orelse return error.ConnectFailed;
        errdefer c.wl_display_disconnect(display);

        const registry = c.wl_display_get_registry(display) orelse return error.RegistryFailed;
        var self = WaylandClient{
            .allocator = allocator,
            .display = display,
            .registry = registry,
        };

        _ = c.wl_registry_add_listener(registry, &registry_listener, &self);
        _ = c.wl_display_roundtrip(display);
        _ = c.wl_display_roundtrip(display);
        return self;
    }

    pub fn deinit(self: *WaylandClient) void {
        for (self.outputs.items) |out| c.wl_output_destroy(out.wl_out);
        self.outputs.deinit(self.allocator);
        if (self.screencopy_mgr) |mgr| c.zwlr_screencopy_manager_v1_destroy(mgr);
        if (self.data_control_mgr) |mgr| c.zwlr_data_control_manager_v1_destroy(mgr);
        if (self.shm) |s| c.wl_shm_destroy(s);
        if (self.seat) |seat| c.wl_seat_destroy(seat);
        c.wl_registry_destroy(self.registry);
        c.wl_display_disconnect(self.display);
    }

    fn registryGlobal(data: ?*anyopaque, registry: ?*c.wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
        const self: *WaylandClient = @ptrCast(@alignCast(data));
        const iface = std.mem.span(interface);
        if (std.mem.eql(u8, iface, "wl_shm")) {
            self.shm = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_shm_interface, 1));
        } else if (std.mem.eql(u8, iface, "zwlr_screencopy_manager_v1")) {
            self.screencopy_mgr = @ptrCast(c.wl_registry_bind(registry, name, &c.zwlr_screencopy_manager_v1_interface, @min(version, 3)));
        } else if (std.mem.eql(u8, iface, "zwlr_data_control_manager_v1")) {
            self.data_control_mgr = @ptrCast(c.wl_registry_bind(registry, name, &c.zwlr_data_control_manager_v1_interface, @min(version, 2)));
        } else if (std.mem.eql(u8, iface, "wl_seat")) {
            self.seat = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_seat_interface, 1));
        } else if (std.mem.eql(u8, iface, "wl_output")) {
            const out = @as(?*c.wl_output, @ptrCast(c.wl_registry_bind(registry, name, &c.wl_output_interface, @min(version, 4)))) orelse return;
            self.outputs.append(self.allocator, .{ .wl_out = out }) catch return;
            const item = &self.outputs.items[self.outputs.items.len - 1];
            _ = c.wl_output_add_listener(out, &output_listener, item);
        }
    }

    fn registryRemove(_: ?*anyopaque, _: ?*c.wl_registry, _: u32) callconv(.c) void {}

    const registry_listener = c.wl_registry_listener{
        .global = &registryGlobal,
        .global_remove = &registryRemove,
    };

    fn outputGeometry(data: ?*anyopaque, _: ?*c.wl_output, x: i32, y: i32, _: i32, _: i32, _: i32, _: [*c]const u8, _: [*c]const u8, _: i32) callconv(.c) void {
        const out: *Output = @ptrCast(@alignCast(data));
        out.x = x;
        out.y = y;
    }
    fn outputMode(data: ?*anyopaque, _: ?*c.wl_output, flags: u32, width: i32, height: i32, _: i32) callconv(.c) void {
        const out: *Output = @ptrCast(@alignCast(data));
        if ((flags & c.WL_OUTPUT_MODE_CURRENT) != 0) {
            out.width = width;
            out.height = height;
        }
    }
    fn outputDone(_: ?*anyopaque, _: ?*c.wl_output) callconv(.c) void {}
    fn outputScale(data: ?*anyopaque, _: ?*c.wl_output, factor: i32) callconv(.c) void {
        const out: *Output = @ptrCast(@alignCast(data));
        out.scale = factor;
    }
    fn outputName(data: ?*anyopaque, _: ?*c.wl_output, name: [*c]const u8) callconv(.c) void {
        const out: *Output = @ptrCast(@alignCast(data));
        const span = std.mem.span(name);
        if (span.len < out.name.len) {
            @memcpy(out.name[0..span.len], span);
            out.name[span.len] = 0;
        }
    }
    fn outputDescription(_: ?*anyopaque, _: ?*c.wl_output, _: [*c]const u8) callconv(.c) void {}

    const output_listener = c.wl_output_listener{
        .geometry = &outputGeometry,
        .mode = &outputMode,
        .done = &outputDone,
        .scale = &outputScale,
        .name = &outputName,
        .description = &outputDescription,
    };
};

pub const FrameCapture = struct {
    shm: *c.wl_shm,
    frame: *c.zwlr_screencopy_frame_v1,
    format: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    stride: u32 = 0,
    buffer: ?*c.wl_buffer = null,
    memory: ?[*]u8 = null,
    length: usize = 0,
    done: bool = false,
    failed: bool = false,
    y_invert: bool = false,

    fn onBuffer(data: ?*anyopaque, frame: ?*c.zwlr_screencopy_frame_v1, format: u32, width: u32, height: u32, stride: u32) callconv(.c) void {
        const self: *FrameCapture = @ptrCast(@alignCast(data));
        self.format = format;
        self.width = width;
        self.height = height;
        self.stride = stride;
        self.length = @as(usize, stride) * height;

        const fd = c.memfd_create("desktop-screenshot", c.MFD_CLOEXEC);
        if (fd < 0) {
            self.failed = true;
            return;
        }
        defer _ = c.close(fd);

        if (c.ftruncate(fd, @intCast(self.length)) != 0) {
            self.failed = true;
            return;
        }
        const mem = c.mmap(null, self.length, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, fd, 0);
        if (mem == c.MAP_FAILED or mem == null) {
            self.failed = true;
            return;
        }
        self.memory = @ptrCast(mem);

        const pool = c.wl_shm_create_pool(self.shm, fd, @intCast(self.length));
        self.buffer = c.wl_shm_pool_create_buffer(pool, 0, @intCast(width), @intCast(height), @intCast(stride), format);
        c.wl_shm_pool_destroy(pool);

        if (c.zwlr_screencopy_frame_v1_get_version(frame) < 3) {
            c.zwlr_screencopy_frame_v1_copy(frame, self.buffer);
        }
    }

    fn onBufferDone(data: ?*anyopaque, frame: ?*c.zwlr_screencopy_frame_v1) callconv(.c) void {
        const self: *FrameCapture = @ptrCast(@alignCast(data));
        if (self.failed) return;
        if (self.buffer == null) {
            self.failed = true;
            return;
        }
        c.zwlr_screencopy_frame_v1_copy(frame, self.buffer);
    }

    fn onLinuxDmabuf(_: ?*anyopaque, _: ?*c.zwlr_screencopy_frame_v1, _: u32, _: u32, _: u32) callconv(.c) void {}
    fn onDamage(_: ?*anyopaque, _: ?*c.zwlr_screencopy_frame_v1, _: u32, _: u32, _: u32, _: u32) callconv(.c) void {}

    fn onFlags(data: ?*anyopaque, _: ?*c.zwlr_screencopy_frame_v1, flags: u32) callconv(.c) void {
        const self: *FrameCapture = @ptrCast(@alignCast(data));
        self.y_invert = (flags & c.ZWLR_SCREENCOPY_FRAME_V1_FLAGS_Y_INVERT) != 0;
    }

    fn onReady(data: ?*anyopaque, _: ?*c.zwlr_screencopy_frame_v1, _: u32, _: u32, _: u32) callconv(.c) void {
        const self: *FrameCapture = @ptrCast(@alignCast(data));
        self.done = true;
    }

    fn onFailed(data: ?*anyopaque, _: ?*c.zwlr_screencopy_frame_v1) callconv(.c) void {
        const self: *FrameCapture = @ptrCast(@alignCast(data));
        self.failed = true;
    }

    const listener = c.zwlr_screencopy_frame_v1_listener{
        .buffer = &onBuffer,
        .flags = &onFlags,
        .ready = &onReady,
        .failed = &onFailed,
        .damage = &onDamage,
        .linux_dmabuf = &onLinuxDmabuf,
        .buffer_done = &onBufferDone,
    };
};

pub const SelectionOverlay = struct {
    window: *c.GtkWidget,
    start_x: f64 = 0,
    start_y: f64 = 0,
    current_x: f64 = 0,
    current_y: f64 = 0,
    dragging: bool = false,
    selected: ?Rect = null,
    done: bool = false,

    pub fn run() ?Rect {
        if (c.gtk_init_check(null, null) == 0) return null;
        var overlay = SelectionOverlay{
            .window = c.gtk_window_new(c.GTK_WINDOW_TOPLEVEL),
        };

        c.gtk_layer_init_for_window(cast(c.GtkWindow, overlay.window));
        c.gtk_layer_set_layer(cast(c.GtkWindow, overlay.window), c.GTK_LAYER_SHELL_LAYER_OVERLAY);
        c.gtk_layer_set_keyboard_mode(cast(c.GtkWindow, overlay.window), c.GTK_LAYER_SHELL_KEYBOARD_MODE_EXCLUSIVE);
        c.gtk_layer_set_anchor(cast(c.GtkWindow, overlay.window), c.GTK_LAYER_SHELL_EDGE_TOP, 1);
        c.gtk_layer_set_anchor(cast(c.GtkWindow, overlay.window), c.GTK_LAYER_SHELL_EDGE_BOTTOM, 1);
        c.gtk_layer_set_anchor(cast(c.GtkWindow, overlay.window), c.GTK_LAYER_SHELL_EDGE_LEFT, 1);
        c.gtk_layer_set_anchor(cast(c.GtkWindow, overlay.window), c.GTK_LAYER_SHELL_EDGE_RIGHT, 1);

        c.gtk_widget_set_app_paintable(overlay.window, 1);
        const visual = c.gdk_screen_get_rgba_visual(c.gtk_widget_get_screen(overlay.window));
        if (visual != null) c.gtk_widget_set_visual(overlay.window, visual);

        c.gtk_widget_add_events(overlay.window, c.GDK_BUTTON_PRESS_MASK | c.GDK_BUTTON_RELEASE_MASK | c.GDK_POINTER_MOTION_MASK | c.GDK_KEY_PRESS_MASK);
        _ = c.g_signal_connect_data(cast(c.GObject, overlay.window), "draw", @ptrCast(&onDraw), &overlay, null, 0);
        _ = c.g_signal_connect_data(cast(c.GObject, overlay.window), "button-press-event", @ptrCast(&onButtonPress), &overlay, null, 0);
        _ = c.g_signal_connect_data(cast(c.GObject, overlay.window), "motion-notify-event", @ptrCast(&onMotion), &overlay, null, 0);
        _ = c.g_signal_connect_data(cast(c.GObject, overlay.window), "button-release-event", @ptrCast(&onButtonRelease), &overlay, null, 0);
        _ = c.g_signal_connect_data(cast(c.GObject, overlay.window), "key-press-event", @ptrCast(&onKeyPress), &overlay, null, 0);

        c.gtk_widget_show_all(overlay.window);
        if (c.gtk_widget_get_window(overlay.window)) |gdk_win| {
            const cursor = c.gdk_cursor_new_from_name(c.gdk_window_get_display(gdk_win), "crosshair");
            c.gdk_window_set_cursor(gdk_win, cursor);
        }

        while (!overlay.done and c.gtk_events_pending() != 0) {
            _ = c.gtk_main_iteration();
        }
        if (!overlay.done) c.gtk_main();

        c.gtk_widget_destroy(overlay.window);
        while (c.gtk_events_pending() != 0) _ = c.gtk_main_iteration();

        return overlay.selected;
    }

    fn onDraw(_: *c.GtkWidget, cr: *c.cairo_t, data: c.gpointer) callconv(.c) c.gboolean {
        const self: *SelectionOverlay = @ptrCast(@alignCast(data));
        c.cairo_set_source_rgba(cr, 0, 0, 0, 0.35);
        c.cairo_paint(cr);

        if (self.dragging) {
            const rx = @min(self.start_x, self.current_x);
            const ry = @min(self.start_y, self.current_y);
            const rw = @abs(self.current_x - self.start_x);
            const rh = @abs(self.current_y - self.start_y);

            if (rw > 1 and rh > 1) {
                c.cairo_save(cr);
                c.cairo_set_operator(cr, c.CAIRO_OPERATOR_CLEAR);
                c.cairo_rectangle(cr, rx, ry, rw, rh);
                c.cairo_fill(cr);
                c.cairo_restore(cr);

                c.cairo_set_source_rgb(cr, 0.208, 0.518, 0.894);
                c.cairo_set_line_width(cr, 2.0);
                c.cairo_rectangle(cr, rx, ry, rw, rh);
                c.cairo_stroke(cr);

                var buf: [64:0]u8 = undefined;
                const label = std.fmt.bufPrintSentinel(&buf, "{d:.0} × {d:.0}", .{ rw, rh }, 0) catch return 0;
                c.cairo_set_source_rgba(cr, 0.1, 0.1, 0.1, 0.85);
                c.cairo_rectangle(cr, rx, ry + rh + 6, 90, 22);
                c.cairo_fill(cr);
                c.cairo_set_source_rgb(cr, 1, 1, 1);
                c.cairo_select_font_face(cr, "Adwaita Sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_BOLD);
                c.cairo_set_font_size(cr, 11);
                c.cairo_move_to(cr, rx + 8, ry + rh + 21);
                c.cairo_show_text(cr, label.ptr);
            }
        }
        return 0;
    }

    fn onButtonPress(_: *c.GtkWidget, event: ?*anyopaque, data: c.gpointer) callconv(.c) c.gboolean {
        const self: *SelectionOverlay = @ptrCast(@alignCast(data));
        var btn: c.guint = 0;
        _ = c.gdk_event_get_button(cast(c.GdkEvent, event), &btn);
        if (btn == 1) {
            _ = c.gdk_event_get_coords(cast(c.GdkEvent, event), &self.start_x, &self.start_y);
            self.current_x = self.start_x;
            self.current_y = self.start_y;
            self.dragging = true;
        }
        return 1;
    }

    fn onMotion(_: *c.GtkWidget, event: ?*anyopaque, data: c.gpointer) callconv(.c) c.gboolean {
        const self: *SelectionOverlay = @ptrCast(@alignCast(data));
        if (self.dragging) {
            _ = c.gdk_event_get_coords(cast(c.GdkEvent, event), &self.current_x, &self.current_y);
            c.gtk_widget_queue_draw(self.window);
        }
        return 1;
    }

    fn onButtonRelease(_: *c.GtkWidget, event: ?*anyopaque, data: c.gpointer) callconv(.c) c.gboolean {
        const self: *SelectionOverlay = @ptrCast(@alignCast(data));
        var btn: c.guint = 0;
        _ = c.gdk_event_get_button(cast(c.GdkEvent, event), &btn);
        if (btn == 1 and self.dragging) {
            self.dragging = false;
            _ = c.gdk_event_get_coords(cast(c.GdkEvent, event), &self.current_x, &self.current_y);
            const rx = @min(self.start_x, self.current_x);
            const ry = @min(self.start_y, self.current_y);
            const rw = @abs(self.current_x - self.start_x);
            const rh = @abs(self.current_y - self.start_y);
            if (rw > 4 and rh > 4) {
                self.selected = Rect{
                    .x = @intFromFloat(rx),
                    .y = @intFromFloat(ry),
                    .w = @intFromFloat(rw),
                    .h = @intFromFloat(rh),
                };
            }
            self.done = true;
            c.gtk_main_quit();
        }
        return 1;
    }

    fn onKeyPress(_: *c.GtkWidget, event: ?*anyopaque, data: c.gpointer) callconv(.c) c.gboolean {
        const self: *SelectionOverlay = @ptrCast(@alignCast(data));
        var keyval: c.guint = 0;
        _ = c.gdk_event_get_keyval(cast(c.GdkEvent, event), &keyval);
        if (keyval == c.GDK_KEY_Escape) {
            self.selected = null;
            self.done = true;
            c.gtk_main_quit();
        }
        return 1;
    }
};

const ClipboardOffer = struct {
    png_data: []const u8,
    cancelled: bool = false,

    fn onSend(data: ?*anyopaque, _: ?*c.zwlr_data_control_source_v1, mime: [*c]const u8, fd: i32) callconv(.c) void {
        const self: *ClipboardOffer = @ptrCast(@alignCast(data));
        defer _ = c.close(fd);
        const mime_str = std.mem.span(mime);
        if (std.mem.eql(u8, mime_str, "image/png") or std.mem.eql(u8, mime_str, "image/x-png")) {
            _ = c.write(fd, self.png_data.ptr, self.png_data.len);
        }
    }

    fn onCancelled(data: ?*anyopaque, _: ?*c.zwlr_data_control_source_v1) callconv(.c) void {
        const self: *ClipboardOffer = @ptrCast(@alignCast(data));
        self.cancelled = true;
    }

    const listener = c.zwlr_data_control_source_v1_listener{
        .send = &onSend,
        .cancelled = &onCancelled,
    };
};

pub fn copyToClipboard(client: *WaylandClient, png_data: []const u8) !void {
    const mgr = client.data_control_mgr orelse return error.NoDataControl;
    const seat = client.seat orelse return error.NoSeat;

    const source = c.zwlr_data_control_manager_v1_create_data_source(mgr) orelse return error.CreateSourceFailed;
    c.zwlr_data_control_source_v1_offer(source, "image/png");
    c.zwlr_data_control_source_v1_offer(source, "image/x-png");

    var offer = ClipboardOffer{ .png_data = png_data };
    _ = c.zwlr_data_control_source_v1_add_listener(source, &ClipboardOffer.listener, &offer);

    const device = c.zwlr_data_control_manager_v1_get_data_device(mgr, seat) orelse return error.GetDeviceFailed;
    c.zwlr_data_control_device_v1_set_selection(device, source);
    _ = c.wl_display_roundtrip(client.display);

    // Fork into background to serve clipboard paste requests until replaced
    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid != 0) return; // Parent returns immediately

    // Background child daemon serves paste requests
    while (!offer.cancelled) {
        if (c.wl_display_dispatch(client.display) < 0) break;
    }
    c.zwlr_data_control_source_v1_destroy(source);
    c.zwlr_data_control_device_v1_destroy(device);
    std.process.exit(0);
}

pub fn captureAndWrite(options: Options, allocator: std.mem.Allocator) !void {
    var client = try WaylandClient.connect(allocator);
    defer client.deinit();

    const screencopy_mgr = client.screencopy_mgr orelse return error.NoScreencopy;
    if (client.outputs.items.len == 0) return error.NoOutputs;

    var target_output: *Output = &client.outputs.items[0];
    if (options.output_name) |name| {
        for (client.outputs.items) |*out| {
            if (std.mem.eql(u8, std.mem.sliceTo(&out.name, 0), name)) {
                target_output = out;
                break;
            }
        }
    }

    var capture = FrameCapture{
        .shm = client.shm orelse return error.NoShm,
        .frame = undefined,
    };

    if (options.geometry) |geom| {
        capture.frame = c.zwlr_screencopy_manager_v1_capture_output_region(screencopy_mgr, 1, target_output.wl_out, geom.x, geom.y, geom.w, geom.h) orelse return error.CaptureFailed;
    } else {
        capture.frame = c.zwlr_screencopy_manager_v1_capture_output(screencopy_mgr, 1, target_output.wl_out) orelse return error.CaptureFailed;
    }
    defer c.zwlr_screencopy_frame_v1_destroy(capture.frame);
    defer {
        if (capture.buffer) |buffer| c.wl_buffer_destroy(buffer);
        if (capture.memory) |memory| _ = c.munmap(memory, capture.length);
    }

    _ = c.zwlr_screencopy_frame_v1_add_listener(capture.frame, &FrameCapture.listener, &capture);

    while (!capture.done and !capture.failed) {
        if (c.wl_display_dispatch(client.display) < 0) return error.DispatchFailed;
    }
    if (capture.failed or capture.memory == null) return error.CaptureFailed;

    const surface = c.cairo_image_surface_create_for_data(
        capture.memory,
        c.CAIRO_FORMAT_ARGB32,
        @intCast(capture.width),
        @intCast(capture.height),
        @intCast(capture.stride),
    ) orelse return error.SurfaceFailed;
    defer c.cairo_surface_destroy(surface);

    if (options.file_path) |path| {
        if (std.mem.eql(u8, path, "-")) {
            if (c.cairo_surface_write_to_png_stream(surface, &writeStdout, null) != c.CAIRO_STATUS_SUCCESS) return error.WriteFailed;
        } else {
            const zpath = try allocator.dupeSentinel(u8, path, 0);
            defer allocator.free(zpath);
            if (c.cairo_surface_write_to_png(surface, zpath.ptr) != c.CAIRO_STATUS_SUCCESS) return error.WriteFailed;
        }
    } else if (options.save_default) {
        const pictures = c.g_get_user_special_dir(c.G_USER_DIRECTORY_PICTURES);
        const directory = if (pictures != null)
            try std.fmt.allocPrintSentinel(allocator, "{s}/Screenshots", .{std.mem.span(pictures)}, 0)
        else
            try std.fmt.allocPrintSentinel(allocator, "{s}/Pictures/Screenshots", .{std.mem.span(c.g_get_home_dir())}, 0);
        defer allocator.free(directory);
        if (c.g_mkdir_with_parents(directory, 0o755) != 0) return error.CreateDirectoryFailed;
        const now = c.g_date_time_new_now_local() orelse return error.TimestampFailed;
        defer c.g_date_time_unref(now);
        const timestamp = c.g_date_time_format(now, "%Y-%m-%d_%H-%M-%S_%f") orelse return error.TimestampFailed;
        defer c.g_free(timestamp);
        const path = try std.fmt.allocPrintSentinel(allocator, "{s}/Screenshot_{s}.png", .{ directory, std.mem.span(timestamp) }, 0);
        defer allocator.free(path);
        if (c.cairo_surface_write_to_png(surface, path) != c.CAIRO_STATUS_SUCCESS) return error.WriteFailed;
        std.debug.print("Screenshot saved to {s}\n", .{path});
    }

    if (options.clipboard) {
        var png = PngBuffer.init(allocator);
        defer png.deinit();
        if (c.cairo_surface_write_to_png_stream(surface, &PngBuffer.writeCallback, &png) != c.CAIRO_STATUS_SUCCESS) return error.PngEncodeFailed;
        try copyToClipboard(&client, png.bytes.items);
    }
}

pub fn main(init: std.process.Init) void {
    const status = run(init) catch 1;
    if (status != 0) std.process.exit(status);
}

fn run(init: std.process.Init) !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const args = try init.minimal.args.toSlice(arena.allocator());
    var opt = Options.parse(args);

    if (opt.slurp_mode) {
        if (SelectionOverlay.run()) |rect| {
            var buf: [64]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "{d},{d} {d}x{d}\n", .{ rect.x, rect.y, rect.w, rect.h }) catch return 1;
            _ = c.write(c.STDOUT_FILENO, text.ptr, text.len);
            return 0;
        } else {
            return 1;
        }
    }

    if (opt.interactive) {
        opt.geometry = SelectionOverlay.run() orelse return 0; // Cancelled
    }

    captureAndWrite(opt, arena.allocator()) catch |err| {
        std.debug.print("desktop-screenshot error: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}
