//! The native compositor: Wayland server state on desktop-wire-server.zig,
//! software composition with desktop-raster.zig, and no wlroots.
//!
//! Stage 1 serves a headless output: wl_compositor, wl_subcompositor, wl_shm,
//! wl_output, xdg-shell, xdg-output, wl_seat and a data device that accepts
//! requests. Shared-memory buffers are copied on commit and released at once,
//! so clients may reuse them immediately.
const std = @import("std");
const wire = @import("wayland-server-wire");
const ws = @import("wayland-server");
const raster = @import("desktop-raster.zig");
const util = @import("desktop-util.zig");
const libc = @import("desktop-libc.zig");
const keymap_text = @import("default-keymap").text;
const xkb = @import("desktop-xkb.zig");

const Rect = struct { x: i32 = 0, y: i32 = 0, width: i32 = 0, height: i32 = 0 };

fn create(comptime T: type, comp: *Compositor, value: T) ?*T {
    const ptr = comp.a.create(T) catch return null;
    ptr.* = value;
    return ptr;
}

fn removeItem(comptime T: type, list: *std.ArrayList(T), value: T) void {
    for (list.items, 0..) |item, index| if (std.meta.eql(item, value)) {
        _ = list.orderedRemove(index);
        return;
    };
}

fn nowMs() u32 {
    return @truncate(@as(u64, @intCast(@divTrunc(util.monotonicTime(), 1000))));
}

// ------------------------------------------------------------------ Buffers

const Pool = struct {
    comp: *Compositor,
    fd: wire.Fd,
    map: []const u8,
    refs: u32 = 1,

    fn unref(self: *Pool) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        if (self.map.len > 0) _ = libc.munmap(@constCast(self.map.ptr), self.map.len);
        _ = std.c.close(self.fd);
        self.comp.a.destroy(self);
    }

    fn remap(self: *Pool, size: usize) bool {
        const memory = libc.mmap(null, size, libc.PROT_READ, libc.MAP_SHARED, self.fd, 0) orelse return false;
        if (@intFromPtr(memory) == std.math.maxInt(usize)) return false;
        if (self.map.len > 0) _ = libc.munmap(@constCast(self.map.ptr), self.map.len);
        self.map = @as([*]const u8, @ptrCast(memory))[0..size];
        return true;
    }
};

const Buffer = struct {
    comp: *Compositor,
    resource: ws.wl_buffer,
    pool: *Pool,
    offset: usize,
    width: u32,
    height: u32,
    stride: usize,
    format: u32,

    /// Copies premultiplied ARGB into the buffer, as capture clients receive it.
    fn write(self: *Buffer, pixels: []const u32, opaque_pixels: bool) bool {
        if (self.bytes() == null) return false;
        const size = self.offset + self.stride * self.height;
        const memory = libc.mmap(null, size, libc.PROT_READ | libc.PROT_WRITE, libc.MAP_SHARED, self.pool.fd, 0) orelse return false;
        if (memory == libc.MAP_FAILED) return false;
        defer _ = libc.munmap(memory, size);
        const target: [*]u8 = @ptrCast(memory);
        for (0..self.height) |row| {
            const line = target[self.offset + row * self.stride ..][0 .. self.width * 4];
            for (pixels[row * self.width ..][0..self.width], 0..) |pixel, column| std.mem.writeInt(u32, line[column * 4 ..][0..4], if (opaque_pixels) pixel | 0xff000000 else pixel, .little);
        }
        return true;
    }

    /// The pixels, if the pool still holds them. A client that shrinks the
    /// file behind the mapping must not make the compositor fault.
    fn bytes(self: *Buffer) ?[]const u8 {
        const size = self.stride * self.height;
        if (self.offset + size > self.pool.map.len) return null;
        // The file must still cover the buffer, or reading it would fault.
        const end = std.os.linux.lseek(self.pool.fd, 0, std.os.linux.SEEK.END);
        if (std.os.linux.errno(end) != .SUCCESS or end < self.offset + size) return null;
        return self.pool.map[self.offset..][0..size];
    }
};

// ------------------------------------------------------------------ Surfaces

/// A wl_region: rectangles added and subtracted in order.
const Region = struct {
    ops: std.ArrayList(Op) = .empty,

    const Op = struct { rect: Rect, add: bool };

    fn contains(ops: []const Op, x: i32, y: i32) bool {
        var inside = false;
        for (ops) |op| {
            const r = op.rect;
            if (x >= r.x and y >= r.y and x < r.x +| r.width and y < r.y +| r.height) inside = op.add;
        }
        return inside;
    }

    fn handle(self: *Region, _: ws.wl_region, request: ws.wl_region.Request) void {
        const a = std.heap.c_allocator;
        switch (request) {
            .destroy => {},
            .add => |r| self.ops.append(a, .{ .rect = .{ .x = r.x, .y = r.y, .width = r.width, .height = r.height }, .add = true }) catch {},
            .subtract => |r| self.ops.append(a, .{ .rect = .{ .x = r.x, .y = r.y, .width = r.width, .height = r.height }, .add = false }) catch {},
        }
    }

    fn destroyed(self: *Region, _: ws.wl_region) void {
        self.ops.deinit(std.heap.c_allocator);
        std.heap.c_allocator.destroy(self);
    }
};

const Role = enum { none, toplevel, popup, subsurface, cursor, layer, lock };

const Surface = struct {
    comp: *Compositor,
    resource: ws.wl_surface,
    role: Role = .none,
    xdg: ?*XdgSurface = null,
    subsurface: ?*Subsurface = null,
    layer: ?*Layer = null,
    lock_surface: ?*LockSurface = null,
    /// Pending state, applied on commit.
    /// Input regions; null accepts input everywhere on the surface.
    pending_input: ?[]Region.Op = null,
    pending_input_set: bool = false,
    input: ?[]Region.Op = null,
    pending_buffer: ?*Buffer = null,
    pending_attach: bool = false,
    pending_dx: i32 = 0,
    pending_dy: i32 = 0,
    pending_scale: i32 = 1,
    pending_frames: std.ArrayList(ws.wl_callback) = .empty,
    pending_releases: std.ArrayList(ws.wl_callback) = .empty,
    /// Current content: premultiplied ARGB, buffer-sized.
    pixels: []u32 = &.{},
    width: u32 = 0,
    height: u32 = 0,
    opaque_format: bool = false,
    scale: i32 = 1,
    frames: std.ArrayList(ws.wl_callback) = .empty,
    /// Subsurfaces drawn above this surface, bottom to top.
    children: std.ArrayList(*Subsurface) = .empty,
    /// The output the surface is shown on.
    entered: ?*Output = null,
    /// wp_viewport destination size, which overrides buffer size / scale.
    pending_destination: ?[2]i32 = null,
    destination: ?[2]i32 = null,
    has_viewport: bool = false,
    fractional: ?ws.wp_fractional_scale_v1 = null,

    fn mapped(self: *const Surface) bool {
        return self.pixels.len > 0;
    }

    /// Size in surface-local (logical) coordinates.
    fn logicalWidth(self: *const Surface) i32 {
        if (self.destination) |size| return size[0];
        return @divTrunc(@as(i32, @intCast(self.width)), @max(1, self.scale));
    }
    fn logicalHeight(self: *const Surface) i32 {
        if (self.destination) |size| return size[1];
        return @divTrunc(@as(i32, @intCast(self.height)), @max(1, self.scale));
    }

    fn handle(self: *Surface, resource: ws.wl_surface, request: ws.wl_surface.Request) void {
        switch (request) {
            .destroy => {},
            .attach => |args| {
                self.pending_attach = true;
                self.pending_buffer = if (args.buffer) |buffer| buffer.data(Buffer) else null;
                if (resource.version() < 5) {
                    self.pending_dx = args.x;
                    self.pending_dy = args.y;
                } else if (args.x != 0 or args.y != 0) {
                    resource.postError(ws.wl_surface.Error.invalid_offset, "attach offsets are set with wl_surface.offset", .{});
                }
            },
            .offset => |args| {
                self.pending_dx = args.x;
                self.pending_dy = args.y;
            },
            .damage, .damage_buffer => {},
            .frame => |args| {
                args.callback.setHandler(Surface, self, null, null);
                self.pending_frames.append(self.comp.a, args.callback) catch {};
            },
            .get_release => |args| {
                args.callback.setHandler(Surface, self, null, null);
                self.pending_releases.append(self.comp.a, args.callback) catch {};
            },
            .set_input_region => |args| {
                // The region is copied now; later changes to it do not apply.
                if (self.pending_input) |ops| std.heap.c_allocator.free(ops);
                self.pending_input = if (args.region) |region| (if (region.data(Region)) |value| std.heap.c_allocator.dupe(Region.Op, value.ops.items) catch null else null) else null;
                self.pending_input_set = true;
            },
            .set_opaque_region, .set_buffer_transform => {},
            .set_buffer_scale => |args| {
                if (args.scale < 1) return resource.postError(ws.wl_surface.Error.invalid_scale, "buffer scale must be positive", .{});
                self.pending_scale = args.scale;
            },
            .commit => self.commit(),
        }
    }

    fn commit(self: *Surface) void {
        // Synchronized subsurfaces apply their state with the parent.
        if (self.subsurface) |sub| if (sub.synchronized()) {
            sub.has_cache = true;
            return;
        };
        self.apply();
    }

    fn apply(self: *Surface) void {
        if (self.pending_attach) {
            self.pending_attach = false;
            if (self.pending_buffer) |buffer| {
                self.copy(buffer);
                buffer.resource.sendRelease();
                // Buffers are copied at commit, so release callbacks fire with it.
                for (self.pending_releases.items) |callback| callback.sendDone(0);
                self.pending_releases.clearRetainingCapacity();
            } else {
                self.comp.a.free(self.pixels);
                self.pixels = &.{};
                self.width = 0;
                self.height = 0;
            }
            self.pending_buffer = null;
        }
        self.scale = self.pending_scale;
        self.destination = self.pending_destination;
        if (self.pending_input_set) {
            self.pending_input_set = false;
            if (self.input) |ops| std.heap.c_allocator.free(ops);
            self.input = self.pending_input;
            self.pending_input = null;
        }
        self.frames.appendSlice(self.comp.a, self.pending_frames.items) catch {};
        self.pending_frames.clearRetainingCapacity();
        for (self.children.items) |child| child.parentCommitted();
        if (self.xdg) |xdg| xdg.committed();
        if (self.layer) |layer| layer.committed();
        if (self.lock_surface) |lock_surface| lock_surface.committed();
        self.comp.scheduleRepaint();
    }

    fn copy(self: *Surface, buffer: *Buffer) void {
        const source = buffer.bytes() orelse {
            self.resource.postError(ws.wl_shm.Error.invalid_fd, "buffer storage shrank", .{});
            return;
        };
        const count = @as(usize, buffer.width) * buffer.height;
        if (self.pixels.len != count) {
            self.comp.a.free(self.pixels);
            self.pixels = self.comp.a.alloc(u32, count) catch {
                self.pixels = &.{};
                return;
            };
        }
        self.width = buffer.width;
        self.height = buffer.height;
        self.opaque_format = buffer.format == ws.wl_shm.Format.xrgb8888;
        for (0..buffer.height) |row| {
            const line = source[row * buffer.stride ..][0 .. buffer.width * 4];
            const out = self.pixels[row * buffer.width ..][0..buffer.width];
            for (out, 0..) |*pixel, column| {
                const value = std.mem.readInt(u32, line[column * 4 ..][0..4], .little);
                pixel.* = if (self.opaque_format) value | 0xff000000 else value;
            }
        }
    }

    fn destroyed(self: *Surface, _: ws.wl_surface) void {
        const comp = self.comp;
        if (self.xdg) |xdg| xdg.surfaceGone();
        if (self.subsurface) |sub| sub.surfaceGone();
        if (self.layer) |layer| layer.surfaceGone();
        if (self.lock_surface) |lock_surface| lock_surface.surfaceGone();
        if (self.input) |ops| std.heap.c_allocator.free(ops);
        if (self.pending_input) |ops| std.heap.c_allocator.free(ops);
        comp.seat.surfaceGone(self);
        for (comp.idle_inhibitors.items) |inhibitor| if (inhibitor.surface == self) {
            inhibitor.surface = null;
        };
        comp.updateInhibition();
        for (self.children.items) |child| child.parent = null;
        self.children.deinit(comp.a);
        for (self.frames.items) |callback| callback.destroyResource();
        for (self.pending_frames.items) |callback| callback.destroyResource();
        for (self.pending_releases.items) |callback| callback.destroyResource();
        self.pending_releases.deinit(comp.a);
        self.frames.deinit(comp.a);
        self.pending_frames.deinit(comp.a);
        comp.a.free(self.pixels);
        removeItem(*Surface, &comp.surfaces, self);
        if (comp.seat.keyboard_focus == self) comp.seat.keyboard_focus = null;
        if (comp.seat.cursor == self) comp.seat.cursor = null;
        comp.scheduleRepaint();
        comp.a.destroy(self);
    }

    /// Whether surface-local (x, y) accepts input.
    fn accepts(self: *const Surface, x: i32, y: i32) bool {
        if (!self.mapped() or x < 0 or y < 0 or x >= self.logicalWidth() or y >= self.logicalHeight()) return false;
        return if (self.input) |ops| Region.contains(ops, x, y) else true;
    }

    /// The topmost surface of this tree under (x, y), relative to this surface's origin.
    fn hit(self: *Surface, x: i32, y: i32) ?Hit {
        var index = self.children.items.len;
        while (index > 0) {
            index -= 1;
            const child = self.children.items[index];
            const surface = child.surface orelse continue;
            if (surface.hit(x - child.x, y - child.y)) |found| return found;
        }
        if (self.accepts(x, y)) return .{ .surface = self, .x = x, .y = y };
        return null;
    }

    /// Draws this surface and its subsurfaces with its origin at (x, y).
    /// Coordinates are logical; `scale` converts them to output pixels.
    fn draw(self: *Surface, target: raster.Buffer, x: i32, y: i32, scale: f64) void {
        if (self.mapped()) {
            const image: raster.Image = .{ .pixels = std.mem.sliceAsBytes(self.pixels), .width = self.width, .height = self.height, .stride = self.width * 4, .format = .argb };
            const fx: f64 = @floatFromInt(x);
            const fy: f64 = @floatFromInt(y);
            raster.blit(target, image, .{ .x = @round(fx * scale), .y = @round(fy * scale), .width = @round(@as(f64, @floatFromInt(self.logicalWidth())) * scale), .height = @round(@as(f64, @floatFromInt(self.logicalHeight())) * scale) }, null) catch {};
        }
        for (self.children.items) |child| if (child.surface) |surface| surface.draw(target, x + child.x, y + child.y, scale);
    }
};

const Subsurface = struct {
    comp: *Compositor,
    resource: ws.wl_subsurface,
    surface: ?*Surface,
    parent: ?*Surface,
    x: i32 = 0,
    y: i32 = 0,
    pending_x: i32 = 0,
    pending_y: i32 = 0,
    sync: bool = true,
    has_cache: bool = false,

    /// Synchronized itself or through any ancestor.
    fn synchronized(self: *const Subsurface) bool {
        if (self.sync) return true;
        var parent = self.parent;
        while (parent) |surface| {
            const sub = surface.subsurface orelse return false;
            if (sub.sync) return true;
            parent = sub.parent;
        }
        return false;
    }

    fn parentCommitted(self: *Subsurface) void {
        self.x = self.pending_x;
        self.y = self.pending_y;
        if (self.has_cache) {
            self.has_cache = false;
            if (self.surface) |surface| surface.apply();
        }
    }

    fn handle(self: *Subsurface, _: ws.wl_subsurface, request: ws.wl_subsurface.Request) void {
        switch (request) {
            .destroy => {},
            .set_position => |args| {
                self.pending_x = args.x;
                self.pending_y = args.y;
            },
            .place_above => |args| self.place(args.sibling, true),
            .place_below => |args| self.place(args.sibling, false),
            .set_sync => self.sync = true,
            .set_desync => {
                self.sync = false;
                if (!self.synchronized() and self.has_cache) {
                    self.has_cache = false;
                    if (self.surface) |surface| surface.apply();
                }
            },
        }
    }

    fn place(self: *Subsurface, sibling_resource: ws.wl_surface, above: bool) void {
        const parent = self.parent orelse return;
        const sibling = sibling_resource.data(Surface) orelse return;
        removeItem(*Subsurface, &parent.children, self);
        // The parent itself sorts below every child in this order.
        const index: usize = if (sibling == parent) 0 else for (parent.children.items, 0..) |child, i| {
            if (child.surface == sibling) break if (above) i + 1 else i;
        } else parent.children.items.len;
        parent.children.insert(self.comp.a, @min(index, parent.children.items.len), self) catch {};
    }

    fn surfaceGone(self: *Subsurface) void {
        if (self.parent) |parent| removeItem(*Subsurface, &parent.children, self);
        self.surface = null;
        self.parent = null;
    }

    fn destroyed(self: *Subsurface, _: ws.wl_subsurface) void {
        if (self.parent) |parent| removeItem(*Subsurface, &parent.children, self);
        if (self.surface) |surface| {
            surface.subsurface = null;
            surface.role = .none;
        }
        self.comp.scheduleRepaint();
        self.comp.a.destroy(self);
    }
};

// ------------------------------------------------------------------ xdg-shell

const Positioner = struct {
    width: i32 = 0,
    height: i32 = 0,
    anchor_rect: Rect = .{},
    anchor: u32 = 0,
    gravity: u32 = 0,
    adjustment: u32 = 0,
    offset_x: i32 = 0,
    offset_y: i32 = 0,

    fn handle(self: *Positioner, resource: ws.xdg_positioner, request: ws.xdg_positioner.Request) void {
        switch (request) {
            .destroy, .set_reactive, .set_parent_size, .set_parent_configure => {},
            .set_size => |args| {
                if (args.width < 1 or args.height < 1) return resource.postError(ws.xdg_positioner.Error.invalid_input, "positioner size must be positive", .{});
                self.width = args.width;
                self.height = args.height;
            },
            .set_anchor_rect => |args| {
                if (args.width < 0 or args.height < 0) return resource.postError(ws.xdg_positioner.Error.invalid_input, "negative anchor rectangle", .{});
                self.anchor_rect = .{ .x = args.x, .y = args.y, .width = args.width, .height = args.height };
            },
            .set_anchor => |args| self.anchor = args.anchor,
            .set_gravity => |args| self.gravity = args.gravity,
            .set_constraint_adjustment => |args| self.adjustment = args.constraint_adjustment,
            .set_offset => |args| {
                self.offset_x = args.x;
                self.offset_y = args.y;
            },
        }
    }

    fn destroyed(self: *Positioner, _: ws.xdg_positioner) void {
        std.heap.c_allocator.destroy(self);
    }

    /// The popup rectangle relative to the parent's window geometry, before constraints.
    fn place(self: Positioner) Rect {
        const r = self.anchor_rect;
        const A = ws.xdg_positioner.Anchor;
        var x = r.x + @divTrunc(r.width, 2);
        var y = r.y + @divTrunc(r.height, 2);
        switch (self.anchor) {
            A.left, A.top_left, A.bottom_left => x = r.x,
            A.right, A.top_right, A.bottom_right => x = r.x + r.width,
            else => {},
        }
        switch (self.anchor) {
            A.top, A.top_left, A.top_right => y = r.y,
            A.bottom, A.bottom_left, A.bottom_right => y = r.y + r.height,
            else => {},
        }
        const G = ws.xdg_positioner.Gravity;
        var left = x - @divTrunc(self.width, 2);
        var top = y - @divTrunc(self.height, 2);
        switch (self.gravity) {
            G.left, G.top_left, G.bottom_left => left = x - self.width,
            G.right, G.top_right, G.bottom_right => left = x,
            else => {},
        }
        switch (self.gravity) {
            G.top, G.top_left, G.top_right => top = y - self.height,
            G.bottom, G.bottom_left, G.bottom_right => top = y,
            else => {},
        }
        return .{ .x = left + self.offset_x, .y = top + self.offset_y, .width = self.width, .height = self.height };
    }

    /// Slides the popup into `bounds` (parent-relative) where the client allows it.
    fn constrain(self: Positioner, placed: Rect, bounds: Rect) Rect {
        var result = placed;
        const slide_x = self.adjustment & ws.xdg_positioner.ConstraintAdjustment.slide_x != 0;
        const slide_y = self.adjustment & ws.xdg_positioner.ConstraintAdjustment.slide_y != 0;
        if (slide_x) {
            if (result.x + result.width > bounds.x + bounds.width) result.x = bounds.x + bounds.width - result.width;
            if (result.x < bounds.x) result.x = bounds.x;
        }
        if (slide_y) {
            if (result.y + result.height > bounds.y + bounds.height) result.y = bounds.y + bounds.height - result.height;
            if (result.y < bounds.y) result.y = bounds.y;
        }
        return result;
    }
};

const XdgSurface = struct {
    comp: *Compositor,
    resource: ws.xdg_surface,
    surface: ?*Surface,
    toplevel: ?*Toplevel = null,
    popup: ?*Popup = null,
    geometry: ?Rect = null,
    pending_geometry: ?Rect = null,
    configure_serial: u32 = 0,
    acked: bool = false,
    initial_sent: bool = false,

    fn handle(self: *XdgSurface, resource: ws.xdg_surface, request: ws.xdg_surface.Request) void {
        const comp = self.comp;
        switch (request) {
            .destroy => {},
            .get_toplevel => |args| {
                const surface = self.surface orelse return;
                if (surface.role != .none and surface.role != .toplevel) return resource.postError(ws.xdg_wm_base.Error.role, "surface already has a role", .{});
                const toplevel = create(Toplevel, comp, .{ .comp = comp, .resource = args.id, .xdg = self }) orelse return;
                surface.role = .toplevel;
                self.toplevel = toplevel;
                args.id.setHandler(Toplevel, toplevel, Toplevel.handle, Toplevel.destroyed);
                if (args.id.version() >= 5) args.id.sendWmCapabilities(&.{});
            },
            .get_popup => |args| {
                const surface = self.surface orelse return;
                if (surface.role != .none and surface.role != .popup) return resource.postError(ws.xdg_wm_base.Error.role, "surface already has a role", .{});
                const positioner = args.positioner.data(Positioner) orelse return;
                const parent = if (args.parent) |p| p.data(XdgSurface) else null;
                const popup = create(Popup, comp, .{ .comp = comp, .resource = args.id, .xdg = self, .parent = parent, .positioner = positioner.* }) orelse return;
                surface.role = .popup;
                self.popup = popup;
                args.id.setHandler(Popup, popup, Popup.handle, Popup.destroyed);
                comp.popups.append(comp.a, popup) catch {};
            },
            .set_window_geometry => |args| {
                if (args.width < 1 or args.height < 1) return resource.postError(ws.xdg_surface.Error.invalid_size, "window geometry must be positive", .{});
                self.pending_geometry = .{ .x = args.x, .y = args.y, .width = args.width, .height = args.height };
            },
            .ack_configure => |args| {
                if (args.serial == self.configure_serial) self.acked = true;
            },
        }
    }

    fn sendConfigure(self: *XdgSurface) void {
        self.configure_serial = self.comp.server.nextSerial();
        self.resource.sendConfigure(self.configure_serial);
    }

    fn committed(self: *XdgSurface) void {
        if (self.pending_geometry) |geometry| self.geometry = geometry;
        const surface = self.surface orelse return;
        if (!self.initial_sent) {
            // The first commit asks for a configure; content may only follow its ack.
            if (surface.mapped()) return self.resource.postError(ws.xdg_surface.Error.unconfigured_buffer, "buffer attached before the first configure", .{});
            self.initial_sent = true;
            if (self.toplevel) |toplevel| toplevel.configure();
            if (self.popup) |popup| popup.configure();
            return;
        }
        if (self.toplevel) |toplevel| toplevel.mapChanged(surface.mapped() and self.acked);
        if (self.popup) |popup| popup.mapped = surface.mapped() and self.acked;
    }

    /// Window geometry, defaulting to the surface's own size.
    fn windowGeometry(self: *const XdgSurface) Rect {
        if (self.geometry) |geometry| return geometry;
        const surface = self.surface orelse return .{};
        return .{ .width = surface.logicalWidth(), .height = surface.logicalHeight() };
    }

    fn surfaceGone(self: *XdgSurface) void {
        if (self.toplevel) |toplevel| toplevel.mapChanged(false);
        if (self.popup) |popup| popup.mapped = false;
        self.surface = null;
    }

    fn destroyed(self: *XdgSurface, resource: ws.xdg_surface) void {
        if ((self.toplevel != null or self.popup != null) and !resource.client().closing)
            resource.postError(ws.xdg_surface.Error.defunct_role_object, "xdg_surface destroyed before its role object", .{});
        if (self.toplevel) |toplevel| toplevel.xdg = null;
        if (self.popup) |popup| popup.xdg = null;
        if (self.surface) |surface| surface.xdg = null;
        self.comp.a.destroy(self);
    }
};

const Toplevel = struct {
    comp: *Compositor,
    resource: ws.xdg_toplevel,
    xdg: ?*XdgSurface,
    title: []u8 = &.{},
    app_id: []u8 = &.{},
    x: i32 = 0,
    y: i32 = 0,
    mapped: bool = false,
    activated: bool = false,
    output: ?*Output = null,
    /// Windows open maximized to the usable area, as with the wlroots compositor.
    maximized: bool = true,
    fullscreen: bool = false,
    /// Super+Left and Super+Right tile a window to half of the usable area.
    tile: enum { none, left, right } = .none,
    parent: ?*Toplevel = null,
    min_size: [2]i32 = .{ 0, 0 },
    max_size: [2]i32 = .{ 0, 0 },
    /// The last configure sent, so unchanged layouts do not wake the client.
    sent: ?struct { width: i32, height: i32, states: u32, activated: bool } = null,
    handles: std.ArrayList(*ForeignHandle) = .empty,
    list_handles: std.ArrayList(*ListHandle) = .empty,
    sessions: std.ArrayList(*CaptureSession) = .empty,
    workspace: u32 = 0,
    /// Distinguishes windows in ext-foreign-toplevel-list and the overview protocol.
    serial: u64 = 0,
    id_buffer: [24]u8 = undefined,
    /// xdg-decoration: clients always decorate themselves, as with the wlroots compositor.
    decoration: ?ws.zxdg_toplevel_decoration_v1 = null,

    fn handle(self: *Toplevel, _: ws.xdg_toplevel, request: ws.xdg_toplevel.Request) void {
        const a = self.comp.a;
        switch (request) {
            .set_title => |args| {
                a.free(self.title);
                self.title = a.dupe(u8, args.title) catch &.{};
                for (self.handles.items) |h| {
                    h.resource.sendTitle(self.title);
                    h.resource.sendDone();
                }
                for (self.list_handles.items) |h| {
                    h.resource.sendTitle(self.title);
                    h.resource.sendDone();
                }
            },
            .set_app_id => |args| {
                a.free(self.app_id);
                self.app_id = a.dupe(u8, args.app_id) catch &.{};
                for (self.handles.items) |h| {
                    h.resource.sendAppId(self.app_id);
                    h.resource.sendDone();
                }
                for (self.list_handles.items) |h| {
                    h.resource.sendAppId(self.app_id);
                    h.resource.sendDone();
                }
            },
            .set_parent => |args| self.parent = if (args.parent) |p| p.data(Toplevel) else null,
            .set_min_size => |args| self.min_size = .{ args.width, args.height },
            .set_max_size => |args| self.max_size = .{ args.width, args.height },
            .set_maximized => self.requestState(.{ .maximized = true }),
            .unset_maximized => self.requestState(.{ .maximized = false }),
            .set_fullscreen => self.requestState(.{ .fullscreen = true }),
            .unset_fullscreen => self.requestState(.{ .fullscreen = false }),
            else => {},
        }
    }

    fn requestState(self: *Toplevel, change: struct { maximized: ?bool = null, fullscreen: ?bool = null }) void {
        if (change.maximized) |value| self.maximized = value;
        if (change.fullscreen) |value| self.fullscreen = value;
        if (self.xdg) |xdg| if (xdg.initial_sent) self.configure();
    }

    /// Dialogs keep their own size and are centred over the usable area.
    fn dialog(self: *const Toplevel) bool {
        return self.parent != null or (self.max_size[0] > 0 and self.max_size[1] > 0 and self.min_size[0] == self.max_size[0] and self.min_size[1] == self.max_size[1]);
    }

    fn area(self: *const Toplevel) Rect {
        const output = self.output orelse self.comp.primary() orelse return .{ .width = 1, .height = 1 };
        if (self.fullscreen) return output.box();
        var box = output.usable;
        if (self.tile != .none) {
            box.width = @divTrunc(box.width, 2);
            if (self.tile == .right) box.x += box.width;
        }
        return box;
    }

    /// Places the window: filling its area, or centred in it when it sizes itself.
    fn place(self: *Toplevel) void {
        const box = self.area();
        if (self.sized()) {
            self.x = box.x;
            self.y = box.y;
            return;
        }
        const geometry = if (self.xdg) |xdg| xdg.windowGeometry() else Rect{};
        self.x = box.x + @divTrunc(box.width - geometry.width, 2);
        self.y = @max(box.y, box.y + @divTrunc(box.height - geometry.height, 2));
    }

    fn sized(self: *const Toplevel) bool {
        return self.fullscreen or (self.maximized and !self.dialog());
    }

    /// Sends a configure if the size or states changed, or when `force` is set.
    fn reconfigure(self: *Toplevel, force: bool) void {
        const box = self.area();
        const width: i32 = if (self.sized()) @max(1, box.width) else 0;
        const height: i32 = if (self.sized()) @max(1, box.height) else 0;
        var bits: u32 = 0;
        if (self.maximized and !self.fullscreen and !self.dialog() and self.tile == .none) bits |= 1;
        if (self.fullscreen) bits |= 2;
        if (!force) if (self.sent) |last| {
            if (last.width == width and last.height == height and last.states == bits and last.activated == self.activated) return;
        };
        self.sent = .{ .width = width, .height = height, .states = bits, .activated = self.activated };
        var states: [3]u32 = undefined;
        var count: usize = 0;
        if (bits & 1 != 0) {
            states[count] = ws.xdg_toplevel.State.maximized;
            count += 1;
        }
        if (bits & 2 != 0) {
            states[count] = ws.xdg_toplevel.State.fullscreen;
            count += 1;
        }
        if (self.activated) {
            states[count] = ws.xdg_toplevel.State.activated;
            count += 1;
        }
        if (self.decoration) |decoration| decoration.sendConfigure(ws.zxdg_toplevel_decoration_v1.Mode.client_side);
        self.resource.sendConfigure(width, height, std.mem.sliceAsBytes(states[0..count]));
        if (self.xdg) |xdg| xdg.sendConfigure();
        for (self.handles.items) |h| h.describe(false);
        self.place();
        self.comp.scheduleRepaint();
    }

    fn configure(self: *Toplevel) void {
        self.reconfigure(true);
    }

    /// Tells window lists and capture sessions that the window went away.
    fn detachLists(self: *Toplevel) void {
        for (self.list_handles.items) |h| {
            h.resource.sendClosed();
            h.toplevel = null;
        }
        self.list_handles.clearRetainingCapacity();
        for (self.sessions.items) |session| session.stop();
        self.sessions.clearRetainingCapacity();
    }

    fn identifier(self: *Toplevel) []const u8 {
        return std.fmt.bufPrint(&self.id_buffer, "native-{d}", .{self.serial}) catch "native";
    }

    fn scale(self: *const Toplevel) f64 {
        const output = self.output orelse self.comp.primary() orelse return 1;
        return output.scale;
    }

    /// Draws the window geometry into `target` at the output scale.
    fn render(self: *Toplevel, target: raster.Buffer) bool {
        const xdg = self.xdg orelse return false;
        const surface = xdg.surface orelse return false;
        const geometry = xdg.windowGeometry();
        surface.draw(target, -geometry.x, -geometry.y, self.scale());
        return true;
    }

    fn mapChanged(self: *Toplevel, mapped: bool) void {
        if (mapped == self.mapped) return;
        const comp = self.comp;
        self.mapped = mapped;
        if (mapped) {
            if (self.output == null) self.output = comp.focusedOutput();
            self.reconfigure(false);
            self.place();
            comp.toplevels.append(comp.a, self) catch {};
            comp.recent.append(comp.a, self) catch {};
            for (comp.foreign_managers.items) |manager| ForeignHandle.announce(comp, manager, self);
            if (self.serial == 0) {
                comp.next_window +%= 1;
                self.serial = comp.next_window;
                self.workspace = comp.workspace;
            }
            for (comp.toplevel_lists.items) |list| ListHandle.announce(comp, list, self);
            if (self.output) |output| if (self.xdg) |xdg| if (xdg.surface) |surface| output.enter(surface);
            comp.focus(self);
            comp.updateInhibition();
        } else {
            removeItem(*Toplevel, &comp.toplevels, self);
            // A window closing while selected moves the selection on, as before.
            if (comp.cycle_selected == self) comp.cycle(false, comp.cycle_app);
            if (comp.cycle_origin == self) comp.cycle_origin = null;
            removeItem(*Toplevel, &comp.recent, self);
            for (self.handles.items) |h| {
                h.resource.sendClosed();
                h.toplevel = null;
            }
            self.handles.clearRetainingCapacity();
            self.detachLists();
            if (comp.focused == self) {
                comp.focused = null;
                comp.refocus();
            }
            comp.updateInhibition();
        }
        comp.scheduleRepaint();
    }

    fn destroyed(self: *Toplevel, _: ws.xdg_toplevel) void {
        self.mapChanged(false);
        if (self.xdg) |xdg| xdg.toplevel = null;
        if (self.comp.focused == self) self.comp.focused = null;
        if (self.comp.cycle_selected == self) self.comp.cycle_selected = null;
        if (self.comp.cycle_origin == self) self.comp.cycle_origin = null;
        self.comp.a.free(self.title);
        self.comp.a.free(self.app_id);
        for (self.handles.items) |h| h.toplevel = null;
        self.handles.deinit(self.comp.a);
        self.detachLists();
        self.list_handles.deinit(self.comp.a);
        self.sessions.deinit(self.comp.a);
        if (self.decoration) |decoration| decoration.setHandler(Toplevel, self, null, null);
        self.comp.a.destroy(self);
    }
};

const Popup = struct {
    comp: *Compositor,
    resource: ws.xdg_popup,
    xdg: ?*XdgSurface,
    parent: ?*XdgSurface,
    positioner: Positioner,
    /// Set when a layer surface adopts the popup with get_popup.
    layer_parent: ?*Layer = null,
    rect: Rect = .{},
    mapped: bool = false,

    fn handle(self: *Popup, _: ws.xdg_popup, request: ws.xdg_popup.Request) void {
        switch (request) {
            .destroy, .grab => {},
            .reposition => |args| {
                const positioner = args.positioner.data(Positioner) orelse return;
                self.positioner = positioner.*;
                self.resource.sendRepositioned(args.token);
                self.configure();
            },
        }
    }

    /// The window this popup ultimately belongs to, if any.
    fn toplevelRoot(self: *const Popup) ?*Toplevel {
        const parent = self.parent orelse return null;
        if (parent.toplevel) |toplevel| return toplevel;
        if (parent.popup) |popup| return popup.toplevelRoot();
        return null;
    }

    /// The parent's origin on the output and its window geometry offset.
    fn parentOrigin(self: *const Popup) ?[2]i32 {
        if (self.layer_parent) |layer| return .{ layer.rect.x, layer.rect.y };
        const parent = self.parent orelse return null;
        if (parent.toplevel) |toplevel| {
            const geometry = parent.windowGeometry();
            return .{ toplevel.x + geometry.x, toplevel.y + geometry.y };
        }
        if (parent.popup) |popup| {
            const origin = popup.parentOrigin() orelse return null;
            return .{ origin[0] + popup.rect.x, origin[1] + popup.rect.y };
        }
        return null;
    }

    fn configure(self: *Popup) void {
        const placed = self.positioner.place();
        const origin = self.parentOrigin() orelse .{ 0, 0 };
        const output = (if (self.layer_parent) |layer| layer.output else if (self.toplevelRoot()) |toplevel| toplevel.output else null) orelse self.comp.primary();
        const area = if (output) |o| o.box() else Rect{ .width = 1, .height = 1 };
        const bounds: Rect = .{ .x = area.x - origin[0], .y = area.y - origin[1], .width = area.width, .height = area.height };
        self.rect = self.positioner.constrain(placed, bounds);
        self.resource.sendConfigure(self.rect.x, self.rect.y, self.rect.width, self.rect.height);
        if (self.xdg) |xdg| xdg.sendConfigure();
    }

    fn destroyed(self: *Popup, _: ws.xdg_popup) void {
        removeItem(*Popup, &self.comp.popups, self);
        if (self.xdg) |xdg| xdg.popup = null;
        self.comp.scheduleRepaint();
        self.comp.a.destroy(self);
    }
};

// ------------------------------------------------------------------ Layer shell

const Layer = struct {
    comp: *Compositor,
    resource: ws.zwlr_layer_surface_v1,
    surface: ?*Surface,
    output: *Output,
    namespace: []u8,
    pending: Config,
    current: Config,
    /// Arranged position and size on the output.
    rect: Rect = .{},
    configured: ?[2]u32 = null,
    configure_serial: u32 = 0,
    acked: bool = false,
    initial_sent: bool = false,
    mapped: bool = false,
    /// Sent closed when its output went away; the client must destroy it.
    closed: bool = false,
    /// The overview's live window previews, applied with its surface commits.
    preview_owner: ?*OverviewControl = null,
    pending_previews: std.ArrayList(Preview) = .empty,
    previews: std.ArrayList(Preview) = .empty,
    previews_pending: bool = false,

    const Config = struct {
        layer: u32,
        width: u32 = 0,
        height: u32 = 0,
        anchor: u32 = 0,
        zone: i32 = 0,
        /// Top, right, bottom, left.
        margin: [4]i32 = .{ 0, 0, 0, 0 },
        interactivity: u32 = 0,
    };

    const A = ws.zwlr_layer_surface_v1.Anchor;

    fn handle(self: *Layer, resource: ws.zwlr_layer_surface_v1, request: ws.zwlr_layer_surface_v1.Request) void {
        switch (request) {
            .destroy => {},
            .set_size => |args| {
                self.pending.width = args.width;
                self.pending.height = args.height;
            },
            .set_anchor => |args| {
                if (args.anchor > 15) return resource.postError(ws.zwlr_layer_surface_v1.Error.invalid_anchor, "invalid anchor", .{});
                self.pending.anchor = args.anchor;
            },
            .set_exclusive_zone => |args| self.pending.zone = args.zone,
            .set_margin => |args| self.pending.margin = .{ args.top, args.right, args.bottom, args.left },
            .set_keyboard_interactivity => |args| {
                if (args.keyboard_interactivity > 2) return resource.postError(ws.zwlr_layer_surface_v1.Error.invalid_keyboard_interactivity, "invalid keyboard interactivity", .{});
                self.pending.interactivity = args.keyboard_interactivity;
            },
            .set_layer => |args| {
                if (args.layer > 3) return resource.postError(ws.zwlr_layer_shell_v1.Error.invalid_layer, "invalid layer", .{});
                self.pending.layer = args.layer;
            },
            .get_popup => |args| if (args.popup.data(Popup)) |popup| {
                popup.layer_parent = self;
                popup.configure();
            },
            .ack_configure => |args| {
                if (args.serial == self.configure_serial) self.acked = true;
            },
        }
    }

    fn committed(self: *Layer) void {
        const surface = self.surface orelse return;
        if (self.closed) return;
        if (self.previews_pending) {
            self.previews_pending = false;
            std.mem.swap(std.ArrayList(Preview), &self.previews, &self.pending_previews);
            self.pending_previews.clearRetainingCapacity();
        }
        const cfg = self.pending;
        const horizontal = cfg.anchor & (A.left | A.right) == A.left | A.right;
        const vertical = cfg.anchor & (A.top | A.bottom) == A.top | A.bottom;
        if ((cfg.width == 0 and !horizontal) or (cfg.height == 0 and !vertical))
            return self.resource.postError(ws.zwlr_layer_surface_v1.Error.invalid_size, "zero size needs opposite anchors", .{});
        self.current = cfg;
        if (!self.initial_sent) {
            if (surface.mapped()) return self.resource.postError(ws.zwlr_layer_shell_v1.Error.already_constructed, "buffer attached before the first configure", .{});
            self.initial_sent = true;
            self.comp.arrange();
            return;
        }
        const mapped = surface.mapped() and self.acked;
        const changed = mapped != self.mapped;
        self.mapped = mapped;
        self.comp.arrange();
        if (changed) {
            if (std.mem.eql(u8, self.namespace, "desktop-overview")) self.comp.broadcastOverview();
            if (mapped) self.output.enter(surface);
            if (!mapped and self.comp.focused_layer == self) self.comp.focused_layer = null;
            self.comp.updateKeyboardFocus();
        }
    }

    /// Places the surface within `bounds`, following anchors and margins.
    fn place(self: *Layer, bounds: Rect) Rect {
        const cfg = self.current;
        const m = cfg.margin;
        var box: Rect = .{ .width = @intCast(cfg.width), .height = @intCast(cfg.height) };
        const horizontal = cfg.anchor & (A.left | A.right) == A.left | A.right;
        const vertical = cfg.anchor & (A.top | A.bottom) == A.top | A.bottom;
        if (box.width == 0 and horizontal) {
            box.x = bounds.x + m[3];
            box.width = bounds.width - m[3] - m[1];
        } else if (horizontal or cfg.anchor & (A.left | A.right) == 0) {
            box.x = bounds.x + @divTrunc(bounds.width - box.width, 2);
        } else if (cfg.anchor & A.left != 0) {
            box.x = bounds.x + m[3];
        } else {
            box.x = bounds.x + bounds.width - box.width - m[1];
        }
        if (box.height == 0 and vertical) {
            box.y = bounds.y + m[0];
            box.height = bounds.height - m[0] - m[2];
        } else if (vertical or cfg.anchor & (A.top | A.bottom) == 0) {
            box.y = bounds.y + @divTrunc(bounds.height - box.height, 2);
        } else if (cfg.anchor & A.top != 0) {
            box.y = bounds.y + m[0];
        } else {
            box.y = bounds.y + bounds.height - box.height - m[2];
        }
        box.width = @max(box.width, 1);
        box.height = @max(box.height, 1);
        return box;
    }

    /// Shrinks `usable` by this surface's exclusive zone, if it claims an edge.
    fn exclude(self: *Layer, usable: *Rect) void {
        const cfg = self.current;
        if (cfg.zone <= 0) return;
        const m = cfg.margin;
        const edges = cfg.anchor;
        const horizontal = edges & (A.left | A.right);
        const vertical = edges & (A.top | A.bottom);
        // The zone applies to the single edge the surface is anchored to,
        // possibly stretched along it between the two perpendicular edges.
        if (edges & A.top != 0 and vertical == A.top and (horizontal == 0 or horizontal == A.left | A.right)) {
            usable.y += cfg.zone + m[0];
            usable.height -= cfg.zone + m[0];
        } else if (edges & A.bottom != 0 and vertical == A.bottom and (horizontal == 0 or horizontal == A.left | A.right)) {
            usable.height -= cfg.zone + m[2];
        } else if (edges & A.left != 0 and horizontal == A.left and (vertical == 0 or vertical == A.top | A.bottom)) {
            usable.x += cfg.zone + m[3];
            usable.width -= cfg.zone + m[3];
        } else if (edges & A.right != 0 and horizontal == A.right and (vertical == 0 or vertical == A.top | A.bottom)) {
            usable.width -= cfg.zone + m[1];
        }
    }

    fn close(self: *Layer) void {
        if (self.closed) return;
        self.closed = true;
        self.mapped = false;
        self.resource.sendClosed();
        for (self.comp.popups.items) |popup| if (popup.layer_parent == self and popup.mapped) popup.resource.sendPopupDone();
        if (self.comp.focused_layer == self) self.comp.focused_layer = null;
    }

    fn clearPreviews(self: *Layer) void {
        self.preview_owner = null;
        self.previews.clearRetainingCapacity();
        self.pending_previews.clearRetainingCapacity();
        self.previews_pending = false;
        self.comp.scheduleRepaint();
    }

    /// Draws each previewed window scaled into its rectangle, clipped and faded.
    fn drawPreviews(self: *Layer, target: raster.Buffer, scale: f64) void {
        const comp = self.comp;
        const s = scale;
        for (self.previews.items) |preview| {
            const toplevel = comp.findWindow(preview.id[0..preview.id_len]) orelse continue;
            const size = CaptureSession.size(toplevel);
            const pixels = comp.a.alloc(u32, @as(usize, size[0]) * size[1]) catch continue;
            defer comp.a.free(pixels);
            @memset(pixels, 0);
            if (!toplevel.render(.{ .pixels = pixels, .width = size[0], .height = size[1] })) continue;
            const v = preview.values;
            const ox: f64 = @floatFromInt(self.rect.x - self.output.x);
            const oy: f64 = @floatFromInt(self.rect.y - self.output.y);
            const image: raster.Image = .{ .pixels = std.mem.sliceAsBytes(pixels), .width = size[0], .height = size[1], .stride = size[0] * 4, .format = .argb };
            const clip: raster.Region = .{ .x = @intFromFloat(@floor((ox + v[4]) * s)), .y = @intFromFloat(@floor((oy + v[5]) * s)), .width = @intFromFloat(@ceil(v[6] * s)), .height = @intFromFloat(@ceil(v[7] * s)) };
            raster.blitWithOptions(target, image, .{ .x = (ox + v[0]) * s, .y = (oy + v[1]) * s, .width = v[2] * s, .height = v[3] * s }, .{ .clip = clip, .opacity = v[8], .filter = .bilinear }) catch {};
        }
    }

    fn configure(self: *Layer) void {
        const size: [2]u32 = .{ @intCast(self.rect.width), @intCast(self.rect.height) };
        if (self.configured) |last| if (last[0] == size[0] and last[1] == size[1]) return;
        self.configured = size;
        self.configure_serial = self.comp.server.nextSerial();
        self.resource.sendConfigure(self.configure_serial, size[0], size[1]);
    }

    fn surfaceGone(self: *Layer) void {
        self.surface = null;
        self.mapped = false;
        if (self.comp.focused_layer == self) self.comp.focused_layer = null;
        self.comp.arrange();
        self.comp.updateKeyboardFocus();
    }

    fn destroyed(self: *Layer, _: ws.zwlr_layer_surface_v1) void {
        const comp = self.comp;
        removeItem(*Layer, &comp.layers, self);
        for (comp.popups.items) |popup| if (popup.layer_parent == self) {
            popup.layer_parent = null;
        };
        if (self.surface) |surface| {
            surface.layer = null;
            surface.role = .none;
        }
        if (comp.focused_layer == self) comp.focused_layer = null;
        comp.a.free(self.namespace);
        self.previews.deinit(comp.a);
        self.pending_previews.deinit(comp.a);
        if (std.mem.eql(u8, self.namespace, "desktop-overview") and self.mapped) comp.broadcastOverview();
        comp.a.destroy(self);
        comp.arrange();
        comp.updateKeyboardFocus();
        comp.scheduleRepaint();
    }
};

// ------------------------------------------------------------------ Output

const Output = struct {
    comp: *Compositor,
    name_buffer: [16]u8 = undefined,
    name_len: usize = 0,
    /// Position in the global logical layout.
    x: i32 = 0,
    y: i32 = 0,
    width: u32,
    height: u32,
    /// Fractional; wl_output and preferred_buffer_scale advertise it rounded up.
    scale: f64 = 1,
    pixels: []u32,
    /// The output area left after layer surfaces' exclusive zones, in global coordinates.
    usable: Rect = .{},
    resources: std.ArrayList(ws.wl_output) = .empty,
    xdg_outputs: std.ArrayList(ws.zxdg_output_v1) = .empty,
    repaint: *wire.Loop.Source = undefined,
    scheduled: bool = false,
    /// Frames rendered so far; tests wait on it.
    frames: u64 = 0,
    /// The lock serial of the last frame drawn while locked.
    lock_serial: u32 = 0,
    enabled: bool = true,
    global: ?*wire.Global = null,

    fn create(comp: *Compositor, index: usize, width: u32, height: u32) !*Output {
        const self = try comp.a.create(Output);
        errdefer comp.a.destroy(self);
        self.* = .{ .comp = comp, .width = width, .height = height, .pixels = try comp.a.alloc(u32, @as(usize, width) * height) };
        errdefer comp.a.free(self.pixels);
        self.name_len = (std.fmt.bufPrint(&self.name_buffer, "HEADLESS-{d}", .{index + 1}) catch unreachable).len;
        self.repaint = try comp.server.loop.timer(self, &repaintReady);
        self.global = try comp.server.createGlobal(&ws.wl_output.interface, 4, self, &bind);
        return self;
    }

    fn destroy(self: *Output) void {
        const a = self.comp.a;
        self.resources.deinit(a);
        self.xdg_outputs.deinit(a);
        a.free(self.pixels);
        a.destroy(self);
    }

    fn name(self: *const Output) []const u8 {
        return self.name_buffer[0..self.name_len];
    }

    /// The output's area in global logical coordinates.
    fn box(self: *const Output) Rect {
        return .{ .x = self.x, .y = self.y, .width = self.logicalWidth(), .height = self.logicalHeight() };
    }

    fn contains(self: *const Output, x: f64, y: f64) bool {
        const b = self.box();
        return x >= @as(f64, @floatFromInt(b.x)) and y >= @as(f64, @floatFromInt(b.y)) and x < @as(f64, @floatFromInt(b.x + b.width)) and y < @as(f64, @floatFromInt(b.y + b.height));
    }

    fn bind(data: ?*anyopaque, resource: wire.Resource) void {
        const self: *Output = @ptrCast(@alignCast(data));
        const output: ws.wl_output = .{ .resource = resource };
        output.setHandler(Output, self, handle, destroyed);
        self.resources.append(self.comp.a, output) catch {};
        self.describe(output);
        // Mapped surfaces of this client are on the output.
        for (self.comp.surfaces.items) |surface| if (surface.entered == self and surface.resource.client() == output.client()) surface.resource.sendEnter(output);
    }

    fn describe(self: *Output, output: ws.wl_output) void {
        output.sendGeometry(self.x, self.y, 0, 0, ws.wl_output.Subpixel.unknown, "Headless", "Headless output", ws.wl_output.Transform.normal);
        output.sendMode(ws.wl_output.Mode.current | ws.wl_output.Mode.preferred, @intCast(self.width), @intCast(self.height), 60000);
        if (output.version() >= 2) output.sendScale(self.bufferScale());
        if (output.version() >= 4) {
            output.sendName(self.name());
            output.sendDescription("Headless output");
        }
        if (output.version() >= 2) output.sendDone();
    }

    fn logicalWidth(self: *const Output) i32 {
        return @intFromFloat(@round(@as(f64, @floatFromInt(self.width)) / self.scale));
    }
    fn logicalHeight(self: *const Output) i32 {
        return @intFromFloat(@round(@as(f64, @floatFromInt(self.height)) / self.scale));
    }

    fn bufferScale(self: *const Output) i32 {
        return @intFromFloat(@ceil(self.scale));
    }

    /// The scale in 120ths, as wp_fractional_scale_v1 reports it.
    fn fractionalScale(self: *const Output) u32 {
        return @intFromFloat(@round(self.scale * 120));
    }

    /// Re-announces geometry, mode and scale to wl_output and xdg-output clients.
    fn announce(self: *Output) void {
        for (self.xdg_outputs.items) |xdg_output| {
            xdg_output.sendLogicalPosition(self.x, self.y);
            xdg_output.sendLogicalSize(self.logicalWidth(), self.logicalHeight());
            if (xdg_output.version() < 3) xdg_output.sendDone();
        }
        for (self.resources.items) |output| self.describe(output);
        for (self.comp.surfaces.items) |surface| if (surface.entered == self) {
            if (surface.resource.version() >= 6) surface.resource.sendPreferredBufferScale(self.bufferScale());
            if (surface.fractional) |fractional| fractional.sendPreferredScale(self.fractionalScale());
        };
    }

    /// Changes the output's scale, mode or position and tells every client.
    fn configure(self: *Output, scale: f64, size: ?[2]u32, position: ?[2]i32) void {
        var changed = scale != self.scale;
        self.scale = scale;
        if (size) |dimensions| if (dimensions[0] != self.width or dimensions[1] != self.height) {
            const pixels = self.comp.a.alloc(u32, @as(usize, dimensions[0]) * dimensions[1]) catch return;
            self.comp.a.free(self.pixels);
            self.pixels = pixels;
            self.width = dimensions[0];
            self.height = dimensions[1];
            changed = true;
        };
        if (position) |point| if (point[0] != self.x or point[1] != self.y) {
            self.x = point[0];
            self.y = point[1];
            changed = true;
        };
        if (!changed) return;
        self.announce();
        self.comp.seat.clampPointer();
        self.comp.arrange();
        self.scheduleRepaint();
    }

    fn handle(_: *Output, _: ws.wl_output, _: ws.wl_output.Request) void {}

    fn destroyed(self: *Output, resource: ws.wl_output) void {
        removeItem(ws.wl_output, &self.resources, resource);
    }

    fn xdgOutputGone(self: *Output, resource: ws.zxdg_output_v1) void {
        removeItem(ws.zxdg_output_v1, &self.xdg_outputs, resource);
    }

    /// Sends wl_surface.enter for this output, and leave for the one it was on.
    fn enter(self: *Output, surface: *Surface) void {
        if (surface.entered == self) return;
        if (surface.entered) |old| for (old.resources.items) |output| {
            if (output.client() == surface.resource.client()) surface.resource.sendLeave(output);
        };
        surface.entered = self;
        for (self.resources.items) |output| if (output.client() == surface.resource.client()) surface.resource.sendEnter(output);
        if (surface.resource.version() >= 6) surface.resource.sendPreferredBufferScale(self.bufferScale());
        if (surface.fractional) |fractional| fractional.sendPreferredScale(self.fractionalScale());
    }

    fn scheduleRepaint(self: *Output) void {
        if (self.scheduled or !self.enabled) return;
        self.scheduled = true;
        // Composite at most once per 60 Hz frame, batching commits that arrive together.
        wire.Loop.arm(self.repaint, 16);
    }

    /// Draws pending commits now, as a capture of the next frame would show them.
    fn flush(self: *Output) void {
        if (!self.scheduled) return;
        self.scheduled = false;
        wire.Loop.arm(self.repaint, 0);
        self.render();
    }

    fn render(self: *Output) void {
        const comp = self.comp;
        if (!self.enabled) return;
        const target: raster.Buffer = .{ .pixels = self.pixels, .width = self.width, .height = self.height };
        @memset(self.pixels, if (comp.locked) 0xff000000 else comp.background);
        var roots: [256]Root = undefined;
        for (comp.stack(&roots)) |root| {
            root.surface.draw(target, root.x - self.x, root.y - self.y, self.scale);
            if (root.surface.layer) |layer| if (layer.previews.items.len > 0 and layer.output == self) layer.drawPreviews(target, self.scale);
        }
        if (comp.locked) {
            self.lock_serial = comp.lock_serial;
            if (comp.lock) |lock| lock.acknowledge();
        }
        self.frames += 1;
        const time = nowMs();
        for (comp.surfaces.items) |surface| {
            for (surface.frames.items) |callback| callback.sendDone(time);
            surface.frames.clearRetainingCapacity();
        }
    }

    fn repaintReady(data: ?*anyopaque, _: u32) void {
        const self: *Output = @ptrCast(@alignCast(data));
        self.scheduled = false;
        self.render();
    }
};

// ------------------------------------------------------------------ Keymaps

/// The byte range of a top-level keymap section such as `xkb_types "name" { ... };`.
fn keymapSection(text: []const u8, keyword: []const u8) ?struct { start: usize, end: usize } {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, keyword)) |start| {
        from = start + keyword.len;
        // Skip names that merely contain the keyword, such as xkb_types_extra.
        if (from < text.len and (std.ascii.isAlphanumeric(text[from]) or text[from] == '_')) continue;
        const open = std.mem.indexOfScalarPos(u8, text, from, '{') orelse return null;
        var depth: usize = 0;
        var index = open;
        var quoted = false;
        while (index < text.len) : (index += 1) {
            const char = text[index];
            if (char == '"') quoted = !quoted;
            if (quoted) continue;
            if (char == '{') depth += 1;
            if (char == '}') {
                depth -= 1;
                if (depth == 0) {
                    var end = index + 1;
                    while (end < text.len and text[end] != ';' and std.ascii.isWhitespace(text[end])) end += 1;
                    if (end < text.len and text[end] == ';') end += 1;
                    return .{ .start = start, .end = end };
                }
            }
        }
        return null;
    }
    return null;
}

/// Completes a client keymap whose sections include shared definitions,
/// as wtype's types and compatibility do, by substituting the compositor's
/// own compiled sections, so clients that read complete keymaps can use it.
/// Returns null when nothing needed replacing.
fn completeKeymap(a: std.mem.Allocator, text: []const u8) !?[]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(a);
    var changed = false;
    var rest = text;
    try result.ensureTotalCapacity(a, text.len + keymap_text.len);
    // Replace sections in the order they appear.
    while (true) {
        var next: ?struct { start: usize, end: usize, keyword: []const u8 } = null;
        for ([_][]const u8{ "xkb_keycodes", "xkb_types", "xkb_compatibility", "xkb_symbols" }) |keyword| {
            const found = keymapSection(rest, keyword) orelse continue;
            if (next == null or found.start < next.?.start) next = .{ .start = found.start, .end = found.end, .keyword = keyword };
        }
        const section = next orelse break;
        const body = rest[section.start..section.end];
        const replacement = if (std.mem.indexOf(u8, body, "include") != null) keymapSection(keymap_text, section.keyword) else null;
        try result.appendSlice(a, rest[0..section.start]);
        if (replacement) |own| {
            try result.appendSlice(a, keymap_text[own.start..own.end]);
            changed = true;
        } else {
            try result.appendSlice(a, body);
        }
        rest = rest[section.end..];
    }
    if (!changed) {
        result.deinit(a);
        return null;
    }
    try result.appendSlice(a, rest);
    return try result.toOwnedSlice(a);
}

/// A sealed, read-only keymap file for clients.
fn keymapFile(text: []const u8) ?Keymap {
    const fd = libc.memfd_create("desktop-keymap", 0x0001 | 0x0002); // MFD_CLOEXEC | MFD_ALLOW_SEALING
    if (fd < 0) return null;
    const size = text.len + 1;
    if (libc.ftruncate(fd, @intCast(size)) != 0) {
        _ = std.c.close(fd);
        return null;
    }
    var written: usize = 0;
    while (written < text.len) {
        const count = std.c.write(fd, text[written..].ptr, text.len - written);
        if (count <= 0) {
            _ = std.c.close(fd);
            return null;
        }
        written += @intCast(count);
    }
    _ = std.c.fcntl(fd, 1033, @as(c_int, 0x0001 | 0x0002 | 0x0004 | 0x0008)); // F_ADD_SEALS: SEAL, SHRINK, GROW, WRITE
    return .{ .fd = fd, .size = @intCast(size), .map = xkb.Keymap.parse(std.heap.c_allocator, text) catch null };
}

/// Reads a client keymap and returns one clients can parse, taking ownership of `fd`.
fn clientKeymap(a: std.mem.Allocator, fd: wire.Fd, size: u32) Keymap {
    var original: Keymap = .{ .fd = fd, .size = size };
    if (size == 0 or size > 1 << 20) return original;
    const memory = libc.mmap(null, size, libc.PROT_READ, libc.MAP_PRIVATE, fd, 0) orelse return original;
    if (memory == libc.MAP_FAILED) return original;
    defer _ = libc.munmap(memory, size);
    const bytes: [*]const u8 = @ptrCast(memory);
    const text = std.mem.sliceTo(bytes[0..size], 0);
    const completed = (completeKeymap(a, text) catch null) orelse {
        original.map = xkb.Keymap.parse(std.heap.c_allocator, text) catch null;
        return original;
    };
    defer a.free(completed);
    const file = keymapFile(completed) orelse return original;
    _ = std.c.close(fd);
    return file;
}

test "virtual keyboard keymaps that include shared types and compatibility are completed" {
    const wtype =
        \\xkb_keymap {
        \\xkb_keycodes "(unnamed)" {
        \\minimum = 8;
        \\maximum = 11;
        \\<K1> = 9;
        \\};
        \\xkb_types "(unnamed)" { include "complete" };
        \\xkb_compatibility "(unnamed)" { include "complete" };
        \\xkb_symbols "(unnamed)" {
        \\key <K1> {[U65E5]};
        \\};
        \\};
    ;
    const a = std.testing.allocator;
    const completed = (try completeKeymap(a, wtype)).?;
    defer a.free(completed);
    try std.testing.expect(std.mem.indexOf(u8, completed, "include") == null);
    try std.testing.expect(std.mem.indexOf(u8, completed, "key <K1> {[U65E5]};") != null);
    try std.testing.expect(std.mem.indexOf(u8, completed, "type \"ALPHABETIC\"") != null);
    // A keymap of includes only becomes the compositor's own.
    const includes = "xkb_keymap {\n xkb_keycodes { include \"evdev+aliases(qwerty)\" };\n xkb_types { include \"complete\" };\n xkb_compatibility { include \"complete\" };\n xkb_symbols { include \"pc+us+inet(evdev)\" };\n};";
    const own = (try completeKeymap(a, includes)).?;
    defer a.free(own);
    try std.testing.expect(std.mem.indexOf(u8, own, "include") == null);
    try std.testing.expect(std.mem.indexOf(u8, own, "<ESC>") != null);
    // A complete keymap is left alone.
    try std.testing.expect(try completeKeymap(a, keymap_text) == null);
}

// ------------------------------------------------------------------ Seat

const Hit = struct { surface: *Surface, x: i32, y: i32 };
/// A surface tree drawn at an output position.
const Root = struct { surface: *Surface, x: i32, y: i32 };

/// A keymap file served to clients, with its parsed form for compositor shortcuts.
const Keymap = struct {
    fd: wire.Fd = -1,
    size: u32 = 0,
    map: ?*xkb.Keymap = null,

    fn deinit(self: Keymap) void {
        if (self.map) |map| map.deinit();
        if (self.fd >= 0) _ = std.c.close(self.fd);
    }
};

const Seat = struct {
    comp: *Compositor,
    seats: std.ArrayList(ws.wl_seat) = .empty,
    keyboards: std.ArrayList(ws.wl_keyboard) = .empty,
    pointers: std.ArrayList(ws.wl_pointer) = .empty,
    keyboard_focus: ?*Surface = null,
    cursor: ?*Surface = null,
    default_keymap: Keymap = .{},
    /// The keymap clients last received; virtual keyboards bring their own.
    active_keymap: Keymap = .{},
    modifiers: [4]u32 = .{ 0, 0, 0, 0 },
    pointer_x: f64 = 0,
    pointer_y: f64 = 0,
    pointer_focus: ?*Surface = null,
    /// The focused surface's origin on the output.
    focus_origin: [2]f64 = .{ 0, 0 },
    buttons: u32 = 0,
    /// Keys a shortcut consumed; their release is withheld from clients too.
    consumed: [256]bool = @splat(false),
    /// Modifiers held by each pressed key, from the keymap's modifier_map.
    held: [256]u32 = @splat(0),

    fn init(self: *Seat) !void {
        self.default_keymap = keymapFile(keymap_text) orelse return error.Keymap;
        self.active_keymap = self.default_keymap;
    }

    fn deinit(self: *Seat) void {
        self.default_keymap.deinit();
        self.seats.deinit(self.comp.a);
        self.keyboards.deinit(self.comp.a);
        self.pointers.deinit(self.comp.a);
    }

    fn bind(data: ?*anyopaque, resource: wire.Resource) void {
        const self: *Seat = @ptrCast(@alignCast(data));
        const seat: ws.wl_seat = .{ .resource = resource };
        seat.setHandler(Seat, self, handle, destroyed);
        self.seats.append(self.comp.a, seat) catch {};
        seat.sendCapabilities(ws.wl_seat.Capability.pointer | ws.wl_seat.Capability.keyboard);
        if (seat.version() >= 2) seat.sendName("seat0");
    }

    fn handle(self: *Seat, _: ws.wl_seat, request: ws.wl_seat.Request) void {
        switch (request) {
            .get_keyboard => |args| {
                const keyboard = args.id;
                keyboard.setHandler(Seat, self, keyboardRequest, keyboardGone);
                self.keyboards.append(self.comp.a, keyboard) catch {};
                keyboard.sendKeymap(ws.wl_keyboard.KeymapFormat.xkb_v1, self.active_keymap.fd, self.active_keymap.size);
                if (keyboard.version() >= 4) keyboard.sendRepeatInfo(25, 600);
                if (self.keyboard_focus) |surface| if (surface.resource.client() == keyboard.client()) {
                    keyboard.sendEnter(self.comp.server.nextSerial(), surface.resource, &.{});
                    keyboard.sendModifiers(self.comp.server.nextSerial(), self.modifiers[0], self.modifiers[1], self.modifiers[2], self.modifiers[3]);
                };
            },
            .get_pointer => |args| {
                args.id.setHandler(Seat, self, pointerRequest, pointerGone);
                self.pointers.append(self.comp.a, args.id) catch {};
                if (self.pointer_focus) |surface| if (surface.resource.client() == args.id.client()) {
                    args.id.sendEnter(self.comp.server.nextSerial(), surface.resource, self.pointer_x - self.focus_origin[0], self.pointer_y - self.focus_origin[1]);
                    if (args.id.version() >= 5) args.id.sendFrame();
                };
            },
            .get_touch => |args| args.id.setHandler(Seat, self, null, null),
            .release => {},
        }
    }

    fn destroyed(self: *Seat, resource: ws.wl_seat) void {
        removeItem(ws.wl_seat, &self.seats, resource);
    }

    fn keyboardRequest(_: *Seat, _: ws.wl_keyboard, _: ws.wl_keyboard.Request) void {}

    fn keyboardGone(self: *Seat, resource: ws.wl_keyboard) void {
        removeItem(ws.wl_keyboard, &self.keyboards, resource);
    }

    fn pointerRequest(self: *Seat, _: ws.wl_pointer, request: ws.wl_pointer.Request) void {
        switch (request) {
            .set_cursor => |args| {
                const surface = if (args.surface) |s| s.data(Surface) else null;
                if (surface) |cursor| {
                    if (cursor.role != .none and cursor.role != .cursor) return args.surface.?.postError(ws.wl_pointer.Error.role, "surface already has a role", .{});
                    cursor.role = .cursor;
                }
                self.cursor = surface;
            },
            .release => {},
        }
    }

    fn pointerGone(self: *Seat, resource: ws.wl_pointer) void {
        removeItem(ws.wl_pointer, &self.pointers, resource);
    }

    fn surfaceGone(self: *Seat, surface: *Surface) void {
        if (self.keyboard_focus == surface) self.keyboard_focus = null;
        if (self.cursor == surface) self.cursor = null;
        if (self.pointer_focus == surface) {
            self.pointer_focus = null;
            self.buttons = 0;
        }
    }

    // -------------------------------------------------------------- Keyboard

    /// Moves keyboard focus, sending leave and enter to the affected clients.
    fn focusSurface(self: *Seat, surface: ?*Surface) void {
        if (self.keyboard_focus == surface) return;
        const server = self.comp.server;
        if (self.keyboard_focus) |old| for (self.keyboards.items) |keyboard| {
            if (keyboard.client() == old.resource.client()) keyboard.sendLeave(server.nextSerial(), old.resource);
        };
        self.keyboard_focus = surface;
        if (surface) |new| for (self.keyboards.items) |keyboard| {
            if (keyboard.client() != new.resource.client()) continue;
            keyboard.sendEnter(server.nextSerial(), new.resource, &.{});
            keyboard.sendModifiers(server.nextSerial(), self.modifiers[0], self.modifiers[1], self.modifiers[2], self.modifiers[3]);
        };
    }

    /// Sends `keymap` to every keyboard unless clients already have it.
    fn useKeymap(self: *Seat, keymap: Keymap) void {
        if (keymap.fd == self.active_keymap.fd) return;
        self.active_keymap = keymap;
        for (self.keyboards.items) |keyboard| keyboard.sendKeymap(ws.wl_keyboard.KeymapFormat.xkb_v1, keymap.fd, keymap.size);
        // Modifiers are re-read under the new keymap, as wlroots does when the seat changes keyboards.
        const surface = self.keyboard_focus orelse return;
        for (self.keyboards.items) |keyboard| {
            if (keyboard.client() == surface.resource.client()) keyboard.sendModifiers(self.comp.server.nextSerial(), self.modifiers[0], self.modifiers[1], self.modifiers[2], self.modifiers[3]);
        }
    }

    fn key(self: *Seat, keymap: Keymap, time: u32, code: u32, state: u32) void {
        self.comp.activity();
        self.useKeymap(keymap);
        const pressed = state == ws.wl_keyboard.KeyState.pressed;
        var handled = false;
        if (keymap.map) |map| {
            var xkb_state: xkb.State = .{ .keymap = map };
            xkb_state.update(self.modifiers[0], self.modifiers[1], self.modifiers[2], self.modifiers[3]);
            handled = self.comp.shortcut(xkb_state.keysym(code + 8), .{
                .shift = xkb_state.active("Shift"),
                .alt = xkb_state.active("Mod1"),
                .logo = xkb_state.active("Mod4"),
            }, pressed);
        }
        if (code < self.consumed.len) {
            if (pressed) self.consumed[code] = handled else {
                handled = self.consumed[code] or handled;
                self.consumed[code] = false;
            }
        }
        if (!handled) if (self.keyboard_focus) |surface| for (self.keyboards.items) |keyboard| {
            if (keyboard.client() == surface.resource.client()) keyboard.sendKey(self.comp.server.nextSerial(), time, code, state);
        };
        if (keymap.map) |map| self.trackModifiers(keymap, map, code, pressed);
    }

    /// Derives modifier state from modifier keys, as xkbcommon does for SetMods
    /// and LockMods: held keys set depressed modifiers, lock keys toggle locked ones.
    fn trackModifiers(self: *Seat, keymap: Keymap, map: *const xkb.Keymap, code: u32, pressed: bool) void {
        const mask = map.modifierMask(code + 8);
        if (mask == 0 or code >= self.held.len) return;
        var values = self.modifiers;
        if (pressed) {
            self.held[code] = mask;
            var xkb_state: xkb.State = .{ .keymap = map };
            xkb_state.update(values[0], values[1], values[2], values[3]);
            const sym = xkb_state.keysym(code + 8);
            if (sym == keysyms.Caps_Lock or sym == keysyms.Num_Lock) values[2] ^= mask;
        } else self.held[code] = 0;
        var depressed: u32 = 0;
        for (self.held) |held| depressed |= held;
        values[0] = depressed;
        if (std.mem.eql(u32, &values, &self.modifiers)) return;
        self.setModifiers(keymap, values);
    }

    fn setModifiers(self: *Seat, keymap: Keymap, values: [4]u32) void {
        self.useKeymap(keymap);
        self.modifiers = values;
        // Releasing Alt or Super confirms the switcher selection.
        if (self.comp.cycling) if (keymap.map) |map| {
            var xkb_state: xkb.State = .{ .keymap = map };
            xkb_state.update(values[0], values[1], values[2], values[3]);
            if (!xkb_state.active("Mod1") and !xkb_state.active("Mod4")) self.comp.finishCycle(false);
        };
        const surface = self.keyboard_focus orelse return;
        for (self.keyboards.items) |keyboard| {
            if (keyboard.client() == surface.resource.client()) keyboard.sendModifiers(self.comp.server.nextSerial(), values[0], values[1], values[2], values[3]);
        }
    }

    // --------------------------------------------------------------- Pointer

    /// Re-targets the pointer at the surface under it, sending leave and enter.
    fn updatePointerFocus(self: *Seat) void {
        const server = self.comp.server;
        const found = self.comp.surfaceAt(self.pointer_x, self.pointer_y);
        const target = if (found) |value| value.surface else null;
        if (found) |value| self.focus_origin = .{ @floor(self.pointer_x) - @as(f64, @floatFromInt(value.x)), @floor(self.pointer_y) - @as(f64, @floatFromInt(value.y)) };
        if (target == self.pointer_focus) return;
        if (self.pointer_focus) |old| for (self.pointers.items) |pointer| {
            if (pointer.client() != old.resource.client()) continue;
            pointer.sendLeave(server.nextSerial(), old.resource);
            if (pointer.version() >= 5) pointer.sendFrame();
        };
        self.pointer_focus = target;
        if (target) |new| for (self.pointers.items) |pointer| {
            if (pointer.client() != new.resource.client()) continue;
            pointer.sendEnter(server.nextSerial(), new.resource, self.pointer_x - self.focus_origin[0], self.pointer_y - self.focus_origin[1]);
            if (pointer.version() >= 5) pointer.sendFrame();
        };
    }

    /// Keeps the pointer on the output layout.
    fn clampPointer(self: *Seat) void {
        const b = self.comp.layoutBox();
        self.pointer_x = std.math.clamp(self.pointer_x, @as(f64, @floatFromInt(b.x)), @as(f64, @floatFromInt(b.x + b.width)) - 1);
        self.pointer_y = std.math.clamp(self.pointer_y, @as(f64, @floatFromInt(b.y)), @as(f64, @floatFromInt(b.y + b.height)) - 1);
    }

    fn moveTo(self: *Seat, x: f64, y: f64, time: u32) void {
        self.comp.activity();
        self.pointer_x = x;
        self.pointer_y = y;
        self.clampPointer();
        // An implicit grab keeps events on the pressed surface until release.
        if (self.buttons == 0) self.updatePointerFocus();
        const surface = self.pointer_focus orelse return;
        for (self.pointers.items) |pointer| {
            if (pointer.client() == surface.resource.client()) pointer.sendMotion(time, self.pointer_x - self.focus_origin[0], self.pointer_y - self.focus_origin[1]);
        }
    }

    fn button(self: *Seat, time: u32, code: u32, pressed: bool) void {
        self.comp.activity();
        if (pressed) {
            if (self.buttons == 0) {
                self.updatePointerFocus();
                self.comp.pointerPressed(self.pointer_focus);
            }
            self.buttons += 1;
        } else {
            self.buttons -|= 1;
        }
        if (self.pointer_focus) |surface| for (self.pointers.items) |pointer| {
            if (pointer.client() == surface.resource.client()) pointer.sendButton(self.comp.server.nextSerial(), time, code, if (pressed) 1 else 0);
        };
        if (!pressed and self.buttons == 0) self.updatePointerFocus();
    }

    fn axis(self: *Seat, time: u32, which: u32, value: f64, discrete: ?i32) void {
        self.comp.activity();
        const surface = self.pointer_focus orelse return;
        for (self.pointers.items) |pointer| {
            if (pointer.client() != surface.resource.client()) continue;
            if (discrete) |steps| {
                if (pointer.version() >= 8) pointer.sendAxisValue120(which, steps * 120) else if (pointer.version() >= 5) pointer.sendAxisDiscrete(which, steps);
            }
            pointer.sendAxis(time, which, value);
        }
    }

    fn frame(self: *Seat) void {
        const surface = self.pointer_focus orelse return;
        for (self.pointers.items) |pointer| {
            if (pointer.client() == surface.resource.client() and pointer.version() >= 5) pointer.sendFrame();
        }
    }
};

/// zwp_virtual_keyboard_v1: keys from a client, under the keymap it uploads.
const VirtualKeyboard = struct {
    comp: *Compositor,
    keymap: ?Keymap = null,

    fn handle(self: *VirtualKeyboard, resource: ws.zwp_virtual_keyboard_v1, request: ws.zwp_virtual_keyboard_v1.Request) void {
        const seat = &self.comp.seat;
        switch (request) {
            .keymap => |args| {
                self.release();
                self.keymap = clientKeymap(self.comp.a, args.fd, args.size);
            },
            .key => |args| {
                const keymap = self.keymap orelse return resource.postError(ws.zwp_virtual_keyboard_v1.Error.no_keymap, "no keymap set", .{});
                seat.key(keymap, args.time, args.key, args.state);
            },
            .modifiers => |args| {
                const keymap = self.keymap orelse return resource.postError(ws.zwp_virtual_keyboard_v1.Error.no_keymap, "no keymap set", .{});
                seat.setModifiers(keymap, .{ args.mods_depressed, args.mods_latched, args.mods_locked, args.group });
            },
            .destroy => {},
        }
    }

    /// Returns clients to the default keymap if this keyboard's was active.
    fn release(self: *VirtualKeyboard) void {
        const keymap = self.keymap orelse return;
        const seat = &self.comp.seat;
        if (seat.active_keymap.fd == keymap.fd) seat.useKeymap(seat.default_keymap);
        keymap.deinit();
        self.keymap = null;
    }

    fn destroyed(self: *VirtualKeyboard, _: ws.zwp_virtual_keyboard_v1) void {
        self.release();
        self.comp.a.destroy(self);
    }
};

/// zwlr_virtual_pointer_v1: pointer events from a client, as wlrctl sends.
const VirtualPointer = struct {
    comp: *Compositor,
    axis_discrete: [2]?i32 = .{ null, null },

    fn handle(self: *VirtualPointer, _: ws.zwlr_virtual_pointer_v1, request: ws.zwlr_virtual_pointer_v1.Request) void {
        const seat = &self.comp.seat;
        const area = self.comp.layoutBox();
        switch (request) {
            .motion => |args| seat.moveTo(seat.pointer_x + args.dx, seat.pointer_y + args.dy, args.time),
            .motion_absolute => |args| {
                if (args.x_extent == 0 or args.y_extent == 0) return;
                const x = @as(f64, @floatFromInt(area.x)) + @as(f64, @floatFromInt(args.x)) * @as(f64, @floatFromInt(area.width)) / @as(f64, @floatFromInt(args.x_extent));
                const y = @as(f64, @floatFromInt(area.y)) + @as(f64, @floatFromInt(args.y)) * @as(f64, @floatFromInt(area.height)) / @as(f64, @floatFromInt(args.y_extent));
                seat.moveTo(x, y, args.time);
            },
            .button => |args| seat.button(args.time, args.button, args.state != 0),
            .axis => |args| seat.axis(args.time, args.axis, args.value, null),
            .axis_discrete => |args| seat.axis(args.time, args.axis, args.value, args.discrete),
            .frame => seat.frame(),
            .axis_source, .axis_stop, .destroy => {},
        }
    }

    fn destroyed(self: *VirtualPointer, _: ws.zwlr_virtual_pointer_v1) void {
        self.comp.a.destroy(self);
    }
};

// ------------------------------------------------------------------ Foreign toplevels

/// A zwlr_foreign_toplevel_handle_v1 describing one window to a task list or wlrctl.
const ForeignHandle = struct {
    comp: *Compositor,
    resource: ws.zwlr_foreign_toplevel_handle_v1,
    toplevel: ?*Toplevel,

    fn handle(self: *ForeignHandle, _: ws.zwlr_foreign_toplevel_handle_v1, request: ws.zwlr_foreign_toplevel_handle_v1.Request) void {
        const toplevel = self.toplevel orelse return;
        switch (request) {
            .activate => {
                self.comp.focused_layer = null;
                self.comp.focus(toplevel);
            },
            .close => toplevel.resource.sendClose(),
            else => {},
        }
    }

    fn destroyed(self: *ForeignHandle, _: ws.zwlr_foreign_toplevel_handle_v1) void {
        if (self.toplevel) |toplevel| removeItem(*ForeignHandle, &toplevel.handles, self);
        self.comp.a.destroy(self);
    }

    /// Sends the window's state, then done.
    fn describe(self: *ForeignHandle, full: bool) void {
        const toplevel = self.toplevel orelse return;
        if (full) {
            self.resource.sendTitle(toplevel.title);
            self.resource.sendAppId(toplevel.app_id);
            if (toplevel.output) |on| for (on.resources.items) |output| if (output.client() == self.resource.client()) self.resource.sendOutputEnter(output);
        }
        var states: [1]u32 = undefined;
        var count: usize = 0;
        if (toplevel.activated) {
            states[count] = ws.zwlr_foreign_toplevel_handle_v1.State.activated;
            count += 1;
        }
        self.resource.sendState(std.mem.sliceAsBytes(states[0..count]));
        self.resource.sendDone();
    }

    /// Announces `toplevel` to one manager.
    fn announce(comp: *Compositor, manager: ws.zwlr_foreign_toplevel_manager_v1, toplevel: *Toplevel) void {
        const resource = manager.sendToplevel();
        if (!resource.alive()) return;
        const self = create(ForeignHandle, comp, .{ .comp = comp, .resource = resource, .toplevel = toplevel }) orelse return resource.destroyResource();
        toplevel.handles.append(comp.a, self) catch {
            comp.a.destroy(self);
            return resource.destroyResource();
        };
        resource.setHandler(ForeignHandle, self, handle, destroyed);
        self.describe(true);
    }
};

// ------------------------------------------------------------------ Screen capture

/// A zwlr_screencopy_frame_v1: one copy of the output, or a region of it, into a client buffer.
const CaptureFrame = struct {
    comp: *Compositor,
    output: *Output,
    rect: Rect,
    used: bool = false,

    fn handle(self: *CaptureFrame, resource: ws.zwlr_screencopy_frame_v1, request: ws.zwlr_screencopy_frame_v1.Request) void {
        switch (request) {
            .copy => |args| self.copy(resource, args.buffer, false),
            .copy_with_damage => |args| self.copy(resource, args.buffer, true),
            .destroy => {},
        }
    }

    fn copy(self: *CaptureFrame, resource: ws.zwlr_screencopy_frame_v1, buffer_resource: ws.wl_buffer, damage: bool) void {
        if (self.used) return resource.postError(ws.zwlr_screencopy_frame_v1.Error.already_used, "frame already used", .{});
        self.used = true;
        const buffer = buffer_resource.data(Buffer) orelse return resource.sendFailed();
        const width: u32 = @intCast(self.rect.width);
        const height: u32 = @intCast(self.rect.height);
        if (buffer.width != width or buffer.height != height or buffer.stride < width * 4 or (buffer.format != ws.wl_shm.Format.xrgb8888 and buffer.format != ws.wl_shm.Format.argb8888))
            return resource.postError(ws.zwlr_screencopy_frame_v1.Error.invalid_buffer, "buffer does not match the frame", .{});
        // Show pending commits, as the next frame would.
        const output = self.output;
        output.flush();
        const size = buffer.offset + buffer.stride * height;
        const memory = libc.mmap(null, size, libc.PROT_READ | libc.PROT_WRITE, libc.MAP_SHARED, buffer.pool.fd, 0) orelse return resource.sendFailed();
        if (memory == libc.MAP_FAILED) return resource.sendFailed();
        defer _ = libc.munmap(memory, size);
        if (buffer.bytes() == null) return resource.sendFailed();
        const bytes: [*]u8 = @ptrCast(memory);
        for (0..height) |row| {
            const source = output.pixels[(@as(usize, @intCast(self.rect.y)) + row) * output.width + @as(usize, @intCast(self.rect.x)) ..][0..width];
            const line = bytes[buffer.offset + row * buffer.stride ..][0 .. width * 4];
            for (source, 0..) |pixel, column| std.mem.writeInt(u32, line[column * 4 ..][0..4], pixel | 0xff000000, .little);
        }
        resource.sendFlags(0);
        if (damage) resource.sendDamage(0, 0, width, height);
        const now = util.monotonicTime();
        const seconds: u64 = @intCast(@divTrunc(now, std.time.us_per_s));
        resource.sendReady(@truncate(seconds >> 32), @truncate(seconds), @intCast(@mod(now, std.time.us_per_s) * 1000));
    }

    fn destroyed(self: *CaptureFrame, _: ws.zwlr_screencopy_frame_v1) void {
        self.comp.a.destroy(self);
    }

    fn start(comp: *Compositor, resource: ws.zwlr_screencopy_frame_v1, output_resource: ws.wl_output, logical: ?Rect) void {
        const output = comp.findOutput(output_resource) orelse {
            resource.setHandler(Compositor, comp, null, null);
            return resource.sendFailed();
        };
        const full: Rect = .{ .width = @intCast(output.width), .height = @intCast(output.height) };
        var rect = full;
        if (logical) |l| {
            // Regions are logical; the frame holds output pixels.
            const r: Rect = .{ .x = @intFromFloat(@floor(@as(f64, @floatFromInt(l.x)) * output.scale)), .y = @intFromFloat(@floor(@as(f64, @floatFromInt(l.y)) * output.scale)), .width = @intFromFloat(@ceil(@as(f64, @floatFromInt(l.width)) * output.scale)), .height = @intFromFloat(@ceil(@as(f64, @floatFromInt(l.height)) * output.scale)) };
            // Clip the requested region to the output.
            const x0 = std.math.clamp(r.x, 0, full.width);
            const y0 = std.math.clamp(r.y, 0, full.height);
            const x1 = std.math.clamp(r.x +| r.width, 0, full.width);
            const y1 = std.math.clamp(r.y +| r.height, 0, full.height);
            rect = .{ .x = x0, .y = y0, .width = x1 - x0, .height = y1 - y0 };
        }
        const self = create(CaptureFrame, comp, .{ .comp = comp, .output = output, .rect = rect }) orelse return;
        resource.setHandler(CaptureFrame, self, handle, destroyed);
        if (rect.width <= 0 or rect.height <= 0) return resource.sendFailed();
        resource.sendBuffer(ws.wl_shm.Format.xrgb8888, @intCast(rect.width), @intCast(rect.height), @intCast(rect.width * 4));
        if (resource.version() >= 3) resource.sendBufferDone();
    }
};

// ------------------------------------------------------------------ Output management

/// One zwlr_output_manager_v1, with the head and current mode it was shown per output.
const HeadManager = struct {
    comp: *Compositor,
    manager: ws.zwlr_output_manager_v1,
    heads: std.ArrayList(*Head) = .empty,

    const Head = struct {
        owner: ?*HeadManager,
        output: *Output,
        head: ?ws.zwlr_output_head_v1 = null,
        mode: ?ws.zwlr_output_mode_v1 = null,
        /// The mode size last announced; a custom size gets a new mode object.
        size: [2]u32 = .{ 0, 0 },

        fn request(_: *Head, _: ws.zwlr_output_head_v1, _: ws.zwlr_output_head_v1.Request) void {}
        fn modeRequest(_: *Head, _: ws.zwlr_output_mode_v1, _: ws.zwlr_output_mode_v1.Request) void {}

        fn gone(self: *Head, _: ws.zwlr_output_head_v1) void {
            self.head = null;
            if (self.owner) |owner| removeItem(*Head, &owner.heads, self);
            if (self.mode == null) std.heap.c_allocator.destroy(self);
        }

        fn modeGone(self: *Head, _: ws.zwlr_output_mode_v1) void {
            self.mode = null;
            if (self.head == null) std.heap.c_allocator.destroy(self);
        }

        /// Announces the current mode, as a new mode object when its size changed.
        fn announceMode(self: *Head) void {
            const head = self.head orelse return;
            const output = self.output;
            if (self.mode != null and self.size[0] == output.width and self.size[1] == output.height) return;
            if (self.mode) |old| {
                old.sendFinished();
                old.setHandler(Head, self, null, null);
                self.mode = null;
            }
            const mode = head.sendMode();
            if (!mode.alive()) return;
            mode.setHandler(Head, self, modeRequest, modeGone);
            self.mode = mode;
            self.size = .{ output.width, output.height };
            mode.sendSize(@intCast(output.width), @intCast(output.height));
            mode.sendRefresh(60000);
            mode.sendPreferred();
        }

        /// The state that configurations change.
        fn describe(self: *Head) void {
            const head = self.head orelse return;
            const output = self.output;
            head.sendEnabled(@intFromBool(output.enabled));
            if (!output.enabled) return;
            self.announceMode();
            if (self.mode) |current| head.sendCurrentMode(current);
            head.sendPosition(output.x, output.y);
            head.sendTransform(ws.wl_output.Transform.normal);
            head.sendScale(output.scale);
        }
    };

    fn announce(self: *HeadManager, output: *Output) void {
        const resource = self.manager.sendHead();
        if (!resource.alive()) return;
        const head = std.heap.c_allocator.create(Head) catch return resource.destroyResource();
        head.* = .{ .owner = self, .output = output, .head = resource };
        resource.setHandler(Head, head, Head.request, Head.gone);
        self.heads.append(self.comp.a, head) catch {};
        resource.sendName(output.name());
        resource.sendDescription("Headless output");
        resource.sendPhysicalSize(0, 0);
        head.describe();
        if (resource.version() >= 2) {
            resource.sendMake("Headless");
            resource.sendModel("Headless output");
        }
    }

    fn describe(self: *HeadManager) void {
        for (self.heads.items) |head| head.describe();
        self.manager.sendDone(self.comp.output_serial);
    }

    fn request(self: *HeadManager, resource: ws.zwlr_output_manager_v1, message: ws.zwlr_output_manager_v1.Request) void {
        switch (message) {
            .create_configuration => |args| {
                const config = create(OutputConfig, self.comp, .{ .comp = self.comp, .serial = args.serial }) orelse return;
                args.id.setHandler(OutputConfig, config, OutputConfig.handle, OutputConfig.destroyed);
            },
            .stop => {
                resource.sendFinished();
                resource.destroyResource();
            },
        }
    }

    fn destroyed(self: *HeadManager, _: ws.zwlr_output_manager_v1) void {
        for (self.heads.items) |head| head.owner = null;
        self.heads.deinit(self.comp.a);
        removeItem(*HeadManager, &self.comp.head_managers, self);
        self.comp.a.destroy(self);
    }
};

/// A zwlr_output_configuration_v1 being assembled by a client.
const OutputConfig = struct {
    comp: *Compositor,
    serial: u32,
    used: bool = false,
    heads: std.ArrayList(*ConfigHead) = .empty,
    disabled: std.ArrayList(*Output) = .empty,

    fn handle(self: *OutputConfig, resource: ws.zwlr_output_configuration_v1, request: ws.zwlr_output_configuration_v1.Request) void {
        const a = self.comp.a;
        switch (request) {
            .enable_head => |args| {
                if (self.used) return resource.postError(ws.zwlr_output_configuration_v1.Error.already_used, "configuration already used", .{});
                const head = args.head.data(HeadManager.Head) orelse return args.id.setHandler(OutputConfig, self, null, null);
                if (self.configures(head.output)) return resource.postError(ws.zwlr_output_configuration_v1.Error.already_configured_head, "head already configured", .{});
                const config_head = a.create(ConfigHead) catch return;
                config_head.* = .{ .comp = self.comp, .config = self, .output = head.output };
                self.heads.append(a, config_head) catch {};
                args.id.setHandler(ConfigHead, config_head, ConfigHead.handle, ConfigHead.destroyed);
            },
            .disable_head => |args| {
                const head = args.head.data(HeadManager.Head) orelse return;
                if (self.configures(head.output)) return resource.postError(ws.zwlr_output_configuration_v1.Error.already_configured_head, "head already configured", .{});
                self.disabled.append(a, head.output) catch {};
            },
            .apply => self.finish(resource, true),
            .@"test" => self.finish(resource, false),
            .destroy => {},
        }
    }

    fn configures(self: *OutputConfig, output: *Output) bool {
        for (self.heads.items) |head| if (head.output == output) return true;
        for (self.disabled.items) |disabled| if (disabled == output) return true;
        return false;
    }

    fn finish(self: *OutputConfig, resource: ws.zwlr_output_configuration_v1, apply: bool) void {
        if (self.used) return resource.postError(ws.zwlr_output_configuration_v1.Error.already_used, "configuration already used", .{});
        self.used = true;
        const comp = self.comp;
        if (self.serial != comp.output_serial) return resource.sendCancelled();
        for (self.heads.items) |head| {
            const scale = head.scale orelse head.output.scale;
            if (!std.math.isFinite(scale) or scale < 0.5 or scale > 4) return resource.sendFailed();
            if (head.size) |size| if (size[0] == 0 or size[1] == 0 or size[0] > 8192 or size[1] > 8192) return resource.sendFailed();
        }
        if (apply) {
            for (self.disabled.items) |output| comp.setOutputEnabled(output, false);
            for (self.heads.items) |head| {
                comp.setOutputEnabled(head.output, true);
                head.output.configure(head.scale orelse head.output.scale, head.size, head.position);
            }
            comp.outputChanged();
        }
        resource.sendSucceeded();
    }

    fn destroyed(self: *OutputConfig, _: ws.zwlr_output_configuration_v1) void {
        for (self.heads.items) |head| head.config = null;
        self.heads.deinit(self.comp.a);
        self.disabled.deinit(self.comp.a);
        self.comp.a.destroy(self);
    }
};

const ConfigHead = struct {
    comp: *Compositor,
    config: ?*OutputConfig,
    output: *Output,
    scale: ?f64 = null,
    size: ?[2]u32 = null,
    position: ?[2]i32 = null,

    fn handle(self: *ConfigHead, _: ws.zwlr_output_configuration_head_v1, request: ws.zwlr_output_configuration_head_v1.Request) void {
        switch (request) {
            .set_scale => |args| self.scale = args.scale,
            .set_mode => |args| if (args.mode.data(HeadManager.Head)) |head| {
                self.size = head.size;
            },
            .set_custom_mode => |args| if (args.width > 0 and args.height > 0) {
                self.size = .{ @intCast(args.width), @intCast(args.height) };
            },
            .set_position => |args| self.position = .{ args.x, args.y },
            .set_transform, .set_adaptive_sync => {},
        }
    }

    fn destroyed(self: *ConfigHead, _: ws.zwlr_output_configuration_head_v1) void {
        if (self.config) |config| removeItem(*ConfigHead, &config.heads, self);
        self.comp.a.destroy(self);
    }
};

// ------------------------------------------------------------------ Window list and capture

const workspace_count = 4;

/// An ext_foreign_toplevel_handle_v1; capture sources refer to windows through it.
const ListHandle = struct {
    comp: *Compositor,
    resource: ws.ext_foreign_toplevel_handle_v1,
    toplevel: ?*Toplevel,

    fn destroyed(self: *ListHandle, _: ws.ext_foreign_toplevel_handle_v1) void {
        if (self.toplevel) |toplevel| removeItem(*ListHandle, &toplevel.list_handles, self);
        self.comp.a.destroy(self);
    }

    fn describe(self: *ListHandle) void {
        const toplevel = self.toplevel orelse return;
        self.resource.sendIdentifier(toplevel.identifier());
        self.resource.sendTitle(toplevel.title);
        self.resource.sendAppId(toplevel.app_id);
        self.resource.sendDone();
    }

    fn announce(comp: *Compositor, list: ws.ext_foreign_toplevel_list_v1, toplevel: *Toplevel) void {
        const resource = list.sendToplevel();
        if (!resource.alive()) return;
        const self = create(ListHandle, comp, .{ .comp = comp, .resource = resource, .toplevel = toplevel }) orelse return resource.destroyResource();
        toplevel.list_handles.append(comp.a, self) catch {
            comp.a.destroy(self);
            return resource.destroyResource();
        };
        resource.setHandler(ListHandle, self, null, destroyed);
        self.describe();
    }
};

/// An ext_image_capture_source_v1 for one window.
const CaptureSource = struct {
    toplevel: ?*Toplevel,

    fn destroyed(self: *CaptureSource, _: ws.ext_image_capture_source_v1) void {
        std.heap.c_allocator.destroy(self);
    }
};

/// An ext_image_copy_capture_session_v1 copying one window.
const CaptureSession = struct {
    comp: *Compositor,
    resource: ws.ext_image_copy_capture_session_v1,
    toplevel: ?*Toplevel,
    width: u32 = 0,
    height: u32 = 0,

    /// Window geometry in output pixels.
    fn size(toplevel: *Toplevel) [2]u32 {
        const geometry = if (toplevel.xdg) |xdg| xdg.windowGeometry() else Rect{};
        const scale = toplevel.scale();
        const width: u32 = @intFromFloat(@max(1, @round(@as(f64, @floatFromInt(geometry.width)) * scale)));
        const height: u32 = @intFromFloat(@max(1, @round(@as(f64, @floatFromInt(geometry.height)) * scale)));
        return .{ width, height };
    }

    fn constraints(self: *CaptureSession) void {
        const toplevel = self.toplevel orelse return;
        const dimensions = size(toplevel);
        self.width = dimensions[0];
        self.height = dimensions[1];
        self.resource.sendBufferSize(self.width, self.height);
        self.resource.sendShmFormat(ws.wl_shm.Format.argb8888);
        self.resource.sendShmFormat(ws.wl_shm.Format.xrgb8888);
        self.resource.sendDone();
    }

    fn handle(self: *CaptureSession, _: ws.ext_image_copy_capture_session_v1, request: ws.ext_image_copy_capture_session_v1.Request) void {
        switch (request) {
            .create_frame => |args| {
                const frame = std.heap.c_allocator.create(CopyFrame) catch return;
                frame.* = .{ .session = self };
                args.frame.setHandler(CopyFrame, frame, CopyFrame.handle, CopyFrame.destroyed);
            },
            .destroy => {},
        }
    }

    fn stop(self: *CaptureSession) void {
        self.toplevel = null;
        self.resource.sendStopped();
    }

    fn destroyed(self: *CaptureSession, _: ws.ext_image_copy_capture_session_v1) void {
        if (self.toplevel) |toplevel| removeItem(*CaptureSession, &toplevel.sessions, self);
        self.comp.a.destroy(self);
    }
};

const CopyFrame = struct {
    session: ?*CaptureSession,
    buffer: ?*Buffer = null,
    captured: bool = false,

    fn handle(self: *CopyFrame, resource: ws.ext_image_copy_capture_frame_v1, request: ws.ext_image_copy_capture_frame_v1.Request) void {
        switch (request) {
            .attach_buffer => |args| self.buffer = args.buffer.data(Buffer),
            .damage_buffer, .destroy => {},
            .capture => {
                if (self.captured) return resource.postError(ws.ext_image_copy_capture_frame_v1.Error.already_captured, "frame already captured", .{});
                self.captured = true;
                self.copy(resource);
            },
        }
    }

    fn copy(self: *CopyFrame, resource: ws.ext_image_copy_capture_frame_v1) void {
        const Reason = ws.ext_image_copy_capture_frame_v1.FailureReason;
        const session = self.session orelse return resource.sendFailed(Reason.stopped);
        const toplevel = session.toplevel orelse return resource.sendFailed(Reason.stopped);
        const buffer = self.buffer orelse return resource.sendFailed(Reason.buffer_constraints);
        if (buffer.width != session.width or buffer.height != session.height or buffer.stride < buffer.width * 4 or (buffer.format != ws.wl_shm.Format.argb8888 and buffer.format != ws.wl_shm.Format.xrgb8888))
            return resource.sendFailed(Reason.buffer_constraints);
        const comp = session.comp;
        const pixels = comp.a.alloc(u32, @as(usize, buffer.width) * buffer.height) catch return resource.sendFailed(Reason.unknown);
        defer comp.a.free(pixels);
        @memset(pixels, 0);
        if (!toplevel.render(.{ .pixels = pixels, .width = buffer.width, .height = buffer.height })) return resource.sendFailed(Reason.unknown);
        if (!buffer.write(pixels, buffer.format == ws.wl_shm.Format.xrgb8888)) return resource.sendFailed(Reason.unknown);
        resource.sendTransform(ws.wl_output.Transform.normal);
        resource.sendDamage(0, 0, @intCast(buffer.width), @intCast(buffer.height));
        const now = util.monotonicTime();
        const seconds: u64 = @intCast(@divTrunc(now, std.time.us_per_s));
        resource.sendPresentationTime(@truncate(seconds >> 32), @truncate(seconds), @intCast(@mod(now, std.time.us_per_s) * 1000));
        resource.sendReady();
    }

    fn destroyed(self: *CopyFrame, _: ws.ext_image_copy_capture_frame_v1) void {
        std.heap.c_allocator.destroy(self);
    }
};

/// A live window drawn into the overview surface, from dotfiles_overview_v1 previews.
const Preview = struct {
    id: [128]u8 = @splat(0),
    id_len: usize = 0,
    /// Destination x, y, width, height, clip x, y, width, height, opacity.
    values: [9]f64 = @splat(0),
};

/// A dotfiles_overview_v1: workspaces, windows and live previews for the overview UI.
const OverviewControl = struct {
    comp: *Compositor,
    resource: ws.dotfiles_overview_v1,
    /// The overview layer whose pending previews this resource is building.
    building: ?*Layer = null,

    fn sendWorkspaces(self: *OverviewControl) void {
        const names = [_][]const u8{ "1", "2", "3", "4" };
        for (names, 0..) |name, index| self.resource.sendWorkspace(@intCast(index), name, @intFromBool(index == self.comp.workspace));
    }

    fn handle(self: *OverviewControl, resource: ws.dotfiles_overview_v1, request: ws.dotfiles_overview_v1.Request) void {
        const comp = self.comp;
        switch (request) {
            .destroy => {},
            .refresh => {
                self.sendWorkspaces();
                for (comp.toplevels.items) |toplevel| {
                    const geometry = if (toplevel.xdg) |xdg| xdg.windowGeometry() else Rect{};
                    resource.sendWindow(toplevel.identifier(), toplevel.workspace, toplevel.x, toplevel.y, geometry.width, geometry.height, 0);
                }
                resource.sendDone();
            },
            .activate => |args| if (comp.findWindow(args.identifier)) |toplevel| {
                comp.focused_layer = null;
                comp.focus(toplevel);
            },
            .close => |args| if (comp.findWindow(args.identifier)) |toplevel| toplevel.resource.sendClose(),
            .switch_workspace => |args| comp.switchWorkspace(args.index),
            .move => |args| if (args.index < workspace_count) if (comp.findWindow(args.identifier)) |toplevel| {
                toplevel.workspace = args.index;
                if (comp.focused == toplevel and args.index != comp.workspace) comp.refocus();
                comp.scheduleRepaint();
            },
            .begin_previews => |args| {
                self.building = null;
                const surface = (if (args.surface) |s| s.data(Surface) else null) orelse {
                    for (comp.layers.items) |layer| if (layer.preview_owner == self) layer.clearPreviews();
                    return;
                };
                const layer = surface.layer orelse return;
                if (!std.mem.eql(u8, layer.namespace, "desktop-overview") or surface.resource.client() != resource.client()) return;
                layer.preview_owner = self;
                layer.pending_previews.clearRetainingCapacity();
                layer.previews_pending = true;
                self.building = layer;
            },
            .preview => |args| {
                const layer = self.building orelse return;
                if (args.rectangles.len != 9 * 4 or args.identifier.len >= 128 or layer.pending_previews.items.len >= 512) return;
                var spec: Preview = .{ .id_len = args.identifier.len };
                @memcpy(spec.id[0..args.identifier.len], args.identifier);
                for (&spec.values, 0..) |*value, index| value.* = @as(f64, @floatFromInt(std.mem.readInt(i32, args.rectangles[index * 4 ..][0..4], .little))) / 256;
                if (spec.values[2] <= 0 or spec.values[3] <= 0 or spec.values[6] <= 0 or spec.values[7] <= 0) return;
                spec.values[8] = std.math.clamp(spec.values[8], 0, 1);
                layer.pending_previews.append(comp.a, spec) catch {};
            },
        }
    }

    fn destroyed(self: *OverviewControl, _: ws.dotfiles_overview_v1) void {
        const comp = self.comp;
        for (comp.layers.items) |layer| if (layer.preview_owner == self) layer.clearPreviews();
        removeItem(*OverviewControl, &comp.overviews, self);
        comp.a.destroy(self);
    }
};

// ------------------------------------------------------------------ Session lock

/// An ext_session_lock_v1. While locked only lock surfaces are drawn and get
/// input. A lock client that goes away without unlocking leaves the session
/// locked and blank until a replacement unlocks it.
const Lock = struct {
    comp: *Compositor,
    resource: ws.ext_session_lock_v1,
    surfaces: std.ArrayList(*LockSurface) = .empty,
    acknowledged: bool = false,
    unlocked: bool = false,

    fn handle(self: *Lock, resource: ws.ext_session_lock_v1, request: ws.ext_session_lock_v1.Request) void {
        const comp = self.comp;
        switch (request) {
            .get_lock_surface => |args| {
                const surface = args.surface.data(Surface) orelse return;
                if (surface.role != .none) return resource.postError(ws.ext_session_lock_v1.Error.role, "surface already has a role", .{});
                if (surface.mapped()) return resource.postError(ws.ext_session_lock_v1.Error.already_constructed, "surface already has a buffer", .{});
                const output = comp.findOutput(args.output) orelse return args.id.setHandler(Compositor, comp, null, null);
                for (self.surfaces.items) |existing| if (existing.output == output) return resource.postError(ws.ext_session_lock_v1.Error.duplicate_output, "output already has a lock surface", .{});
                const lock_surface = create(LockSurface, comp, .{ .comp = comp, .output = output, .lock = self, .resource = args.id, .surface = surface }) orelse return;
                surface.role = .lock;
                surface.lock_surface = lock_surface;
                self.surfaces.append(comp.a, lock_surface) catch {};
                args.id.setHandler(LockSurface, lock_surface, LockSurface.handle, LockSurface.destroyed);
                lock_surface.configure();
            },
            .unlock_and_destroy => {
                if (!self.acknowledged) return resource.postError(ws.ext_session_lock_v1.Error.invalid_unlock, "unlock before locked", .{});
                self.unlocked = true;
                comp.locked = false;
                comp.updateInhibition();
                comp.refocus();
                comp.updateKeyboardFocus();
                comp.scheduleRepaint();
            },
            .destroy => {},
        }
    }

    /// Sends locked once an output has shown an opaque locked frame.
    fn acknowledge(self: *Lock) void {
        if (self.acknowledged) return;
        for (self.comp.outputs.items) |output| if (output.enabled and output.lock_serial != self.comp.lock_serial) return;
        self.acknowledged = true;
        self.resource.sendLocked();
    }

    fn focus(self: *Lock) ?*Surface {
        for (self.surfaces.items) |lock_surface| if (lock_surface.surface) |surface| if (surface.mapped()) return surface;
        return null;
    }

    fn destroyed(self: *Lock, _: ws.ext_session_lock_v1) void {
        const comp = self.comp;
        for (self.surfaces.items) |lock_surface| lock_surface.lock = null;
        self.surfaces.deinit(comp.a);
        if (comp.lock == self) comp.lock = null;
        comp.updateKeyboardFocus();
        comp.scheduleRepaint();
        comp.a.destroy(self);
    }
};

const LockSurface = struct {
    comp: *Compositor,
    lock: ?*Lock,
    output: *Output,
    resource: ws.ext_session_lock_surface_v1,
    surface: ?*Surface,

    fn configure(self: *LockSurface) void {
        const lock = self.lock orelse return;
        const output = self.output;
        self.resource.sendConfigure(lock.comp.server.nextSerial(), @intCast(output.logicalWidth()), @intCast(output.logicalHeight()));
    }

    fn handle(_: *LockSurface, _: ws.ext_session_lock_surface_v1, _: ws.ext_session_lock_surface_v1.Request) void {}

    fn committed(self: *LockSurface) void {
        const lock = self.lock orelse return;
        lock.comp.updateKeyboardFocus();
        lock.comp.scheduleRepaint();
    }

    fn surfaceGone(self: *LockSurface) void {
        self.surface = null;
        if (self.lock) |lock| lock.comp.updateKeyboardFocus();
    }

    fn destroyed(self: *LockSurface, _: ws.ext_session_lock_surface_v1) void {
        if (self.surface) |surface| {
            surface.lock_surface = null;
            surface.role = .none;
        }
        if (self.lock) |lock| removeItem(*LockSurface, &lock.surfaces, self);
        self.comp.updateKeyboardFocus();
        self.comp.scheduleRepaint();
        self.comp.a.destroy(self);
    }
};

// ------------------------------------------------------------------ Idle

/// An ext_idle_notification_v1 with its own timer, as wlroots' idle notifier.
const IdleNotification = struct {
    comp: *Compositor,
    resource: ws.ext_idle_notification_v1,
    timeout: u32,
    timer: *wire.Loop.Source,
    /// Input idle notifications (version 2) ignore idle inhibitors.
    input_only: bool,
    idle: bool = false,

    fn arm(self: *IdleNotification) void {
        const inhibited = self.comp.idle_inhibited and !self.input_only;
        wire.Loop.arm(self.timer, if (inhibited) 0 else @max(1, self.timeout));
    }

    fn expired(data: ?*anyopaque, _: u32) void {
        const self: *IdleNotification = @ptrCast(@alignCast(data));
        if (self.idle or (self.comp.idle_inhibited and !self.input_only)) return;
        self.idle = true;
        self.resource.sendIdled();
    }

    /// User input: idled notifications resume, and every timer starts again.
    fn activity(self: *IdleNotification) void {
        if (self.idle) {
            self.idle = false;
            self.resource.sendResumed();
        }
        self.arm();
    }

    fn destroyed(self: *IdleNotification, _: ws.ext_idle_notification_v1) void {
        removeItem(*IdleNotification, &self.comp.idle_notifications, self);
        self.comp.server.loop.remove(self.timer);
        self.comp.a.destroy(self);
    }
};

const IdleInhibitor = struct {
    comp: *Compositor,
    surface: ?*Surface,

    fn destroyed(self: *IdleInhibitor, _: ws.zwp_idle_inhibitor_v1) void {
        const comp = self.comp;
        removeItem(*IdleInhibitor, &comp.idle_inhibitors, self);
        comp.a.destroy(self);
        comp.updateInhibition();
    }
};

// ------------------------------------------------------------------ Clipboard

/// A selection source from wl_data_device or wlr-data-control; both share the selection.
const DataSource = struct {
    comp: *Compositor,
    resource: wire.Resource,
    control: bool,
    mimes: std.ArrayList([]u8) = .empty,
    /// Offers made from this source; they stop working when it goes away.
    offers: std.ArrayList(*Offer) = .empty,

    fn addMime(self: *DataSource, mime_type: []const u8) void {
        for (self.mimes.items) |mime| if (std.mem.eql(u8, mime, mime_type)) return;
        const copy = self.comp.a.dupe(u8, mime_type) catch return;
        self.mimes.append(self.comp.a, copy) catch self.comp.a.free(copy);
    }

    fn coreRequest(self: *DataSource, _: ws.wl_data_source, request: ws.wl_data_source.Request) void {
        switch (request) {
            .offer => |args| self.addMime(args.mime_type),
            .destroy, .set_actions => {},
        }
    }

    fn controlRequest(self: *DataSource, _: ws.zwlr_data_control_source_v1, request: ws.zwlr_data_control_source_v1.Request) void {
        switch (request) {
            .offer => |args| self.addMime(args.mime_type),
            .destroy => {},
        }
    }

    fn send(self: *DataSource, mime_type: []const u8, fd: wire.Fd) void {
        if (self.control) (ws.zwlr_data_control_source_v1{ .resource = self.resource }).sendSend(mime_type, fd) else (ws.wl_data_source{ .resource = self.resource }).sendSend(mime_type, fd);
    }

    fn cancel(self: *DataSource) void {
        if (self.control) (ws.zwlr_data_control_source_v1{ .resource = self.resource }).sendCancelled() else (ws.wl_data_source{ .resource = self.resource }).sendCancelled();
    }

    fn gone(self: *DataSource) void {
        const comp = self.comp;
        for (self.offers.items) |offer| offer.source = null;
        self.offers.deinit(comp.a);
        for (self.mimes.items) |mime| comp.a.free(mime);
        self.mimes.deinit(comp.a);
        if (comp.selection == self) comp.setSelection(null);
        comp.a.destroy(self);
    }

    fn coreGone(self: *DataSource, _: ws.wl_data_source) void {
        self.gone();
    }

    fn controlGone(self: *DataSource, _: ws.zwlr_data_control_source_v1) void {
        self.gone();
    }
};

const Offer = struct {
    comp: *Compositor,
    source: ?*DataSource,

    fn receive(self: *Offer, mime_type: []const u8, fd: wire.Fd) void {
        defer _ = std.c.close(fd);
        // A replaced selection no longer answers; the pipe closes empty.
        const source = self.source orelse return;
        source.send(mime_type, fd);
    }

    fn coreRequest(self: *Offer, _: ws.wl_data_offer, request: ws.wl_data_offer.Request) void {
        switch (request) {
            .receive => |args| self.receive(args.mime_type, args.fd),
            .accept, .destroy, .finish, .set_actions => {},
        }
    }

    fn controlRequest(self: *Offer, _: ws.zwlr_data_control_offer_v1, request: ws.zwlr_data_control_offer_v1.Request) void {
        switch (request) {
            .receive => |args| self.receive(args.mime_type, args.fd),
            .destroy => {},
        }
    }

    fn gone(self: *Offer) void {
        if (self.source) |source| removeItem(*Offer, &source.offers, self);
        self.comp.a.destroy(self);
    }

    fn coreGone(self: *Offer, _: ws.wl_data_offer) void {
        self.gone();
    }

    fn controlGone(self: *Offer, _: ws.zwlr_data_control_offer_v1) void {
        self.gone();
    }

    /// Records an offer of `source`, or returns null if it cannot be tracked.
    fn make(comp: *Compositor, source: *DataSource) ?*Offer {
        const record = create(Offer, comp, .{ .comp = comp, .source = source }) orelse return null;
        source.offers.append(comp.a, record) catch {
            comp.a.destroy(record);
            return null;
        };
        return record;
    }
};

/// A wl_data_device or a wlr-data-control device.
const DataDevice = struct {
    comp: *Compositor,
    resource: wire.Resource,
    control: bool,

    fn setSelection(self: *DataDevice, source: ?*DataSource) void {
        const comp = self.comp;
        if (comp.selection == source) return;
        if (comp.selection) |old| old.cancel();
        comp.setSelection(source);
    }

    fn coreRequest(self: *DataDevice, _: ws.wl_data_device, request: ws.wl_data_device.Request) void {
        switch (request) {
            .set_selection => |args| self.setSelection(if (args.source) |resource| resource.data(DataSource) else null),
            .start_drag, .release => {},
        }
    }

    fn controlRequest(self: *DataDevice, resource: ws.zwlr_data_control_device_v1, request: ws.zwlr_data_control_device_v1.Request) void {
        switch (request) {
            .set_selection => |args| {
                const source = if (args.source) |s| s.data(DataSource) else null;
                if (source) |value| if (value == self.comp.selection) return resource.postError(ws.zwlr_data_control_device_v1.Error.used_source, "source already used", .{});
                self.setSelection(source);
            },
            .set_primary_selection => {},
            .destroy => {},
        }
    }

    fn gone(self: *DataDevice) void {
        removeItem(*DataDevice, &self.comp.data_devices, self);
        self.comp.a.destroy(self);
    }

    fn coreGone(self: *DataDevice, _: ws.wl_data_device) void {
        self.gone();
    }

    fn controlGone(self: *DataDevice, _: ws.zwlr_data_control_device_v1) void {
        self.gone();
    }

    /// Sends the current selection to this device's client.
    fn offer(self: *DataDevice, source: ?*DataSource) void {
        const comp = self.comp;
        if (self.control) {
            const device: ws.zwlr_data_control_device_v1 = .{ .resource = self.resource };
            const current = source orelse return device.sendSelection(null);
            const record = Offer.make(comp, current) orelse return;
            const resource = device.sendDataOffer();
            if (!resource.alive()) return record.gone();
            resource.setHandler(Offer, record, Offer.controlRequest, Offer.controlGone);
            for (current.mimes.items) |mime| resource.sendOffer(mime);
            device.sendSelection(resource);
        } else {
            const device: ws.wl_data_device = .{ .resource = self.resource };
            const current = source orelse return device.sendSelection(null);
            const record = Offer.make(comp, current) orelse return;
            const resource = device.sendDataOffer();
            if (!resource.alive()) return record.gone();
            resource.setHandler(Offer, record, Offer.coreRequest, Offer.coreGone);
            for (current.mimes.items) |mime| resource.sendOffer(mime);
            device.sendSelection(resource);
        }
    }
};

// ------------------------------------------------------------------ Globals

const Compositor = struct {
    a: std.mem.Allocator,
    server: *wire.Server,
    outputs: std.ArrayList(*Output) = .empty,
    seat: Seat = undefined,
    surfaces: std.ArrayList(*Surface) = .empty,
    /// Mapped toplevels, bottom to top.
    toplevels: std.ArrayList(*Toplevel) = .empty,
    popups: std.ArrayList(*Popup) = .empty,
    focused: ?*Toplevel = null,
    /// Mapped toplevels, most recently focused first; Alt-Tab cycles through them.
    recent: std.ArrayList(*Toplevel) = .empty,
    cycling: bool = false,
    cycle_app: bool = false,
    cycle_origin: ?*Toplevel = null,
    cycle_selected: ?*Toplevel = null,
    super_alone: bool = false,
    workspace: u32 = 0,
    next_window: u64 = 0,
    locked: bool = false,
    lock: ?*Lock = null,
    idle_notifications: std.ArrayList(*IdleNotification) = .empty,
    idle_inhibitors: std.ArrayList(*IdleInhibitor) = .empty,
    idle_inhibited: bool = false,
    lock_serial: u32 = 0,
    toplevel_lists: std.ArrayList(ws.ext_foreign_toplevel_list_v1) = .empty,
    overviews: std.ArrayList(*OverviewControl) = .empty,
    layers: std.ArrayList(*Layer) = .empty,
    /// A layer surface given keyboard focus by a click (on-demand interactivity).
    focused_layer: ?*Layer = null,
    selection: ?*DataSource = null,
    data_devices: std.ArrayList(*DataDevice) = .empty,
    foreign_managers: std.ArrayList(ws.zwlr_foreign_toplevel_manager_v1) = .empty,
    head_managers: std.ArrayList(*HeadManager) = .empty,
    /// Changes whenever the output configuration does.
    output_serial: u32 = 1,
    background: u32 = 0xff303030,

    /// Creates `count` headless outputs side by side, as wlroots lays them out.
    fn init(self: *Compositor, width: u32, height: u32, count: usize) !void {
        for (0..count) |index| {
            const output = try Output.create(self, index, width, height);
            output.x = @intCast(index * width);
            output.usable = output.box();
            try self.outputs.append(self.a, output);
        }
        self.seat = .{ .comp = self };
        try self.seat.init();
        const server = self.server;
        _ = try server.createGlobal(&ws.wl_compositor.interface, 6, self, &bindCompositor);
        _ = try server.createGlobal(&ws.wl_subcompositor.interface, 1, self, &bindSubcompositor);
        _ = try server.createGlobal(&ws.wl_shm.interface, 2, self, &bindShm);
        _ = try server.createGlobal(&ws.xdg_wm_base.interface, 6, self, &bindWmBase);
        _ = try server.createGlobal(&ws.zxdg_output_manager_v1.interface, 3, self, &bindOutputManager);
        _ = try server.createGlobal(&ws.wl_seat.interface, 9, &self.seat, &Seat.bind);
        _ = try server.createGlobal(&ws.wl_data_device_manager.interface, 3, self, &bindDataDeviceManager);
        _ = try server.createGlobal(&ws.zwlr_data_control_manager_v1.interface, 1, self, &bindDataControlManager);
        _ = try server.createGlobal(&ws.zwlr_layer_shell_v1.interface, 4, self, &bindLayerShell);
        _ = try server.createGlobal(&ws.zwp_virtual_keyboard_manager_v1.interface, 1, self, &bindVirtualKeyboardManager);
        _ = try server.createGlobal(&ws.zwlr_virtual_pointer_manager_v1.interface, 2, self, &bindVirtualPointerManager);
        _ = try server.createGlobal(&ws.zwlr_foreign_toplevel_manager_v1.interface, 3, self, &bindForeignManager);
        _ = try server.createGlobal(&ws.zwlr_screencopy_manager_v1.interface, 3, self, &bindScreencopy);
        _ = try server.createGlobal(&ws.zwlr_output_manager_v1.interface, 4, self, &bindOutputManagement);
        _ = try server.createGlobal(&ws.zxdg_decoration_manager_v1.interface, 1, self, &bindDecorationManager);
        _ = try server.createGlobal(&ws.ext_foreign_toplevel_list_v1.interface, 1, self, &bindToplevelList);
        _ = try server.createGlobal(&ws.ext_foreign_toplevel_image_capture_source_manager_v1.interface, 1, self, &bindCaptureSources);
        _ = try server.createGlobal(&ws.ext_image_copy_capture_manager_v1.interface, 1, self, &bindImageCopy);
        _ = try server.createGlobal(&ws.dotfiles_overview_v1.interface, 3, self, &bindOverview);
        _ = try server.createGlobal(&ws.wp_viewporter.interface, 1, self, &bindViewporter);
        _ = try server.createGlobal(&ws.ext_session_lock_manager_v1.interface, 1, self, &bindLockManager);
        _ = try server.createGlobal(&ws.wp_fractional_scale_manager_v1.interface, 1, self, &bindFractionalScale);
        _ = try server.createGlobal(&ws.ext_idle_notifier_v1.interface, 2, self, &bindIdleNotifier);
        _ = try server.createGlobal(&ws.zwp_idle_inhibit_manager_v1.interface, 1, self, &bindIdleInhibit);
        for (self.outputs.items) |output| output.render();
    }

    fn deinit(self: *Compositor) void {
        self.seat.deinit();
        self.surfaces.deinit(self.a);
        self.toplevels.deinit(self.a);
        self.recent.deinit(self.a);
        self.toplevel_lists.deinit(self.a);
        self.idle_notifications.deinit(self.a);
        self.idle_inhibitors.deinit(self.a);
        self.overviews.deinit(self.a);
        self.popups.deinit(self.a);
        self.layers.deinit(self.a);
        self.data_devices.deinit(self.a);
        self.foreign_managers.deinit(self.a);
        self.head_managers.deinit(self.a);
        for (self.outputs.items) |output| output.destroy();
        self.outputs.deinit(self.a);
    }

    fn scheduleRepaint(self: *Compositor) void {
        for (self.outputs.items) |output| output.scheduleRepaint();
    }

    /// The first enabled output, where windows go when no other output fits.
    fn primary(self: *Compositor) ?*Output {
        for (self.outputs.items) |output| if (output.enabled) return output;
        return null;
    }

    fn outputAt(self: *Compositor, x: f64, y: f64) ?*Output {
        for (self.outputs.items) |output| if (output.enabled and output.contains(x, y)) return output;
        return null;
    }

    /// The output under the pointer, where new windows and panels appear.
    fn focusedOutput(self: *Compositor) ?*Output {
        return self.outputAt(self.seat.pointer_x, self.seat.pointer_y) orelse self.primary();
    }

    /// The bounding box of every enabled output.
    fn layoutBox(self: *Compositor) Rect {
        var result: ?Rect = null;
        for (self.outputs.items) |output| {
            if (!output.enabled) continue;
            const b = output.box();
            if (result) |*r| {
                const x1 = @max(r.x + r.width, b.x + b.width);
                const y1 = @max(r.y + r.height, b.y + b.height);
                r.x = @min(r.x, b.x);
                r.y = @min(r.y, b.y);
                r.width = x1 - r.x;
                r.height = y1 - r.y;
            } else result = b;
        }
        return result orelse .{ .width = 1, .height = 1 };
    }

    fn findOutput(self: *Compositor, resource: ?ws.wl_output) ?*Output {
        const value = resource orelse return null;
        const output = value.data(Output) orelse return null;
        for (self.outputs.items) |candidate| if (candidate == output) return output;
        return null;
    }

    /// Offers the selection to the newly focused client, as wlroots does on focus.
    fn sendSelection(self: *Compositor) void {
        const surface = self.seat.keyboard_focus orelse return;
        for (self.data_devices.items) |device| if (!device.control and device.resource.client == surface.resource.client()) device.offer(self.selection);
    }

    fn focus(self: *Compositor, toplevel: ?*Toplevel) void {
        if (self.locked) return;
        if (self.focused == toplevel) return;
        if (self.focused) |old| {
            old.activated = false;
            if (old.xdg != null) old.configure();
        }
        self.focused = toplevel;
        if (toplevel) |new| if (new.workspace != self.workspace) {
            self.workspace = new.workspace;
            self.broadcastWorkspaces();
            self.scheduleRepaint();
        };
        if (toplevel) |new| {
            new.activated = true;
            if (!self.cycling) {
                removeItem(*Toplevel, &self.recent, new);
                self.recent.insert(self.a, 0, new) catch {};
            }
            new.configure();
            // Raise the focused window.
            removeItem(*Toplevel, &self.toplevels, new);
            self.toplevels.append(self.a, new) catch {};
        }
        self.updateKeyboardFocus();
    }

    /// Focuses the most recently used window on the active workspace.
    fn refocus(self: *Compositor) void {
        for (self.recent.items) |toplevel| if (toplevel.mapped and toplevel.workspace == self.workspace) {
            self.focused = null;
            return self.focus(toplevel);
        };
        self.focus(null);
        self.updateKeyboardFocus();
    }

    fn switchWorkspace(self: *Compositor, index: u32) void {
        if (index >= workspace_count) return;
        self.workspace = index;
        self.updateInhibition();
        self.refocus();
        self.broadcastWorkspaces();
        self.scheduleRepaint();
    }

    fn findWindow(self: *Compositor, identifier: []const u8) ?*Toplevel {
        for (self.toplevels.items) |toplevel| if (std.mem.eql(u8, toplevel.identifier(), identifier)) return toplevel;
        return null;
    }

    fn overviewActive(self: *Compositor) bool {
        for (self.layers.items) |layer| if (layer.mapped and std.mem.eql(u8, layer.namespace, "desktop-overview")) return true;
        return false;
    }

    fn broadcastWorkspaces(self: *Compositor) void {
        for (self.overviews.items) |overview| if (overview.resource.version() >= 2) {
            overview.sendWorkspaces();
            overview.resource.sendDone();
        };
    }

    fn broadcastOverview(self: *Compositor) void {
        const active: u32 = @intFromBool(self.overviewActive());
        for (self.overviews.items) |overview| if (overview.resource.version() >= 2) overview.resource.sendOverview(active);
    }

    // ---------------------------------------------------------- Shortcuts

    const Mods = struct { shift: bool, alt: bool, logo: bool };

    /// Handles a key before clients see it; returns whether it was consumed.
    fn shortcut(self: *Compositor, sym: u32, mods: Mods, pressed: bool) bool {
        if (self.locked) return false;
        if (sym == keysyms.Super_L) {
            if (pressed) self.super_alone = true else {
                if (self.super_alone) launch(self.a, "overview");
                self.super_alone = false;
            }
            return true;
        }
        if (!pressed) return false;
        self.super_alone = false;
        return self.binding(sym, mods);
    }

    fn binding(self: *Compositor, sym: u32, mods: Mods) bool {
        if ((mods.logo or mods.alt) and (sym == keysyms.Tab or sym == keysyms.ISO_Left_Tab)) {
            self.cycle(mods.shift, false);
            return true;
        }
        if ((mods.logo or mods.alt) and (sym == keysyms.grave or sym == keysyms.asciitilde)) {
            self.cycle(mods.shift, true);
            return true;
        }
        if (self.cycling) {
            switch (sym) {
                keysyms.Escape => self.finishCycle(true),
                keysyms.Return, keysyms.KP_Enter => self.finishCycle(false),
                keysyms.Down => self.cycle_app = true,
                keysyms.Up => self.cycle_app = false,
                keysyms.Left, keysyms.Right => self.cycle(sym == keysyms.Left, self.cycle_app),
                else => return false,
            }
            return true;
        }
        if (mods.alt and sym == keysyms.F4) {
            if (self.focused) |toplevel| toplevel.resource.sendClose();
            return true;
        }
        if (mods.logo) {
            switch (sym) {
                keysyms.Return => launchTerminal(self.a),
                keysyms.d, keysyms.a => launch(self.a, "overview"),
                keysyms.l => launch(self.a, "lock --daemonize"),
                keysyms.e, keysyms.E => {
                    if (!mods.shift) return false;
                    self.server.quit = true;
                },
                keysyms.Left, keysyms.Right, keysyms.Up, keysyms.Down => if (self.focused) |toplevel| {
                    toplevel.tile = if (sym == keysyms.Left) .left else if (sym == keysyms.Right) .right else .none;
                    toplevel.maximized = true;
                    toplevel.reconfigure(false);
                },
                else => return false,
            }
            return true;
        }
        switch (sym) {
            keysyms.XF86AudioRaiseVolume => launch(self.a, "volume up"),
            keysyms.XF86AudioLowerVolume => launch(self.a, "volume down"),
            keysyms.XF86AudioMute => launch(self.a, "volume mute"),
            keysyms.XF86AudioMicMute => launch(self.a, "microphone mute"),
            keysyms.XF86MonBrightnessUp => launch(self.a, "brightness up"),
            keysyms.XF86MonBrightnessDown => launch(self.a, "brightness down"),
            keysyms.Print => launch(self.a, "screenshot"),
            else => return false,
        }
        return true;
    }

    /// The first window of `toplevel`'s application in most-recently-used order.
    fn representative(self: *Compositor, toplevel: *Toplevel) *Toplevel {
        for (self.recent.items) |candidate| if (candidate.mapped and candidate.workspace == self.workspace and sameApp(toplevel, candidate)) return candidate;
        return toplevel;
    }

    /// Alt-Tab: moves the selection by application, or by window within one.
    fn cycle(self: *Compositor, reverse: bool, same_app: bool) void {
        if (!self.cycling) {
            self.cycle_origin = self.focused;
            self.cycle_selected = self.focused;
            self.cycling = true;
        }
        self.cycle_app = same_app;
        const windows = self.recent.items;
        const selected = self.cycle_selected;
        const start_window = if (!same_app and selected != null) self.representative(selected.?) else selected;
        var start: usize = 0;
        for (windows, 0..) |candidate, index| if (candidate == start_window) {
            start = index;
            break;
        };
        for (1..windows.len + 1) |offset| {
            const index = if (reverse) (start + windows.len - offset % windows.len) % windows.len else (start + offset) % windows.len;
            const candidate = windows[index];
            if (!candidate.mapped or candidate.workspace != self.workspace) continue;
            if (!same_app and self.representative(candidate) != candidate) continue;
            if (same_app) if (selected) |origin| if (!sameApp(origin, candidate)) continue;
            self.cycle_selected = candidate;
            return;
        }
        if (same_app) self.cycle(reverse, false) else self.finishCycle(true);
    }

    fn finishCycle(self: *Compositor, cancel: bool) void {
        const selected = if (cancel) self.cycle_origin else self.cycle_selected;
        self.cycling = false;
        self.cycle_origin = null;
        self.cycle_selected = null;
        if (selected) |toplevel| if (toplevel.mapped) {
            self.focused_layer = null;
            self.focus(toplevel);
        };
    }

    /// Keyboard focus: an exclusive layer surface on the top or overlay layer,
    /// then a layer surface the user clicked, then the focused window.
    fn updateKeyboardFocus(self: *Compositor) void {
        var target: ?*Surface = null;
        if (self.locked) {
            const surface = if (self.lock) |lock| lock.focus() else null;
            if (surface != self.seat.keyboard_focus) self.seat.focusSurface(surface);
            return;
        }
        for ([_]u32{ 3, 2 }) |level| {
            for (self.layers.items) |layer| {
                if (layer.mapped and layer.current.layer == level and layer.current.interactivity == 1) target = layer.surface;
            }
            if (target != null) break;
        }
        if (target == null) if (self.focused_layer) |layer| {
            if (layer.mapped and layer.current.interactivity != 0) target = layer.surface;
        };
        if (target == null) if (self.focused) |toplevel| {
            if (toplevel.xdg) |xdg| target = xdg.surface;
        };
        if (target == self.seat.keyboard_focus) return;
        self.seat.focusSurface(target);
        self.sendSelection();
    }

    /// Lays out layer surfaces: exclusive zones first, from the overlay down.
    fn arrange(self: *Compositor) void {
        for (self.outputs.items) |output| if (output.enabled) self.arrangeOutput(output);
        for (self.layers.items) |layer| if (layer.initial_sent and !layer.closed) layer.configure();
        for (self.toplevels.items) |toplevel| toplevel.reconfigure(false);
        self.scheduleRepaint();
    }

    fn arrangeOutput(self: *Compositor, output: *Output) void {
        const full = output.box();
        var usable = full;
        var level: u32 = 4;
        while (level > 0) {
            level -= 1;
            for (self.layers.items) |layer| {
                if (layer.output != output or layer.current.layer != level or !layer.initial_sent or layer.closed or layer.current.zone <= 0) continue;
                layer.rect = layer.place(usable);
                layer.exclude(&usable);
            }
        }
        for (self.layers.items) |layer| {
            if (layer.output != output or !layer.initial_sent or layer.closed or layer.current.zone > 0) continue;
            layer.rect = layer.place(if (layer.current.zone < 0) full else usable);
        }
        output.usable = usable;
    }

    /// Mapped surfaces bottom to top with their positions on the output.
    fn stack(self: *Compositor, out: []Root) []Root {
        var count: usize = 0;
        const add = struct {
            fn f(list: []Root, n: *usize, surface: ?*Surface, x: i32, y: i32) void {
                const value = surface orelse return;
                if (n.* < list.len and value.mapped()) {
                    list[n.*] = .{ .surface = value, .x = x, .y = y };
                    n.* += 1;
                }
            }
        }.f;
        if (self.locked) {
            if (self.lock) |lock| for (lock.surfaces.items) |lock_surface| add(out, &count, lock_surface.surface, lock_surface.output.x, lock_surface.output.y);
            return out[0..count];
        }
        for ([_]u32{ 0, 1 }) |level| for (self.layers.items) |layer| {
            if (layer.mapped and layer.current.layer == level) add(out, &count, layer.surface, layer.rect.x, layer.rect.y);
        };
        for (self.toplevels.items) |toplevel| {
            if (toplevel.workspace != self.workspace) continue;
            const xdg = toplevel.xdg orelse continue;
            const geometry = xdg.windowGeometry();
            add(out, &count, xdg.surface, toplevel.x - geometry.x, toplevel.y - geometry.y);
        }
        for (self.layers.items) |layer| {
            if (layer.mapped and layer.current.layer == 2) add(out, &count, layer.surface, layer.rect.x, layer.rect.y);
        }
        for (self.popups.items) |popup| {
            if (!popup.mapped) continue;
            if (popup.toplevelRoot()) |owner| if (owner.workspace != self.workspace) continue;
            const xdg = popup.xdg orelse continue;
            const origin = popup.parentOrigin() orelse continue;
            const geometry = xdg.windowGeometry();
            add(out, &count, xdg.surface, origin[0] + popup.rect.x - geometry.x, origin[1] + popup.rect.y - geometry.y);
        }
        for (self.layers.items) |layer| {
            if (layer.mapped and layer.current.layer == 3) add(out, &count, layer.surface, layer.rect.x, layer.rect.y);
        }
        return out[0..count];
    }

    /// The topmost surface accepting input at an output position.
    fn surfaceAt(self: *Compositor, x: f64, y: f64) ?Hit {
        var roots: [256]Root = undefined;
        const ordered = self.stack(&roots);
        const px: i32 = @intFromFloat(@floor(x));
        const py: i32 = @intFromFloat(@floor(y));
        var index = ordered.len;
        while (index > 0) {
            index -= 1;
            const root = ordered[index];
            if (root.surface.hit(px - root.x, py - root.y)) |found| return found;
        }
        return null;
    }

    /// Click to focus, and dismiss popups when clicking outside them.
    fn pointerPressed(self: *Compositor, surface: ?*Surface) void {
        var root = surface;
        while (root) |candidate| {
            const sub = candidate.subsurface orelse break;
            root = sub.parent;
        }
        const target = root orelse {
            self.dismissPopups();
            return;
        };
        if (target.xdg) |xdg| {
            if (xdg.popup == null) self.dismissPopups();
            if (xdg.toplevel) |toplevel| {
                self.focused_layer = null;
                self.focus(toplevel);
                self.updateKeyboardFocus();
            }
        } else if (target.layer) |layer| {
            self.dismissPopups();
            if (layer.current.interactivity != 0) {
                self.focused_layer = layer;
                self.updateKeyboardFocus();
            }
        } else self.dismissPopups();
    }

    fn dismissPopups(self: *Compositor) void {
        var index = self.popups.items.len;
        while (index > 0) {
            index -= 1;
            const popup = self.popups.items[index];
            if (popup.mapped) popup.resource.sendPopupDone();
        }
    }

    fn bindCompositor(data: ?*anyopaque, resource: wire.Resource) void {
        const self: *Compositor = @ptrCast(@alignCast(data));
        (ws.wl_compositor{ .resource = resource }).setHandler(Compositor, self, compositorRequest, null);
    }

    fn compositorRequest(self: *Compositor, _: ws.wl_compositor, request: ws.wl_compositor.Request) void {
        switch (request) {
            .create_surface => |args| {
                const surface = create(Surface, self, .{ .comp = self, .resource = args.id }) orelse return args.id.postError(wire.DisplayError.no_memory, "out of memory", .{});
                self.surfaces.append(self.a, surface) catch {};
                args.id.setHandler(Surface, surface, Surface.handle, Surface.destroyed);
            },
            .create_region => |args| {
                const region = std.heap.c_allocator.create(Region) catch return;
                region.* = .{};
                args.id.setHandler(Region, region, Region.handle, Region.destroyed);
            },
            .release => {},
        }
    }

    fn bindSubcompositor(data: ?*anyopaque, resource: wire.Resource) void {
        const self: *Compositor = @ptrCast(@alignCast(data));
        (ws.wl_subcompositor{ .resource = resource }).setHandler(Compositor, self, subcompositorRequest, null);
    }

    fn subcompositorRequest(self: *Compositor, resource: ws.wl_subcompositor, request: ws.wl_subcompositor.Request) void {
        switch (request) {
            .destroy => {},
            .get_subsurface => |args| {
                const surface = args.surface.data(Surface) orelse return;
                const parent = args.parent.data(Surface) orelse return;
                if (surface == parent) return resource.postError(ws.wl_subcompositor.Error.bad_parent, "a surface cannot be its own parent", .{});
                if (surface.role != .none and surface.role != .subsurface or surface.subsurface != null) return resource.postError(ws.wl_subcompositor.Error.bad_surface, "surface already has a role", .{});
                // A parent may not be a descendant of the surface.
                var ancestor: ?*Surface = parent;
                while (ancestor) |candidate| {
                    if (candidate == surface) return resource.postError(ws.wl_subcompositor.Error.bad_parent, "parent is a descendant", .{});
                    ancestor = if (candidate.subsurface) |sub| sub.parent else null;
                }
                const sub = create(Subsurface, self, .{ .comp = self, .resource = args.id, .surface = surface, .parent = parent }) orelse return;
                surface.role = .subsurface;
                surface.subsurface = sub;
                parent.children.append(self.a, sub) catch {};
                args.id.setHandler(Subsurface, sub, Subsurface.handle, Subsurface.destroyed);
            },
        }
    }

    fn bindShm(data: ?*anyopaque, resource: wire.Resource) void {
        const self: *Compositor = @ptrCast(@alignCast(data));
        const shm: ws.wl_shm = .{ .resource = resource };
        shm.setHandler(Compositor, self, shmRequest, null);
        shm.sendFormat(ws.wl_shm.Format.argb8888);
        shm.sendFormat(ws.wl_shm.Format.xrgb8888);
    }

    fn shmRequest(self: *Compositor, resource: ws.wl_shm, request: ws.wl_shm.Request) void {
        switch (request) {
            .create_pool => |args| {
                if (args.size <= 0) {
                    _ = std.c.close(args.fd);
                    return resource.postError(ws.wl_shm.Error.invalid_stride, "pool size must be positive", .{});
                }
                const pool = create(Pool, self, .{ .comp = self, .fd = args.fd, .map = &.{} }) orelse {
                    _ = std.c.close(args.fd);
                    return;
                };
                if (!pool.remap(@intCast(args.size))) {
                    pool.unref();
                    return resource.postError(ws.wl_shm.Error.invalid_fd, "cannot map the pool", .{});
                }
                args.id.setHandler(Pool, pool, poolRequest, poolGone);
            },
            .release => {},
        }
    }

    fn poolRequest(pool: *Pool, resource: ws.wl_shm_pool, request: ws.wl_shm_pool.Request) void {
        switch (request) {
            .destroy => {},
            .resize => |args| {
                if (args.size < pool.map.len) return resource.postError(ws.wl_shm.Error.invalid_stride, "pools cannot shrink", .{});
                if (!pool.remap(@intCast(args.size))) resource.postError(ws.wl_shm.Error.invalid_fd, "cannot map the pool", .{});
            },
            .create_buffer => |args| {
                if (args.format != ws.wl_shm.Format.argb8888 and args.format != ws.wl_shm.Format.xrgb8888)
                    return resource.postError(ws.wl_shm.Error.invalid_format, "unsupported format {d}", .{args.format});
                if (args.width <= 0 or args.height <= 0 or args.offset < 0 or args.stride < args.width * 4 or args.stride > 1 << 20)
                    return resource.postError(ws.wl_shm.Error.invalid_stride, "invalid buffer geometry", .{});
                const end = @as(u64, @intCast(args.offset)) + @as(u64, @intCast(args.stride)) * @as(u64, @intCast(args.height));
                if (end > pool.map.len) return resource.postError(ws.wl_shm.Error.invalid_stride, "buffer exceeds the pool", .{});
                const comp = pool.comp;
                const buffer = create(Buffer, comp, .{ .comp = comp, .resource = args.id, .pool = pool, .offset = @intCast(args.offset), .width = @intCast(args.width), .height = @intCast(args.height), .stride = @intCast(args.stride), .format = args.format }) orelse return;
                pool.refs += 1;
                args.id.setHandler(Buffer, buffer, bufferRequest, bufferGone);
            },
        }
    }

    fn poolGone(pool: *Pool, _: ws.wl_shm_pool) void {
        pool.unref();
    }

    fn bufferRequest(_: *Buffer, _: ws.wl_buffer, _: ws.wl_buffer.Request) void {}

    fn bufferGone(buffer: *Buffer, _: ws.wl_buffer) void {
        const comp = buffer.comp;
        for (comp.surfaces.items) |surface| if (surface.pending_buffer == buffer) {
            surface.pending_buffer = null;
        };
        buffer.pool.unref();
        comp.a.destroy(buffer);
    }

    fn bindWmBase(data: ?*anyopaque, resource: wire.Resource) void {
        const self: *Compositor = @ptrCast(@alignCast(data));
        (ws.xdg_wm_base{ .resource = resource }).setHandler(Compositor, self, wmBaseRequest, null);
    }

    fn wmBaseRequest(self: *Compositor, resource: ws.xdg_wm_base, request: ws.xdg_wm_base.Request) void {
        switch (request) {
            .destroy, .pong => {},
            .create_positioner => |args| {
                const positioner = std.heap.c_allocator.create(Positioner) catch return;
                positioner.* = .{};
                args.id.setHandler(Positioner, positioner, Positioner.handle, Positioner.destroyed);
            },
            .get_xdg_surface => |args| {
                const surface = args.surface.data(Surface) orelse return;
                if (surface.xdg != null) return resource.postError(ws.xdg_wm_base.Error.role, "surface already has an xdg_surface", .{});
                if (surface.mapped()) return resource.postError(ws.xdg_surface.Error.unconfigured_buffer, "surface already has a buffer", .{});
                const xdg = create(XdgSurface, self, .{ .comp = self, .resource = args.id, .surface = surface }) orelse return;
                surface.xdg = xdg;
                args.id.setHandler(XdgSurface, xdg, XdgSurface.handle, XdgSurface.destroyed);
            },
        }
    }

    fn bindOutputManager(data: ?*anyopaque, resource: wire.Resource) void {
        const self: *Compositor = @ptrCast(@alignCast(data));
        (ws.zxdg_output_manager_v1{ .resource = resource }).setHandler(Compositor, self, outputManagerRequest, null);
    }

    fn outputManagerRequest(self: *Compositor, _: ws.zxdg_output_manager_v1, request: ws.zxdg_output_manager_v1.Request) void {
        switch (request) {
            .destroy => {},
            .get_xdg_output => |args| {
                const xdg_output = args.id;
                const output = self.findOutput(args.output) orelse return xdg_output.setHandler(Compositor, self, null, null);
                xdg_output.setHandler(Output, output, null, Output.xdgOutputGone);
                output.xdg_outputs.append(self.a, xdg_output) catch {};
                xdg_output.sendLogicalPosition(output.x, output.y);
                xdg_output.sendLogicalSize(output.logicalWidth(), output.logicalHeight());
                if (xdg_output.version() >= 2) {
                    xdg_output.sendName(output.name());
                    xdg_output.sendDescription("Headless output");
                }
                if (xdg_output.version() < 3) xdg_output.sendDone();
                // wl_output.done completes xdg_output state since version 3.
                for (output.resources.items) |wl_output| if (wl_output.client() == xdg_output.client() and wl_output.version() >= 2) wl_output.sendDone();
            },
        }
    }

    fn bindLayerShell(data: ?*anyopaque, resource: wire.Resource) void {
        const self: *Compositor = @ptrCast(@alignCast(data));
        (ws.zwlr_layer_shell_v1{ .resource = resource }).setHandler(Compositor, self, layerShellRequest, null);
    }

    fn layerShellRequest(self: *Compositor, resource: ws.zwlr_layer_shell_v1, request: ws.zwlr_layer_shell_v1.Request) void {
        switch (request) {
            .destroy => {},
            .get_layer_surface => |args| {
                const surface = args.surface.data(Surface) orelse return;
                if (surface.role != .none) return resource.postError(ws.zwlr_layer_shell_v1.Error.role, "surface already has a role", .{});
                if (args.layer > 3) return resource.postError(ws.zwlr_layer_shell_v1.Error.invalid_layer, "invalid layer", .{});
                if (surface.mapped()) return resource.postError(ws.zwlr_layer_shell_v1.Error.already_constructed, "surface already has a buffer", .{});
                const namespace = self.a.dupe(u8, args.namespace) catch return;
                const config: Layer.Config = .{ .layer = args.layer };
                // A panel asks for an output, or gets the one under the pointer.
                const output = self.findOutput(args.output) orelse self.focusedOutput() orelse {
                    self.a.free(namespace);
                    args.id.setHandler(Compositor, self, null, null);
                    return args.id.sendClosed();
                };
                const layer = create(Layer, self, .{ .comp = self, .resource = args.id, .surface = surface, .output = output, .namespace = namespace, .pending = config, .current = config }) orelse {
                    self.a.free(namespace);
                    return;
                };
                surface.role = .layer;
                surface.layer = layer;
                self.layers.append(self.a, layer) catch {};
                args.id.setHandler(Layer, layer, Layer.handle, Layer.destroyed);
            },
        }
    }

    fn bindVirtualKeyboardManager(data: ?*anyopaque, resource: wire.Resource) void {
        const self: *Compositor = @ptrCast(@alignCast(data));
        (ws.zwp_virtual_keyboard_manager_v1{ .resource = resource }).setHandler(Compositor, self, virtualKeyboardManagerRequest, null);
    }

    fn virtualKeyboardManagerRequest(self: *Compositor, _: ws.zwp_virtual_keyboard_manager_v1, request: ws.zwp_virtual_keyboard_manager_v1.Request) void {
        switch (request) {
            .create_virtual_keyboard => |args| {
                const keyboard = create(VirtualKeyboard, self, .{ .comp = self }) orelse return;
                args.id.setHandler(VirtualKeyboard, keyboard, VirtualKeyboard.handle, VirtualKeyboard.destroyed);
            },
        }
    }

    fn bindVirtualPointerManager(data: ?*anyopaque, resource: wire.Resource) void {
        const self: *Compositor = @ptrCast(@alignCast(data));
        (ws.zwlr_virtual_pointer_manager_v1{ .resource = resource }).setHandler(Compositor, self, virtualPointerManagerRequest, null);
    }

    fn virtualPointerManagerRequest(self: *Compositor, _: ws.zwlr_virtual_pointer_manager_v1, request: ws.zwlr_virtual_pointer_manager_v1.Request) void {
        switch (request) {
            .destroy => {},
            .create_virtual_pointer => |args| self.virtualPointer(args.id),
            .create_virtual_pointer_with_output => |args| self.virtualPointer(args.id),
        }
    }

    fn virtualPointer(self: *Compositor, resource: ws.zwlr_virtual_pointer_v1) void {
        const pointer = create(VirtualPointer, self, .{ .comp = self }) orelse return;
        resource.setHandler(VirtualPointer, pointer, VirtualPointer.handle, VirtualPointer.destroyed);
    }

    fn bindLockManager(data: ?*anyopaque, resource: wire.Resource) void {
        const self: *Compositor = @ptrCast(@alignCast(data));
        (ws.ext_session_lock_manager_v1{ .resource = resource }).setHandler(Compositor, self, lockManagerRequest, null);
    }

    fn lockManagerRequest(self: *Compositor, _: ws.ext_session_lock_manager_v1, request: ws.ext_session_lock_manager_v1.Request) void {
        switch (request) {
            .destroy => {},
            .lock => |args| {
                const lock = create(Lock, self, .{ .comp = self, .resource = args.id }) orelse return;
                args.id.setHandler(Lock, lock, Lock.handle, Lock.destroyed);
                // One lock at a time; a crashed lock can be replaced while still locked.
                if (self.lock != null) return args.id.sendFinished();
                self.lock = lock;
                self.locked = true;
                self.updateInhibition();
                self.lock_serial +%= 1;
                self.cycling = false;
                self.cycle_origin = null;
                self.cycle_selected = null;
                self.super_alone = false;
                self.dismissPopups();
                self.seat.focusSurface(null);
                self.seat.updatePointerFocus();
                self.scheduleRepaint();
            },
        }
    }

    /// User input resets idle timers.
    fn activity(self: *Compositor) void {
        for (self.idle_notifications.items) |notification| notification.activity();
    }

    /// Idle is inhibited by a visible window's inhibitor, never while locked.
    fn updateInhibition(self: *Compositor) void {
        var inhibited = false;
        if (!self.locked) for (self.idle_inhibitors.items) |inhibitor| {
            var root = inhibitor.surface orelse continue;
            while (root.subsurface) |sub| root = sub.parent orelse break;
            if (!root.mapped()) continue;
            const xdg = root.xdg orelse continue;
            const toplevel = xdg.toplevel orelse continue;
            if (toplevel.mapped and toplevel.workspace == self.workspace) inhibited = true;
        };
        if (inhibited == self.idle_inhibited) return;
        self.idle_inhibited = inhibited;
        for (self.idle_notifications.items) |notification| notification.arm();
    }

    fn bindIdleNotifier(data: ?*anyopaque, resource: wire.Resource) void {
        const self: *Compositor = @ptrCast(@alignCast(data));
        (ws.ext_idle_notifier_v1{ .resource = resource }).setHandler(Compositor, self, idleNotifierRequest, null);
    }

    fn idleNotifierRequest(self: *Compositor, _: ws.ext_idle_notifier_v1, request: ws.ext_idle_notifier_v1.Request) void {
        switch (request) {
            .destroy => {},
            .get_idle_notification => |args| self.idleNotification(args.id, args.timeout, false),
            .get_input_idle_notification => |args| self.idleNotification(args.id, args.timeout, true),
        }
    }

    fn idleNotification(self: *Compositor, resource: ws.ext_idle_notification_v1, timeout: u32, input_only: bool) void {
        const notification = self.a.create(IdleNotification) catch return resource.setHandler(Compositor, self, null, null);
        const timer = self.server.loop.timer(notification, &IdleNotification.expired) catch {
            self.a.destroy(notification);
            return resource.setHandler(Compositor, self, null, null);
        };
        notification.* = .{ .comp = self, .resource = resource, .timeout = timeout, .timer = timer, .input_only = input_only };
        resource.setHandler(IdleNotification, notification, null, IdleNotification.destroyed);
        self.idle_notifications.append(self.a, notification) catch {};
        notification.arm();
    }

    fn bindIdleInhibit(data: ?*anyopaque, resource: wire.Resource) void {
        const self: *Compositor = @ptrCast(@alignCast(data));
        (ws.zwp_idle_inhibit_manager_v1{ .resource = resource }).setHandler(Compositor, self, idleInhibitRequest, null);
    }

    fn idleInhibitRequest(self: *Compositor, _: ws.zwp_idle_inhibit_manager_v1, request: ws.zwp_idle_inhibit_manager_v1.Request) void {
        switch (request) {
            .destroy => {},
            .create_inhibitor => |args| {
                const inhibitor = create(IdleInhibitor, self, .{ .comp = self, .surface = args.surface.data(Surface) }) orelse return;
                args.id.setHandler(IdleInhibitor, inhibitor, null, IdleInhibitor.destroyed);
                self.idle_inhibitors.append(self.a, inhibitor) catch {};
                self.updateInhibition();
            },
        }
    }

    fn bindViewporter(data: ?*anyopaque, resource: wire.Resource) void {
        const self: *Compositor = @ptrCast(@alignCast(data));
        (ws.wp_viewporter{ .resource = resource }).setHandler(Compositor, self, viewporterRequest, null);
    }

    fn viewporterRequest(_: *Compositor, resource: ws.wp_viewporter, request: ws.wp_viewporter.Request) void {
        switch (request) {
            .destroy => {},
            .get_viewport => |args| {
                const surface = args.surface.data(Surface) orelse return;
                if (surface.has_viewport) return resource.postError(ws.wp_viewporter.Error.viewport_exists, "surface already has a viewport", .{});
                surface.has_viewport = true;
                args.id.setHandler(Surface, surface, viewportRequest, viewportGone);
            },
        }
    }

    fn viewportRequest(surface: *Surface, resource: ws.wp_viewport, request: ws.wp_viewport.Request) void {
        switch (request) {
            .destroy => {},
            // Cropping is accepted; the whole buffer is shown scaled to the destination.
            .set_source => {},
            .set_destination => |args| {
                if (args.width == -1 and args.height == -1) {
                    surface.pending_destination = null;
                } else if (args.width <= 0 or args.height <= 0) {
                    resource.postError(ws.wp_viewport.Error.bad_value, "destination size must be positive", .{});
                } else surface.pending_destination = .{ args.width, args.height };
            },
        }
    }

    fn viewportGone(surface: *Surface, _: ws.wp_viewport) void {
        surface.has_viewport = false;
        surface.pending_destination = null;
    }

    fn bindFractionalScale(data: ?*anyopaque, resource: wire.Resource) void {
        const self: *Compositor = @ptrCast(@alignCast(data));
        (ws.wp_fractional_scale_manager_v1{ .resource = resource }).setHandler(Compositor, self, fractionalScaleRequest, null);
    }

    fn fractionalScaleRequest(self: *Compositor, resource: ws.wp_fractional_scale_manager_v1, request: ws.wp_fractional_scale_manager_v1.Request) void {
        switch (request) {
            .destroy => {},
            .get_fractional_scale => |args| {
                const surface = args.surface.data(Surface) orelse return;
                if (surface.fractional != null) return resource.postError(ws.wp_fractional_scale_manager_v1.Error.fractional_scale_exists, "surface already has a fractional scale", .{});
                surface.fractional = args.id;
                args.id.setHandler(Surface, surface, null, fractionalGone);
                const output = surface.entered orelse self.focusedOutput();
                if (output) |o| args.id.sendPreferredScale(o.fractionalScale());
            },
        }
    }

    fn fractionalGone(surface: *Surface, _: ws.wp_fractional_scale_v1) void {
        surface.fractional = null;
    }

    fn bindToplevelList(data: ?*anyopaque, resource: wire.Resource) void {
        const self: *Compositor = @ptrCast(@alignCast(data));
        const list: ws.ext_foreign_toplevel_list_v1 = .{ .resource = resource };
        list.setHandler(Compositor, self, toplevelListRequest, toplevelListGone);
        self.toplevel_lists.append(self.a, list) catch {};
        for (self.toplevels.items) |toplevel| ListHandle.announce(self, list, toplevel);
    }

    fn toplevelListRequest(self: *Compositor, resource: ws.ext_foreign_toplevel_list_v1, request: ws.ext_foreign_toplevel_list_v1.Request) void {
        switch (request) {
            .stop => {
                removeItem(ws.ext_foreign_toplevel_list_v1, &self.toplevel_lists, resource);
                resource.sendFinished();
            },
            .destroy => {},
        }
    }

    fn toplevelListGone(self: *Compositor, resource: ws.ext_foreign_toplevel_list_v1) void {
        removeItem(ws.ext_foreign_toplevel_list_v1, &self.toplevel_lists, resource);
    }

    fn bindCaptureSources(data: ?*anyopaque, resource: wire.Resource) void {
        const self: *Compositor = @ptrCast(@alignCast(data));
        (ws.ext_foreign_toplevel_image_capture_source_manager_v1{ .resource = resource }).setHandler(Compositor, self, captureSourceRequest, null);
    }

    fn captureSourceRequest(_: *Compositor, _: ws.ext_foreign_toplevel_image_capture_source_manager_v1, request: ws.ext_foreign_toplevel_image_capture_source_manager_v1.Request) void {
        switch (request) {
            .create_source => |args| {
                const handle = args.toplevel_handle.data(ListHandle);
                const source = std.heap.c_allocator.create(CaptureSource) catch return;
                source.* = .{ .toplevel = if (handle) |h| h.toplevel else null };
                args.source.setHandler(CaptureSource, source, null, CaptureSource.destroyed);
            },
            .destroy => {},
        }
    }

    fn bindImageCopy(data: ?*anyopaque, resource: wire.Resource) void {
        const self: *Compositor = @ptrCast(@alignCast(data));
        (ws.ext_image_copy_capture_manager_v1{ .resource = resource }).setHandler(Compositor, self, imageCopyRequest, null);
    }

    fn imageCopyRequest(self: *Compositor, _: ws.ext_image_copy_capture_manager_v1, request: ws.ext_image_copy_capture_manager_v1.Request) void {
        switch (request) {
            .create_session => |args| {
                const source = args.source.data(CaptureSource);
                const toplevel = if (source) |s| s.toplevel else null;
                const session = create(CaptureSession, self, .{ .comp = self, .resource = args.session, .toplevel = toplevel }) orelse return;
                args.session.setHandler(CaptureSession, session, CaptureSession.handle, CaptureSession.destroyed);
                // A window that is gone, or still unknown, stops the session at once.
                const owner = toplevel orelse return args.session.sendStopped();
                if (!owner.mapped) return session.stop();
                owner.sessions.append(self.a, session) catch return session.stop();
                session.constraints();
            },
            .create_pointer_cursor_session => |args| args.session.setHandler(Compositor, self, null, null),
            .destroy => {},
        }
    }

    fn bindOverview(data: ?*anyopaque, resource: wire.Resource) void {
        const self: *Compositor = @ptrCast(@alignCast(data));
        const control = create(OverviewControl, self, .{ .comp = self, .resource = .{ .resource = resource } }) orelse return;
        control.resource.setHandler(OverviewControl, control, OverviewControl.handle, OverviewControl.destroyed);
        self.overviews.append(self.a, control) catch {};
        if (control.resource.version() >= 2) {
            control.sendWorkspaces();
            control.resource.sendDone();
            control.resource.sendOverview(@intFromBool(self.overviewActive()));
        }
    }

    fn bindDecorationManager(data: ?*anyopaque, resource: wire.Resource) void {
        const self: *Compositor = @ptrCast(@alignCast(data));
        (ws.zxdg_decoration_manager_v1{ .resource = resource }).setHandler(Compositor, self, decorationManagerRequest, null);
    }

    fn decorationManagerRequest(_: *Compositor, resource: ws.zxdg_decoration_manager_v1, request: ws.zxdg_decoration_manager_v1.Request) void {
        switch (request) {
            .destroy => {},
            .get_toplevel_decoration => |args| {
                const toplevel = args.toplevel.data(Toplevel) orelse return;
                if (toplevel.decoration != null) return resource.postError(ws.zxdg_toplevel_decoration_v1.Error.already_constructed, "toplevel already has a decoration", .{});
                toplevel.decoration = args.id;
                args.id.setHandler(Toplevel, toplevel, decorationRequest, decorationGone);
            },
        }
    }

    fn decorationRequest(toplevel: *Toplevel, _: ws.zxdg_toplevel_decoration_v1, request: ws.zxdg_toplevel_decoration_v1.Request) void {
        switch (request) {
            .destroy => {},
            // Mode requests before the first commit wait for its configure.
            .set_mode, .unset_mode => if (toplevel.xdg) |xdg| if (xdg.initial_sent) toplevel.configure(),
        }
    }

    fn decorationGone(toplevel: *Toplevel, _: ws.zxdg_toplevel_decoration_v1) void {
        toplevel.decoration = null;
    }

    fn bindOutputManagement(data: ?*anyopaque, resource: wire.Resource) void {
        const self: *Compositor = @ptrCast(@alignCast(data));
        const manager = create(HeadManager, self, .{ .comp = self, .manager = .{ .resource = resource } }) orelse return;
        manager.manager.setHandler(HeadManager, manager, HeadManager.request, HeadManager.destroyed);
        self.head_managers.append(self.a, manager) catch {};
        for (self.outputs.items) |output| manager.announce(output);
        manager.manager.sendDone(self.output_serial);
    }

    /// Turns an output off, as unplugging it, or back on.
    fn setOutputEnabled(self: *Compositor, output: *Output, enabled: bool) void {
        if (output.enabled == enabled) return;
        output.enabled = enabled;
        if (!enabled) {
            if (output.global) |global| global.remove();
            output.global = null;
            for (self.layers.items) |layer| if (layer.output == output) layer.close();
            for (self.surfaces.items) |surface| if (surface.entered == output) {
                surface.entered = null;
            };
            // Windows move to an output that is still there.
            for (self.toplevels.items) |toplevel| if (toplevel.output == output) {
                toplevel.output = self.primary();
                if (toplevel.output) |other| if (toplevel.xdg) |xdg| if (xdg.surface) |surface| other.enter(surface);
            };
            self.seat.clampPointer();
            self.updateKeyboardFocus();
            self.arrange();
            return;
        }
        output.global = self.server.createGlobal(&ws.wl_output.interface, 4, output, &Output.bind) catch null;
        self.seat.clampPointer();
        self.arrange();
        output.scheduleRepaint();
    }

    /// Tells output management clients about the new configuration.
    fn outputChanged(self: *Compositor) void {
        self.output_serial +%= 1;
        for (self.head_managers.items) |manager| manager.describe();
    }

    fn bindScreencopy(data: ?*anyopaque, resource: wire.Resource) void {
        const self: *Compositor = @ptrCast(@alignCast(data));
        (ws.zwlr_screencopy_manager_v1{ .resource = resource }).setHandler(Compositor, self, screencopyRequest, null);
    }

    fn screencopyRequest(self: *Compositor, _: ws.zwlr_screencopy_manager_v1, request: ws.zwlr_screencopy_manager_v1.Request) void {
        switch (request) {
            .capture_output => |args| CaptureFrame.start(self, args.frame, args.output, null),
            .capture_output_region => |args| CaptureFrame.start(self, args.frame, args.output, .{ .x = args.x, .y = args.y, .width = args.width, .height = args.height }),
            .destroy => {},
        }
    }

    fn bindForeignManager(data: ?*anyopaque, resource: wire.Resource) void {
        const self: *Compositor = @ptrCast(@alignCast(data));
        const manager: ws.zwlr_foreign_toplevel_manager_v1 = .{ .resource = resource };
        manager.setHandler(Compositor, self, foreignManagerRequest, foreignManagerGone);
        self.foreign_managers.append(self.a, manager) catch {};
        for (self.toplevels.items) |toplevel| ForeignHandle.announce(self, manager, toplevel);
    }

    fn foreignManagerRequest(self: *Compositor, resource: ws.zwlr_foreign_toplevel_manager_v1, request: ws.zwlr_foreign_toplevel_manager_v1.Request) void {
        switch (request) {
            .stop => {
                removeItem(ws.zwlr_foreign_toplevel_manager_v1, &self.foreign_managers, resource);
                resource.sendFinished();
                resource.destroyResource();
            },
        }
    }

    fn foreignManagerGone(self: *Compositor, resource: ws.zwlr_foreign_toplevel_manager_v1) void {
        removeItem(ws.zwlr_foreign_toplevel_manager_v1, &self.foreign_managers, resource);
    }

    fn bindDataDeviceManager(data: ?*anyopaque, resource: wire.Resource) void {
        const self: *Compositor = @ptrCast(@alignCast(data));
        (ws.wl_data_device_manager{ .resource = resource }).setHandler(Compositor, self, dataDeviceManagerRequest, null);
    }

    fn dataDeviceManagerRequest(self: *Compositor, _: ws.wl_data_device_manager, request: ws.wl_data_device_manager.Request) void {
        switch (request) {
            .create_data_source => |args| {
                const source = create(DataSource, self, .{ .comp = self, .resource = args.id.resource, .control = false }) orelse return;
                args.id.setHandler(DataSource, source, DataSource.coreRequest, DataSource.coreGone);
            },
            .get_data_device => |args| {
                const device = create(DataDevice, self, .{ .comp = self, .resource = args.id.resource, .control = false }) orelse return;
                self.data_devices.append(self.a, device) catch {};
                args.id.setHandler(DataDevice, device, DataDevice.coreRequest, DataDevice.coreGone);
                // A client that already has keyboard focus learns the selection at once.
                if (self.seat.keyboard_focus) |surface| if (surface.resource.client() == args.id.client()) device.offer(self.selection);
            },
            .release => {},
        }
    }

    fn bindDataControlManager(data: ?*anyopaque, resource: wire.Resource) void {
        const self: *Compositor = @ptrCast(@alignCast(data));
        (ws.zwlr_data_control_manager_v1{ .resource = resource }).setHandler(Compositor, self, dataControlManagerRequest, null);
    }

    fn dataControlManagerRequest(self: *Compositor, _: ws.zwlr_data_control_manager_v1, request: ws.zwlr_data_control_manager_v1.Request) void {
        switch (request) {
            .create_data_source => |args| {
                const source = create(DataSource, self, .{ .comp = self, .resource = args.id.resource, .control = true }) orelse return;
                args.id.setHandler(DataSource, source, DataSource.controlRequest, DataSource.controlGone);
            },
            .get_data_device => |args| {
                const device = create(DataDevice, self, .{ .comp = self, .resource = args.id.resource, .control = true }) orelse return;
                self.data_devices.append(self.a, device) catch {};
                args.id.setHandler(DataDevice, device, DataDevice.controlRequest, DataDevice.controlGone);
                // Clipboard managers learn the selection whether or not they have focus.
                device.offer(self.selection);
            },
            .destroy => {},
        }
    }

    /// Replaces the selection and tells data-control clients and the focused client.
    fn setSelection(self: *Compositor, source: ?*DataSource) void {
        self.selection = source;
        const focus_client = if (self.seat.keyboard_focus) |surface| surface.resource.client() else null;
        for (self.data_devices.items) |device| {
            if (device.control or device.resource.client == focus_client) device.offer(source);
        }
    }
};

// ------------------------------------------------------------------ Thread

pub const Handle = struct {
    allocator: std.mem.Allocator,
    thread: std.Thread = undefined,
    stop_fd: wire.Fd = -1,
    ready: [2]wire.Fd = .{ -1, -1 },
    failed: bool = false,
    socket: [32:0]u8 = @splat(0),
    width: u32 = 1280,
    height: u32 = 720,
    /// For tests: a copy of the last rendered frame, guarded by `snapshot_lock`.
    snapshot_lock: util.Mutex = .{},
    snapshot: []u32 = &.{},
    snapshot_frames: u64 = 0,

    /// Starts the compositor thread and sets WAYLAND_DISPLAY for clients.
    pub fn start(allocator: std.mem.Allocator) !*Handle {
        const self = try allocator.create(Handle);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator };
        const opened = std.os.linux.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
        if (std.os.linux.errno(opened) != .SUCCESS) return error.CompositorPipe;
        const fd: wire.Fd = @intCast(opened);
        self.stop_fd = fd;
        errdefer _ = std.c.close(fd);
        if (libc.pipe2(&self.ready, libc.O_CLOEXEC) != 0) return error.CompositorPipe;
        defer for (self.ready) |end| {
            _ = std.c.close(end);
        };
        self.thread = try std.Thread.spawn(.{}, worker, .{self});
        var status: u8 = 0;
        _ = std.c.read(self.ready[0], @ptrCast(&status), 1);
        if (self.failed) {
            self.thread.join();
            return error.CompositorStartup;
        }
        if (libc.setenv("WAYLAND_DISPLAY", &self.socket, 1) != 0) {
            self.stop();
            return error.CompositorEnvironment;
        }
        return self;
    }

    pub fn stop(self: *Handle) void {
        const one: u64 = 1;
        _ = std.c.write(self.stop_fd, std.mem.asBytes(&one), 8);
        self.wait();
    }

    pub fn wait(self: *Handle) void {
        self.thread.join();
        _ = std.c.close(self.stop_fd);
        self.allocator.free(self.snapshot);
        self.allocator.destroy(self);
    }

    fn signal(self: *Handle) void {
        const status: u8 = 1;
        _ = std.c.write(self.ready[1], @ptrCast(&status), 1);
    }

    fn stopReady(data: ?*anyopaque, _: u32) void {
        const running: *bool = @ptrCast(@alignCast(data));
        running.* = false;
    }

    fn worker(self: *Handle) void {
        const a = self.allocator;
        const server = wire.Server.create(a) catch {
            self.failed = true;
            self.signal();
            return;
        };
        defer server.destroy();
        var comp: Compositor = .{ .a = a, .server = server };
        comp.init(self.width, self.height, headlessOutputs()) catch {
            self.failed = true;
            self.signal();
            return;
        };
        defer comp.deinit();
        const name = server.addSocketAuto() catch {
            self.failed = true;
            self.signal();
            return;
        };
        @memcpy(self.socket[0..name.len], name);
        var running = true;
        _ = server.loop.add(self.stop_fd, std.os.linux.EPOLL.IN, &running, &stopReady) catch {
            self.failed = true;
            self.signal();
            return;
        };
        self.signal();
        while (running and !server.quit) {
            const output = comp.outputs.items[0];
            const before = output.frames;
            server.dispatch(-1);
            if (output.frames != before) self.publish(output);
        }
    }

    /// How many headless outputs to create; WLR_HEADLESS_OUTPUTS is honoured as with wlroots.
    fn headlessOutputs() usize {
        const value = std.c.getenv("WLR_HEADLESS_OUTPUTS") orelse return 1;
        return std.math.clamp(std.fmt.parseInt(usize, std.mem.span(value), 10) catch 1, 1, 8);
    }

    fn publish(self: *Handle, output: *Output) void {
        self.snapshot_lock.lock();
        defer self.snapshot_lock.unlock();
        if (self.snapshot.len != output.pixels.len) {
            self.allocator.free(self.snapshot);
            self.snapshot = self.allocator.alloc(u32, output.pixels.len) catch &.{};
        }
        if (self.snapshot.len == output.pixels.len) @memcpy(self.snapshot, output.pixels);
        self.snapshot_frames = output.frames;
    }

    /// The pixel at (x, y) of the most recent frame, and how many frames were rendered.
    pub fn pixel(self: *Handle, x: u32, y: u32) struct { value: u32, frames: u64 } {
        self.snapshot_lock.lock();
        defer self.snapshot_lock.unlock();
        if (self.snapshot.len == 0) return .{ .value = 0, .frames = 0 };
        return .{ .value = self.snapshot[@as(usize, y) * self.width + x], .frames = self.snapshot_frames };
    }
};

// ------------------------------------------------------------------ Tests

test "native compositor maps an xdg toplevel from shared memory and composites it" {
    const client_wire = @import("wayland-wire");
    const wl = @import("wayland-client");
    const a = std.testing.allocator;
    var runtime: [64]u8 = undefined;
    const directory = try std.fmt.bufPrintSentinel(&runtime, "/tmp/desktop-native-test-{d}", .{libc.getpid()}, 0);
    _ = libc.mkdir(directory, 0o700);
    defer _ = libc.rmdir(directory);
    const previous_runtime = std.c.getenv("XDG_RUNTIME_DIR");
    _ = libc.setenv("XDG_RUNTIME_DIR", directory, 1);
    defer if (previous_runtime) |value| {
        _ = libc.setenv("XDG_RUNTIME_DIR", value, 1);
    };
    const handle = try Handle.start(a);
    defer handle.stop();

    const connection = try client_wire.Connection.connect(a);
    defer connection.deinit();
    const Globals = struct {
        compositor: ?wl.wl_compositor = null,
        shm: ?wl.wl_shm = null,
        wm_base: ?wl.xdg_wm_base = null,
        seat: ?wl.wl_seat = null,
        output: ?wl.wl_output = null,
        fn global(self: *@This(), registry: wl.wl_registry, event: wl.wl_registry.Event) void {
            switch (event) {
                .global => |g| {
                    if (std.mem.eql(u8, g.interface, "wl_compositor")) self.compositor = registry.bind(g.name, wl.wl_compositor, 6);
                    if (std.mem.eql(u8, g.interface, "wl_shm")) self.shm = registry.bind(g.name, wl.wl_shm, 1);
                    if (std.mem.eql(u8, g.interface, "xdg_wm_base")) self.wm_base = registry.bind(g.name, wl.xdg_wm_base, 6);
                    if (std.mem.eql(u8, g.interface, "wl_seat")) self.seat = registry.bind(g.name, wl.wl_seat, 9);
                    if (std.mem.eql(u8, g.interface, "wl_output")) self.output = registry.bind(g.name, wl.wl_output, 4);
                },
                .global_remove => {},
            }
        }
    };
    var globals: Globals = .{};
    const display: wl.wl_display = .{ .proxy = connection.display() };
    const registry = display.get_registry();
    registry.listen(Globals, &globals, Globals.global);
    try connection.roundtrip();
    try std.testing.expect(globals.compositor != null and globals.shm != null and globals.wm_base != null and globals.seat != null and globals.output != null);

    const Window = struct {
        configured: u32 = 0,
        serial: u32 = 0,
        activated: bool = false,
        released: bool = false,
        frame_done: bool = false,
        keymap_size: u32 = 0,
        entered: bool = false,
        fn xdgSurface(self: *@This(), surface: wl.xdg_surface, event: wl.xdg_surface.Event) void {
            self.configured += 1;
            self.serial = event.configure.serial;
            surface.ack_configure(event.configure.serial);
        }
        fn toplevel(self: *@This(), _: wl.xdg_toplevel, event: wl.xdg_toplevel.Event) void {
            switch (event) {
                .configure => |args| {
                    const states = std.mem.bytesAsSlice(u32, args.states);
                    for (states) |state| if (state == 4) {
                        self.activated = true;
                    };
                },
                else => {},
            }
        }
        fn buffer(self: *@This(), _: wl.wl_buffer, _: wl.wl_buffer.Event) void {
            self.released = true;
        }
        fn frame(self: *@This(), _: wl.wl_callback, _: wl.wl_callback.Event) void {
            self.frame_done = true;
        }
        fn keyboard(self: *@This(), _: wl.wl_keyboard, event: wl.wl_keyboard.Event) void {
            switch (event) {
                .keymap => |args| {
                    self.keymap_size = args.size;
                    _ = std.c.close(args.fd);
                },
                .enter => self.entered = true,
                else => {},
            }
        }
    };
    var window: Window = .{};
    const keyboard = globals.seat.?.get_keyboard();
    keyboard.listen(Window, &window, Window.keyboard);
    const surface = globals.compositor.?.create_surface();
    const xdg_surface = globals.wm_base.?.get_xdg_surface(surface);
    xdg_surface.listen(Window, &window, Window.xdgSurface);
    const toplevel = xdg_surface.get_toplevel();
    toplevel.listen(Window, &window, Window.toplevel);
    toplevel.set_title("native test");
    surface.commit();
    try connection.roundtrip();
    try std.testing.expectEqual(@as(u32, 1), window.configured);
    try std.testing.expect(window.keymap_size > 1000);

    // A 100x50 opaque red buffer.
    const width = 100;
    const height = 50;
    const fd = libc.memfd_create("buffer", 0x0001);
    defer _ = std.c.close(fd);
    try std.testing.expectEqual(@as(c_int, 0), libc.ftruncate(fd, width * height * 4));
    const memory = libc.mmap(null, width * height * 4, libc.PROT_READ | libc.PROT_WRITE, libc.MAP_SHARED, fd, 0).?;
    defer _ = libc.munmap(memory, width * height * 4);
    @memset(@as([*]u32, @ptrCast(@alignCast(memory)))[0 .. width * height], 0xffff0000);
    const pool = globals.shm.?.create_pool(fd, width * height * 4);
    const buffer = pool.create_buffer(0, width, height, width * 4, 0);
    buffer.listen(Window, &window, Window.buffer);
    pool.destroy();
    surface.attach(buffer, 0, 0);
    surface.damage_buffer(0, 0, width, height);
    const callback = surface.frame();
    callback.listen(Window, &window, Window.frame);
    surface.commit();
    var deadline = util.monotonicTime() + 3_000_000;
    while (!window.frame_done and util.monotonicTime() < deadline) _ = try connection.dispatchTimeout(100);
    try std.testing.expect(window.frame_done);
    try std.testing.expect(window.released);
    try std.testing.expect(window.activated);
    try std.testing.expect(window.entered);
    // Windows open maximized; this one draws less than it was offered, from the corner.
    deadline = util.monotonicTime() + 3_000_000;
    while (handle.pixel(50, 25).value != 0xffff0000 and util.monotonicTime() < deadline) util.sleep(10 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u32, 0xffff0000), handle.pixel(50, 25).value);
    try std.testing.expectEqual(@as(u32, 0xff303030), handle.pixel(640, 360).value);
    buffer.destroy();
    toplevel.destroy();
    xdg_surface.destroy();
    surface.destroy();
    try connection.roundtrip();
}

fn sameApp(a: *const Toplevel, b: *const Toplevel) bool {
    return a == b or (a.app_id.len > 0 and std.mem.eql(u8, a.app_id, b.app_id));
}

fn launch(a: std.mem.Allocator, comptime command: [:0]const u8) void {
    @import("desktop-command.zig").commandLine(a, command, "/proc/self/exe " ++ command);
}

fn launchTerminal(a: std.mem.Allocator) void {
    @import("desktop-command.zig").commandLine(a, "Terminal", "ghostty");
}

/// Keysyms the compositor binds, from xkbcommon-keysyms.h.
const keysyms = struct {
    const Tab: u32 = 0xff09;
    const ISO_Left_Tab: u32 = 0xfe20;
    const grave: u32 = 0x60;
    const asciitilde: u32 = 0x7e;
    const Escape: u32 = 0xff1b;
    const Return: u32 = 0xff0d;
    const KP_Enter: u32 = 0xff8d;
    const Left: u32 = 0xff51;
    const Up: u32 = 0xff52;
    const Right: u32 = 0xff53;
    const Down: u32 = 0xff54;
    const F4: u32 = 0xffc1;
    const Super_L: u32 = 0xffeb;
    const Caps_Lock: u32 = 0xffe5;
    const Num_Lock: u32 = 0xff7f;
    const Print: u32 = 0xff61;
    const a: u32 = 0x61;
    const d: u32 = 0x64;
    const e: u32 = 0x65;
    const E: u32 = 0x45;
    const l: u32 = 0x6c;
    const XF86MonBrightnessUp: u32 = 0x1008ff02;
    const XF86MonBrightnessDown: u32 = 0x1008ff03;
    const XF86AudioLowerVolume: u32 = 0x1008ff11;
    const XF86AudioMute: u32 = 0x1008ff12;
    const XF86AudioRaiseVolume: u32 = 0x1008ff13;
    const XF86AudioMicMute: u32 = 0x1008ffb2;
};

test "bound keysyms match the names xkbcommon gives them" {
    inline for (@typeInfo(keysyms).@"struct".decl_names) |name| {
        try std.testing.expectEqual(@as(?u32, @field(keysyms, name)), xkb.keysymFromName(name));
    }
}
