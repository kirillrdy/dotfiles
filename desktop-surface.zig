//! Native Wayland layer surfaces and application windows with SHM rendering.
//! Each client has a private connection over the Zig wire runtime, driven by GLib.
const std = @import("std");
const cairo = @import("tests/desktop-cairo.zig");
const c = @import("desktop-glib.zig");
const client_helpers = @import("desktop-wayland-client.zig");
const wl = @import("wayland-client");
const wire = @import("wayland-wire");
const input = @import("desktop-input.zig");
const raster = @import("desktop-raster.zig");
const a = std.heap.page_allocator;
const cast = c.__zig.cast;

pub const top = 1;
pub const bottom = 2;
pub const left = 4;
pub const right = 8;

fn erase(comptime T: type, list: *std.ArrayList(T), value: T) void {
    for (list.items, 0..) |entry, i| if (entry == value) {
        _ = list.orderedRemove(i);
        return;
    };
}

/// Whether two optional handles name the same live protocol object.
pub fn same(first: anytype, second: anytype) bool {
    const x = first orelse return false;
    const y = second orelse return false;
    return x.proxy.id == y.proxy.id;
}

pub const Callbacks = struct {
    added: *const fn (?*anyopaque, *Output) void,
    removed: *const fn (?*anyopaque, *Output) void,
    changed: ?*const fn (?*anyopaque, *Output) void = null,
};

pub const Client = struct {
    connection: *wire.Connection,
    registry: wl.wl_registry,
    compositor: ?wl.wl_compositor = null,
    shm: ?wl.wl_shm = null,
    shell: ?wl.zwlr_layer_shell_v1 = null,
    wm_base: ?wl.xdg_wm_base = null,
    activation: ?wl.xdg_activation_v1 = null,
    clipboard_manager: ?wl.zwlr_data_control_manager_v1 = null,
    importer: ?wl.zxdg_importer_v2 = null,
    output_manager: ?wl.zxdg_output_manager_v1 = null,
    text_manager: ?wl.zwp_text_input_manager_v3 = null,
    cursor_manager: ?wl.wp_cursor_shape_manager_v1 = null,
    overview_global: u32 = 0,
    preview_control: ?wl.dotfiles_overview_v1 = null,
    outputs: std.ArrayList(*Output) = .empty,
    surfaces: std.ArrayList(*Surface) = .empty,
    buffers: std.ArrayList(*Buffer) = .empty,
    seats: std.ArrayList(*input.Seat) = .empty,
    input_enabled: bool = false,
    callbacks: Callbacks,
    data: ?*anyopaque,
    source: c.guint = 0,
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
        const connection = wire.Connection.connect(a) catch return error.WaylandConnection;
        const display: wl.wl_display = .{ .proxy = connection.display() };
        self.* = .{ .connection = connection, .registry = display.get_registry(), .callbacks = callbacks, .data = data, .input_enabled = enabled };
        errdefer self.clear();
        self.registry.listen(Client, self, registryEvent);
        connection.roundtrip() catch return error.WaylandDispatch;
        if (self.compositor == null or self.shm == null) return error.MissingWaylandGlobals;
        if (self.compositor.?.version() < 3) return error.UnsupportedCompositor;
        // xdg-output can be advertised after wl_output. Bind it after discovery.
        for (self.outputs.items) |output| output.bindLogical();
        connection.roundtrip() catch return error.WaylandDispatch;
        return self;
    }
    pub fn start(self: *Client) !void {
        self.source = c.g_unix_fd_add(self.connection.getFd(), c.G_IO_IN | c.G_IO_ERR | c.G_IO_HUP, &dispatch, self);
        if (self.source == 0) return error.WaylandEventSource;
        self.running = true;
        for (self.outputs.items) |output| {
            output.announced = true;
            self.callbacks.added(self.data, output);
        }
        self.connection.dispatchPending() catch self.fail();
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
        while (self.surfaces.items.len > 0) self.surfaces.items[0].destroy();
        for (self.seats.items) |seat| seat.destroy();
        self.seats.deinit(a);
        while (self.buffers.items.len > 0) self.buffers.items[0].destroy();
        for (self.outputs.items) |output| output.destroy();
        self.outputs.deinit(a);
        self.surfaces.deinit(a);
        self.buffers.deinit(a);
        if (self.output_manager) |value| value.destroy();
        if (self.text_manager) |value| value.destroy();
        if (self.cursor_manager) |value| value.destroy();
        if (self.preview_control) |value| value.destroy();
        if (self.shell) |value| value.proxy.forget();
        if (self.wm_base) |value| value.destroy();
        if (self.activation) |value| value.destroy();
        if (self.clipboard_manager) |value| value.destroy();
        if (self.importer) |value| value.destroy();
        if (self.shm) |value| value.destroy();
        if (self.compositor) |value| value.destroy();
        self.registry.destroy();
        self.connection.deinit();
    }
    fn fail(self: *Client) void {
        if (!self.failed) std.log.err("native Wayland surface connection failed", .{});
        self.failed = true;
    }
    pub fn flush(self: *Client) void {
        if (self.failed) return;
        self.connection.flush() catch self.fail();
    }
    /// Blocks until the compositor has handled every request sent so far.
    pub fn roundtrip(self: *Client) void {
        if (self.failed) return;
        self.connection.roundtrip() catch self.fail();
    }
    pub fn enablePreviews(self: *Client) bool {
        if (self.preview_control != null) return true;
        if (self.overview_global == 0) return false;
        // Events on this object are not needed; the overview only sends requests.
        self.preview_control = self.registry.bind(self.overview_global, wl.dotfiles_overview_v1, 3);
        return true;
    }
    fn dispatch(_: c_int, condition: c.GIOCondition, data: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast(Client, data);
        if (condition & (c.G_IO_ERR | c.G_IO_HUP) != 0) {
            self.source = 0;
            self.fail();
            return 0;
        }
        self.connection.readAndDispatch() catch {
            self.source = 0;
            self.fail();
            return 0;
        };
        return 1;
    }
    fn registryEvent(self: *Client, registry: wl.wl_registry, event: wl.wl_registry.Event) void {
        switch (event) {
            .global => |value| self.global(registry, value.name, value.interface, value.version),
            .global_remove => |value| self.remove(value.name),
        }
    }
    fn global(self: *Client, registry: wl.wl_registry, name: u32, kind: []const u8, version: u32) void {
        if (std.mem.eql(u8, kind, "wl_compositor")) {
            self.compositor = registry.bind(name, wl.wl_compositor, @min(version, 4));
        } else if (std.mem.eql(u8, kind, "wl_shm")) {
            self.shm = registry.bind(name, wl.wl_shm, 1);
        } else if (std.mem.eql(u8, kind, "zwlr_layer_shell_v1")) {
            self.shell = registry.bind(name, wl.zwlr_layer_shell_v1, @min(version, 4));
        } else if (std.mem.eql(u8, kind, "xdg_wm_base")) {
            const base = registry.bind(name, wl.xdg_wm_base, @min(version, 3));
            self.wm_base = base;
            base.listen(Client, self, ping);
        } else if (self.input_enabled and std.mem.eql(u8, kind, "zwlr_data_control_manager_v1")) {
            self.clipboard_manager = registry.bind(name, wl.zwlr_data_control_manager_v1, 1);
            for (self.seats.items) |seat| seat.bindClipboard();
        } else if (self.input_enabled and std.mem.eql(u8, kind, "xdg_activation_v1")) {
            self.activation = registry.bind(name, wl.xdg_activation_v1, 1);
        } else if (std.mem.eql(u8, kind, "zxdg_importer_v2")) {
            self.importer = registry.bind(name, wl.zxdg_importer_v2, 1);
        } else if (std.mem.eql(u8, kind, "zxdg_output_manager_v1")) {
            // Version 2 has an explicit done event, independent of wl_output.
            self.output_manager = registry.bind(name, wl.zxdg_output_manager_v1, @min(version, 2));
        } else if (self.input_enabled and std.mem.eql(u8, kind, "zwp_text_input_manager_v3")) {
            self.text_manager = registry.bind(name, wl.zwp_text_input_manager_v3, 1);
            for (self.seats.items) |seat| seat.bindTextInput();
        } else if (self.input_enabled and std.mem.eql(u8, kind, "wp_cursor_shape_manager_v1")) {
            self.cursor_manager = registry.bind(name, wl.wp_cursor_shape_manager_v1, 1);
            for (self.seats.items) |seat| seat.bindCursorShape();
        } else if (self.input_enabled and std.mem.eql(u8, kind, "wl_seat")) {
            const seat = input.Seat.create(self, registry, name, version) catch @panic("Wayland seat allocation");
            self.seats.append(a, seat) catch @panic("out of memory");
            seat.bindTextInput();
            seat.bindCursorShape();
            seat.bindClipboard();
        } else if (std.mem.eql(u8, kind, "dotfiles_overview_v1")) {
            if (version >= 3) self.overview_global = name;
        } else if (std.mem.eql(u8, kind, "wl_output")) {
            if (version < 2) return; // Buffer scale requires wl_output version 2.
            const output = a.create(Output) catch @panic("out of memory");
            output.* = .{ .client = self, .name = name, .proxy = registry.bind(name, wl.wl_output, @min(version, 4)) };
            self.outputs.append(a, output) catch @panic("out of memory");
            output.proxy.listen(Output, output, Output.outputEvent);
            output.bindLogical();
        }
    }
    fn remove(self: *Client, name: u32) void {
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
    fn ping(_: *Client, base: wl.xdg_wm_base, event: wl.xdg_wm_base.Event) void {
        base.pong(event.ping.serial);
    }
};

pub const Output = struct {
    client: *Client,
    name: u32,
    proxy: wl.wl_output,
    logical: ?wl.zxdg_output_v1 = null,
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
        const logical = manager.get_xdg_output(self.proxy);
        self.logical = logical;
        logical.listen(Output, self, logicalEvent);
    }
    fn destroy(self: *Output) void {
        if (self.logical) |value| value.destroy();
        if (self.proxy.version() >= 3) self.proxy.release() else self.proxy.destroy();
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
    fn outputEvent(self: *Output, _: wl.wl_output, event: wl.wl_output.Event) void {
        switch (event) {
            .geometry => |value| {
                self.transform = value.transform;
                self.x = value.x;
                self.y = value.y;
            },
            .mode => |value| if (value.flags & wl.wl_output.Mode.current != 0) {
                self.pixel_width = value.width;
                self.pixel_height = value.height;
            },
            .done => self.changed(),
            .scale => |value| self.scale = @intCast(std.math.clamp(value.factor, 1, 8)),
            .name => |value| self.setName(value.name),
            .description => {},
        }
    }
    fn logicalEvent(self: *Output, _: wl.zxdg_output_v1, event: wl.zxdg_output_v1.Event) void {
        switch (event) {
            .logical_position => |value| {
                self.x = value.x;
                self.y = value.y;
            },
            .logical_size => |value| {
                self.logical_width = value.width;
                self.logical_height = value.height;
            },
            .done => self.changed(),
            .name => |value| self.setName(value.name),
            .description => {},
        }
    }
    fn setName(self: *Output, bytes: []const u8) void {
        if (bytes.len >= self.label.len) return;
        @memset(&self.label, 0);
        @memcpy(self.label[0..bytes.len], bytes);
    }
};

const Buffer = struct {
    client: *Client,
    owner: ?*Surface,
    shm: client_helpers.ShmBuffer,
    width: u32,
    height: u32,
    busy: bool = false,

    fn create(owner: *Surface, width: u32, height: u32) !*Buffer {
        _ = try bufferSize(width, height);
        const shm = try client_helpers.shmBuffer(owner.client.shm.?, "desktop-surface", width, height, wl.wl_shm.Format.argb8888);
        errdefer {
            shm.buffer.destroy();
            shm.unmap();
        }
        const self = try a.create(Buffer);
        errdefer a.destroy(self);
        self.* = .{ .client = owner.client, .owner = owner, .shm = shm, .width = width, .height = height };
        try owner.client.buffers.append(a, self);
        shm.buffer.listen(Buffer, self, released);
        return self;
    }
    fn pixels(self: *Buffer) []u32 {
        const words: [*]u32 = @ptrCast(@alignCast(self.shm.memory));
        return words[0 .. self.shm.size / 4];
    }
    fn released(self: *Buffer, _: wl.wl_buffer, _: wl.wl_buffer.Event) void {
        self.busy = false;
        if (self.owner) |owner| {
            if (owner.pending) owner.render() catch |err| std.log.err("native surface render: {s}", .{@errorName(err)});
        } else self.destroy();
    }
    fn destroy(self: *Buffer) void {
        erase(*Buffer, &self.client.buffers, self);
        self.shm.buffer.destroy();
        self.shm.unmap();
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
    fully_opaque: bool = false,
};
pub const Pixels = raster.Buffer;
/// Physical pixels, cleared by default, writable only during the callback.
pub const PixelPaint = *const fn (?*anyopaque, Pixels) void;

/// A small SHM cursor keeps interactive clients independent of GTK cursor APIs.
pub fn setCursor(owner: *Surface, cursor: wl.wl_surface, pointer: wl.wl_pointer, serial: u32) !void {
    const scale = owner.output.scale;
    const buffer = try Buffer.create(owner, 24 * scale, 24 * scale);
    buffer.owner = null;
    errdefer buffer.destroy();
    const target: Pixels = .{ .pixels = buffer.pixels(), .width = 24 * scale, .height = 24 * scale };
    if (owner.options.cursor == .crosshair) {
        raster.crosshair(target.pixels, scale);
    } else {
        @memset(target.pixels, 0);
        const canvas: raster.Canvas = .{ .target = target, .scale = @floatFromInt(scale) };
        canvas.draw(&.{.{ .polygon = &.{ .{ .x = 2, .y = 1 }, .{ .x = 2, .y = 20 }, .{ .x = 7, .y = 15 }, .{ .x = 11, .y = 23 }, .{ .x = 15, .y = 21 }, .{ .x = 11, .y = 13 }, .{ .x = 18, .y = 13 } } }}, .{ .red = 0, .green = 0, .blue = 0 });
        canvas.draw(&.{.{ .polygon = &.{ .{ .x = 3, .y = 3 }, .{ .x = 3, .y = 17 }, .{ .x = 7, .y = 13 }, .{ .x = 12, .y = 21 }, .{ .x = 13, .y = 20 }, .{ .x = 9, .y = 12 }, .{ .x = 15, .y = 12 } } }}, .{ .red = 1, .green = 1, .blue = 1 });
    }
    cursor.set_buffer_scale(@intCast(scale));
    cursor.attach(buffer.shm.buffer, 0, 0);
    cursor.damage(0, 0, 24, 24);
    const hotspot: i32 = if (owner.options.cursor == .crosshair) 12 else 2;
    pointer.set_cursor(serial, cursor, hotspot, hotspot);
    buffer.busy = true;
    cursor.commit();
    owner.client.flush();
}

pub const Surface = struct {
    client: *Client,
    output: *Output,
    options: Options,
    paint: PixelPaint,
    data: ?*anyopaque,
    input: input.Events = .{},
    proxy: ?wl.wl_surface = null,
    /// The layer surface or toplevel while mapped; null when hidden.
    role: ?wire.Proxy = null,
    layer: ?wl.zwlr_layer_surface_v1 = null,
    toplevel: ?wl.xdg_toplevel = null,
    xdg_surface: ?wl.xdg_surface = null,
    imported_parent: ?wl.zxdg_imported_v2 = null,
    activation_token: ?wl.xdg_activation_token_v1 = null,
    close: ?*const fn (?*anyopaque) void = null,
    /// Opt into compositor-paced commits. Return true to animate another frame;
    /// queued redraws are coalesced until the compositor is ready for them.
    next_frame: ?*const fn (?*anyopaque, *Surface, u32) bool = null,
    frame_callback: ?wl.wl_callback = null,
    /// Optional quality policy for the next buffer; logical geometry is stable.
    render_scale: ?*const fn (?*anyopaque, *Surface) u32 = null,
    /// Optional commit gate. Returning false keeps the redraw pending, so
    /// surfaces that must appear together can commit in the same dispatch.
    ready: ?*const fn (?*anyopaque, *Surface) bool = null,
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
        const surface = compositor.create_surface();
        self.proxy = surface;
        errdefer self.hide();
        if (!self.options.interactive) {
            // Passive feedback never intercepts input.
            const region = compositor.create_region();
            surface.set_input_region(region);
            region.destroy();
        }
        if (self.options.role == .toplevel) {
            const base = self.client.wm_base orelse return error.MissingWaylandGlobals;
            const xdg = base.get_xdg_surface(surface);
            self.xdg_surface = xdg;
            xdg.listen(Surface, self, xdgEvent);
            const toplevel = xdg.get_toplevel();
            self.toplevel = toplevel;
            self.role = toplevel.proxy;
            toplevel.listen(Surface, self, toplevelEvent);
            toplevel.set_title(self.options.title);
            toplevel.set_app_id(self.options.namespace);
            if (self.options.maximized) toplevel.set_maximized();
            if (std.mem.startsWith(u8, self.options.parent, "wayland:")) if (self.client.importer) |importer| {
                const imported = importer.import_toplevel(self.options.parent[8..]);
                self.imported_parent = imported;
                imported.listen(Surface, self, parentEvent);
                imported.set_parent_of(surface);
            };
            toplevel.set_min_size(self.options.min_width, self.options.min_height);
            self.pending_width = @max(1, self.options.width);
            self.pending_height = @max(1, self.options.height);
            surface.commit();
            self.client.flush();
            return;
        }
        const shell = self.client.shell orelse return error.MissingWaylandGlobals;
        const layer = shell.get_layer_surface(surface, self.output.proxy, self.options.layer, self.options.namespace);
        self.layer = layer;
        self.role = layer.proxy;
        layer.listen(Surface, self, layerEvent);
        layer.set_size(self.options.width, self.options.height);
        layer.set_anchor(self.options.anchors);
        layer.set_exclusive_zone(self.options.exclusive_zone);
        layer.set_margin(self.options.top_margin, 0, self.options.bottom_margin, self.options.left_margin);
        const keyboard: u32 = if (self.options.keyboard == .on_demand and shell.version() < 4) 1 else @backingInt(self.options.keyboard);
        layer.set_keyboard_interactivity(keyboard);
        surface.commit();
        self.client.flush();
    }
    pub fn present(self: *Surface) void {
        if (self.proxy == null or self.activation_token != null) return;
        const manager = self.client.activation orelse return;
        const token = manager.get_activation_token();
        self.activation_token = token;
        token.listen(Surface, self, activated);
        token.set_app_id(self.options.namespace);
        for (self.client.seats.items) |seat| {
            const origin = seat.keyboard_focus orelse seat.pointer_focus orelse continue;
            if (seat.serial == 0) continue;
            const origin_surface = origin.proxy orelse continue;
            token.set_serial(seat.serial, seat.proxy);
            token.set_surface(origin_surface);
            break;
        }
        token.commit();
        self.client.flush();
    }
    fn activated(self: *Surface, token: wl.xdg_activation_token_v1, event: wl.xdg_activation_token_v1.Event) void {
        if (self.proxy) |surface| if (self.client.activation) |manager| manager.activate(event.done.token, surface);
        token.destroy();
        self.activation_token = null;
        self.client.flush();
    }
    pub fn hide(self: *Surface) void {
        if (self.activation_token) |token| token.destroy();
        self.activation_token = null;
        if (self.frame_callback) |callback| callback.destroy();
        self.frame_callback = null;
        for (self.client.seats.items) |seat| seat.forget(self);
        if (self.layer) |layer| layer.destroy();
        if (self.toplevel) |toplevel| toplevel.destroy();
        if (self.imported_parent) |imported| imported.destroy();
        if (self.xdg_surface) |xdg| xdg.destroy();
        if (self.proxy) |surface| surface.destroy();
        self.role = null;
        self.layer = null;
        self.toplevel = null;
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
        if (self.layer) |layer| {
            layer.set_margin(self.options.top_margin, 0, margin, self.options.left_margin);
            self.proxy.?.commit();
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
        if (self.layer) |layer| {
            layer.set_size(width, height);
            layer.set_margin(top_margin, 0, self.options.bottom_margin, left_margin);
            self.proxy.?.commit();
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
        if (self.ready) |ready| if (!ready(self.data, self)) return;
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
        const surface = self.proxy.?;
        self.buffer_scale = scale;
        if (self.options.clear_buffer) @memset(buffer.pixels(), 0);
        self.paint(self.data, .{ .pixels = buffer.pixels(), .width = width, .height = height });
        if (self.next_frame != null) {
            const callback = surface.frame();
            self.frame_callback = callback;
            callback.listen(Surface, self, frameDone);
        }
        surface.set_buffer_scale(@intCast(scale));
        if (self.options.fully_opaque) {
            const region = self.client.compositor.?.create_region();
            region.add(0, 0, @intCast(self.width), @intCast(self.height));
            surface.set_opaque_region(region);
            region.destroy();
        }
        surface.attach(buffer.shm.buffer, 0, 0);
        surface.damage(0, 0, @intCast(self.width), @intCast(self.height));
        buffer.busy = true;
        self.pending = false;
        surface.commit();
        self.client.flush();
    }
    fn frameDone(self: *Surface, _: wl.wl_callback, event: wl.wl_callback.Event) void {
        // The callback is gone once done arrives; the runtime retires it.
        self.frame_callback = null;
        if (self.next_frame) |next| if (next(self.data, self, event.done.callback_data)) {
            self.pending = true;
        };
        self.render() catch |err| std.log.err("native surface frame: {s}", .{@errorName(err)});
    }
    fn layerEvent(self: *Surface, layer: wl.zwlr_layer_surface_v1, event: wl.zwlr_layer_surface_v1.Event) void {
        switch (event) {
            .configure => |value| {
                layer.ack_configure(value.serial);
                const next_width = if (value.width == 0) self.options.width else value.width;
                const next_height = if (value.height == 0) self.options.height else value.height;
                const changed = !self.configured or self.width != next_width or self.height != next_height;
                self.width = next_width;
                self.height = next_height;
                self.configured = true;
                // Layout can be configured again after any layer commits. Acknowledge
                // unchanged geometry without creating a commit/configure feedback loop.
                if (changed) self.redraw() else self.client.flush();
            },
            .closed => self.hide(),
        }
    }
    fn xdgEvent(self: *Surface, xdg: wl.xdg_surface, event: wl.xdg_surface.Event) void {
        xdg.ack_configure(event.configure.serial);
        self.width = self.pending_width;
        self.height = self.pending_height;
        self.configured = true;
        self.redraw();
    }
    fn toplevelEvent(self: *Surface, _: wl.xdg_toplevel, event: wl.xdg_toplevel.Event) void {
        switch (event) {
            .configure => |value| {
                if (value.width > 0) self.pending_width = @intCast(value.width);
                if (value.height > 0) self.pending_height = @intCast(value.height);
            },
            .close => {
                self.hide();
                if (self.close) |callback| callback(self.data);
            },
            else => {},
        }
    }
    fn parentEvent(self: *Surface, imported: wl.zxdg_imported_v2, _: wl.zxdg_imported_v2.Event) void {
        imported.destroy();
        self.imported_parent = null;
    }
};

test "native buffer bounds reject empty images and oversized allocations" {
    try std.testing.expectError(error.SurfaceTooLarge, bufferSize(0, 1));
    try std.testing.expectError(error.SurfaceTooLarge, bufferSize(16385, 1));
    try std.testing.expectError(error.SurfaceTooLarge, bufferSize(16384, 16384));
    try std.testing.expectEqual(@as(usize, 3840 * 2160 * 4), try bufferSize(3840, 2160));
}

test "integration: passive clients do not bind input seats or accept interactive surfaces" {
    if (!@import("options").integration_tests) return error.SkipZigTest;
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

test "integration: frame callbacks coalesce redraws, finish animation and cancel on hide" {
    if (!@import("options").integration_tests) return error.SkipZigTest;
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
    const deadline = c.__zig.monotonicTime() + 2_000_000;
    while (state.paints == 0 and c.__zig.monotonicTime() < deadline) {
        while (c.g_main_context_iteration(null, 0) != 0) {}
        c.g_usleep(1000);
    }
    try std.testing.expect(surface.frame_callback != null);
    const paints = state.paints;
    for (0..20) |_| surface.redraw();
    try std.testing.expectEqual(paints, state.paints);
    try std.testing.expect(surface.pending);
    while ((state.frames < 4 or surface.frame_callback != null or surface.pending) and c.__zig.monotonicTime() < deadline) {
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
        const image = cairo.cairo_image_surface_create(cairo.CAIRO_FORMAT_ARGB32, @intCast(size), @intCast(size)).?;
        defer cairo.cairo_surface_destroy(image);
        cairo.cairo_surface_set_device_scale(image, @floatFromInt(scale), @floatFromInt(scale));
        const cr = cairo.cairo_create(image).?;
        defer cairo.cairo_destroy(cr);
        cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_CLEAR);
        cairo.cairo_paint(cr);
        cairo.cairo_set_operator(cr, cairo.CAIRO_OPERATOR_OVER);
        for ([_]f64{ 4, 2 }, 0..) |width, i| {
            const color: f64 = if (i == 0) 0 else 1;
            cairo.cairo_set_source_rgba(cr, color, color, color, 1);
            cairo.cairo_set_line_width(cr, width);
            cairo.cairo_move_to(cr, 12, 2);
            cairo.cairo_line_to(cr, 12, 22);
            cairo.cairo_move_to(cr, 2, 12);
            cairo.cairo_line_to(cr, 22, 12);
            cairo.cairo_stroke(cr);
        }
        cairo.cairo_surface_flush(image);

        const expected: [*]const u32 = @ptrCast(@alignCast(cairo.cairo_image_surface_get_data(image)));
        const pixels = try std.testing.allocator.alloc(u32, size * size);
        defer std.testing.allocator.free(pixels);
        raster.crosshair(pixels, scale);
        try std.testing.expectEqualSlices(u32, expected[0..pixels.len], pixels);
    }
}
