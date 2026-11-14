//! Native Wayland layer surfaces and application windows with SHM rendering.
//! Each client has a private connection, driven by GLib rather than GDK.
const std = @import("std");
const wayland = @import("desktop-wayland.zig");
const c = @import("desktop-gtk.zig");
const libc = @import("desktop-libc.zig");
const p = @import("desktop-protocols.zig");
const input = @import("desktop-input.zig");
const raster = @import("desktop-raster.zig");
const a = std.heap.page_allocator;
const Proxy = c.wl_proxy;
const cast = c.__zig.cast;

pub const top = 1;
pub const bottom = 2;
pub const left = 4;
pub const right = 8;

fn send(proxy: *Proxy, opcode: u32, args: anytype) void {
    _ = @call(.auto, c.wl_proxy_marshal_flags, .{ proxy, opcode, @as([*c]const c.wl_interface, null), c.wl_proxy_get_version(proxy), @as(u32, 0) } ++ args);
}
fn destroyProxy(proxy: *Proxy, opcode: u32) void {
    _ = c.wl_proxy_marshal_flags(proxy, opcode, null, c.wl_proxy_get_version(proxy), 1);
}
fn listen(proxy: anytype, listener: anytype, data: anytype) void {
    if (c.wl_proxy_add_listener(@ptrCast(proxy), @ptrCast(@constCast(listener)), data) != 0) @panic("Wayland listener allocation");
}
fn erase(comptime T: type, list: *std.ArrayList(T), value: T) void {
    for (list.items, 0..) |entry, i| if (entry == value) {
        _ = list.orderedRemove(i);
        return;
    };
}

pub const Callbacks = struct {
    added: *const fn (?*anyopaque, *Output) void,
    removed: *const fn (?*anyopaque, *Output) void,
    changed: ?*const fn (?*anyopaque, *Output) void = null,
};

pub const Client = struct {
    display: *c.wl_display,
    registry: *c.wl_registry,
    compositor: ?*Proxy = null,
    shm: ?*c.wl_shm = null,
    shell: ?*Proxy = null,
    wm_base: ?*Proxy = null,
    activation: ?*Proxy = null,
    clipboard_manager: ?*Proxy = null,
    importer: ?*Proxy = null,
    output_manager: ?*Proxy = null,
    text_manager: ?*Proxy = null,
    cursor_manager: ?*Proxy = null,
    outputs: std.ArrayList(*Output) = .empty,
    surfaces: std.ArrayList(*Surface) = .empty,
    buffers: std.ArrayList(*Buffer) = .empty,
    seats: std.ArrayList(*input.Seat) = .empty,
    input_enabled: bool = false,
    callbacks: Callbacks,
    data: ?*anyopaque,
    source: c.guint = 0,
    write_source: c.guint = 0,
    running: bool = false,
    failed: bool = false,

    pub fn create(callbacks: Callbacks, data: ?*anyopaque) !*Client {
        return createWithInput(callbacks, data, false);
    }
    pub fn createInteractive(callbacks: Callbacks, data: ?*anyopaque) !*Client {
        return createWithInput(callbacks, data, true);
    }
    fn createWithInput(callbacks: Callbacks, data: ?*anyopaque, enabled: bool) !*Client {
        const self = try a.create(Client);
        errdefer a.destroy(self);
        const display = c.wl_display_connect(null) orelse return error.WaylandConnection;
        const registry = c.wl_display_get_registry(display) orelse {
            c.wl_display_disconnect(display);
            return error.WaylandRegistry;
        };
        self.* = .{ .display = display, .registry = registry, .callbacks = callbacks, .data = data, .input_enabled = enabled };
        errdefer self.clear();
        _ = c.wl_registry_add_listener(registry, &registry_listener, self);
        if (c.wl_display_roundtrip(display) < 0) return error.WaylandDispatch;
        if (self.compositor == null or self.shm == null) return error.MissingWaylandGlobals;
        if (c.wl_proxy_get_version(self.compositor.?) < 3) return error.UnsupportedCompositor;
        // xdg-output can be advertised after wl_output. Bind it after discovery.
        for (self.outputs.items) |output| output.bindLogical();
        if (c.wl_display_roundtrip(display) < 0) return error.WaylandDispatch;
        return self;
    }
    pub fn start(self: *Client) !void {
        self.source = c.g_unix_fd_add(c.wl_display_get_fd(self.display), c.G_IO_IN | c.G_IO_ERR | c.G_IO_HUP, &dispatch, self);
        if (self.source == 0) return error.WaylandEventSource;
        self.running = true;
        for (self.outputs.items) |output| {
            output.announced = true;
            self.callbacks.added(self.data, output);
        }
        _ = c.wl_display_dispatch_pending(self.display);
        self.flush();
    }
    pub fn destroy(self: *Client) void {
        self.clear();
        a.destroy(self);
    }
    fn clear(self: *Client) void {
        self.running = false;
        self.failed = true;
        if (self.source != 0) _ = c.g_source_remove(self.source);
        if (self.write_source != 0) _ = c.g_source_remove(self.write_source);
        while (self.surfaces.items.len > 0) self.surfaces.items[0].destroy();
        for (self.seats.items) |seat| seat.destroy();
        self.seats.deinit(a);
        while (self.buffers.items.len > 0) self.buffers.items[0].destroy();
        for (self.outputs.items) |output| output.destroy();
        self.outputs.deinit(a);
        self.surfaces.deinit(a);
        self.buffers.deinit(a);
        if (self.output_manager) |proxy| destroyProxy(proxy, 0);
        if (self.text_manager) |proxy| destroyProxy(proxy, 0);
        if (self.cursor_manager) |proxy| destroyProxy(proxy, 0);
        if (self.shell) |proxy| c.wl_proxy_destroy(proxy);
        if (self.wm_base) |proxy| destroyProxy(proxy, 0);
        if (self.activation) |proxy| destroyProxy(proxy, 0);
        if (self.clipboard_manager) |proxy| destroyProxy(proxy, 2);
        if (self.importer) |proxy| destroyProxy(proxy, 0);
        if (self.shm) |shm| c.wl_shm_destroy(shm);
        if (self.compositor) |proxy| c.wl_proxy_destroy(proxy);
        c.wl_registry_destroy(self.registry);
        c.wl_display_disconnect(self.display);
    }
    fn fail(self: *Client) void {
        if (!self.failed) std.log.err("native Wayland surface connection failed", .{});
        self.failed = true;
    }
    pub fn flush(self: *Client) void {
        if (self.failed) return;
        if (c.wl_display_flush(self.display) >= 0) return;
        if (libc.__errno_location().* != @backingInt(std.c.E.AGAIN)) {
            self.fail();
            return;
        }
        if (self.write_source == 0) self.write_source = c.g_unix_fd_add(c.wl_display_get_fd(self.display), c.G_IO_OUT | c.G_IO_ERR | c.G_IO_HUP, &writable, self);
    }
    fn writable(_: c_int, condition: c.GIOCondition, data: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast(Client, data);
        if (condition & (c.G_IO_ERR | c.G_IO_HUP) != 0) self.fail() else if (c.wl_display_flush(self.display) < 0) {
            if (libc.__errno_location().* == @backingInt(std.c.E.AGAIN)) return 1;
            self.fail();
        }
        self.write_source = 0;
        return 0;
    }
    fn dispatch(_: c_int, condition: c.GIOCondition, data: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast(Client, data);
        if (condition & (c.G_IO_ERR | c.G_IO_HUP) != 0 or !c.__zig.dispatchWayland(self.display)) {
            self.source = 0;
            self.fail();
            return 0;
        }
        self.flush();
        return 1;
    }
    fn global(data: ?*anyopaque, registry: ?*c.wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
        const self = cast(Client, data);
        const kind = std.mem.span(interface);
        if (std.mem.eql(u8, kind, "wl_compositor")) {
            self.compositor = @ptrCast(c.wl_registry_bind(registry, name, &wayland.wl_compositor_interface, @min(version, 4)));
        } else if (std.mem.eql(u8, kind, "wl_shm")) {
            self.shm = @ptrCast(c.wl_registry_bind(registry, name, &wayland.wl_shm_interface, 1));
        } else if (std.mem.eql(u8, kind, "zwlr_layer_shell_v1")) {
            self.shell = @ptrCast(c.wl_registry_bind(registry, name, &p.zwlr_layer_shell_v1_interface, @min(version, 4)));
        } else if (std.mem.eql(u8, kind, "xdg_wm_base")) {
            self.wm_base = @ptrCast(c.wl_registry_bind(registry, name, &p.xdg_wm_base_interface, @min(version, 3)));
            listen(self.wm_base.?, &wm_listener, self);
        } else if (self.input_enabled and std.mem.eql(u8, kind, "zwlr_data_control_manager_v1")) {
            self.clipboard_manager = @ptrCast(c.wl_registry_bind(registry, name, &p.zwlr_data_control_manager_v1_interface, 1));
            for (self.seats.items) |seat| seat.bindClipboard();
        } else if (self.input_enabled and std.mem.eql(u8, kind, "xdg_activation_v1")) {
            self.activation = @ptrCast(c.wl_registry_bind(registry, name, &p.xdg_activation_v1_interface, 1));
        } else if (std.mem.eql(u8, kind, "zxdg_importer_v2")) {
            self.importer = @ptrCast(c.wl_registry_bind(registry, name, &p.zxdg_importer_v2_interface, 1));
        } else if (std.mem.eql(u8, kind, "zxdg_output_manager_v1")) {
            // Version 2 has an explicit done event, independent of wl_output.
            self.output_manager = @ptrCast(c.wl_registry_bind(registry, name, &p.zxdg_output_manager_v1_interface, @min(version, 2)));
        } else if (self.input_enabled and std.mem.eql(u8, kind, "zwp_text_input_manager_v3")) {
            self.text_manager = @ptrCast(c.wl_registry_bind(registry, name, &p.zwp_text_input_manager_v3_interface, 1));
            for (self.seats.items) |seat| seat.bindTextInput();
        } else if (self.input_enabled and std.mem.eql(u8, kind, "wp_cursor_shape_manager_v1")) {
            self.cursor_manager = @ptrCast(c.wl_registry_bind(registry, name, &p.wp_cursor_shape_manager_v1_interface, 1));
            for (self.seats.items) |seat| seat.bindCursorShape();
        } else if (self.input_enabled and std.mem.eql(u8, kind, "wl_seat")) {
            const seat = input.Seat.create(self, registry.?, name, version) catch @panic("Wayland seat allocation");
            self.seats.append(a, seat) catch @panic("out of memory");
            seat.bindTextInput();
            seat.bindCursorShape();
            seat.bindClipboard();
        } else if (std.mem.eql(u8, kind, "wl_output")) {
            if (version < 2) return; // Buffer scale requires wl_output version 2.
            const output = a.create(Output) catch @panic("out of memory");
            output.* = .{ .client = self, .name = name, .proxy = @ptrCast(c.wl_registry_bind(registry, name, &wayland.wl_output_interface, @min(version, 4))) };
            self.outputs.append(a, output) catch @panic("out of memory");
            _ = c.wl_output_add_listener(output.proxy, &Output.listener, output);
            output.bindLogical();
        }
    }
    fn remove(data: ?*anyopaque, _: ?*c.wl_registry, name: u32) callconv(.c) void {
        const self = cast(Client, data);
        for (self.outputs.items) |output| if (output.name == name) {
            if (self.running and output.announced) self.callbacks.removed(self.data, output);
            // Also revoke any surfaces whose owner did not remove them.
            var i: usize = 0;
            while (i < self.surfaces.items.len) {
                if (self.surfaces.items[i].output == output) self.surfaces.items[i].destroy() else i += 1;
            }
            erase(*Output, &self.outputs, output);
            output.destroy();
            return;
        };
        for (self.seats.items) |seat| if (seat.name == name) {
            erase(*input.Seat, &self.seats, seat);
            seat.destroy();
            return;
        };
    }
    pub fn hasInput(self: *Client) bool {
        for (self.seats.items) |seat| if (seat.pointer != null or seat.keyboard != null) return true;
        return false;
    }
    fn ping(_: ?*anyopaque, base: *Proxy, serial: u32) callconv(.c) void {
        send(base, 3, .{serial});
    }
    const wm_listener = extern struct { ping: *const @TypeOf(ping) = &ping }{};
    const registry_listener: c.wl_registry_listener = .{ .global = &global, .global_remove = &remove };
};

pub const Output = struct {
    client: *Client,
    name: u32,
    proxy: *c.wl_output,
    logical: ?*Proxy = null,
    scale: u32 = 1,
    pixel_width: i32 = 0,
    pixel_height: i32 = 0,
    logical_width: i32 = 0,
    logical_height: i32 = 0,
    x: i32 = 0,
    y: i32 = 0,
    label: [64:0]u8 = @splat(0),
    transform: i32 = 0,
    announced: bool = false,

    pub fn height(self: *Output) i32 {
        if (self.logical_height > 0) return self.logical_height;
        const pixels = if (self.transform & 1 != 0) self.pixel_width else self.pixel_height;
        return @divTrunc(pixels, @as(i32, @intCast(self.scale)));
    }
    pub fn width(self: *Output) i32 {
        if (self.logical_width > 0) return self.logical_width;
        const pixels = if (self.transform & 1 != 0) self.pixel_height else self.pixel_width;
        return @divTrunc(pixels, @as(i32, @intCast(self.scale)));
    }
    fn bindLogical(self: *Output) void {
        if (self.logical != null) return;
        const manager = self.client.output_manager orelse return;
        self.logical = c.wl_proxy_marshal_flags(manager, 1, &p.zxdg_output_v1_interface, c.wl_proxy_get_version(manager), 0, @as(?*anyopaque, null), self.proxy);
        if (self.logical) |proxy| listen(proxy, &logical_listener, self);
    }
    fn destroy(self: *Output) void {
        if (self.logical) |proxy| destroyProxy(proxy, 0);
        const proxy: *Proxy = @ptrCast(self.proxy);
        if (c.wl_proxy_get_version(proxy) >= 3) destroyProxy(proxy, 0) else c.wl_output_destroy(self.proxy);
        a.destroy(self);
    }
    fn changed(self: *Output) void {
        if (!self.client.running) return;
        if (!self.announced) {
            self.announced = true;
            self.client.callbacks.added(self.client.data, self);
        } else if (self.client.callbacks.changed) |callback| callback(self.client.data, self);
        for (self.client.surfaces.items) |surface| if (surface.output == self) surface.redraw();
    }
    fn geometry(data: ?*anyopaque, _: ?*c.wl_output, x: i32, y: i32, _: i32, _: i32, _: i32, _: [*c]const u8, _: [*c]const u8, transform: i32) callconv(.c) void {
        const self = cast(Output, data);
        self.transform = transform;
        self.x = x;
        self.y = y;
    }
    fn mode(data: ?*anyopaque, _: ?*c.wl_output, flags: u32, width_: i32, height_: i32, _: i32) callconv(.c) void {
        if (flags & c.WL_OUTPUT_MODE_CURRENT == 0) return;
        const self = cast(Output, data);
        self.pixel_width = width_;
        self.pixel_height = height_;
    }
    fn done(data: ?*anyopaque, _: ?*c.wl_output) callconv(.c) void {
        cast(Output, data).changed();
    }
    fn scaled(data: ?*anyopaque, _: ?*c.wl_output, scale: i32) callconv(.c) void {
        cast(Output, data).scale = @intCast(std.math.clamp(scale, 1, 8));
    }
    fn text(_: ?*anyopaque, _: ?*c.wl_output, _: [*c]const u8) callconv(.c) void {}
    fn named(data: ?*anyopaque, _: ?*c.wl_output, name: [*c]const u8) callconv(.c) void {
        cast(Output, data).setName(name);
    }
    fn setName(self: *Output, name: [*c]const u8) void {
        const bytes = std.mem.span(name);
        if (bytes.len >= self.label.len) return;
        @memset(&self.label, 0);
        @memcpy(self.label[0..bytes.len], bytes);
    }
    const listener: c.wl_output_listener = .{ .geometry = &geometry, .mode = &mode, .done = &done, .scale = &scaled, .name = &named, .description = &text };
    fn logicalPosition(data: ?*anyopaque, _: *Proxy, x: i32, y: i32) callconv(.c) void {
        const self = cast(Output, data);
        self.x = x;
        self.y = y;
    }
    fn logicalSize(data: ?*anyopaque, _: *Proxy, width_: i32, height_: i32) callconv(.c) void {
        const self = cast(Output, data);
        self.logical_width = width_;
        self.logical_height = height_;
    }
    fn logicalDone(data: ?*anyopaque, _: *Proxy) callconv(.c) void {
        cast(Output, data).changed();
    }
    fn logicalText(_: ?*anyopaque, _: *Proxy, _: [*c]const u8) callconv(.c) void {}
    fn logicalName(data: ?*anyopaque, _: *Proxy, name: [*c]const u8) callconv(.c) void {
        cast(Output, data).setName(name);
    }
    const logical_listener = extern struct {
        position: *const @TypeOf(logicalPosition) = &logicalPosition,
        size: *const @TypeOf(logicalSize) = &logicalSize,
        done: *const @TypeOf(logicalDone) = &logicalDone,
        name: *const @TypeOf(logicalName) = &logicalName,
        description: *const @TypeOf(logicalText) = &logicalText,
    }{};
};

const Buffer = struct {
    client: *Client,
    owner: ?*Surface,
    proxy: *c.wl_buffer,
    memory: [*]u8,
    size: usize,
    width: u32,
    height: u32,
    busy: bool = false,

    fn create(owner: *Surface, width: u32, height: u32) !*Buffer {
        const size = try bufferSize(width, height);
        const shm = try c.__zig.createShmBuffer(owner.client.shm, "desktop-surface", size, width, height, width * 4, c.WL_SHM_FORMAT_ARGB8888);
        errdefer _ = libc.munmap(shm.memory, size);
        errdefer c.wl_buffer_destroy(shm.proxy);
        const self = try a.create(Buffer);
        errdefer a.destroy(self);
        self.* = .{ .client = owner.client, .owner = owner, .proxy = shm.proxy, .memory = @ptrCast(shm.memory), .size = size, .width = width, .height = height };
        try owner.client.buffers.append(a, self);
        listen(shm.proxy, &listener, self);
        return self;
    }
    fn release(data: ?*anyopaque, _: ?*c.wl_buffer) callconv(.c) void {
        const self = cast(Buffer, data);
        self.busy = false;
        if (self.owner) |owner| {
            if (owner.pending) owner.render() catch |err| std.log.err("native surface render: {s}", .{@errorName(err)});
        } else self.destroy();
    }
    const listener = extern struct { release: *const @TypeOf(release) = &release }{};
    fn destroy(self: *Buffer) void {
        erase(*Buffer, &self.client.buffers, self);
        c.wl_buffer_destroy(self.proxy);
        _ = libc.munmap(self.memory, self.size);
        a.destroy(self);
    }
};

pub fn bufferSize(width: u32, height: u32) !usize {
    if (width == 0 or height == 0 or width > 16384 or height > 16384 or @as(u64, width) * height > 64 * 1024 * 1024) return error.SurfaceTooLarge;
    return @as(usize, width) * height * 4;
}

pub const Options = struct {
    namespace: [:0]const u8,
    layer: u32 = 2,
    anchors: u32 = 0,
    role: enum { layer, toplevel } = .layer,
    title: [:0]const u8 = "Desktop",
    parent: [:0]const u8 = "",
    width: u32 = 0,
    height: u32 = 0,
    bottom_margin: i32 = 0,
    top_margin: i32 = 0,
    left_margin: i32 = 0,
    interactive: bool = false,
    keyboard: enum(u32) { none, exclusive, on_demand } = .none,
    cursor: enum { crosshair, arrow } = .crosshair,
    exclusive_zone: i32 = -1,
    maximized: bool = false,
    min_width: i32 = 240,
    min_height: i32 = 120,
    /// Disable only when the painter replaces every destination pixel.
    clear_buffer: bool = true,
};
pub const Pixels = raster.Buffer;
/// Physical pixels, cleared by default, writable only during the callback.
pub const PixelPaint = *const fn (?*anyopaque, Pixels) void;

/// A small SHM cursor keeps interactive clients independent of GTK cursor APIs.
pub fn setCursor(owner: *Surface, cursor: *Proxy, pointer: *Proxy, serial: u32) !void {
    const scale = owner.output.scale;
    const buffer = try Buffer.create(owner, 24 * scale, 24 * scale);
    buffer.owner = null;
    errdefer buffer.destroy();
    const pixels: [*]u32 = @ptrCast(@alignCast(buffer.memory));
    if (owner.options.cursor == .crosshair) {
        raster.crosshair(pixels[0 .. buffer.size / 4], scale);
    } else {
        const target: Pixels = .{ .pixels = pixels[0 .. buffer.size / 4], .width = 24 * scale, .height = 24 * scale };
        @memset(target.pixels, 0);
        const canvas: raster.Canvas = .{ .target = target, .scale = @floatFromInt(scale) };
        canvas.draw(&.{.{ .polygon = &.{ .{ .x = 2, .y = 1 }, .{ .x = 2, .y = 20 }, .{ .x = 7, .y = 15 }, .{ .x = 11, .y = 23 }, .{ .x = 15, .y = 21 }, .{ .x = 11, .y = 13 }, .{ .x = 18, .y = 13 } } }}, .{ .red = 0, .green = 0, .blue = 0 });
        canvas.draw(&.{.{ .polygon = &.{ .{ .x = 3, .y = 3 }, .{ .x = 3, .y = 17 }, .{ .x = 7, .y = 13 }, .{ .x = 12, .y = 21 }, .{ .x = 13, .y = 20 }, .{ .x = 9, .y = 12 }, .{ .x = 15, .y = 12 } } }}, .{ .red = 1, .green = 1, .blue = 1 });
    }
    send(cursor, 8, .{@as(i32, @intCast(scale))});
    send(cursor, 1, .{ buffer.proxy, @as(i32, 0), @as(i32, 0) });
    send(cursor, 2, .{ @as(i32, 0), @as(i32, 0), @as(i32, 24), @as(i32, 24) });
    const hotspot: i32 = if (owner.options.cursor == .crosshair) 12 else 2;
    send(pointer, 0, .{ serial, cursor, hotspot, hotspot });
    buffer.busy = true;
    send(cursor, 6, .{});
    owner.client.flush();
}

pub const Surface = struct {
    client: *Client,
    output: *Output,
    options: Options,
    paint: PixelPaint,
    data: ?*anyopaque,
    input: input.Events = .{},
    proxy: ?*Proxy = null,
    role: ?*Proxy = null,
    xdg_surface: ?*Proxy = null,
    imported_parent: ?*Proxy = null,
    activation_token: ?*Proxy = null,
    close: ?*const fn (?*anyopaque) void = null,
    /// Opt into compositor-paced commits. Return true to animate another frame;
    /// queued redraws are coalesced until the compositor is ready for them.
    next_frame: ?*const fn (?*anyopaque, *Surface, u32) bool = null,
    frame_callback: ?*Proxy = null,
    /// Optional quality policy for the next buffer; logical geometry is stable.
    render_scale: ?*const fn (?*anyopaque, *Surface) u32 = null,
    buffer_scale: u32 = 1,
    pending_width: u32 = 0,
    pending_height: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    configured: bool = false,
    pending: bool = false,
    rendering: bool = false,
    buffers: [2]?*Buffer = .{ null, null },

    pub fn createPixels(output: *Output, options: Options, paint: PixelPaint, data: ?*anyopaque) !*Surface {
        const self = try a.create(Surface);
        errdefer a.destroy(self);
        self.* = .{ .client = output.client, .output = output, .options = options, .paint = paint, .data = data };
        try self.client.surfaces.append(a, self);
        return self;
    }
    pub fn show(self: *Surface) !void {
        if (self.client.failed) return error.WaylandDispatch;
        if (self.options.interactive and !self.client.input_enabled) return error.InputNotEnabled;
        if (self.role != null) {
            self.redraw();
            return;
        }
        const compositor = self.client.compositor.?;
        self.proxy = c.wl_proxy_marshal_flags(compositor, 0, &wayland.wl_surface_interface, c.wl_proxy_get_version(compositor), 0, @as(?*anyopaque, null)) orelse return error.WaylandSurface;
        errdefer self.hide();
        listen(self.proxy.?, &surface_listener, self);
        if (!self.options.interactive) {
            const region = c.wl_proxy_marshal_flags(compositor, 1, &wayland.wl_region_interface, 1, 0, @as(?*anyopaque, null)) orelse return error.WaylandSurface;
            send(self.proxy.?, 5, .{region}); // Passive feedback never intercepts input.
            destroyProxy(region, 0);
        }
        if (self.options.role == .toplevel) {
            const base = self.client.wm_base orelse return error.MissingWaylandGlobals;
            self.xdg_surface = c.wl_proxy_marshal_flags(base, 2, &p.xdg_surface_interface, c.wl_proxy_get_version(base), 0, @as(?*anyopaque, null), self.proxy.?) orelse return error.WaylandSurface;
            listen(self.xdg_surface.?, &xdg_surface_listener, self);
            self.role = c.wl_proxy_marshal_flags(self.xdg_surface.?, 1, &p.xdg_toplevel_interface, c.wl_proxy_get_version(self.xdg_surface.?), 0, @as(?*anyopaque, null)) orelse return error.WaylandSurface;
            listen(self.role.?, &toplevel_listener, self);
            send(self.role.?, 2, .{self.options.title.ptr});
            send(self.role.?, 3, .{self.options.namespace.ptr});
            if (self.options.maximized) send(self.role.?, 9, .{});
            if (std.mem.startsWith(u8, self.options.parent, "wayland:")) if (self.client.importer) |importer| {
                const handle: [*:0]const u8 = self.options.parent.ptr + 8;
                self.imported_parent = c.wl_proxy_marshal_flags(importer, 1, &p.zxdg_imported_v2_interface, 1, 0, @as(?*anyopaque, null), handle) orelse return error.WaylandSurface;
                listen(self.imported_parent.?, &parent_listener, self);
                send(self.imported_parent.?, 1, .{self.proxy.?});
            };
            send(self.role.?, 8, .{ self.options.min_width, self.options.min_height });
            self.pending_width = @max(1, self.options.width);
            self.pending_height = @max(1, self.options.height);
            send(self.proxy.?, 6, .{});
            self.client.flush();
            return;
        }
        const shell = self.client.shell orelse return error.MissingWaylandGlobals;
        self.role = c.wl_proxy_marshal_flags(shell, 0, &p.zwlr_layer_surface_v1_interface, c.wl_proxy_get_version(shell), 0, @as(?*anyopaque, null), self.proxy.?, self.output.proxy, self.options.layer, self.options.namespace.ptr) orelse return error.WaylandSurface;
        listen(self.role.?, &layer_listener, self);
        send(self.role.?, 0, .{ self.options.width, self.options.height });
        send(self.role.?, 1, .{self.options.anchors});
        send(self.role.?, 2, .{self.options.exclusive_zone});
        send(self.role.?, 3, .{ self.options.top_margin, @as(i32, 0), self.options.bottom_margin, self.options.left_margin });
        const keyboard: u32 = if (self.options.keyboard == .on_demand and c.wl_proxy_get_version(shell) < 4) 1 else @backingInt(self.options.keyboard);
        send(self.role.?, 4, .{keyboard});
        send(self.proxy.?, 6, .{});
        self.client.flush();
    }
    pub fn present(self: *Surface) void {
        if (self.proxy == null or self.activation_token != null) return;
        const manager = self.client.activation orelse return;
        const token = c.wl_proxy_marshal_flags(manager, 1, &p.xdg_activation_token_v1_interface, 1, 0, @as(?*anyopaque, null)) orelse return;
        self.activation_token = token;
        listen(token, &activation_listener, self);
        send(token, 1, .{self.options.namespace.ptr});
        for (self.client.seats.items) |seat| {
            const origin = seat.keyboard_focus orelse seat.pointer_focus orelse continue;
            if (seat.serial == 0 or origin.proxy == null) continue;
            send(token, 0, .{ seat.serial, seat.proxy });
            send(token, 2, .{origin.proxy.?});
            break;
        }
        send(token, 3, .{});
        self.client.flush();
    }
    fn activated(ptr: ?*anyopaque, token: *Proxy, value: [*c]const u8) callconv(.c) void {
        const self = cast(Surface, ptr);
        if (self.proxy) |proxy| if (self.client.activation) |manager| send(manager, 2, .{ value, proxy });
        destroyProxy(token, 4);
        self.activation_token = null;
        self.client.flush();
    }
    const activation_listener = extern struct { done: *const @TypeOf(activated) = &activated }{};
    pub fn hide(self: *Surface) void {
        if (self.activation_token) |token| destroyProxy(token, 4);
        self.activation_token = null;
        if (self.frame_callback) |callback| c.wl_proxy_destroy(callback);
        self.frame_callback = null;
        for (self.client.seats.items) |seat| seat.forget(self);
        if (self.role) |role| destroyProxy(role, if (self.options.role == .toplevel) 0 else 7);
        if (self.imported_parent) |proxy| destroyProxy(proxy, 0);
        if (self.xdg_surface) |proxy| destroyProxy(proxy, 0);
        if (self.proxy) |proxy| destroyProxy(proxy, 0);
        self.role = null;
        self.xdg_surface = null;
        self.imported_parent = null;
        self.proxy = null;
        self.configured = false;
        self.pending = false;
        for (&self.buffers) |*slot| if (slot.*) |buffer| {
            buffer.owner = null;
            if (!buffer.busy) buffer.destroy();
            slot.* = null;
        };
        self.client.flush();
    }
    pub fn destroy(self: *Surface) void {
        self.hide();
        erase(*Surface, &self.client.surfaces, self);
        a.destroy(self);
    }
    pub fn setBottomMargin(self: *Surface, margin: i32) void {
        std.debug.assert(self.options.role == .layer);
        if (margin == self.options.bottom_margin) return;
        self.options.bottom_margin = margin;
        if (self.role) |role| {
            send(role, 3, .{ self.options.top_margin, @as(i32, 0), margin, self.options.left_margin });
            send(self.proxy.?, 6, .{});
            self.client.flush();
        }
    }
    pub fn setLayout(self: *Surface, width: u32, height: u32, top_margin: i32, left_margin: i32) void {
        std.debug.assert(self.options.role == .layer);
        const changed = self.options.width != width or self.options.height != height or self.options.top_margin != top_margin or self.options.left_margin != left_margin;
        if (!changed) return;
        self.options.width = width;
        self.options.height = height;
        self.options.top_margin = top_margin;
        self.options.left_margin = left_margin;
        if (self.role) |role| {
            send(role, 0, .{ width, height });
            send(role, 3, .{ top_margin, @as(i32, 0), self.options.bottom_margin, left_margin });
            send(self.proxy.?, 6, .{});
            self.client.flush();
        }
    }
    pub fn redraw(self: *Surface) void {
        if (self.role == null) return;
        self.pending = true;
        self.render() catch |err| std.log.err("native surface render: {s}", .{@errorName(err)});
    }
    fn render(self: *Surface) !void {
        if (!self.pending or !self.configured or self.client.failed or self.frame_callback != null or self.rendering) return;
        self.rendering = true;
        defer self.rendering = false;
        const scale = if (self.render_scale) |choose| choose(self.data, self) else self.output.scale;
        if (scale < 1 or scale > 8) return error.InvalidBufferScale;
        const width = std.math.mul(u32, self.width, scale) catch return error.SurfaceTooLarge;
        const height = std.math.mul(u32, self.height, scale) catch return error.SurfaceTooLarge;
        _ = try bufferSize(width, height);
        var available: ?*Buffer = null;
        for (&self.buffers) |*slot| {
            if (slot.*) |buffer| {
                if (buffer.busy) continue;
                if (buffer.width != width or buffer.height != height) {
                    buffer.destroy();
                    slot.* = null;
                }
            }
            if (slot.* == null) slot.* = try Buffer.create(self, width, height);
            available = slot.*;
            break;
        }
        const buffer = available orelse return; // release retries the newest state.
        const pixels: [*]u32 = @ptrCast(@alignCast(buffer.memory));
        self.buffer_scale = scale;
        if (self.options.clear_buffer) @memset(pixels[0 .. buffer.size / 4], 0);
        self.paint(self.data, .{ .pixels = pixels[0 .. buffer.size / 4], .width = width, .height = height });
        if (self.next_frame != null) {
            const callback = c.wl_proxy_marshal_flags(self.proxy.?, 3, &wayland.wl_callback_interface, 1, 0, @as(?*anyopaque, null)) orelse return error.WaylandFrameCallback;
            self.frame_callback = callback;
            listen(callback, &frame_listener, self);
        }
        send(self.proxy.?, 8, .{@as(i32, @intCast(scale))});
        send(self.proxy.?, 1, .{ buffer.proxy, @as(i32, 0), @as(i32, 0) });
        send(self.proxy.?, 2, .{ @as(i32, 0), @as(i32, 0), @as(i32, @intCast(self.width)), @as(i32, @intCast(self.height)) });
        buffer.busy = true;
        self.pending = false;
        send(self.proxy.?, 6, .{});
        self.client.flush();
    }
    fn frameDone(data: ?*anyopaque, callback: *Proxy, time: u32) callconv(.c) void {
        const self = cast(Surface, data);
        c.wl_proxy_destroy(callback);
        self.frame_callback = null;
        if (self.next_frame) |next| if (next(self.data, self, time)) {
            self.pending = true;
        };
        self.render() catch |err| std.log.err("native surface frame: {s}", .{@errorName(err)});
    }
    const frame_listener = extern struct { done: *const @TypeOf(frameDone) = &frameDone }{};
    fn configure(data: ?*anyopaque, role: *Proxy, serial: u32, width: u32, height: u32) callconv(.c) void {
        const self = cast(Surface, data);
        send(role, 6, .{serial});
        const next_width = if (width == 0) self.options.width else width;
        const next_height = if (height == 0) self.options.height else height;
        const changed = !self.configured or self.width != next_width or self.height != next_height;
        self.width = next_width;
        self.height = next_height;
        self.configured = true;
        // Layout can be configured again after any layer commits. Acknowledge
        // unchanged geometry without creating a commit/configure feedback loop.
        if (changed) self.redraw() else self.client.flush();
    }
    fn closed(data: ?*anyopaque, _: *Proxy) callconv(.c) void {
        cast(Surface, data).hide();
    }
    const layer_listener = extern struct {
        configure: *const @TypeOf(configure) = &configure,
        closed: *const @TypeOf(closed) = &closed,
    }{};
    fn xdgConfigured(data: ?*anyopaque, proxy: *Proxy, serial: u32) callconv(.c) void {
        const self = cast(Surface, data);
        send(proxy, 4, .{serial});
        self.width = self.pending_width;
        self.height = self.pending_height;
        self.configured = true;
        self.redraw();
    }
    const xdg_surface_listener = extern struct { configure: *const @TypeOf(xdgConfigured) = &xdgConfigured }{};
    fn toplevelConfigured(data: ?*anyopaque, _: *Proxy, width: i32, height: i32, _: ?*c.wl_array) callconv(.c) void {
        const self = cast(Surface, data);
        if (width > 0) self.pending_width = @intCast(width);
        if (height > 0) self.pending_height = @intCast(height);
    }
    fn toplevelClosed(data: ?*anyopaque, _: *Proxy) callconv(.c) void {
        const self = cast(Surface, data);
        self.hide();
        if (self.close) |callback| callback(self.data);
    }
    const toplevel_listener = extern struct {
        configure: *const @TypeOf(toplevelConfigured) = &toplevelConfigured,
        close: *const @TypeOf(toplevelClosed) = &toplevelClosed,
    }{};
    fn parentDestroyed(data: ?*anyopaque, _: *Proxy) callconv(.c) void {
        const self = cast(Surface, data);
        if (self.imported_parent) |proxy| destroyProxy(proxy, 0);
        self.imported_parent = null;
    }
    const parent_listener = extern struct { destroyed: *const @TypeOf(parentDestroyed) = &parentDestroyed }{};
    fn entered(_: ?*anyopaque, _: *Proxy, _: ?*c.wl_output) callconv(.c) void {}
    const surface_listener = extern struct {
        enter: *const @TypeOf(entered) = &entered,
        leave: *const @TypeOf(entered) = &entered,
    }{};
};

test "native buffer bounds reject empty images and oversized allocations" {
    try std.testing.expectError(error.SurfaceTooLarge, bufferSize(0, 1));
    try std.testing.expectError(error.SurfaceTooLarge, bufferSize(16385, 1));
    try std.testing.expectError(error.SurfaceTooLarge, bufferSize(16384, 16384));
    try std.testing.expectEqual(@as(usize, 3840 * 2160 * 4), try bufferSize(3840, 2160));
}

test "passive clients do not bind input seats or accept interactive surfaces" {
    const Noop = struct {
        fn output(_: ?*anyopaque, _: *Output) void {}
        fn paint(_: ?*anyopaque, _: Pixels) void {}
    };
    const client = try Client.create(.{ .added = &Noop.output, .removed = &Noop.output }, null);
    defer client.destroy();
    try std.testing.expectEqual(@as(usize, 0), client.seats.items.len);
    try std.testing.expect(!client.hasInput());
    const surface = try Surface.createPixels(client.outputs.items[0], .{ .namespace = "input-guard", .layer = 3, .anchors = 0, .width = 32, .height = 32, .interactive = true }, &Noop.paint, null);
    defer surface.destroy();
    try std.testing.expectError(error.InputNotEnabled, surface.show());
    try std.testing.expect(surface.proxy == null);
}

test "frame callbacks coalesce redraws, finish animation and cancel on hide" {
    const State = struct {
        paints: usize = 0,
        frames: usize = 0,
        sizes: u8 = 0,
        fn output(_: ?*anyopaque, _: *Output) void {}
        fn paint(data: ?*anyopaque, pixels: Pixels) void {
            const self = cast(@This(), data);
            self.paints += 1;
            self.sizes |= if (pixels.width == 32) @as(u8, 1) else if (pixels.width == 64) @as(u8, 2) else 0;
            @memset(pixels.pixels, 0xff245b98);
        }
        fn next(data: ?*anyopaque, _: *Surface, _: u32) bool {
            const self = cast(@This(), data);
            self.frames += 1;
            return self.frames < 4;
        }
        fn scale(data: ?*anyopaque, _: *Surface) u32 {
            return if (cast(@This(), data).frames < 2) 1 else 2;
        }
    };
    var state: State = .{};
    const client = try Client.create(.{ .added = &State.output, .removed = &State.output }, &state);
    defer client.destroy();
    const surface = try Surface.createPixels(client.outputs.items[0], .{ .namespace = "frame-pacing-test", .layer = 3, .width = 32, .height = 32 }, &State.paint, &state);
    surface.next_frame = &State.next;
    surface.render_scale = &State.scale;
    try client.start();
    try surface.show();
    const deadline = c.g_get_monotonic_time() + 2_000_000;
    while (state.paints == 0 and c.g_get_monotonic_time() < deadline) {
        while (c.g_main_context_iteration(null, 0) != 0) {}
        c.g_usleep(1000);
    }
    try std.testing.expect(surface.frame_callback != null);
    const paints = state.paints;
    for (0..20) |_| surface.redraw();
    try std.testing.expectEqual(paints, state.paints);
    try std.testing.expect(surface.pending);
    while ((state.frames < 4 or surface.frame_callback != null or surface.pending) and c.g_get_monotonic_time() < deadline) {
        while (c.g_main_context_iteration(null, 0) != 0) {}
        c.g_usleep(1000);
    }
    try std.testing.expectEqual(@as(usize, 4), state.frames);
    try std.testing.expectEqual(@as(usize, 4), state.paints);
    try std.testing.expectEqual(@as(u8, 3), state.sizes);
    try std.testing.expectEqual(@as(u32, 2), surface.buffer_scale);
    try std.testing.expect(surface.frame_callback == null and !surface.pending);
    surface.redraw();
    try std.testing.expect(surface.frame_callback != null);
    surface.hide();
    try std.testing.expect(surface.frame_callback == null and !surface.pending);
    const hidden_paints = state.paints;
    @import("tests/desktop-surface-capture.zig").pump();
    try std.testing.expectEqual(hidden_paints, state.paints);
    // Remapping must start a fresh callback rather than await the cancelled one.
    try surface.show();
    @import("tests/desktop-surface-capture.zig").pump();
    try std.testing.expect(state.paints > hidden_paints);
}

test "native cursor matches Cairo strokes and transparency at every output scale" {
    for (1..9) |value| {
        const scale: u32 = @intCast(value);
        const size = 24 * scale;
        const image = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, @intCast(size), @intCast(size)).?;
        defer c.cairo_surface_destroy(image);
        c.cairo_surface_set_device_scale(image, @floatFromInt(scale), @floatFromInt(scale));
        const cr = c.cairo_create(image).?;
        defer c.cairo_destroy(cr);
        c.cairo_set_operator(cr, c.CAIRO_OPERATOR_CLEAR);
        c.cairo_paint(cr);
        c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);
        for ([_]f64{ 4, 2 }, 0..) |width, i| {
            const color: f64 = if (i == 0) 0 else 1;
            c.cairo_set_source_rgba(cr, color, color, color, 1);
            c.cairo_set_line_width(cr, width);
            c.cairo_move_to(cr, 12, 2);
            c.cairo_line_to(cr, 12, 22);
            c.cairo_move_to(cr, 2, 12);
            c.cairo_line_to(cr, 22, 12);
            c.cairo_stroke(cr);
        }
        c.cairo_surface_flush(image);

        const expected: [*]const u32 = @ptrCast(@alignCast(c.cairo_image_surface_get_data(image)));
        const pixels = try std.testing.allocator.alloc(u32, size * size);
        defer std.testing.allocator.free(pixels);
        raster.crosshair(pixels, scale);
        try std.testing.expectEqualSlices(u32, expected[0..pixels.len], pixels);
    }
}
