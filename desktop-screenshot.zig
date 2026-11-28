//! Wayland screenshot tool with region selection and clipboard support.
const native = @import("desktop-surface.zig");
const std = @import("std");
pub const wl = @import("wayland-client");
const wire = @import("wayland-wire");
const helpers = @import("desktop-wayland-client.zig");
const libc = @import("desktop-libc.zig");
const mainloop = @import("desktop-loop.zig");
const util = @import("desktop-util.zig");
pub const png = @import("desktop-png.zig");
const raster = @import("desktop-raster.zig");
const fonts = @import("desktop-text.zig");

fn cast(comptime T: type, ptr: anytype) *T { return @ptrCast(@alignCast(ptr)); }

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

    pub fn between(start_x: f64, start_y: f64, current_x: f64, current_y: f64, width: u32, height: u32) Rect {
        const max_x: f64 = @floatFromInt(@min(width, 16384));
        const max_y: f64 = @floatFromInt(@min(height, 16384));
        const x1 = std.math.clamp(start_x, 0, max_x);
        const x2 = std.math.clamp(current_x, 0, max_x);
        const y1 = std.math.clamp(start_y, 0, max_y);
        const y2 = std.math.clamp(current_y, 0, max_y);
        return .{ .x = @intFromFloat(@min(x1, x2)), .y = @intFromFloat(@min(y1, y2)), .w = @intFromFloat(@abs(x2 - x1)), .h = @intFromFloat(@abs(y2 - y1)) };
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
    wl_out: wl.wl_output,
    global_name: u32 = 0,
    available: bool = true,
    name: [64:0]u8 = @splat(0),
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    scale: i32 = 1,

    fn outputEvent(out: *Output, _: wl.wl_output, event: wl.wl_output.Event) void {
        switch (event) {
            .geometry => |value| {
                out.x = value.x;
                out.y = value.y;
            },
            .mode => |value| if (value.flags & wl.wl_output.Mode.current != 0) {
                out.width = value.width;
                out.height = value.height;
            },
            .scale => |value| out.scale = value.factor,
            .name => |value| if (value.name.len < out.name.len) {
                @memcpy(out.name[0..value.name.len], value.name);
                out.name[value.name.len] = 0;
            },
            else => {},
        }
    }
};

pub const WaylandClient = struct {
    allocator: std.mem.Allocator,
    connection: *wire.Connection,
    registry: wl.wl_registry,
    shm: ?wl.wl_shm = null,
    screencopy_mgr: ?wl.zwlr_screencopy_manager_v1 = null,
    data_control_mgr: ?wl.zwlr_data_control_manager_v1 = null,
    seat: ?wl.wl_seat = null,
    outputs: std.ArrayList(Output) = .empty,

    /// Initialize in the final location: Wayland listeners retain this address.
    pub fn init(self: *WaylandClient, allocator: std.mem.Allocator) !void {
        const connection = wire.Connection.connect(allocator) catch return error.ConnectFailed;
        errdefer connection.deinit();
        const display: wl.wl_display = .{ .proxy = connection.display() };
        self.* = WaylandClient{
            .allocator = allocator,
            .connection = connection,
            .registry = display.get_registry(),
        };

        // Output listeners also need stable addresses while globals arrive.
        try self.outputs.ensureTotalCapacity(allocator, 64);
        errdefer self.outputs.deinit(allocator);
        self.registry.listen(WaylandClient, self, registryEvent);
        connection.roundtrip() catch return error.DispatchFailed;
        connection.roundtrip() catch return error.DispatchFailed;
    }

    pub fn deinit(self: *WaylandClient) void {
        for (self.outputs.items) |out| out.wl_out.destroy();
        self.outputs.deinit(self.allocator);
        if (self.screencopy_mgr) |mgr| mgr.destroy();
        if (self.data_control_mgr) |mgr| mgr.destroy();
        if (self.shm) |s| s.destroy();
        if (self.seat) |seat| seat.destroy();
        self.registry.destroy();
        self.connection.deinit();
    }

    /// Blocks for the next batch of events.
    pub fn dispatch(self: *WaylandClient) !void {
        self.connection.dispatch() catch return error.DispatchFailed;
    }

    fn registryEvent(self: *WaylandClient, registry: wl.wl_registry, event: wl.wl_registry.Event) void {
        switch (event) {
            .global => |value| {
                const name = value.name;
                const iface = value.interface;
                if (std.mem.eql(u8, iface, "wl_shm")) {
                    self.shm = registry.bind(name, wl.wl_shm, 1);
                } else if (std.mem.eql(u8, iface, "zwlr_screencopy_manager_v1")) {
                    self.screencopy_mgr = registry.bind(name, wl.zwlr_screencopy_manager_v1, @min(value.version, 3));
                } else if (std.mem.eql(u8, iface, "zwlr_data_control_manager_v1")) {
                    self.data_control_mgr = registry.bind(name, wl.zwlr_data_control_manager_v1, @min(value.version, 2));
                } else if (std.mem.eql(u8, iface, "wl_seat")) {
                    self.seat = registry.bind(name, wl.wl_seat, 1);
                } else if (std.mem.eql(u8, iface, "wl_output")) {
                    if (self.outputs.items.len == self.outputs.capacity) return;
                    const out = registry.bind(name, wl.wl_output, @min(value.version, 4));
                    self.outputs.appendAssumeCapacity(.{ .wl_out = out, .global_name = name });
                    const item = &self.outputs.items[self.outputs.items.len - 1];
                    out.listen(Output, item, Output.outputEvent);
                }
            },
            .global_remove => |value| for (self.outputs.items) |*output| if (output.global_name == value.name) {
                output.available = false;
            },
        }
    }
};

pub const FrameCapture = struct {
    shm: wl.wl_shm,
    frame: wl.zwlr_screencopy_frame_v1,
    format: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    stride: u32 = 0,
    buffer: ?wl.wl_buffer = null,
    memory: ?[*]u8 = null,
    length: usize = 0,
    done: bool = false,
    failed: bool = false,
    y_invert: bool = false,

    /// Starts receiving frame events; `self` must stay at this address.
    pub fn listen(self: *FrameCapture) void {
        self.frame.listen(FrameCapture, self, frameEvent);
    }

    /// Destroys the frame and releases any buffer it was copied into.
    pub fn deinit(self: *FrameCapture) void {
        self.frame.destroy();
        if (self.buffer) |buffer| buffer.destroy();
        if (self.memory) |memory| _ = libc.munmap(memory, self.length);
        self.buffer = null;
        self.memory = null;
    }

    fn frameEvent(self: *FrameCapture, frame: wl.zwlr_screencopy_frame_v1, event: wl.zwlr_screencopy_frame_v1.Event) void {
        switch (event) {
            .buffer => |value| self.onBuffer(frame, value.format, value.width, value.height, value.stride),
            .buffer_done => {
                if (self.failed) return;
                const buffer = self.buffer orelse {
                    self.failed = true;
                    return;
                };
                frame.copy(buffer);
            },
            .flags => |value| self.y_invert = (value.flags & wl.zwlr_screencopy_frame_v1.Flags.y_invert) != 0,
            .ready => self.onReady(),
            .failed => self.failed = true,
            else => {},
        }
    }

    fn onBuffer(self: *FrameCapture, frame: wl.zwlr_screencopy_frame_v1, format: u32, width: u32, height: u32, stride: u32) void {
        const formats = wl.wl_shm.Format;
        const packed_bgr = format == formats.bgr888;
        if (self.buffer != null or width == 0 or height == 0 or width > 16384 or height > 16384 or stride < width * @as(u32, if (packed_bgr) 3 else 4) or @as(u64, @max(stride, width * 4)) * height > 256 * 1024 * 1024 or
            (format != formats.argb8888 and format != formats.xrgb8888 and
                format != formats.abgr8888 and format != formats.xbgr8888 and !packed_bgr))
        {
            self.failed = true;
            return;
        }
        self.format = format;
        self.width = width;
        self.height = height;
        self.stride = stride;
        // Reserve room to expand packed GPU readback pixels after ready. The
        // compositor still receives its advertised format and source stride.
        self.length = @as(usize, @max(stride, width * 4)) * height;
        const shm = helpers.shmBufferLayout(self.shm, "desktop-screenshot", self.length, width, height, stride, format) catch {
            self.failed = true;
            return;
        };
        self.memory = shm.memory;
        self.buffer = shm.buffer;

        if (frame.version() < 3) frame.copy(shm.buffer);
    }

    /// Normalizes received pixels to XRGB/ARGB; runs on the ready event.
    pub fn onReady(self: *FrameCapture) void {
        const formats = wl.wl_shm.Format;
        // GPU renderers can offer XBGR/ABGR instead of XRGB/ARGB. Normalize
        // once here so PNG, clipboard, portal images and color picking agree.
        if (self.memory) |memory| {
            if (self.format == formats.bgr888) {
                const stride = @max(self.stride, self.width * 4);
                // Expand backwards so neither later rows nor unread pixels
                // are overwritten, including when source rows have padding.
                var y: usize = self.height;
                while (y > 0) {
                    y -= 1;
                    var x: usize = self.width;
                    while (x > 0) {
                        x -= 1;
                        const source = memory[y * self.stride + x * 3 ..][0..3];
                        // BGR888 stores R, G, B bytes in increasing addresses.
                        const value = @as(u32, source[0]) << 16 | @as(u32, source[1]) << 8 | source[2] | 0xff000000;
                        std.mem.writeInt(u32, memory[y * stride + x * 4 ..][0..4], value, @import("builtin").cpu.arch.endian());
                    }
                }
                self.stride = stride;
                self.format = formats.xrgb8888;
            } else if (self.format == formats.xbgr8888 or self.format == formats.abgr8888) {
                for (0..self.height) |y| for (0..self.width) |x| {
                    const pixel = memory[y * self.stride + x * 4 ..][0..4];
                    const value = std.mem.readInt(u32, pixel, @import("builtin").cpu.arch.endian());
                    const swapped = (value & 0xff00ff00) | ((value & 0xff) << 16) | ((value >> 16) & 0xff);
                    std.mem.writeInt(u32, pixel, swapped, @import("builtin").cpu.arch.endian());
                };
                self.format = if (self.format == formats.xbgr8888) formats.xrgb8888 else formats.argb8888;
            }
        }
        self.done = true;
    }
};

pub const SelectionOverlay = struct {
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
        renderer: fonts.Renderer = .{},
        label: ?fonts.Mask = null,
        label_size: [2]i32 = .{ 0, 0 },
        label_scale: u32 = 0,
        fn create(owner: *SelectionOverlay, output: *native.Output) !*Layer {
            const allocator = owner.allocator;
            const self = try allocator.create(Layer);
            errdefer allocator.destroy(self);
            self.* = .{ .owner = owner, .surface = try native.Surface.createPixels(output, .{
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
            if (self.label) |label| label.deinit(self.owner.allocator);
            self.renderer.deinit();
            self.surface.destroy();
            self.owner.allocator.destroy(self);
        }
        fn paint(data: ?*anyopaque, buffer: native.Pixels) void {
            const self = cast(Layer, data);
            self.owner.draw(self, buffer);
        }
        fn updateLabel(self: *Layer, rect: Rect) void {
            const scale = self.surface.output.scale;
            const size: [2]i32 = .{ rect.w, rect.h };
            if (std.mem.eql(i32, &self.label_size, &size) and self.label_scale == scale) return;
            var buffer: [64:0]u8 = undefined;
            const value = std.fmt.bufPrintSentinel(&buffer, "{d} × {d}", .{ rect.w, rect.h }, 0) catch return;
            const next = self.renderer.render(self.owner.allocator, "Adwaita Sans Bold", 11 * scale, value) catch |err| {
                std.log.warn("selection label: {s}", .{@errorName(err)});
                return;
            };
            if (self.label) |old| old.deinit(self.owner.allocator);
            self.label = next;
            self.label_size = size;
            self.label_scale = scale;
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
    allocator: std.mem.Allocator = undefined,
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

    pub fn run(allocator: std.mem.Allocator, io: std.Io) ?Rect {
        const result = runForOutput(allocator, io, null) orelse return null;
        return result.globalRect();
    }
    pub fn runForOutput(allocator: std.mem.Allocator, io: std.Io, requested: ?[]const u8) ?Result {
        var self: SelectionOverlay = .{ .allocator = allocator, .requested = requested };
        const client = native.Client.createInteractive(allocator, io, .{ .added = &added, .removed = &removed }, &self) catch |err| {
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
            client.roundtrip();
        }
        client.start() catch return null;
        while (!self.done and !client.failed and client.hasInput() and self.hasLayers()) _ = mainloop.iteration(io, true);
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
        self.layers.append(self.allocator, layer) catch @panic("out of memory");
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
        return Rect.between(self.start_x, self.start_y, self.current_x, self.current_y, width, height);
    }
    fn draw(self: *SelectionOverlay, layer: *Layer, buffer: native.Pixels) void {
        const selected = if (self.dragging and self.active == layer) self.rectangle(layer.surface.width, layer.surface.height) else null;
        if (selected) |rect| if (rect.w > 1 and rect.h > 1) layer.updateLabel(rect);
        paintSelection(buffer, layer.surface.output.scale, selected, layer.label);
    }
};

pub fn paintSelectionRegion(buffer: raster.Buffer, scale: u32, selected: ?Rect) void {
    @memset(buffer.pixels, 0x59000000); // 35% black, including inactive outputs.
    const rect = selected orelse return;
    if (rect.w <= 1 or rect.h <= 1) return;
    const factor: i32 = @intCast(scale);
    const x = rect.x * factor;
    const y = rect.y * factor;
    const w: u32 = @intCast(rect.w * factor);
    const h: u32 = @intCast(rect.h * factor);
    raster.fill(buffer, .{ .x = x, .y = y, .width = w, .height = h }, 0, .source);
    const blue: u32 = 0xff3584e4;
    const horizontal = w + 2 * scale;
    raster.fill(buffer, .{ .x = x - factor, .y = y - factor, .width = horizontal, .height = 2 * scale }, blue, .source);
    raster.fill(buffer, .{ .x = x - factor, .y = y + @as(i32, @intCast(h)) - factor, .width = horizontal, .height = 2 * scale }, blue, .source);
    raster.fill(buffer, .{ .x = x - factor, .y = y + factor, .width = 2 * scale, .height = h - 2 * scale }, blue, .source);
    raster.fill(buffer, .{ .x = x + @as(i32, @intCast(w)) - factor, .y = y + factor, .width = 2 * scale, .height = h - 2 * scale }, blue, .source);
}

fn paintSelection(buffer: raster.Buffer, scale: u32, selected: ?Rect, label: ?fonts.Mask) void {
    paintSelectionRegion(buffer, scale, selected);
    const rect = selected orelse return;
    if (rect.w <= 1 or rect.h <= 1) return;
    const factor: i32 = @intCast(scale);
    const width: i32 = @intCast(buffer.width / scale);
    const height: i32 = @intCast(buffer.height / scale);
    const label_x = @max(0, @min(rect.x, width - 90)) * factor;
    const label_y = @max(0, @min(rect.y + rect.h + 6, height - 22)) * factor;
    raster.fill(buffer, .{ .x = label_x, .y = label_y, .width = 90 * scale, .height = 22 * scale }, 0xd9161616, .over);
    if (label) |value| raster.mask(buffer, .{ .x = label_x + 8 * factor + value.left, .y = label_y + 15 * factor + value.top, .width = value.width, .height = value.height }, value.pixels, .{ .red = 1, .green = 1, .blue = 1 });
}

const ClipboardOffer = struct {
    png_data: []const u8,
    cancelled: bool = false,

    fn sourceEvent(self: *ClipboardOffer, _: wl.zwlr_data_control_source_v1, event: wl.zwlr_data_control_source_v1.Event) void {
        switch (event) {
            .send => |value| {
                defer _ = libc.close(value.fd);
                if (std.mem.eql(u8, value.mime_type, "image/png") or std.mem.eql(u8, value.mime_type, "image/x-png")) {
                    writeAll(value.fd, self.png_data) catch {};
                }
            },
            .cancelled => self.cancelled = true,
        }
    }
};

pub fn copyToClipboard(client: *WaylandClient, png_data: []const u8) !void {
    const mgr = client.data_control_mgr orelse return error.NoDataControl;
    const seat = client.seat orelse return error.NoSeat;

    const source = mgr.create_data_source();
    source.offer("image/png");
    source.offer("image/x-png");

    var offer = ClipboardOffer{ .png_data = png_data };
    source.listen(ClipboardOffer, &offer, ClipboardOffer.sourceEvent);

    const device = mgr.get_data_device(seat);
    device.set_selection(source);
    client.connection.roundtrip() catch return error.DispatchFailed;

    // Fork into background to serve clipboard paste requests until replaced
    const pid = libc.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid != 0) return; // Parent returns immediately

    // Background child daemon serves paste requests
    while (!offer.cancelled) client.dispatch() catch break;
    source.destroy();
    device.destroy();
    client.connection.flush() catch {};
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
        .frame = if (options.geometry) |geom|
            screencopy_mgr.capture_output_region(1, target_output.wl_out, geom.x, geom.y, geom.w, geom.h)
        else
            screencopy_mgr.capture_output(1, target_output.wl_out),
    };
    defer capture.deinit();
    capture.listen();

    while (!capture.done and !capture.failed) try client.dispatch();
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
        const files = @import("desktop-paths.zig");
        const directory = if (files.special(.pictures)) |pictures|
            try std.fmt.allocPrintSentinel(allocator, "{s}/Screenshots", .{pictures}, 0)
        else
            try std.fmt.allocPrintSentinel(allocator, "{s}/Pictures/Screenshots", .{files.home()}, 0);
        defer allocator.free(directory);
        try files.makeDirectories(directory, 0o755);
        const now = try @import("desktop-datetime.zig").DateTime.now();
        var stamp: [64]u8 = undefined;
        const timestamp = try now.format(&stamp, "%Y-%m-%d_%H-%M-%S_%f");
        const path = try std.fmt.allocPrintSentinel(allocator, "{s}/Screenshot_{s}.png", .{ directory, timestamp }, 0);
        defer allocator.free(path);
        try writeFile(path, encoded);
        std.debug.print("Screenshot saved to {s}\n", .{path});
    }

    if (options.clipboard) {
        try copyToClipboard(&client, encoded);
    }
}

pub fn runArgs(init: std.process.Init, args: []const []const u8) !u8 {
    var opt = Options.parse(args);
    // Clipboard mode keeps dispatching in the forked child. Its allocator
    // must work without locks inherited from other threads.
    var arena = std.heap.ArenaAllocator.init(if (opt.clipboard) std.heap.page_allocator else init.gpa);
    defer arena.deinit();

    if (opt.slurp_mode) {
        if (SelectionOverlay.runForOutput(init.gpa, init.io, opt.output_name)) |selection| {
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
        const selection = SelectionOverlay.runForOutput(init.gpa, init.io, opt.output_name) orelse return 0; // Cancelled.
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

test "native selection composites a cached text mask at the requested baseline" {
    const a = std.testing.allocator;
    var renderer: fonts.Renderer = .{};
    defer renderer.deinit();
    const label = try renderer.render(a, "Adwaita Sans Bold", 11, "70 × 40");
    defer label.deinit(a);
    var pixels: [140 * 100]u32 = undefined;
    const target: raster.Buffer = .{ .pixels = &pixels, .width = 140, .height = 100 };
    const rect: Rect = .{ .x = 10, .y = 15, .w = 70, .h = 40 };
    paintSelection(target, 1, rect, label);
    try std.testing.expectEqual(@as(u32, 0), pixels[30 * 140 + 30]);
    var ink: usize = 0;
    for (61..83) |y| for (10..100) |x| {
        if ((pixels[y * 140 + x] & 255) > 32) ink += 1;
    };
    try std.testing.expect(ink > 20);
}
