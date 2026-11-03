//! Wayland screenshot tool with region selection and clipboard support.
const native = @import("desktop-surface.zig");
const std = @import("std");
pub const protocols = @import("desktop-protocols.zig");
const libc = @import("desktop-libc.zig");
pub const c = @import("desktop-gtk.zig");
pub const png = @import("desktop-png.zig");

const cast = c.__zig.cast;

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
            } else if (std.mem.eql(u8, arg, "-")) {
                opt.file_path = arg;
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

/// Write complete PNGs to files, pipes and clipboard receivers, retrying EINTR.
pub fn writeAll(fd: c_int, bytes: []const u8) !void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const count = libc.write(fd, remaining.ptr, remaining.len);
        if (count < 0) {
            if (libc.__errno_location().* == libc.EINTR) continue;
            return error.WriteFailed;
        }
        if (count == 0) return error.WriteFailed;
        remaining = remaining[@intCast(count)..];
    }
}
fn writeFile(path: [:0]const u8, bytes: []const u8) !void {
    const fd = libc.open(path, libc.O_WRONLY | libc.O_CREAT | libc.O_TRUNC | libc.O_CLOEXEC, @as(c_uint, 0o666));
    if (fd < 0) return error.WriteFailed;
    defer _ = libc.close(fd);
    try writeAll(fd, bytes);
}

pub const Output = struct {
    wl_out: *c.wl_output,
    global_name: u32 = 0,
    available: bool = true,
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
    screencopy_mgr: ?*protocols.zwlr_screencopy_manager_v1 = null,
    data_control_mgr: ?*protocols.zwlr_data_control_manager_v1 = null,
    seat: ?*c.wl_seat = null,
    outputs: std.ArrayList(Output) = .empty,

    /// Initialize in the final location: Wayland listeners retain this address.
    pub fn init(self: *WaylandClient, allocator: std.mem.Allocator) !void {
        const display = c.wl_display_connect(null) orelse return error.ConnectFailed;
        errdefer c.wl_display_disconnect(display);

        const registry = c.wl_display_get_registry(display) orelse return error.RegistryFailed;
        errdefer c.wl_registry_destroy(registry);
        self.* = WaylandClient{
            .allocator = allocator,
            .display = display,
            .registry = registry,
        };

        // Output listeners also need stable addresses while globals arrive.
        try self.outputs.ensureTotalCapacity(allocator, 64);
        errdefer self.outputs.deinit(allocator);
        _ = c.wl_registry_add_listener(registry, &registry_listener, self);
        if (c.wl_display_roundtrip(display) < 0 or c.wl_display_roundtrip(display) < 0) return error.DispatchFailed;
    }

    pub fn deinit(self: *WaylandClient) void {
        for (self.outputs.items) |out| c.wl_output_destroy(out.wl_out);
        self.outputs.deinit(self.allocator);
        if (self.screencopy_mgr) |mgr| protocols.zwlr_screencopy_manager_v1_destroy(mgr);
        if (self.data_control_mgr) |mgr| protocols.zwlr_data_control_manager_v1_destroy(mgr);
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
            self.screencopy_mgr = @ptrCast(c.wl_registry_bind(registry, name, &protocols.zwlr_screencopy_manager_v1_interface, @min(version, 3)));
        } else if (std.mem.eql(u8, iface, "zwlr_data_control_manager_v1")) {
            self.data_control_mgr = @ptrCast(c.wl_registry_bind(registry, name, &protocols.zwlr_data_control_manager_v1_interface, @min(version, 2)));
        } else if (std.mem.eql(u8, iface, "wl_seat")) {
            self.seat = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_seat_interface, 1));
        } else if (std.mem.eql(u8, iface, "wl_output")) {
            if (self.outputs.items.len == self.outputs.capacity) return;
            const out = @as(?*c.wl_output, @ptrCast(c.wl_registry_bind(registry, name, &c.wl_output_interface, @min(version, 4)))) orelse return;
            self.outputs.append(self.allocator, .{ .wl_out = out, .global_name = name }) catch return;
            const item = &self.outputs.items[self.outputs.items.len - 1];
            _ = c.wl_output_add_listener(out, &output_listener, item);
        }
    }

    fn registryRemove(data: ?*anyopaque, _: ?*c.wl_registry, name: u32) callconv(.c) void {
        const self = cast(WaylandClient, data);
        for (self.outputs.items) |*output| if (output.global_name == name) {
            output.available = false;
        };
    }

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
    frame: *protocols.zwlr_screencopy_frame_v1,
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

    fn onBuffer(data: ?*anyopaque, frame: ?*protocols.zwlr_screencopy_frame_v1, format: u32, width: u32, height: u32, stride: u32) callconv(.c) void {
        const self: *FrameCapture = @ptrCast(@alignCast(data));
        if (self.buffer != null or width == 0 or height == 0 or width > 16384 or height > 16384 or stride < width * 4 or @as(u64, stride) * height > 256 * 1024 * 1024 or
            (format != c.WL_SHM_FORMAT_ARGB8888 and format != c.WL_SHM_FORMAT_XRGB8888))
        {
            self.failed = true;
            return;
        }
        self.format = format;
        self.width = width;
        self.height = height;
        self.stride = stride;
        self.length = @as(usize, stride) * height;

        const fd = libc.memfd_create("desktop-screenshot", libc.MFD_CLOEXEC);
        if (fd < 0) {
            self.failed = true;
            return;
        }
        defer _ = libc.close(fd);

        if (libc.ftruncate(fd, @intCast(self.length)) != 0) {
            self.failed = true;
            return;
        }
        const mem = libc.mmap(null, self.length, libc.PROT_READ | libc.PROT_WRITE, libc.MAP_SHARED, fd, 0);
        if (mem == libc.MAP_FAILED or mem == null) {
            self.failed = true;
            return;
        }
        self.memory = @ptrCast(mem);

        const pool = c.wl_shm_create_pool(self.shm, fd, @intCast(self.length));
        self.buffer = c.wl_shm_pool_create_buffer(pool, 0, @intCast(width), @intCast(height), @intCast(stride), format);
        c.wl_shm_pool_destroy(pool);

        if (protocols.zwlr_screencopy_frame_v1_get_version(frame) < 3) {
            protocols.zwlr_screencopy_frame_v1_copy(frame, self.buffer);
        }
    }

    fn onBufferDone(data: ?*anyopaque, frame: ?*protocols.zwlr_screencopy_frame_v1) callconv(.c) void {
        const self: *FrameCapture = @ptrCast(@alignCast(data));
        if (self.failed) return;
        if (self.buffer == null) {
            self.failed = true;
            return;
        }
        protocols.zwlr_screencopy_frame_v1_copy(frame, self.buffer);
    }

    fn onLinuxDmabuf(_: ?*anyopaque, _: ?*protocols.zwlr_screencopy_frame_v1, _: u32, _: u32, _: u32) callconv(.c) void {}
    fn onDamage(_: ?*anyopaque, _: ?*protocols.zwlr_screencopy_frame_v1, _: u32, _: u32, _: u32, _: u32) callconv(.c) void {}

    fn onFlags(data: ?*anyopaque, _: ?*protocols.zwlr_screencopy_frame_v1, flags: u32) callconv(.c) void {
        const self: *FrameCapture = @ptrCast(@alignCast(data));
        self.y_invert = (flags & protocols.ZWLR_SCREENCOPY_FRAME_V1_FLAGS_Y_INVERT) != 0;
    }

    fn onReady(data: ?*anyopaque, _: ?*protocols.zwlr_screencopy_frame_v1, _: u32, _: u32, _: u32) callconv(.c) void {
        const self: *FrameCapture = @ptrCast(@alignCast(data));
        self.done = true;
    }

    fn onFailed(data: ?*anyopaque, _: ?*protocols.zwlr_screencopy_frame_v1) callconv(.c) void {
        const self: *FrameCapture = @ptrCast(@alignCast(data));
        self.failed = true;
    }

    pub const listener = protocols.zwlr_screencopy_frame_v1_listener{
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
    const allocator = std.heap.page_allocator;
    pub const Result = struct {
        rect: Rect,
        output_name: [64:0]u8,
        origin_x: i32,
        origin_y: i32,
        fn globalRect(self: Result) ?Rect {
            var rect = self.rect;
            rect.x = std.math.add(i32, rect.x, self.origin_x) catch return null;
            rect.y = std.math.add(i32, rect.y, self.origin_y) catch return null;
            return rect;
        }
    };
    const Layer = struct {
        owner: *SelectionOverlay,
        surface: *native.Surface,
        fn create(owner: *SelectionOverlay, output: *native.Output) !*Layer {
            const self = try allocator.create(Layer);
            errdefer allocator.destroy(self);
            self.* = .{ .owner = owner, .surface = try native.Surface.create(output, .{
                .namespace = "desktop-selection",
                .layer = 3,
                .anchors = native.top | native.bottom | native.left | native.right,
                .interactive = true,
                .keyboard = .exclusive,
            }, &paint, self) };
            errdefer self.surface.destroy();
            self.surface.input = .{ .motion = &motion, .button = &button, .key = &key };
            try self.surface.show();
            return self;
        }
        fn destroy(self: *Layer) void {
            self.surface.destroy();
            allocator.destroy(self);
        }
        fn paint(data: ?*anyopaque, cr: *c.cairo_t, width: f64, height: f64) void {
            const self = cast(Layer, data);
            self.owner.draw(self, cr, width, height);
        }
        fn motion(data: ?*anyopaque, _: *native.Surface, x: f64, y: f64) void {
            const self = cast(Layer, data);
            if (self.owner.done or !self.owner.dragging or self.owner.active != self) return;
            self.owner.current_x = x;
            self.owner.current_y = y;
            self.surface.redraw();
        }
        fn button(data: ?*anyopaque, _: *native.Surface, code: u32, pressed: bool, x: f64, y: f64) void {
            if (code != 272) return; // BTN_LEFT, independent of keyboard layout.
            const self = cast(Layer, data);
            const owner = self.owner;
            if (owner.done) return;
            if (pressed) {
                if (owner.dragging) return;
                owner.active = self;
                owner.start_x = x;
                owner.start_y = y;
                owner.current_x = x;
                owner.current_y = y;
                owner.dragging = true;
                self.surface.redraw();
            } else if (owner.dragging and owner.active == self) {
                owner.current_x = x;
                owner.current_y = y;
                const rect = owner.rectangle(self.surface.width, self.surface.height);
                if (rect.w > 4 and rect.h > 4) owner.selected = .{
                    .rect = rect,
                    .output_name = self.surface.output.label,
                    .origin_x = self.surface.output.x,
                    .origin_y = self.surface.output.y,
                };
                owner.dragging = false;
                owner.done = true;
            }
        }
        fn key(data: ?*anyopaque, _: *native.Surface, code: u32, pressed: bool) void {
            if (code != 1 or !pressed) return; // KEY_ESC.
            const owner = cast(Layer, data).owner;
            if (owner.done) return;
            owner.dragging = false;
            owner.selected = null;
            owner.done = true;
        }
    };
    layers: std.ArrayList(*Layer) = .empty,
    requested: ?[]const u8 = null,
    active: ?*Layer = null,
    start_x: f64 = 0,
    start_y: f64 = 0,
    current_x: f64 = 0,
    current_y: f64 = 0,
    dragging: bool = false,
    selected: ?Result = null,
    done: bool = false,

    pub fn run() ?Rect {
        const result = runForOutput(null) orelse return null;
        return result.globalRect();
    }
    pub fn runForOutput(requested: ?[]const u8) ?Result {
        var self: SelectionOverlay = .{ .requested = requested };
        const client = native.Client.createInteractive(.{ .added = &added, .removed = &removed }, &self) catch |err| {
            std.log.err("screenshot selection: {s}", .{@errorName(err)});
            return null;
        };
        defer client.destroy();
        defer {
            self.done = true;
            while (self.layers.pop()) |layer| layer.destroy();
            self.layers.deinit(allocator);
            self.layers = .empty;
            // Ensure overlays are gone before a new connection captures pixels.
            if (!client.failed) _ = c.wl_display_roundtrip(client.display);
        }
        client.start() catch return null;
        while (!self.done and !client.failed and client.hasInput() and self.hasLayers()) _ = c.g_main_context_iteration(null, 1);
        return self.selected;
    }
    fn hasLayers(self: *SelectionOverlay) bool {
        for (self.layers.items) |layer| if (layer.surface.role != null) return true;
        return false;
    }
    fn added(data: ?*anyopaque, output: *native.Output) void {
        const self = cast(SelectionOverlay, data);
        if (self.done) return;
        if (self.requested) |name| if (!std.mem.eql(u8, name, std.mem.sliceTo(&output.label, 0))) return;
        const layer = Layer.create(self, output) catch |err| {
            std.log.err("screenshot selection: {s}", .{@errorName(err)});
            self.done = true;
            return;
        };
        self.layers.append(allocator, layer) catch @panic("out of memory");
    }
    fn removed(data: ?*anyopaque, output: *native.Output) void {
        const self = cast(SelectionOverlay, data);
        for (self.layers.items, 0..) |layer, i| if (layer.surface.output == output) {
            if (self.active == layer) {
                self.active = null;
                self.selected = null;
                self.done = true;
            }
            _ = self.layers.orderedRemove(i);
            layer.destroy();
            return;
        };
    }
    fn rectangle(self: *const SelectionOverlay, width: u32, height: u32) Rect {
        const max_x: f64 = @floatFromInt(@min(width, 16384));
        const max_y: f64 = @floatFromInt(@min(height, 16384));
        const x1 = std.math.clamp(self.start_x, 0, max_x);
        const x2 = std.math.clamp(self.current_x, 0, max_x);
        const y1 = std.math.clamp(self.start_y, 0, max_y);
        const y2 = std.math.clamp(self.current_y, 0, max_y);
        return .{ .x = @intFromFloat(@min(x1, x2)), .y = @intFromFloat(@min(y1, y2)), .w = @intFromFloat(@abs(x2 - x1)), .h = @intFromFloat(@abs(y2 - y1)) };
    }
    fn draw(self: *SelectionOverlay, layer: *Layer, cr: *c.cairo_t, width: f64, height: f64) void {
        c.cairo_set_source_rgba(cr, 0, 0, 0, 0.35);
        c.cairo_paint(cr);
        if (!self.dragging or self.active != layer) return;
        const rect = self.rectangle(@intFromFloat(width), @intFromFloat(height));
        if (rect.w <= 1 or rect.h <= 1) return;
        const rx: f64 = @floatFromInt(rect.x);
        const ry: f64 = @floatFromInt(rect.y);
        const rw: f64 = @floatFromInt(rect.w);
        const rh: f64 = @floatFromInt(rect.h);
        c.cairo_save(cr);
        c.cairo_set_operator(cr, c.CAIRO_OPERATOR_CLEAR);
        c.cairo_rectangle(cr, rx, ry, rw, rh);
        c.cairo_fill(cr);
        c.cairo_restore(cr);
        c.cairo_set_source_rgb(cr, 0.208, 0.518, 0.894);
        c.cairo_set_line_width(cr, 2);
        c.cairo_rectangle(cr, rx, ry, rw, rh);
        c.cairo_stroke(cr);
        var buf: [64:0]u8 = undefined;
        const label = std.fmt.bufPrintSentinel(&buf, "{d} × {d}", .{ rect.w, rect.h }, 0) catch return;
        const label_x = @max(0, @min(rx, width - 90));
        const label_y = @max(0, @min(ry + rh + 6, height - 22));
        c.cairo_set_source_rgba(cr, 0.1, 0.1, 0.1, 0.85);
        c.cairo_rectangle(cr, label_x, label_y, 90, 22);
        c.cairo_fill(cr);
        c.cairo_set_source_rgb(cr, 1, 1, 1);
        c.cairo_select_font_face(cr, "Adwaita Sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_BOLD);
        c.cairo_set_font_size(cr, 11);
        c.cairo_move_to(cr, label_x + 8, label_y + 15);
        c.cairo_show_text(cr, label.ptr);
    }
};

const ClipboardOffer = struct {
    png_data: []const u8,
    cancelled: bool = false,

    fn onSend(data: ?*anyopaque, _: ?*protocols.zwlr_data_control_source_v1, mime: [*c]const u8, fd: i32) callconv(.c) void {
        const self: *ClipboardOffer = @ptrCast(@alignCast(data));
        defer _ = libc.close(fd);
        const mime_str = std.mem.span(mime);
        if (std.mem.eql(u8, mime_str, "image/png") or std.mem.eql(u8, mime_str, "image/x-png")) {
            writeAll(fd, self.png_data) catch {};
        }
    }

    fn onCancelled(data: ?*anyopaque, _: ?*protocols.zwlr_data_control_source_v1) callconv(.c) void {
        const self: *ClipboardOffer = @ptrCast(@alignCast(data));
        self.cancelled = true;
    }

    const listener = protocols.zwlr_data_control_source_v1_listener{
        .send = &onSend,
        .cancelled = &onCancelled,
    };
};

pub fn copyToClipboard(client: *WaylandClient, png_data: []const u8) !void {
    const mgr = client.data_control_mgr orelse return error.NoDataControl;
    const seat = client.seat orelse return error.NoSeat;

    const source = protocols.zwlr_data_control_manager_v1_create_data_source(mgr) orelse return error.CreateSourceFailed;
    protocols.zwlr_data_control_source_v1_offer(source, "image/png");
    protocols.zwlr_data_control_source_v1_offer(source, "image/x-png");

    var offer = ClipboardOffer{ .png_data = png_data };
    _ = protocols.zwlr_data_control_source_v1_add_listener(source, &ClipboardOffer.listener, &offer);

    const device = protocols.zwlr_data_control_manager_v1_get_data_device(mgr, seat) orelse return error.GetDeviceFailed;
    protocols.zwlr_data_control_device_v1_set_selection(device, source);
    _ = c.wl_display_roundtrip(client.display);

    // Fork into background to serve clipboard paste requests until replaced
    const pid = libc.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid != 0) return; // Parent returns immediately

    // Background child daemon serves paste requests
    while (!offer.cancelled) {
        if (c.wl_display_dispatch(client.display) < 0) break;
    }
    protocols.zwlr_data_control_source_v1_destroy(source);
    protocols.zwlr_data_control_device_v1_destroy(device);
    std.process.exit(0);
}

pub fn captureAndWrite(options: Options, allocator: std.mem.Allocator) !void {
    var client: WaylandClient = undefined;
    try client.init(allocator);
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
        capture.frame = protocols.zwlr_screencopy_manager_v1_capture_output_region(screencopy_mgr, 1, target_output.wl_out, geom.x, geom.y, geom.w, geom.h) orelse return error.CaptureFailed;
    } else {
        capture.frame = protocols.zwlr_screencopy_manager_v1_capture_output(screencopy_mgr, 1, target_output.wl_out) orelse return error.CaptureFailed;
    }
    defer protocols.zwlr_screencopy_frame_v1_destroy(capture.frame);
    defer {
        if (capture.buffer) |buffer| c.wl_buffer_destroy(buffer);
        if (capture.memory) |memory| _ = libc.munmap(memory, capture.length);
    }

    _ = protocols.zwlr_screencopy_frame_v1_add_listener(capture.frame, &FrameCapture.listener, &capture);

    while (!capture.done and !capture.failed) {
        if (c.wl_display_dispatch(client.display) < 0) return error.DispatchFailed;
    }
    if (capture.failed or capture.memory == null) return error.CaptureFailed;

    const encoded = try png.encode(allocator, .{
        .pixels = capture.memory.?[0..capture.length],
        .width = capture.width,
        .height = capture.height,
        .stride = capture.stride,
        .y_invert = capture.y_invert,
    });
    defer allocator.free(encoded);

    if (options.file_path) |path| {
        if (std.mem.eql(u8, path, "-")) {
            try writeAll(libc.STDOUT_FILENO, encoded);
        } else {
            const zpath = try allocator.dupeSentinel(u8, path, 0);
            defer allocator.free(zpath);
            try writeFile(zpath, encoded);
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
        try writeFile(path, encoded);
        std.debug.print("Screenshot saved to {s}\n", .{path});
    }

    if (options.clipboard) {
        try copyToClipboard(&client, encoded);
    }
}

pub fn main(init: std.process.Init) void {
    const status = run(init) catch 1;
    if (status != 0) std.process.exit(status);
}

fn run(init: std.process.Init) !u8 {
    var arguments = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arguments.deinit();
    return runArgs(init, try init.minimal.args.toSlice(arguments.allocator()));
}
pub fn runArgs(init: std.process.Init, args: []const []const u8) !u8 {
    _ = init;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var opt = Options.parse(args);

    if (opt.slurp_mode) {
        if (SelectionOverlay.runForOutput(opt.output_name)) |selection| {
            const rect = selection.globalRect() orelse return 1;
            var buf: [64]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "{d},{d} {d}x{d}\n", .{ rect.x, rect.y, rect.w, rect.h }) catch return 1;
            _ = libc.write(libc.STDOUT_FILENO, text.ptr, text.len);
            return 0;
        } else {
            return 1;
        }
    }

    if (opt.interactive) {
        const selection = SelectionOverlay.runForOutput(opt.output_name) orelse return 0; // Cancelled.
        opt.geometry = selection.rect;
        opt.output_name = try arena.allocator().dupe(u8, std.mem.sliceTo(&selection.output_name, 0));
    }

    captureAndWrite(opt, arena.allocator()) catch |err| {
        std.debug.print("desktop-screenshot error: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

test "selection rectangles normalize reverse drags and clamp to one output" {
    var selection: SelectionOverlay = .{ .start_x = 400, .start_y = 270, .current_x = 100, .current_y = 90 };
    try std.testing.expectEqual(Rect{ .x = 100, .y = 90, .w = 300, .h = 180 }, selection.rectangle(1280, 720));
    selection.start_x = -30;
    selection.start_y = -50;
    selection.current_x = 2000;
    selection.current_y = 1000;
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 1280, .h = 720 }, selection.rectangle(1280, 720));
}

test "slurp returns global coordinates while screenshot regions remain output-local" {
    const selection: SelectionOverlay.Result = .{ .rect = .{ .x = 100, .y = 90, .w = 300, .h = 180 }, .output_name = @splat(0), .origin_x = -1280, .origin_y = 200 };
    try std.testing.expectEqual(Rect{ .x = -1180, .y = 290, .w = 300, .h = 180 }, selection.globalRect().?);
    try std.testing.expectEqual(@as(i32, 100), selection.rect.x);
}

test "Escape during a drag ignores queued pointer events" {
    var selection: SelectionOverlay = .{ .dragging = true };
    var surface: native.Surface = undefined;
    var layer: SelectionOverlay.Layer = .{ .owner = &selection, .surface = &surface };
    selection.active = &layer;
    SelectionOverlay.Layer.key(&layer, &surface, 1, true);
    SelectionOverlay.Layer.motion(&layer, &surface, 400, 270);
    SelectionOverlay.Layer.button(&layer, &surface, 272, false, 400, 270);
    try std.testing.expect(selection.done);
    try std.testing.expect(!selection.dragging);
    try std.testing.expect(selection.selected == null);
}
