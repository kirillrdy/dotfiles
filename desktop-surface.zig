//! Native, input-transparent layer surfaces, one per output. The caller owns
//! event-loop integration and painting; this module owns Wayland and SHM state.
const std = @import("std");
const c = @import("desktop-gtk.zig");
const libc = @import("desktop-libc.zig");
const p = @import("desktop-protocols.zig");
const a = std.heap.page_allocator;
const Proxy = c.wl_proxy;
const cast = c.__zig.cast;
extern const wl_compositor_interface: c.wl_interface;
extern const wl_surface_interface: c.wl_interface;
extern const wl_region_interface: c.wl_interface;

fn request(proxy: *Proxy, opcode: u32, interface: ?*const c.wl_interface, flags: u32, args: []const c.wl_argument) ?*Proxy {
    // libwayland writes the allocated object ID back into constructor arguments.
    // Call sites may pass constant literals, so always marshal a writable copy.
    var arguments: [8]c.wl_argument = undefined;
    std.debug.assert(args.len <= arguments.len);
    @memcpy(arguments[0..args.len], args);
    return c.wl_proxy_marshal_array_flags(proxy, opcode, interface, c.wl_proxy_get_version(proxy), flags, if (args.len == 0) null else &arguments);
}
fn listen(proxy: anytype, listener: anytype, data: anytype) !void {
    if (c.wl_proxy_add_listener(@ptrCast(proxy), @ptrCast(@constCast(listener)), data) != 0) return error.WaylandListenerFailed;
}

pub const Layout = struct {
    width: i32,
    height: i32,
    stride: i32,
    size: usize,

    pub fn init(width: u32, height: u32, scale: i32) !Layout {
        if (width == 0 or height == 0 or scale < 1) return error.InvalidSurfaceSize;
        const w = @as(u64, width) * @as(u32, @intCast(scale));
        const h = @as(u64, height) * @as(u32, @intCast(scale));
        if (w > 16384 or h > 16384 or w * h > 32 * 1024 * 1024) return error.SurfaceTooLarge;
        return .{ .width = @intCast(w), .height = @intCast(h), .stride = @intCast(w * 4), .size = @intCast(w * h * 4) };
    }
};

pub const Frame = struct {
    pixels: [*]u8,
    layout: Layout,
    width: u32,
    height: u32,
    scale: i32,
};
pub const Options = struct {
    namespace: [:0]const u8,
    layer: enum(u32) { background, bottom, top, overlay } = .background,
    // Zero dimensions with all anchors let the compositor choose output size.
    width: u32 = 0,
    height: u32 = 0,
    anchors: u32 = 15,
    exclusive_zone: i32 = -1,
    format: enum { xrgb, argb } = .xrgb,
    initially_visible: bool = true,
    bottom_margin_percent: u8 = 0,
};

const Buffer = struct {
    output: *Output,
    proxy: *c.wl_buffer,
    memory: *anyopaque,
    layout: Layout,
    busy: bool = false,

    fn create(output: *Output, layout: Layout) !*Buffer {
        const fd = libc.memfd_create("desktop-surface", libc.MFD_CLOEXEC);
        if (fd < 0) return error.SharedMemoryFailed;
        defer _ = libc.close(fd);
        if (libc.ftruncate(fd, @intCast(layout.size)) != 0) return error.SharedMemoryFailed;
        const memory = libc.mmap(null, layout.size, libc.PROT_READ | libc.PROT_WRITE, libc.MAP_SHARED, fd, 0);
        if (memory == null or memory == libc.MAP_FAILED) return error.SharedMemoryFailed;
        errdefer _ = libc.munmap(memory, layout.size);
        const pool = c.wl_shm_create_pool(output.client.shm, fd, @intCast(layout.size)) orelse return error.SharedMemoryFailed;
        defer c.wl_shm_pool_destroy(pool);
        const format: u32 = if (output.client.options.format == .argb) c.WL_SHM_FORMAT_ARGB8888 else c.WL_SHM_FORMAT_XRGB8888;
        const proxy = c.wl_shm_pool_create_buffer(pool, 0, layout.width, layout.height, layout.stride, format) orelse return error.SharedMemoryFailed;
        errdefer c.wl_buffer_destroy(proxy);
        const self = try a.create(Buffer);
        errdefer a.destroy(self);
        self.* = .{ .output = output, .proxy = proxy, .memory = memory.?, .layout = layout };
        try listen(proxy, &buffer_listener, self);
        return self;
    }
    fn destroy(self: *Buffer) void {
        // Destroying a wl_buffer does not invalidate the compositor's mapping
        // of its pool; the server owns its received file descriptor.
        c.wl_buffer_destroy(self.proxy);
        _ = libc.munmap(self.memory, self.layout.size);
        a.destroy(self);
    }
    fn release(data: ?*anyopaque, _: ?*c.wl_buffer) callconv(.c) void {
        const self = cast(Buffer, data);
        const output = self.output;
        self.busy = false;
        output.render() catch |err| {
            output.client.failure = err;
        };
    }
};
const buffer_listener = extern struct { release: *const @TypeOf(Buffer.release) = Buffer.release }{};

const Output = struct {
    client: *Client,
    name: u32,
    proxy: *c.wl_output,
    info: ?*Proxy = null,
    surface: ?*Proxy = null,
    layer: ?*Proxy = null,
    width: u32 = 0,
    height: u32 = 0,
    scale: i32 = 1,
    pending_scale: i32 = 1,
    dirty: bool = false,
    closed: bool = false,
    physical_width: i32 = 0,
    physical_height: i32 = 0,
    transform: i32 = 0,
    logical_height: i32 = 0,
    pending_logical_height: i32 = 0,
    margin: i32 = -1,
    buffers: [2]?*Buffer = .{ null, null },

    fn open(self: *Output) !void {
        if (self.surface != null or self.closed or !self.client.visible) return;
        const client = self.client;
        self.surface = request(client.compositor.?, 0, &wl_surface_interface, 0, &.{.{ .o = null }}) orelse return error.SurfaceUnavailable;
        try listen(self.surface.?, &surface_listener, self);
        self.layer = request(client.shell.?, 0, &p.zwlr_layer_surface_v1_interface, 0, &.{ .{ .o = null }, .{ .o = @ptrCast(self.surface.?) }, .{ .o = @ptrCast(self.proxy) }, .{ .u = @backingInt(client.options.layer) }, .{ .s = client.options.namespace } }) orelse return error.LayerSurfaceUnavailable;
        try listen(self.layer.?, &layer_listener, self);
        const region = request(client.compositor.?, 1, &wl_region_interface, 0, &.{.{ .o = null }}) orelse return error.RegionUnavailable;
        _ = request(self.surface.?, 5, null, 0, &.{.{ .o = @ptrCast(region) }});
        _ = request(region, 0, null, 1, &.{});
        _ = request(self.layer.?, 0, null, 0, &.{ .{ .u = client.options.width }, .{ .u = client.options.height } });
        _ = request(self.layer.?, 1, null, 0, &.{.{ .u = client.options.anchors }});
        _ = request(self.layer.?, 2, null, 0, &.{.{ .i = client.options.exclusive_zone }});
        _ = request(self.layer.?, 4, null, 0, &.{.{ .u = 0 }});
        self.updateMargin(false);
        // Initial commit must have no buffer; wait for and acknowledge configure.
        _ = request(self.surface.?, 6, null, 0, &.{});
    }

    fn render(self: *Output) !void {
        if (!self.dirty or self.closed or self.width == 0 or self.height == 0) return;
        const layout = try Layout.init(self.width, self.height, self.scale);
        // At most two buffers per output. Coalesce configure/scale events while
        // both are in flight, and repaint the latest state on the next release.
        var slot: ?usize = null;
        for (self.buffers, 0..) |item, i| {
            if (item) |buffer| {
                if (!buffer.busy) {
                    slot = i;
                    break;
                }
            } else {
                slot = i;
                break;
            }
        }
        const index = slot orelse return;
        if (self.buffers[index]) |buffer| {
            if (!std.meta.eql(buffer.layout, layout)) {
                buffer.destroy();
                self.buffers[index] = null;
            }
        }
        if (self.buffers[index] == null) self.buffers[index] = try Buffer.create(self, layout);
        const buffer = self.buffers[index].?;
        try self.client.paint(self.client.context, .{ .pixels = @ptrCast(buffer.memory), .layout = layout, .width = self.width, .height = self.height, .scale = self.scale });
        _ = request(self.surface.?, 8, null, 0, &.{.{ .i = self.scale }});
        _ = request(self.surface.?, 1, null, 0, &.{ .{ .o = @ptrCast(buffer.proxy) }, .{ .i = 0 }, .{ .i = 0 } });
        _ = request(self.surface.?, 2, null, 0, &.{ .{ .i = 0 }, .{ .i = 0 }, .{ .i = @intCast(self.width) }, .{ .i = @intCast(self.height) } });
        _ = request(self.surface.?, 6, null, 0, &.{});
        buffer.busy = true;
        self.dirty = false;
    }
    fn configure(data: ?*anyopaque, layer: ?*Proxy, serial: u32, width: u32, height: u32) callconv(.c) void {
        const self = cast(Output, data);
        _ = request(layer.?, 6, null, 0, &.{.{ .u = serial }});
        const next_width = if (width != 0) width else self.client.options.width;
        const next_height = if (height != 0) height else self.client.options.height;
        // Some compositors configure after every commit. Acknowledge unchanged
        // sizes without committing again, otherwise the two sides form a loop.
        self.dirty = self.dirty or self.width != next_width or self.height != next_height;
        self.width = next_width;
        self.height = next_height;
        self.render() catch |err| {
            self.client.failure = err;
        };
    }
    fn unmap(self: *Output) void {
        if (self.layer) |proxy| _ = request(proxy, 7, null, 1, &.{});
        if (self.surface) |proxy| _ = request(proxy, 0, null, 1, &.{});
        self.layer = null;
        self.surface = null;
        self.width = 0;
        self.height = 0;
        self.margin = -1;
        self.dirty = false;
        for (&self.buffers) |*item| {
            if (item.*) |buffer| buffer.destroy();
            item.* = null;
        }
    }
    fn closedEvent(data: ?*anyopaque, _: ?*Proxy) callconv(.c) void {
        const self = cast(Output, data);
        self.closed = true;
        self.unmap();
    }
    fn destroy(self: *Output) void {
        self.unmap();
        if (self.info) |info| _ = request(info, 0, null, 1, &.{});
        releaseOutput(self.proxy);
        a.destroy(self);
    }
    fn geometry(data: ?*anyopaque, _: ?*c.wl_output, _: i32, _: i32, _: i32, _: i32, _: i32, _: [*c]const u8, _: [*c]const u8, transform: i32) callconv(.c) void {
        cast(Output, data).transform = transform;
    }
    fn entered(_: ?*anyopaque, _: ?*Proxy, _: ?*c.wl_output) callconv(.c) void {}
    fn mode(data: ?*anyopaque, _: ?*c.wl_output, flags: u32, width: i32, height: i32, _: i32) callconv(.c) void {
        if (flags & c.WL_OUTPUT_MODE_CURRENT == 0) return;
        const self = cast(Output, data);
        self.physical_width = width;
        self.physical_height = height;
    }
    fn scaleEvent(data: ?*anyopaque, _: ?*c.wl_output, scale: i32) callconv(.c) void {
        cast(Output, data).pending_scale = @max(1, scale);
    }
    fn done(data: ?*anyopaque, _: ?*c.wl_output) callconv(.c) void {
        const self = cast(Output, data);
        if (self.info == null) {
            self.logical_height = @divTrunc(if (self.transform & 1 != 0) self.physical_width else self.physical_height, self.pending_scale);
            self.updateMargin(true);
        }
        if (self.scale != self.pending_scale) {
            self.scale = self.pending_scale;
            self.dirty = self.surface != null;
        }
        self.render() catch |err| {
            self.client.failure = err;
        };
    }
    fn updateMargin(self: *Output, commit: bool) void {
        const layer = self.layer orelse return;
        const margin: i32 = @intCast(@divTrunc(@as(i64, @max(0, self.logical_height)) * self.client.options.bottom_margin_percent, 100));
        if (self.margin == margin) return;
        self.margin = margin;
        _ = request(layer, 3, null, 0, &.{ .{ .i = 0 }, .{ .i = 0 }, .{ .i = margin }, .{ .i = 0 } });
        if (commit) _ = request(self.surface.?, 6, null, 0, &.{});
    }
    fn attachInfo(self: *Output) !void {
        if (self.info != null or self.client.output_manager == null) return;
        self.info = request(self.client.output_manager.?, 1, &p.zxdg_output_v1_interface, 0, &.{ .{ .o = null }, .{ .o = @ptrCast(self.proxy) } }) orelse return error.OutputUnavailable;
        try listen(self.info.?, &info_listener, self);
    }
    fn logicalPosition(_: ?*anyopaque, _: ?*Proxy, _: i32, _: i32) callconv(.c) void {}
    fn logicalSize(data: ?*anyopaque, _: ?*Proxy, _: i32, height: i32) callconv(.c) void {
        cast(Output, data).pending_logical_height = height;
    }
    fn infoDone(data: ?*anyopaque, _: ?*Proxy) callconv(.c) void {
        const self = cast(Output, data);
        self.logical_height = self.pending_logical_height;
        self.updateMargin(true);
    }
    fn infoText(_: ?*anyopaque, _: ?*Proxy, _: [*:0]const u8) callconv(.c) void {}
};
const info_listener = extern struct {
    logical_position: *const @TypeOf(Output.logicalPosition) = Output.logicalPosition,
    logical_size: *const @TypeOf(Output.logicalSize) = Output.logicalSize,
    done: *const @TypeOf(Output.infoDone) = Output.infoDone,
    name: *const @TypeOf(Output.infoText) = Output.infoText,
    description: *const @TypeOf(Output.infoText) = Output.infoText,
}{};
const layer_listener = extern struct {
    configure: *const @TypeOf(Output.configure) = Output.configure,
    closed: *const @TypeOf(Output.closedEvent) = Output.closedEvent,
}{};
const output_listener = c.wl_output_listener{ .geometry = Output.geometry, .mode = Output.mode, .done = Output.done, .scale = Output.scaleEvent };
const surface_listener = extern struct {
    enter: *const @TypeOf(Output.entered) = Output.entered,
    leave: *const @TypeOf(Output.entered) = Output.entered,
}{};

fn releaseOutput(output: *c.wl_output) void {
    if (c.wl_proxy_get_version(@ptrCast(output)) >= 3) {
        _ = request(@ptrCast(output), 0, null, 1, &.{});
    } else c.wl_output_destroy(output);
}

pub const Client = struct {
    display: *c.wl_display,
    registry: *c.wl_registry,
    compositor: ?*Proxy = null,
    shell: ?*Proxy = null,
    shm: ?*c.wl_shm = null,
    output_manager: ?*Proxy = null,
    outputs: std.ArrayList(*Output) = .empty,
    options: Options,
    context: ?*anyopaque,
    paint: *const fn (?*anyopaque, Frame) anyerror!void,
    failure: ?anyerror = null,
    ready: bool = false,
    visible: bool,

    pub fn create(options: Options, context: ?*anyopaque, paint: *const fn (?*anyopaque, Frame) anyerror!void) !*Client {
        const display = c.wl_display_connect(null) orelse return error.WaylandUnavailable;
        errdefer c.wl_display_disconnect(display);
        const registry = c.wl_display_get_registry(display) orelse return error.WaylandRegistryUnavailable;
        const self = a.create(Client) catch |err| {
            c.wl_registry_destroy(registry);
            return err;
        };
        self.* = .{ .display = display, .registry = registry, .options = options, .context = context, .paint = paint, .visible = options.initially_visible };
        errdefer {
            self.deinit();
            a.destroy(self);
        }
        try listen(registry, &registry_listener, self);
        // Discover globals, then receive the initial output scale snapshots.
        if (c.wl_display_roundtrip(display) < 0 or c.wl_display_roundtrip(display) < 0) return error.WaylandDisconnected;
        if (self.failure) |err| return err;
        if (self.compositor == null or self.shell == null or self.shm == null) return error.LayerShellUnavailable;
        self.ready = true;
        for (self.outputs.items) |output| try output.open();
        return self;
    }
    fn deinit(self: *Client) void {
        for (self.outputs.items) |output| output.destroy();
        self.outputs.deinit(a);
        if (self.output_manager) |manager| _ = request(manager, 0, null, 1, &.{});
        if (self.shell) |shell| c.wl_proxy_destroy(shell); // Bound at v1.
        if (self.shm) |shm| c.wl_shm_destroy(shm);
        if (self.compositor) |compositor| c.wl_proxy_destroy(compositor);
        c.wl_registry_destroy(self.registry);
    }
    pub fn destroy(self: *Client) void {
        self.deinit();
        c.wl_display_disconnect(self.display);
        a.destroy(self);
    }
    pub fn dispatch(self: *Client) !void {
        if (c.wl_display_dispatch(self.display) < 0) return error.WaylandDisconnected;
        if (self.failure) |err| return err;
    }
    pub fn setVisible(self: *Client, visible: bool) !void {
        self.visible = visible;
        for (self.outputs.items) |output| {
            if (visible) try output.open() else output.unmap();
        }
    }
    pub fn invalidate(self: *Client) !void {
        if (self.failure) |err| return err;
        for (self.outputs.items) |output| {
            output.dirty = output.surface != null;
            try output.render();
        }
    }
    // False means the caller must watch for writability before retrying.
    pub fn flush(self: *Client) !bool {
        if (c.wl_display_flush(self.display) >= 0) return true;
        if (libc.__errno_location().* == @backingInt(std.c.E.AGAIN)) return false;
        return error.WaylandDisconnected;
    }
    fn global(data: ?*anyopaque, registry: ?*c.wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
        const self = cast(Client, data);
        self.bind(registry, name, std.mem.span(interface), version) catch |err| {
            self.failure = err;
        };
    }
    fn bind(self: *Client, registry: ?*c.wl_registry, name: u32, interface: []const u8, version: u32) !void {
        if (std.mem.eql(u8, interface, "wl_compositor") and self.compositor == null and version >= 3) {
            self.compositor = @ptrCast(c.wl_registry_bind(registry, name, &wl_compositor_interface, 3) orelse return error.SurfaceUnavailable);
        } else if (std.mem.eql(u8, interface, "wl_shm") and self.shm == null) {
            self.shm = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_shm_interface, 1) orelse return error.SharedMemoryFailed);
        } else if (std.mem.eql(u8, interface, "zwlr_layer_shell_v1") and self.shell == null) {
            self.shell = @ptrCast(c.wl_registry_bind(registry, name, &p.zwlr_layer_shell_v1_interface, 1) orelse return error.LayerShellUnavailable);
        } else if (std.mem.eql(u8, interface, "zxdg_output_manager_v1") and self.options.bottom_margin_percent != 0 and self.output_manager == null) {
            self.output_manager = @ptrCast(c.wl_registry_bind(registry, name, &p.zxdg_output_manager_v1_interface, @min(version, 2)) orelse return error.OutputUnavailable);
            for (self.outputs.items) |output| try output.attachInfo();
        } else if (std.mem.eql(u8, interface, "wl_output") and version >= 2) {
            const proxy: *c.wl_output = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_output_interface, @min(version, 3)) orelse return error.OutputUnavailable);
            const output = a.create(Output) catch |err| {
                releaseOutput(proxy);
                return err;
            };
            output.* = .{ .client = self, .name = name, .proxy = proxy };
            errdefer output.destroy();
            try listen(proxy, &output_listener, output);
            try output.attachInfo();
            if (self.ready) try output.open();
            try self.outputs.append(a, output);
        }
    }
    fn removed(data: ?*anyopaque, _: ?*c.wl_registry, name: u32) callconv(.c) void {
        const self = cast(Client, data);
        for (self.outputs.items, 0..) |output, i| {
            if (output.name != name) continue;
            _ = self.outputs.orderedRemove(i);
            output.destroy();
            break;
        }
    }
};
const registry_listener = c.wl_registry_listener{ .global = Client.global, .global_remove = Client.removed };

test "surface layout checks scaled allocation bounds before allocating" {
    const layout = try Layout.init(800, 600, 2);
    try std.testing.expectEqual(@as(i32, 1600), layout.width);
    try std.testing.expectEqual(@as(i32, 1200), layout.height);
    try std.testing.expectEqual(@as(i32, 6400), layout.stride);
    try std.testing.expectEqual(@as(usize, 7680000), layout.size);
    try std.testing.expectError(error.InvalidSurfaceSize, Layout.init(0, 1, 1));
    try std.testing.expectError(error.InvalidSurfaceSize, Layout.init(1, 1, 0));
    try std.testing.expectError(error.SurfaceTooLarge, Layout.init(std.math.maxInt(u32), std.math.maxInt(u32), std.math.maxInt(i32)));
    try std.testing.expectError(error.SurfaceTooLarge, Layout.init(8192, 8192, 1));
}
