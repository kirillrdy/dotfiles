//! Wayland screenshot tool with region selection and clipboard support.
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

fn writeAll(fd: c_int, bytes: []const u8) !void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const count = libc.write(fd, remaining.ptr, remaining.len);
        if (count < 0) {
            if (libc.__errno_location().* == @backingInt(std.c.E.INTR)) continue;
            return error.WriteFailed;
        }
        if (count == 0) return error.WriteFailed;
        remaining = remaining[@intCast(count)..];
    }
}

fn writePngFile(path: [*:0]const u8, bytes: []const u8) !void {
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
    configured: bool = false,
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

extern const wl_compositor_interface: c.wl_interface;
extern const wl_surface_interface: c.wl_interface;
extern const wl_pointer_interface: c.wl_interface;
extern const wl_keyboard_interface: c.wl_interface;

fn request(proxy: *c.wl_proxy, opcode: u32, interface: ?*const c.wl_interface, flags: u32, args: []const c.wl_argument) ?*c.wl_proxy {
    var arguments: [8]c.wl_argument = undefined;
    std.debug.assert(args.len <= arguments.len);
    @memcpy(arguments[0..args.len], args);
    return c.wl_proxy_marshal_array_flags(proxy, opcode, interface, c.wl_proxy_get_version(proxy), flags, if (args.len == 0) null else &arguments);
}

fn listen(proxy: anytype, listener: anytype, data: anytype) !void {
    if (c.wl_proxy_add_listener(@ptrCast(proxy), @ptrCast(@constCast(listener)), data) != 0) return error.WaylandListenerFailed;
}

pub const SelectionOverlay = struct {
    display: *c.wl_display,
    registry: *c.wl_registry,
    compositor: ?*c.wl_proxy = null,
    shm: ?*c.wl_shm = null,
    layer_shell: ?*c.wl_proxy = null,
    seat: ?*c.wl_seat = null,
    output: ?*c.wl_output = null,

    surface: ?*c.wl_proxy = null,
    layer_surface: ?*c.wl_proxy = null,
    pointer: ?*c.wl_proxy = null,
    keyboard: ?*c.wl_proxy = null,

    width: u32 = 0,
    height: u32 = 0,
    configured: bool = false,

    start_x: f64 = 0,
    start_y: f64 = 0,
    current_x: f64 = 0,
    current_y: f64 = 0,
    dragging: bool = false,
    selected: ?Rect = null,
    done: bool = false,

    buffer: ?*c.wl_buffer = null,
    buffer_memory: ?[*]u32 = null,
    buffer_size: usize = 0,

    pub fn run() ?Rect {
        const display = c.wl_display_connect(null) orelse return null;
        const registry = c.wl_display_get_registry(display) orelse {
            c.wl_display_disconnect(display);
            return null;
        };

        var overlay = SelectionOverlay{
            .display = display,
            .registry = registry,
        };
        defer overlay.deinit();

        _ = c.wl_registry_add_listener(registry, &registry_listener, &overlay);
        if (c.wl_display_roundtrip(display) < 0 or c.wl_display_roundtrip(display) < 0) return null;

        if (overlay.compositor == null or overlay.shm == null or overlay.layer_shell == null) return null;

        overlay.surface = request(overlay.compositor.?, 0, &wl_surface_interface, 0, &.{.{ .o = null }}) orelse return null;
        overlay.layer_surface = request(
            overlay.layer_shell.?,
            0,
            &protocols.zwlr_layer_surface_v1_interface,
            0,
            &.{
                .{ .o = null },
                .{ .o = @ptrCast(overlay.surface.?) },
                .{ .o = if (overlay.output) |out| @ptrCast(out) else null },
                .{ .u = 3 }, // overlay layer
                .{ .s = "selection" },
            },
        ) orelse return null;

        _ = listen(overlay.layer_surface.?, &layer_surface_listener, &overlay) catch return null;

        // Set size 0,0 for full anchor stretch
        _ = request(overlay.layer_surface.?, 0, null, 0, &.{ .{ .u = 0 }, .{ .u = 0 } });
        // Set anchors (top | bottom | left | right = 15)
        _ = request(overlay.layer_surface.?, 1, null, 0, &.{.{ .u = 15 }});
        // Set exclusive zone (-1)
        _ = request(overlay.layer_surface.?, 2, null, 0, &.{.{ .i = -1 }});
        // Set keyboard interactivity (1 = exclusive)
        _ = request(overlay.layer_surface.?, 4, null, 0, &.{.{ .u = 1 }});

        // Initial commit to wait for configure event
        _ = request(overlay.surface.?, 6, null, 0, &.{});
        if (c.wl_display_flush(display) < 0) return null;

        while (!overlay.done) {
            if (c.wl_display_dispatch(display) < 0) break;
        }

        return overlay.selected;
    }

    fn ensureBuffer(self: *SelectionOverlay) void {
        const size = @as(usize, self.width) * self.height * 4;
        if (self.buffer != null and self.buffer_size == size) return;
        if (self.buffer) |buf| c.wl_buffer_destroy(buf);
        if (self.buffer_memory) |mem| _ = libc.munmap(mem, self.buffer_size);
        self.buffer = null;
        self.buffer_memory = null;
        self.buffer_size = 0;

        const shm = self.shm orelse return;
        const fd = libc.memfd_create("selection-overlay", libc.MFD_CLOEXEC);
        if (fd < 0) return;
        defer _ = libc.close(fd);

        if (libc.ftruncate(fd, @intCast(size)) != 0) return;
        const mem = libc.mmap(null, size, libc.PROT_READ | libc.PROT_WRITE, libc.MAP_SHARED, fd, 0);
        if (mem == libc.MAP_FAILED or mem == null) return;

        const pool = c.wl_shm_create_pool(shm, fd, @intCast(size)) orelse return;
        self.buffer = c.wl_shm_pool_create_buffer(pool, 0, @intCast(self.width), @intCast(self.height), @intCast(self.width * 4), c.WL_SHM_FORMAT_ARGB8888);
        c.wl_shm_pool_destroy(pool);
        self.buffer_memory = @ptrCast(@alignCast(mem));
        self.buffer_size = size;
    }

    fn render(self: *SelectionOverlay) void {
        if (self.buffer_memory == null or self.surface == null or self.width == 0 or self.height == 0) return;
        const pixels = self.buffer_memory.?[0 .. @as(usize, self.width) * self.height];
        const bg: u32 = 0x59000000; // 35% alpha black premultiplied

        if (!self.dragging) {
            @memset(pixels, bg);
        } else {
            const rx_f = @min(self.start_x, self.current_x);
            const ry_f = @min(self.start_y, self.current_y);
            const rw_f = @abs(self.current_x - self.start_x);
            const rh_f = @abs(self.current_y - self.start_y);

            if (rw_f <= 1 or rh_f <= 1) {
                @memset(pixels, bg);
            } else {
                const rx: usize = @intCast(@max(0, @min(self.width, @as(u32, @intFromFloat(rx_f)))));
                const ry: usize = @intCast(@max(0, @min(self.height, @as(u32, @intFromFloat(ry_f)))));
                const rw: usize = @intCast(@min(self.width - rx, @as(u32, @intFromFloat(rw_f))));
                const rh: usize = @intCast(@min(self.height - ry, @as(u32, @intFromFloat(rh_f))));
                const border: u32 = 0xff3584e4; // RGB (53, 132, 228)

                for (0..self.height) |y| {
                    const row = pixels[y * self.width .. (y + 1) * self.width];
                    if (y >= ry and y < ry + rh) {
                        if (y < ry + 2 or y >= ry + rh - 2) {
                            for (row[0..rx]) |*p| p.* = bg;
                            for (row[rx .. rx + rw]) |*p| p.* = border;
                            for (row[rx + rw .. self.width]) |*p| p.* = bg;
                        } else {
                            for (row[0..rx]) |*p| p.* = bg;
                            const left_end = @min(rx + 2, rx + rw);
                            for (row[rx..left_end]) |*p| p.* = border;
                            const right_start = if (rw > 2) rx + rw - 2 else rx + rw;
                            if (right_start > left_end) {
                                for (row[left_end..right_start]) |*p| p.* = 0; // Cutout
                            }
                            for (row[right_start .. rx + rw]) |*p| p.* = border;
                            for (row[rx + rw .. self.width]) |*p| p.* = bg;
                        }
                    } else {
                        for (row) |*p| p.* = bg;
                    }
                }
            }
        }

        _ = request(self.surface.?, 1, null, 0, &.{ .{ .o = @ptrCast(self.buffer.?) }, .{ .i = 0 }, .{ .i = 0 } });
        _ = request(self.surface.?, 2, null, 0, &.{ .{ .i = 0 }, .{ .i = 0 }, .{ .i = @intCast(self.width) }, .{ .i = @intCast(self.height) } });
        _ = request(self.surface.?, 6, null, 0, &.{});
        _ = c.wl_display_flush(self.display);
    }

    fn deinit(self: *SelectionOverlay) void {
        if (self.buffer) |buf| c.wl_buffer_destroy(buf);
        if (self.buffer_memory) |mem| _ = libc.munmap(mem, self.buffer_size);
        if (self.pointer) |ptr| c.wl_proxy_destroy(ptr);
        if (self.keyboard) |kbd| c.wl_proxy_destroy(kbd);
        if (self.layer_surface) |ls| _ = request(ls, 7, null, 1, &.{});
        if (self.surface) |s| _ = request(s, 0, null, 1, &.{});
        if (self.layer_shell) |ls| c.wl_proxy_destroy(ls);
        if (self.compositor) |comp| c.wl_proxy_destroy(comp);
        if (self.output) |out| c.wl_output_destroy(out);
        if (self.seat) |seat| c.wl_seat_destroy(seat);
        if (self.shm) |shm| c.wl_shm_destroy(shm);
        c.wl_registry_destroy(self.registry);
        _ = c.wl_display_flush(self.display);
        c.wl_display_disconnect(self.display);
    }

    fn registryGlobal(data: ?*anyopaque, registry: ?*c.wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
        const self: *SelectionOverlay = @ptrCast(@alignCast(data));
        const iface = std.mem.span(interface);
        if (std.mem.eql(u8, iface, "wl_compositor")) {
            self.compositor = @ptrCast(c.wl_registry_bind(registry, name, &wl_compositor_interface, 1));
        } else if (std.mem.eql(u8, iface, "wl_shm")) {
            self.shm = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_shm_interface, 1));
        } else if (std.mem.eql(u8, iface, "zwlr_layer_shell_v1")) {
            self.layer_shell = @ptrCast(c.wl_registry_bind(registry, name, &protocols.zwlr_layer_shell_v1_interface, @min(version, 4)));
        } else if (std.mem.eql(u8, iface, "wl_seat")) {
            self.seat = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_seat_interface, 1));
            if (self.seat) |seat| {
                _ = listen(seat, &seat_listener, self) catch {};
            }
        } else if (std.mem.eql(u8, iface, "wl_output")) {
            if (self.output == null) {
                self.output = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_output_interface, 1));
            }
        }
    }
    fn registryRemove(_: ?*anyopaque, _: ?*c.wl_registry, _: u32) callconv(.c) void {}

    const registry_listener = c.wl_registry_listener{
        .global = &registryGlobal,
        .global_remove = &registryRemove,
    };

    fn seatCapabilities(data: ?*anyopaque, seat: ?*c.wl_proxy, caps: u32) callconv(.c) void {
        const self: *SelectionOverlay = @ptrCast(@alignCast(data));
        if ((caps & 1) != 0 and self.pointer == null) {
            self.pointer = request(seat.?, 0, &wl_pointer_interface, 0, &.{.{ .o = null }});
            if (self.pointer) |ptr| {
                _ = listen(ptr, &pointer_listener, self) catch {};
            }
        }
        if ((caps & 2) != 0 and self.keyboard == null) {
            self.keyboard = request(seat.?, 1, &wl_keyboard_interface, 0, &.{.{ .o = null }});
            if (self.keyboard) |kbd| {
                _ = listen(kbd, &keyboard_listener, self) catch {};
            }
        }
    }
    fn seatName(_: ?*anyopaque, _: ?*c.wl_proxy, _: [*c]const u8) callconv(.c) void {}

    const seat_listener = extern struct {
        capabilities: *const @TypeOf(seatCapabilities) = &seatCapabilities,
        name: *const @TypeOf(seatName) = &seatName,
    }{};

    fn layerConfigure(data: ?*anyopaque, layer: ?*c.wl_proxy, serial: u32, width: u32, height: u32) callconv(.c) void {
        const self: *SelectionOverlay = @ptrCast(@alignCast(data));
        _ = request(layer.?, 6, null, 0, &.{.{ .u = serial }});
        const next_w = if (width > 0) width else self.width;
        const next_h = if (height > 0) height else self.height;
        if (next_w > 0 and next_h > 0 and (!self.configured or self.width != next_w or self.height != next_h)) {
            self.configured = true;
            self.width = next_w;
            self.height = next_h;
            self.ensureBuffer();
            self.render();
        }
    }
    fn layerClosed(data: ?*anyopaque, _: ?*c.wl_proxy) callconv(.c) void {
        const self: *SelectionOverlay = @ptrCast(@alignCast(data));
        self.done = true;
    }

    const layer_surface_listener = extern struct {
        configure: *const @TypeOf(layerConfigure) = &layerConfigure,
        closed: *const @TypeOf(layerClosed) = &layerClosed,
    }{};

    fn pointerEnter(data: ?*anyopaque, _: ?*c.wl_proxy, _: u32, _: ?*c.wl_proxy, sx: i32, sy: i32) callconv(.c) void {
        const self: *SelectionOverlay = @ptrCast(@alignCast(data));
        self.current_x = @as(f64, @floatFromInt(sx)) / 256.0;
        self.current_y = @as(f64, @floatFromInt(sy)) / 256.0;
    }
    fn pointerLeave(_: ?*anyopaque, _: ?*c.wl_proxy, _: u32, _: ?*c.wl_proxy) callconv(.c) void {}
    fn pointerMotion(data: ?*anyopaque, _: ?*c.wl_proxy, _: u32, sx: i32, sy: i32) callconv(.c) void {
        const self: *SelectionOverlay = @ptrCast(@alignCast(data));
        self.current_x = @as(f64, @floatFromInt(sx)) / 256.0;
        self.current_y = @as(f64, @floatFromInt(sy)) / 256.0;
        if (self.dragging) self.render();
    }
    fn pointerButton(data: ?*anyopaque, _: ?*c.wl_proxy, _: u32, _: u32, button: u32, state: u32) callconv(.c) void {
        const self: *SelectionOverlay = @ptrCast(@alignCast(data));
        if (button == 272) {
            if (state == 1) {
                self.start_x = self.current_x;
                self.start_y = self.current_y;
                self.dragging = true;
                self.render();
            } else if (state == 0 and self.dragging) {
                self.dragging = false;
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
            }
        }
    }
    fn pointerAxis(_: ?*anyopaque, _: ?*c.wl_proxy, _: u32, _: u32, _: i32) callconv(.c) void {}
    fn pointerFrame(_: ?*anyopaque, _: ?*c.wl_proxy) callconv(.c) void {}
    fn pointerAxisSource(_: ?*anyopaque, _: ?*c.wl_proxy, _: u32) callconv(.c) void {}
    fn pointerAxisStop(_: ?*anyopaque, _: ?*c.wl_proxy, _: u32, _: u32) callconv(.c) void {}
    fn pointerAxisDiscrete(_: ?*anyopaque, _: ?*c.wl_proxy, _: u32, _: i32) callconv(.c) void {}

    const pointer_listener = extern struct {
        enter: ?*const fn (data: ?*anyopaque, wl_pointer: ?*c.wl_proxy, serial: u32, surface: ?*c.wl_proxy, surface_x: i32, surface_y: i32) callconv(.c) void = &pointerEnter,
        leave: ?*const fn (data: ?*anyopaque, wl_pointer: ?*c.wl_proxy, serial: u32, surface: ?*c.wl_proxy) callconv(.c) void = &pointerLeave,
        motion: ?*const fn (data: ?*anyopaque, wl_pointer: ?*c.wl_proxy, time: u32, surface_x: i32, surface_y: i32) callconv(.c) void = &pointerMotion,
        button: ?*const fn (data: ?*anyopaque, wl_pointer: ?*c.wl_proxy, serial: u32, time: u32, button: u32, state: u32) callconv(.c) void = &pointerButton,
        axis: ?*const fn (data: ?*anyopaque, wl_pointer: ?*c.wl_proxy, time: u32, axis: u32, value: i32) callconv(.c) void = &pointerAxis,
        frame: ?*const fn (data: ?*anyopaque, wl_pointer: ?*c.wl_proxy) callconv(.c) void = &pointerFrame,
        axis_source: ?*const fn (data: ?*anyopaque, wl_pointer: ?*c.wl_proxy, axis_source: u32) callconv(.c) void = &pointerAxisSource,
        axis_stop: ?*const fn (data: ?*anyopaque, wl_pointer: ?*c.wl_proxy, time: u32, axis: u32) callconv(.c) void = &pointerAxisStop,
        axis_discrete: ?*const fn (data: ?*anyopaque, wl_pointer: ?*c.wl_proxy, axis: u32, discrete: i32) callconv(.c) void = &pointerAxisDiscrete,
        axis_value120: ?*const fn (data: ?*anyopaque, wl_pointer: ?*c.wl_proxy, axis: u32, value120: i32) callconv(.c) void = null,
        axis_relative_direction: ?*const fn (data: ?*anyopaque, wl_pointer: ?*c.wl_proxy, axis: u32, direction: u32) callconv(.c) void = null,
        warp: ?*const fn (data: ?*anyopaque, wl_pointer: ?*c.wl_proxy, surface_x: i32, surface_y: i32) callconv(.c) void = null,
    }{};

    fn keyboardKeymap(_: ?*anyopaque, _: ?*c.wl_proxy, _: u32, fd: c_int, _: u32) callconv(.c) void {
        if (fd >= 0) _ = libc.close(fd);
    }
    fn keyboardEnter(_: ?*anyopaque, _: ?*c.wl_proxy, _: u32, _: ?*c.wl_proxy, _: ?*c.wl_array) callconv(.c) void {}
    fn keyboardLeave(_: ?*anyopaque, _: ?*c.wl_proxy, _: u32, _: ?*c.wl_proxy) callconv(.c) void {}
    fn keyboardKey(data: ?*anyopaque, _: ?*c.wl_proxy, _: u32, _: u32, code: u32, pressed: u32) callconv(.c) void {
        const self: *SelectionOverlay = @ptrCast(@alignCast(data));
        if (pressed != 0 and code == 1) { // KEY_ESC
            self.selected = null;
            self.done = true;
        }
    }
    fn keyboardModifiers(_: ?*anyopaque, _: ?*c.wl_proxy, _: u32, _: u32, _: u32, _: u32, _: u32) callconv(.c) void {}
    fn keyboardRepeatInfo(_: ?*anyopaque, _: ?*c.wl_proxy, _: i32, _: i32) callconv(.c) void {}

    const keyboard_listener = extern struct {
        keymap: ?*const fn (data: ?*anyopaque, wl_keyboard: ?*c.wl_proxy, format: u32, fd: i32, size: u32) callconv(.c) void = &keyboardKeymap,
        enter: ?*const fn (data: ?*anyopaque, wl_keyboard: ?*c.wl_proxy, serial: u32, surface: ?*c.wl_proxy, keys: ?*c.wl_array) callconv(.c) void = &keyboardEnter,
        leave: ?*const fn (data: ?*anyopaque, wl_keyboard: ?*c.wl_proxy, serial: u32, surface: ?*c.wl_proxy) callconv(.c) void = &keyboardLeave,
        key: ?*const fn (data: ?*anyopaque, wl_keyboard: ?*c.wl_proxy, serial: u32, time: u32, key: u32, state: u32) callconv(.c) void = &keyboardKey,
        modifiers: ?*const fn (data: ?*anyopaque, wl_keyboard: ?*c.wl_proxy, serial: u32, mods_depressed: u32, mods_latched: u32, mods_locked: u32, group: u32) callconv(.c) void = &keyboardModifiers,
        repeat_info: ?*const fn (data: ?*anyopaque, wl_keyboard: ?*c.wl_proxy, rate: i32, delay: i32) callconv(.c) void = &keyboardRepeatInfo,
    }{};
};

const ClipboardOffer = struct {
    png_data: []const u8,
    cancelled: bool = false,

    fn onSend(data: ?*anyopaque, _: ?*protocols.zwlr_data_control_source_v1, mime: [*c]const u8, fd: i32) callconv(.c) void {
        const self: *ClipboardOffer = @ptrCast(@alignCast(data));
        defer _ = libc.close(fd);
        const mime_str = std.mem.span(mime);
        if (std.mem.eql(u8, mime_str, "image/png") or std.mem.eql(u8, mime_str, "image/x-png")) {
            _ = libc.write(fd, self.png_data.ptr, self.png_data.len);
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

    const bytes = try png.encode(allocator, .{
        .pixels = capture.memory.?[0..capture.length],
        .width = capture.width,
        .height = capture.height,
        .stride = capture.stride,
        .alpha = capture.format == c.WL_SHM_FORMAT_ARGB8888,
        .y_invert = capture.y_invert,
    });
    defer allocator.free(bytes);

    if (options.file_path) |path| {
        if (std.mem.eql(u8, path, "-")) {
            try writeAll(libc.STDOUT_FILENO, bytes);
        } else {
            const zpath = try allocator.dupeSentinel(u8, path, 0);
            defer allocator.free(zpath);
            try writePngFile(zpath, bytes);
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
        try writePngFile(path, bytes);
        std.debug.print("Screenshot saved to {s}\n", .{path});
    }

    if (options.clipboard) {
        try copyToClipboard(&client, bytes);
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
        if (SelectionOverlay.run()) |rect| {
            var buf: [64]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "{d},{d} {d}x{d}\n", .{ rect.x, rect.y, rect.w, rect.h }) catch return 1;
            _ = libc.write(libc.STDOUT_FILENO, text.ptr, text.len);
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
