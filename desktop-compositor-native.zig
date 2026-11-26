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

const Role = enum { none, toplevel, popup, subsurface, cursor };

const Surface = struct {
    comp: *Compositor,
    resource: ws.wl_surface,
    role: Role = .none,
    xdg: ?*XdgSurface = null,
    subsurface: ?*Subsurface = null,
    /// Pending state, applied on commit.
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
    entered: bool = false,

    fn mapped(self: *const Surface) bool {
        return self.pixels.len > 0;
    }

    /// Size in surface-local (logical) coordinates.
    fn logicalWidth(self: *const Surface) i32 {
        return @divTrunc(@as(i32, @intCast(self.width)), @max(1, self.scale));
    }
    fn logicalHeight(self: *const Surface) i32 {
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
            .set_opaque_region, .set_input_region, .set_buffer_transform => {},
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
        self.frames.appendSlice(self.comp.a, self.pending_frames.items) catch {};
        self.pending_frames.clearRetainingCapacity();
        for (self.children.items) |child| child.parentCommitted();
        if (self.xdg) |xdg| xdg.committed();
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

    /// Draws this surface and its subsurfaces with its origin at (x, y).
    fn draw(self: *Surface, target: raster.Buffer, x: i32, y: i32) void {
        if (self.mapped()) {
            const image: raster.Image = .{ .pixels = std.mem.sliceAsBytes(self.pixels), .width = self.width, .height = self.height, .stride = self.width * 4, .format = .argb };
            raster.blit(target, image, .{ .x = @floatFromInt(x), .y = @floatFromInt(y), .width = @floatFromInt(self.logicalWidth()), .height = @floatFromInt(self.logicalHeight()) }, null) catch {};
        }
        for (self.children.items) |child| if (child.surface) |surface| surface.draw(target, x + child.x, y + child.y);
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
    placed: bool = false,
    activated: bool = false,

    fn handle(self: *Toplevel, _: ws.xdg_toplevel, request: ws.xdg_toplevel.Request) void {
        const a = self.comp.a;
        switch (request) {
            .set_title => |args| {
                a.free(self.title);
                self.title = a.dupe(u8, args.title) catch &.{};
            },
            .set_app_id => |args| {
                a.free(self.app_id);
                self.app_id = a.dupe(u8, args.app_id) catch &.{};
            },
            else => {},
        }
    }

    fn configure(self: *Toplevel) void {
        var states: [1]u32 = undefined;
        var count: usize = 0;
        if (self.activated) {
            states[count] = ws.xdg_toplevel.State.activated;
            count += 1;
        }
        self.resource.sendConfigure(0, 0, std.mem.sliceAsBytes(states[0..count]));
        if (self.xdg) |xdg| xdg.sendConfigure();
    }

    fn mapChanged(self: *Toplevel, mapped: bool) void {
        if (mapped == self.mapped) return;
        const comp = self.comp;
        self.mapped = mapped;
        if (mapped) {
            if (!self.placed) {
                // New windows open centred on the output.
                self.placed = true;
                const geometry = if (self.xdg) |xdg| xdg.windowGeometry() else Rect{};
                const output = comp.output;
                self.x = @divTrunc(@as(i32, @intCast(output.width)) - geometry.width, 2);
                self.y = @max(0, @divTrunc(@as(i32, @intCast(output.height)) - geometry.height, 2));
            }
            comp.toplevels.append(comp.a, self) catch {};
            if (self.xdg) |xdg| if (xdg.surface) |surface| comp.output.enter(surface);
            comp.focus(self);
        } else {
            removeItem(*Toplevel, &comp.toplevels, self);
            if (comp.focused == self) {
                comp.focused = null;
                comp.focus(if (comp.toplevels.items.len > 0) comp.toplevels.items[comp.toplevels.items.len - 1] else null);
            }
        }
        comp.scheduleRepaint();
    }

    fn destroyed(self: *Toplevel, _: ws.xdg_toplevel) void {
        self.mapChanged(false);
        if (self.xdg) |xdg| xdg.toplevel = null;
        if (self.comp.focused == self) self.comp.focused = null;
        self.comp.a.free(self.title);
        self.comp.a.free(self.app_id);
        self.comp.a.destroy(self);
    }
};

const Popup = struct {
    comp: *Compositor,
    resource: ws.xdg_popup,
    xdg: ?*XdgSurface,
    parent: ?*XdgSurface,
    positioner: Positioner,
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

    /// The parent's origin on the output and its window geometry offset.
    fn parentOrigin(self: *const Popup) ?[2]i32 {
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
        const bounds: Rect = .{ .x = -origin[0], .y = -origin[1], .width = @intCast(self.comp.output.width), .height = @intCast(self.comp.output.height) };
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

// ------------------------------------------------------------------ Output

const Output = struct {
    comp: *Compositor,
    name: []const u8 = "HEADLESS-1",
    width: u32,
    height: u32,
    scale: i32 = 1,
    pixels: []u32,
    resources: std.ArrayList(ws.wl_output) = .empty,
    repaint: *wire.Loop.Source = undefined,
    scheduled: bool = false,
    /// Frames rendered so far; tests wait on it.
    frames: u64 = 0,

    fn bind(data: ?*anyopaque, resource: wire.Resource) void {
        const self: *Output = @ptrCast(@alignCast(data));
        const output: ws.wl_output = .{ .resource = resource };
        output.setHandler(Output, self, handle, destroyed);
        self.resources.append(self.comp.a, output) catch {};
        output.sendGeometry(0, 0, 0, 0, ws.wl_output.Subpixel.unknown, "Headless", "Headless output", ws.wl_output.Transform.normal);
        output.sendMode(ws.wl_output.Mode.current | ws.wl_output.Mode.preferred, @intCast(self.width), @intCast(self.height), 60000);
        if (output.version() >= 2) output.sendScale(self.scale);
        if (output.version() >= 4) {
            output.sendName(self.name);
            output.sendDescription("Headless output");
        }
        if (output.version() >= 2) output.sendDone();
        // Mapped surfaces of this client are on the output.
        for (self.comp.surfaces.items) |surface| if (surface.entered and surface.resource.client() == output.client()) surface.resource.sendEnter(output);
    }

    fn handle(_: *Output, _: ws.wl_output, _: ws.wl_output.Request) void {}

    fn destroyed(self: *Output, resource: ws.wl_output) void {
        removeItem(ws.wl_output, &self.resources, resource);
    }

    fn enter(self: *Output, surface: *Surface) void {
        if (surface.entered) return;
        surface.entered = true;
        for (self.resources.items) |output| if (output.client() == surface.resource.client()) surface.resource.sendEnter(output);
        if (surface.resource.version() >= 6) surface.resource.sendPreferredBufferScale(self.scale);
    }

    fn render(self: *Output) void {
        const comp = self.comp;
        const target: raster.Buffer = .{ .pixels = self.pixels, .width = self.width, .height = self.height };
        @memset(self.pixels, comp.background);
        for (comp.toplevels.items) |toplevel| {
            const xdg = toplevel.xdg orelse continue;
            const surface = xdg.surface orelse continue;
            const geometry = xdg.windowGeometry();
            surface.draw(target, toplevel.x - geometry.x, toplevel.y - geometry.y);
        }
        for (comp.popups.items) |popup| {
            if (!popup.mapped) continue;
            const xdg = popup.xdg orelse continue;
            const surface = xdg.surface orelse continue;
            const origin = popup.parentOrigin() orelse continue;
            const geometry = xdg.windowGeometry();
            surface.draw(target, origin[0] + popup.rect.x - geometry.x, origin[1] + popup.rect.y - geometry.y);
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

// ------------------------------------------------------------------ Seat

const Seat = struct {
    comp: *Compositor,
    seats: std.ArrayList(ws.wl_seat) = .empty,
    keyboards: std.ArrayList(ws.wl_keyboard) = .empty,
    pointers: std.ArrayList(ws.wl_pointer) = .empty,
    keyboard_focus: ?*Surface = null,
    cursor: ?*Surface = null,
    keymap_fd: wire.Fd = -1,
    keymap_size: u32 = 0,

    fn init(self: *Seat) !void {
        const fd = libc.memfd_create("desktop-keymap", 0x0001 | 0x0002); // MFD_CLOEXEC | MFD_ALLOW_SEALING
        if (fd < 0) return error.Keymap;
        errdefer _ = std.c.close(fd);
        const size = keymap_text.len + 1;
        if (libc.ftruncate(fd, @intCast(size)) != 0) return error.Keymap;
        var written: usize = 0;
        while (written < keymap_text.len) {
            const count = std.c.write(fd, keymap_text[written..].ptr, keymap_text.len - written);
            if (count <= 0) return error.Keymap;
            written += @intCast(count);
        }
        // Clients map the keymap read-only and must not be able to change it for others.
        _ = std.c.fcntl(fd, 1033, @as(c_int, 0x0001 | 0x0002 | 0x0004 | 0x0008)); // F_ADD_SEALS: SEAL, SHRINK, GROW, WRITE
        self.keymap_fd = fd;
        self.keymap_size = @intCast(size);
    }

    fn deinit(self: *Seat) void {
        if (self.keymap_fd >= 0) _ = std.c.close(self.keymap_fd);
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
                keyboard.sendKeymap(ws.wl_keyboard.KeymapFormat.xkb_v1, self.keymap_fd, self.keymap_size);
                if (keyboard.version() >= 4) keyboard.sendRepeatInfo(25, 600);
                if (self.keyboard_focus) |surface| if (surface.resource.client() == keyboard.client()) {
                    keyboard.sendEnter(self.comp.server.nextSerial(), surface.resource, &.{});
                    keyboard.sendModifiers(self.comp.server.nextSerial(), 0, 0, 0, 0);
                };
            },
            .get_pointer => |args| {
                args.id.setHandler(Seat, self, pointerRequest, pointerGone);
                self.pointers.append(self.comp.a, args.id) catch {};
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
            keyboard.sendModifiers(server.nextSerial(), 0, 0, 0, 0);
        };
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
    output: *Output = undefined,
    seat: Seat = undefined,
    surfaces: std.ArrayList(*Surface) = .empty,
    /// Mapped toplevels, bottom to top.
    toplevels: std.ArrayList(*Toplevel) = .empty,
    popups: std.ArrayList(*Popup) = .empty,
    focused: ?*Toplevel = null,
    selection: ?*DataSource = null,
    data_devices: std.ArrayList(*DataDevice) = .empty,
    background: u32 = 0xff303030,

    fn init(self: *Compositor, width: u32, height: u32) !void {
        const output = try self.a.create(Output);
        errdefer self.a.destroy(output);
        output.* = .{ .comp = self, .width = width, .height = height, .pixels = try self.a.alloc(u32, @as(usize, width) * height) };
        errdefer self.a.free(output.pixels);
        output.repaint = try self.server.loop.timer(output, &Output.repaintReady);
        self.output = output;
        self.seat = .{ .comp = self };
        try self.seat.init();
        const server = self.server;
        _ = try server.createGlobal(&ws.wl_compositor.interface, 6, self, &bindCompositor);
        _ = try server.createGlobal(&ws.wl_subcompositor.interface, 1, self, &bindSubcompositor);
        _ = try server.createGlobal(&ws.wl_shm.interface, 2, self, &bindShm);
        _ = try server.createGlobal(&ws.wl_output.interface, 4, output, &Output.bind);
        _ = try server.createGlobal(&ws.xdg_wm_base.interface, 6, self, &bindWmBase);
        _ = try server.createGlobal(&ws.zxdg_output_manager_v1.interface, 3, self, &bindOutputManager);
        _ = try server.createGlobal(&ws.wl_seat.interface, 9, &self.seat, &Seat.bind);
        _ = try server.createGlobal(&ws.wl_data_device_manager.interface, 3, self, &bindDataDeviceManager);
        _ = try server.createGlobal(&ws.zwlr_data_control_manager_v1.interface, 1, self, &bindDataControlManager);
        output.render();
    }

    fn deinit(self: *Compositor) void {
        self.seat.deinit();
        self.surfaces.deinit(self.a);
        self.toplevels.deinit(self.a);
        self.popups.deinit(self.a);
        self.data_devices.deinit(self.a);
        self.output.resources.deinit(self.a);
        self.a.free(self.output.pixels);
        self.a.destroy(self.output);
    }

    fn scheduleRepaint(self: *Compositor) void {
        const output = self.output;
        if (output.scheduled) return;
        output.scheduled = true;
        // Composite at most once per 60 Hz frame, batching commits that arrive together.
        wire.Loop.arm(output.repaint, 16);
    }

    /// Offers the selection to the newly focused client, as wlroots does on focus.
    fn sendSelection(self: *Compositor) void {
        const surface = self.seat.keyboard_focus orelse return;
        for (self.data_devices.items) |device| if (!device.control and device.resource.client == surface.resource.client()) device.offer(self.selection);
    }

    fn focus(self: *Compositor, toplevel: ?*Toplevel) void {
        if (self.focused == toplevel) return;
        if (self.focused) |old| {
            old.activated = false;
            if (old.xdg != null) old.configure();
        }
        self.focused = toplevel;
        if (toplevel) |new| {
            new.activated = true;
            new.configure();
            // Raise the focused window.
            removeItem(*Toplevel, &self.toplevels, new);
            self.toplevels.append(self.a, new) catch {};
        }
        const surface = if (toplevel) |t| (if (t.xdg) |xdg| xdg.surface else null) else null;
        self.seat.focusSurface(surface);
        self.sendSelection();
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
            .create_region => |args| args.id.setHandler(Compositor, self, null, null),
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
                const output = self.output;
                const xdg_output = args.id;
                xdg_output.setHandler(Compositor, self, null, null);
                xdg_output.sendLogicalPosition(0, 0);
                xdg_output.sendLogicalSize(@divTrunc(@as(i32, @intCast(output.width)), output.scale), @divTrunc(@as(i32, @intCast(output.height)), output.scale));
                if (xdg_output.version() >= 2) {
                    xdg_output.sendName(output.name);
                    xdg_output.sendDescription("Headless output");
                }
                if (xdg_output.version() < 3) xdg_output.sendDone();
                // wl_output.done completes xdg_output state since version 3.
                for (output.resources.items) |wl_output| if (wl_output.client() == xdg_output.client() and wl_output.version() >= 2) wl_output.sendDone();
            },
        }
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
        comp.init(self.width, self.height) catch {
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
        while (running) {
            const before = comp.output.frames;
            server.dispatch(-1);
            if (comp.output.frames != before) self.publish(comp.output);
        }
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
    // Centred on the 1280x720 output.
    deadline = util.monotonicTime() + 3_000_000;
    while (handle.pixel(640, 360).value != 0xffff0000 and util.monotonicTime() < deadline) util.sleep(10 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u32, 0xffff0000), handle.pixel(640, 360).value);
    try std.testing.expectEqual(@as(u32, 0xff303030), handle.pixel(10, 10).value);
    buffer.destroy();
    toplevel.destroy();
    xdg_surface.destroy();
    surface.destroy();
    try connection.roundtrip();
}
