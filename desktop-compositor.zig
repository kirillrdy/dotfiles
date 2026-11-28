//! The desktop compositor: Wayland server state on desktop-wire-server.zig,
//! composition on the GPU with desktop-gl.zig or in software with
//! desktop-raster.zig, and displays and input through DRM, libinput and logind.
//! Outputs are headless, windows of another Wayland session, or real displays.
//!
//! Shared-memory buffers are copied on commit and released at once, so clients
//! may reuse them immediately.
const std = @import("std");
const wire = @import("wayland-server-wire");
const ws = @import("wayland-server");
const raster = @import("desktop-raster.zig");
const Xcursor = @import("desktop-xcursor.zig");
const Gl = @import("desktop-gl.zig");
const util = @import("desktop-util.zig");
const libc = @import("desktop-libc.zig");
const keymap_text = @import("default-keymap").text;
const xkb = @import("desktop-xkb.zig");

const Rect = struct {
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,

    /// The smallest rectangle covering both.
    fn merge(self: Rect, other: Rect) Rect {
        const left = @min(self.x, other.x);
        const top = @min(self.y, other.y);
        return .{ .x = left, .y = top, .width = @max(self.x +| self.width, other.x +| other.width) - left, .height = @max(self.y +| self.height, other.y +| other.height) - top };
    }
};

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
    /// Shared memory, or null for a single-pixel buffer of `solid` colour.
    pool: ?*Pool,
    solid: u32 = 0,
    /// A client's GPU buffer, imported for sampling; such buffers have no pool.
    image: Gl.EGLImage = null,
    offset: usize,
    width: u32,
    height: u32,
    stride: usize,
    format: u32,
    /// Kept alive while held by a surface even if the client destroys wl_buffer.
    refs: u32 = 1,
    alive: bool = true,

    fn unref(self: *Buffer) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        if (self.image != null) if (self.comp.drm) |backend| if (backend.renderer) |renderer| renderer.destroyImage(self.image);
        if (self.pool) |pool| pool.unref();
        self.comp.a.destroy(self);
    }

    /// Copies premultiplied ARGB into the buffer, as capture clients receive it.
    fn write(self: *Buffer, pixels: []const u32, opaque_pixels: bool) bool {
        return self.writeRect(pixels, self.width, 0, 0, opaque_pixels);
    }

    fn writeRect(self: *Buffer, pixels: []const u32, source_stride: usize, x: usize, y: usize, opaque_pixels: bool) bool {
        if (self.bytes() == null) return false;
        const size = self.offset + self.stride * self.height;
        const pool = self.pool orelse return false;
        const memory = libc.mmap(null, size, libc.PROT_READ | libc.PROT_WRITE, libc.MAP_SHARED, pool.fd, 0) orelse return false;
        if (memory == libc.MAP_FAILED) return false;
        defer _ = libc.munmap(memory, size);
        const target: [*]u8 = @ptrCast(memory);
        for (0..self.height) |row| {
            const line = target[self.offset + row * self.stride ..][0 .. self.width * 4];
            for (pixels[(y + row) * source_stride + x ..][0..self.width], 0..) |pixel, column|
                std.mem.writeInt(u32, line[column * 4 ..][0..4], if (opaque_pixels) pixel | 0xff000000 else pixel, .little);
        }
        return true;
    }

    /// The pixels, if the pool still holds them. A client that shrinks the
    /// file behind the mapping must not make the compositor fault.
    fn bytes(self: *Buffer) ?[]const u8 {
        const size = self.stride * self.height;
        const pool = self.pool orelse return null;
        if (self.offset + size > pool.map.len) return null;
        // The file must still cover the buffer, or reading it would fault.
        const end = std.os.linux.lseek(pool.fd, 0, std.os.linux.SEEK.END);
        if (std.os.linux.errno(end) != .SUCCESS or end < self.offset + size) return null;
        return pool.map[self.offset..][0..size];
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

const Role = enum { none, toplevel, popup, subsurface, cursor, layer, lock, ime_popup, drag_icon };

const Surface = struct {
    comp: *Compositor,
    resource: ws.wl_surface,
    role: Role = .none,
    xdg: ?*XdgSurface = null,
    subsurface: ?*Subsurface = null,
    layer: ?*Layer = null,
    lock_surface: ?*LockSurface = null,
    ime_popup: ?*ImePopup = null,
    /// Pending state, applied on commit.
    /// Input regions; null accepts input everywhere on the surface.
    pending_input: ?[]Region.Op = null,
    pending_input_set: bool = false,
    input: ?[]Region.Op = null,
    pending_buffer: ?*Buffer = null,
    pending_attach: bool = false,
    pending_scale: i32 = 1,
    pending_frames: std.ArrayList(ws.wl_callback) = .empty,
    pending_releases: std.ArrayList(ws.wl_callback) = .empty,
    held_releases: std.ArrayList(ws.wl_callback) = .empty,
    /// Current content: premultiplied ARGB, buffer-sized.
    pixels: []u32 = &.{},
    width: u32 = 0,
    height: u32 = 0,
    opaque_format: bool = false,
    /// The GPU copy of `pixels`, uploaded when the content changed.
    texture: u32 = 0,
    texture_stale: bool = true,
    /// The client's GPU buffer being shown, released when replaced. `pixels`
    /// then holds a CPU copy only once something needs one.
    held: ?*Buffer = null,
    cpu_stale: bool = false,
    /// Explicit sync: the surface's syncobj object, the client's fence the
    /// GPU waits for before sampling the held buffer, and the point that
    /// signals when the buffer is released.
    sync: ?*SyncSurface = null,
    acquire_fence: i32 = -1,
    release: ?SyncPoint = null,
    scale: i32 = 1,
    frames: std.ArrayList(ws.wl_callback) = .empty,
    /// Subsurfaces drawn above this surface, bottom to top.
    children: std.ArrayList(*Subsurface) = .empty,
    /// The output the surface is shown on.
    entered: ?*Output = null,
    /// wp_viewport destination size, which overrides buffer size / scale.
    pending_destination: ?[2]i32 = null,
    destination: ?[2]i32 = null,
    /// wp_viewport source crop, in surface coordinates of the transformed buffer.
    pending_source: ?[4]f64 = null,
    source: ?[4]f64 = null,
    /// wl_surface buffer transform, a wl_output.transform value.
    pending_transform: u32 = 0,
    transform: u32 = 0,
    viewport: ?ws.wp_viewport = null,
    /// Damage collected for the next commit, in surface coordinates.
    pending_damage: ?Rect = null,
    fractional: ?ws.wp_fractional_scale_v1 = null,

    /// Damage in surface coordinates since the last commit.
    fn addDamage(self: *Surface, x: i32, y: i32, width: i32, height: i32) void {
        if (width <= 0 or height <= 0) return;
        const box: Rect = .{ .x = x, .y = y, .width = width, .height = height };
        self.pending_damage = if (self.pending_damage) |current| current.merge(box) else box;
    }

    fn mapped(self: *const Surface) bool {
        return self.width > 0 and (self.pixels.len > 0 or self.held != null);
    }

    /// Shows a GPU buffer; it stays the client's until the next one replaces it.
    fn hold(self: *Surface, buffer: *Buffer) void {
        if (self.held != buffer) {
            self.releaseHeld();
            buffer.refs += 1;
            self.held = buffer;
        }
        self.width = buffer.width;
        self.height = buffer.height;
        self.opaque_format = buffer.format == 0x34325258 or buffer.format == 0x34324258; // XRGB8888, XBGR8888
        self.cpu_stale = true;
    }

    fn releaseHeld(self: *Surface) void {
        self.signalRelease();
        for (self.held_releases.items) |callback| callback.sendDone(0);
        self.held_releases.clearRetainingCapacity();
        const buffer = self.held orelse return;
        self.held = null;
        self.cpu_stale = false;
        if (buffer.alive) buffer.resource.sendRelease();
        buffer.unref();
    }

    /// Signals the held buffer's release point once the GPU is done with the
    /// frames drawn so far, as the last frame's fence says.
    fn signalRelease(self: *Surface) void {
        const point = self.release orelse return;
        self.release = null;
        defer point.timeline.unref();
        const fence = if (self.comp.drm) |backend| if (backend.renderer) |renderer| renderer.last_fence else -1 else -1;
        if (fence >= 0 and point.timeline.timeline.importPoint(point.value, fence)) return;
        _ = point.timeline.timeline.signal(point.value);
    }

    /// Checks and takes the explicit sync points of a commit; false after a protocol error.
    fn takeSyncPoints(self: *Surface) ?struct { acquire: ?SyncPoint, release: ?SyncPoint } {
        const sync = self.sync orelse return .{ .acquire = null, .release = null };
        const Error = ws.wp_linux_drm_syncobj_surface_v1.Error;
        const buffer: ?*Buffer = if (self.pending_attach) self.pending_buffer else null;
        if (buffer == null) {
            if (sync.acquire != null or sync.release != null) {
                sync.resource.postError(Error.no_buffer, "timeline points without a buffer", .{});
                return null;
            }
            return .{ .acquire = null, .release = null };
        }
        const acquire = sync.acquire orelse {
            sync.resource.postError(Error.no_acquire_point, "no acquire point", .{});
            return null;
        };
        const release = sync.release orelse {
            sync.resource.postError(Error.no_release_point, "no release point", .{});
            return null;
        };
        if (buffer.?.image == null) {
            sync.resource.postError(Error.unsupported_buffer, "explicit sync needs a dmabuf", .{});
            return null;
        }
        if (acquire.timeline == release.timeline and acquire.value >= release.value) {
            sync.resource.postError(Error.conflicting_points, "the acquire point is not before the release point", .{});
            return null;
        }
        sync.acquire = null;
        sync.release = null;
        return .{ .acquire = acquire, .release = release };
    }

    /// Turns the acquire point into a fence for the GPU to wait on.
    fn useAcquirePoint(self: *Surface, point: SyncPoint) void {
        defer point.timeline.unref();
        if (self.acquire_fence >= 0) _ = std.c.close(self.acquire_fence);
        self.acquire_fence = -1;
        const timeline = point.timeline.timeline;
        // Clients normally submit before committing; bound the wait so a stalled client cannot freeze the compositor.
        const timeout_ns = 50 * std.time.ns_per_ms;
        if (timeline.waitSubmitted(point.value, timeout_ns)) {
            if (timeline.exportPoint(point.value)) |fence| {
                self.acquire_fence = fence;
                return;
            }
        }
        // Without a fence to hand the GPU, wait briefly for the client's work here.
        _ = timeline.waitSignalled(point.value, timeout_ns);
    }

    /// Makes `texture` show the current content: the GPU buffer, or uploaded pixels.
    fn syncTexture(self: *Surface, renderer: *Gl.Renderer) void {
        if (self.texture == 0) self.texture = Gl.Renderer.createTexture();
        if (!self.texture_stale) return;
        self.texture_stale = false;
        // The client's rendering must finish before the buffer is sampled.
        if (self.acquire_fence >= 0) {
            _ = renderer.waitFence(self.acquire_fence);
            self.acquire_fence = -1;
        }
        if (self.held) |buffer| renderer.bindImage(self.texture, buffer.image) else renderer.upload(self.texture, self.pixels, self.width, self.height);
    }

    fn ensurePixels(self: *Surface, count: usize) bool {
        if (self.pixels.len == count) return true;
        self.comp.a.free(self.pixels);
        self.pixels = self.comp.a.alloc(u32, count) catch {
            self.pixels = &.{};
            return false;
        };
        return true;
    }

    /// Whether `pixels` holds the content, reading a GPU buffer back if needed.
    fn cpuReady(self: *Surface) bool {
        if (self.held != null and self.cpu_stale) {
            const renderer = (self.comp.drm orelse return false).renderer orelse return false;
            if (!self.ensurePixels(@as(usize, self.width) * self.height)) return false;
            self.syncTexture(renderer);
            if (!renderer.readTexture(self.texture, self.width, self.height, self.pixels)) return false;
            if (self.opaque_format) for (self.pixels) |*pixel| {
                pixel.* |= 0xff000000;
            };
            self.cpu_stale = false;
        }
        return self.pixels.len == @as(usize, self.width) * self.height and self.pixels.len > 0;
    }

    /// Size in surface-local (logical) coordinates.
    fn logicalWidth(self: *const Surface) i32 {
        if (self.destination) |size| return size[0];
        if (self.source) |crop| return @intFromFloat(@round(crop[2]));
        return @divTrunc(@as(i32, @intCast(self.transformedSize()[0])), @max(1, self.scale));
    }
    fn logicalHeight(self: *const Surface) i32 {
        if (self.destination) |size| return size[1];
        if (self.source) |crop| return @intFromFloat(@round(crop[3]));
        return @divTrunc(@as(i32, @intCast(self.transformedSize()[1])), @max(1, self.scale));
    }

    /// The buffer's size as displayed: quarter turns swap its sides.
    fn transformedSize(self: *const Surface) [2]u32 {
        return if (self.transform & 1 != 0) .{ self.height, self.width } else .{ self.width, self.height };
    }

    /// How the surface's texture is sampled: the source crop, then the
    /// inverse of the buffer transform (the buffer holds content already
    /// turned by it, counter-clockwise, flipping first).
    fn uvMap(self: *const Surface) Gl.UvMap {
        const shown = self.transformedSize();
        var crop = [4]f64{ 0, 0, 1, 1 };
        if (self.source) |source| if (shown[0] > 0 and shown[1] > 0) {
            const scale: f64 = @floatFromInt(@max(1, self.scale));
            const w: f64 = @floatFromInt(shown[0]);
            const h: f64 = @floatFromInt(shown[1]);
            crop = .{ source[0] * scale / w, source[1] * scale / h, source[2] * scale / w, source[3] * scale / h };
        };
        const m = Gl.transformMatrix(self.transform);
        const origin = [2]f64{ m[0] * crop[0] + m[1] * crop[1] + m[2], m[3] * crop[0] + m[4] * crop[1] + m[5] };
        return .{
            .origin = .{ @floatCast(origin[0]), @floatCast(origin[1]) },
            .x = .{ @floatCast(m[0] * crop[2]), @floatCast(m[3] * crop[2]) },
            .y = .{ @floatCast(m[1] * crop[3]), @floatCast(m[4] * crop[3]) },
        };
    }

    fn handle(self: *Surface, resource: ws.wl_surface, request: ws.wl_surface.Request) void {
        switch (request) {
            .destroy => {},
            .attach => |args| {
                self.pending_attach = true;
                self.pending_buffer = if (args.buffer) |buffer| buffer.data(Buffer) else null;
                if (resource.version() >= 5 and (args.x != 0 or args.y != 0)) {
                    resource.postError(ws.wl_surface.Error.invalid_offset, "attach offsets are set with wl_surface.offset", .{});
                }
            },
            .offset => {},
            .damage => |args| self.addDamage(args.x, args.y, args.width, args.height),
            .damage_buffer => |args| {
                // Buffer pixels to surface coordinates, rounding outwards.
                const fx = if (self.width > 0) @as(f64, @floatFromInt(self.logicalWidth())) / @as(f64, @floatFromInt(self.transformedSize()[0])) else 1;
                const fy = if (self.height > 0) @as(f64, @floatFromInt(self.logicalHeight())) / @as(f64, @floatFromInt(self.transformedSize()[1])) else 1;
                const x0: f64 = @floor(@as(f64, @floatFromInt(args.x)) * fx);
                const y0: f64 = @floor(@as(f64, @floatFromInt(args.y)) * fy);
                const x1: f64 = @ceil(@as(f64, @floatFromInt(args.x +| args.width)) * fx);
                const y1: f64 = @ceil(@as(f64, @floatFromInt(args.y +| args.height)) * fy);
                self.addDamage(clampInt(x0), clampInt(y0), clampInt(x1 - x0), clampInt(y1 - y0));
            },
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
            .set_opaque_region => {},
            .set_buffer_transform => |args| {
                if (args.transform > 7) return resource.postError(ws.wl_surface.Error.invalid_transform, "invalid buffer transform", .{});
                self.pending_transform = @intCast(args.transform);
            },
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
        const points = self.takeSyncPoints() orelse return;
        // A commit that maps, unmaps or resizes redraws everything; otherwise
        // only what the client damaged.
        const was_mapped = self.mapped();
        const old_size = [2]i32{ self.logicalWidth(), self.logicalHeight() };
        const attached = self.pending_attach;
        defer {
            var damage = self.pending_damage;
            self.pending_damage = null;
            const whole: Rect = .{ .width = self.logicalWidth(), .height = self.logicalHeight() };
            if (attached and damage == null) damage = whole;
            // Clients damage "everything" with huge rectangles; keep to the surface.
            if (damage) |box| {
                const left = @max(box.x, 0);
                const top = @max(box.y, 0);
                const right = @min(box.x +| box.width, whole.width);
                const bottom = @min(box.y +| box.height, whole.height);
                damage = if (right > left and bottom > top) .{ .x = left, .y = top, .width = right - left, .height = bottom - top } else null;
            }
            const unchanged = was_mapped == self.mapped() and old_size[0] == self.logicalWidth() and old_size[1] == self.logicalHeight();
            if (unchanged) self.comp.surfaceDamaged(self, damage) else self.comp.scheduleRepaint();
        }
        if (self.pending_attach) {
            self.pending_attach = false;
            self.texture_stale = true;
            if (self.pending_buffer) |buffer| {
                if (buffer.image != null) {
                    self.hold(buffer);
                    // A re-committed buffer's earlier release point is released now.
                    self.signalRelease();
                    self.release = points.release;
                    if (points.acquire) |acquire| self.useAcquirePoint(acquire);
                    // GPU buffers stay held until replaced; release callbacks fire then.
                    self.held_releases.appendSlice(self.comp.a, self.pending_releases.items) catch {
                        for (self.pending_releases.items) |callback| callback.sendDone(0);
                    };
                    self.pending_releases.clearRetainingCapacity();
                } else {
                    self.releaseHeld();
                    self.copy(buffer);
                    buffer.resource.sendRelease();
                    // SHM buffers are copied at commit, so release callbacks fire with it.
                    for (self.pending_releases.items) |callback| callback.sendDone(0);
                    self.pending_releases.clearRetainingCapacity();
                }
            } else {
                self.releaseHeld();
                self.comp.a.free(self.pixels);
                self.pixels = &.{};
                self.width = 0;
                self.height = 0;
            }
            self.pending_buffer = null;
        }
        self.scale = self.pending_scale;
        self.destination = self.pending_destination;
        self.source = self.pending_source;
        self.transform = self.pending_transform;
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
        if (self.ime_popup != null) self.comp.ime.placePopups();
        for (self.comp.presentations.items) |entry| if (entry.surface == self) {
            entry.committed = true;
        };
        if (self.comp.seat.cursor == self) self.comp.cursorChanged();
    }

    fn copy(self: *Surface, buffer: *Buffer) void {
        if (buffer.pool == null) {
            // A single-pixel buffer stretches to the viewport destination.
            if (!self.ensurePixels(1)) return;
            self.pixels[0] = buffer.solid;
            self.width = 1;
            self.height = 1;
            self.opaque_format = (buffer.solid >> 24) == 0xff;
            return;
        }
        const source = buffer.bytes() orelse {
            self.resource.postError(ws.wl_shm.Error.invalid_fd, "buffer storage shrank", .{});
            return;
        };
        if (!self.ensurePixels(@as(usize, buffer.width) * buffer.height)) return;
        self.width = buffer.width;
        self.height = buffer.height;
        const layout = shmLayout(buffer.format) orelse return;
        self.opaque_format = layout.opaque_pixels;
        for (0..buffer.height) |row| {
            const line = source[row * buffer.stride ..][0 .. buffer.width * layout.bytes];
            const out = self.pixels[row * buffer.width ..][0..buffer.width];
            if (buffer.format == ws.wl_shm.Format.argb8888 or buffer.format == ws.wl_shm.Format.xrgb8888) {
                for (out, 0..) |*pixel, column| {
                    const value = std.mem.readInt(u32, line[column * 4 ..][0..4], .little);
                    pixel.* = if (self.opaque_format) value | 0xff000000 else value;
                }
            } else for (out, 0..) |*pixel, column| {
                pixel.* = shmPixel(buffer.format, line[column * layout.bytes ..]);
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
        if (self.ime_popup) |popup| popup.surface = null;
        for (comp.ime.texts.items) |text| if (text.entered == self) {
            text.entered = null;
        };
        if (self.viewport) |viewport| viewport.setHandler(Compositor, comp, Compositor.inertViewportRequest, null);
        if (self.fractional) |fractional| fractional.setHandler(Surface, self, null, null);
        // Feedback for a surface that goes away is discarded.
        var feedback = comp.presentations.items.len;
        while (feedback > 0) {
            feedback -= 1;
            const entry = comp.presentations.items[feedback];
            if (entry.surface != self) continue;
            entry.surface = null;
            _ = comp.presentations.swapRemove(feedback);
            entry.resource.sendDiscarded();
        }
        for (comp.idle_inhibitors.items) |inhibitor| if (inhibitor.surface == self) {
            inhibitor.surface = null;
        };
        comp.updateInhibition();
        for (self.children.items) |child| child.parent = null;
        self.children.deinit(comp.a);
        for (self.frames.items) |callback| callback.destroyResource();
        for (self.pending_frames.items) |callback| callback.destroyResource();
        for (self.pending_releases.items) |callback| callback.destroyResource();
        for (self.held_releases.items) |callback| callback.destroyResource();
        self.pending_releases.deinit(comp.a);
        self.held_releases.deinit(comp.a);
        self.held_releases = .empty;
        self.frames.deinit(comp.a);
        self.pending_frames.deinit(comp.a);
        if (self.texture != 0) if (comp.drm) |backend| if (backend.renderer) |renderer| renderer.deleteTexture(self.texture);
        self.releaseHeld();
        if (self.acquire_fence >= 0) _ = std.c.close(self.acquire_fence);
        if (self.sync) |sync| sync.surface = null;
        comp.a.free(self.pixels);
        comp.dragSurfaceGone(self);
        removeItem(*Surface, &comp.surfaces, self);
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
    /// Draws the surface tree with surface-local coordinates scaled by
    /// (fx, fy) from (x, y) in output pixels, clipped and faded.
    fn drawGpu(self: *Surface, renderer: *Gl.Renderer, x: f64, y: f64, fx: f64, fy: f64, clip: Gl.Clip, opacity: f32) void {
        if (self.mapped()) {
            self.syncTexture(renderer);
            renderer.drawMapped(self.texture, .{ .x = x, .y = y, .width = @as(f64, @floatFromInt(self.logicalWidth())) * fx, .height = @as(f64, @floatFromInt(self.logicalHeight())) * fy }, self.uvMap(), clip, opacity, self.opaque_format);
        }
        for (self.children.items) |child| if (child.surface) |surface| surface.drawGpu(renderer, x + @as(f64, @floatFromInt(child.x)) * fx, y + @as(f64, @floatFromInt(child.y)) * fy, fx, fy, clip, opacity);
    }

    fn draw(self: *Surface, target: Canvas, x: i32, y: i32, scale: f64) void {
        if (self.mapped()) {
            const fx: f64 = @floatFromInt(x);
            const fy: f64 = @floatFromInt(y);
            target.surface(self, .{ .x = @round(fx * scale), .y = @round(fy * scale), .width = @round(@as(f64, @floatFromInt(self.logicalWidth())) * scale), .height = @round(@as(f64, @floatFromInt(self.logicalHeight())) * scale) });
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

    /// The positioner mirrored horizontally or vertically, for flipping.
    fn flipped(self: Positioner, horizontal: bool) Positioner {
        var result = self;
        // Anchor and gravity share values: 1 top, 2 bottom, 3 left, 4 right,
        // 5 top-left, 6 bottom-left, 7 top-right, 8 bottom-right.
        const swap_x = [_]u32{ 0, 1, 2, 4, 3, 7, 8, 5, 6 };
        const swap_y = [_]u32{ 0, 2, 1, 3, 4, 6, 5, 8, 7 };
        const table = if (horizontal) swap_x else swap_y;
        if (self.anchor < table.len) result.anchor = table[self.anchor];
        if (self.gravity < table.len) result.gravity = table[self.gravity];
        if (horizontal) result.offset_x = -self.offset_x else result.offset_y = -self.offset_y;
        return result;
    }

    /// Fits the popup into `bounds` (parent-relative) as the client allows:
    /// flipping, then sliding, then resizing, along each axis.
    fn constrain(self: Positioner, placed: Rect, bounds: Rect) Rect {
        var result = placed;
        const CA = ws.xdg_positioner.ConstraintAdjustment;
        const fits_x = struct {
            fn check(r: Rect, b: Rect) bool {
                return r.x >= b.x and r.x + r.width <= b.x + b.width;
            }
        }.check;
        const fits_y = struct {
            fn check(r: Rect, b: Rect) bool {
                return r.y >= b.y and r.y + r.height <= b.y + b.height;
            }
        }.check;
        if (!fits_x(result, bounds) and self.adjustment & CA.flip_x != 0) {
            const candidate = self.flipped(true).place();
            if (fits_x(candidate, bounds)) result.x = candidate.x;
        }
        if (!fits_y(result, bounds) and self.adjustment & CA.flip_y != 0) {
            const candidate = self.flipped(false).place();
            if (fits_y(candidate, bounds)) result.y = candidate.y;
        }
        const slide_x = self.adjustment & CA.slide_x != 0;
        const slide_y = self.adjustment & CA.slide_y != 0;
        if (slide_x) {
            if (result.x + result.width > bounds.x + bounds.width) result.x = bounds.x + bounds.width - result.width;
            if (result.x < bounds.x) result.x = bounds.x;
        }
        if (slide_y) {
            if (result.y + result.height > bounds.y + bounds.height) result.y = bounds.y + bounds.height - result.height;
            if (result.y < bounds.y) result.y = bounds.y;
        }
        if (self.adjustment & CA.resize_x != 0) {
            const left = @max(result.x, bounds.x);
            const right = @min(result.x + result.width, bounds.x + bounds.width);
            if (right > left) {
                result.x = left;
                result.width = right - left;
            }
        }
        if (self.adjustment & CA.resize_y != 0) {
            const top = @max(result.y, bounds.y);
            const bottom = @min(result.y + result.height, bounds.y + bounds.height);
            if (bottom > top) {
                result.y = top;
                result.height = bottom - top;
            }
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
        if (self.toplevel) |toplevel| {
            toplevel.mapChanged(surface.mapped() and self.acked);
            // Dialogs size themselves; they stay centred as they do.
            if (toplevel.mapped and toplevel.dialog()) {
                const before = [2]i32{ toplevel.x, toplevel.y };
                toplevel.place();
                if (before[0] != toplevel.x or before[1] != toplevel.y) self.comp.scheduleRepaint();
            }
        }
        if (self.popup) |popup| {
            const mapped = surface.mapped() and self.acked;
            if (mapped != popup.mapped) {
                popup.mapped = mapped;
                if (popup.grabbed) self.comp.updateKeyboardFocus();
            }
        }
    }

    /// Window geometry, defaulting to the surface's own size.
    fn windowGeometry(self: *const XdgSurface) Rect {
        if (self.geometry) |geometry| return geometry;
        const surface = self.surface orelse return .{};
        return .{ .width = surface.logicalWidth(), .height = surface.logicalHeight() };
    }

    fn surfaceGone(self: *XdgSurface) void {
        if (self.toplevel) |toplevel| toplevel.mapChanged(false);
        if (self.popup) |popup| {
            popup.mapped = false;
            if (popup.grabbed) self.comp.updateKeyboardFocus();
        }
        self.surface = null;
    }

    fn destroyed(self: *XdgSurface, resource: ws.xdg_surface) void {
        if ((self.toplevel != null or self.popup != null) and !resource.client().closing)
            resource.postError(ws.xdg_surface.Error.defunct_role_object, "xdg_surface destroyed before its role object", .{});
        if (self.toplevel) |toplevel| toplevel.xdg = null;
        if (self.popup) |popup| popup.xdg = null;
        if (self.surface) |surface| surface.xdg = null;
        for (self.comp.popups.items) |popup| if (popup.parent == self) {
            popup.parent = null;
        };
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
    /// Where an unmaximized window sits, as the wlroots compositor kept it.
    floating: ?Rect = null,
    parent: ?*Toplevel = null,
    min_size: [2]i32 = .{ 0, 0 },
    max_size: [2]i32 = .{ 0, 0 },
    /// The last configure sent, so unchanged layouts do not wake the client.
    sent: ?struct { width: i32, height: i32, states: u32, activated: bool } = null,
    handles: std.ArrayList(*ForeignHandle) = .empty,
    list_handles: std.ArrayList(*ListHandle) = .empty,
    sources: std.ArrayList(*CaptureSource) = .empty,
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
            // Dragging a title bar or a border.
            .move => self.comp.beginGrab(self, 0),
            .resize => |args| self.comp.beginGrab(self, args.edges),
            else => {},
        }
    }

    fn requestState(self: *Toplevel, change: struct { maximized: ?bool = null, fullscreen: ?bool = null }) void {
        if (change.maximized) |value| {
            self.maximized = value;
            // Unmaximizing for the first time gives a centred two-thirds of the area.
            if (!value and self.floating == null) if (self.output orelse self.comp.primary()) |output| {
                const u = output.usable;
                self.floating = .{ .x = u.x + @divTrunc(u.width, 6), .y = u.y + @divTrunc(u.height, 6), .width = @divTrunc(u.width * 2, 3), .height = @divTrunc(u.height * 2, 3) };
            };
            if (value) self.tile = .none;
        }
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
        if (!self.maximized and self.tile == .none) if (self.floating) |box| return box;
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
        return self.fullscreen or (!self.dialog() and (self.maximized or self.tile != .none or self.floating != null));
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
        for (self.sources.items) |source| source.toplevel = null;
        self.sources.clearRetainingCapacity();
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
        surface.draw(.{ .cpu = target }, -geometry.x, -geometry.y, self.scale());
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
            if (comp.grab) |grab| if (grab.toplevel == self) {
                comp.grab = null;
            };
            // A window closing while selected moves the selection on, as before.
            if (comp.cycle_selected == self) comp.cycle(false, comp.cycle_app);
            if (comp.cycle_origin == self) comp.cycle_origin = null;
            removeItem(*Toplevel, &comp.recent, self);
            if (comp.cycling) comp.showSwitcher();
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
        for (self.comp.surfaces.items) |surface| if (surface.xdg) |xdg| if (xdg.toplevel) |other| if (other.parent == self) {
            other.parent = null;
        };
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
        self.sources.deinit(self.comp.a);
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
    /// Grabbing popups (menus) take the keyboard while shown.
    grabbed: bool = false,

    fn handle(self: *Popup, _: ws.xdg_popup, request: ws.xdg_popup.Request) void {
        switch (request) {
            .destroy => {},
            .grab => self.grabbed = true,
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
        const grabbed = self.grabbed;
        self.comp.scheduleRepaint();
        self.comp.a.destroy(self);
        if (grabbed) self.comp.updateKeyboardFocus();
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
        const old_interactivity = self.current.interactivity;
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
            // A layer that takes the keyboard gets it when it appears, as before.
            if (mapped and !self.comp.locked and self.current.interactivity != 0) self.comp.focused_layer = self;
            if (!mapped and self.comp.focused_layer == self) self.comp.focused_layer = null;
            self.comp.updateKeyboardFocus();
        } else if (mapped and old_interactivity != self.current.interactivity) {
            if (self.current.interactivity == 0 and self.comp.focused_layer == self) self.comp.focused_layer = null;
            if (self.current.interactivity != 0 and old_interactivity == 0 and !self.comp.locked) self.comp.focused_layer = self;
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
        self.comp.broadcastOverview();
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
    fn drawPreviews(self: *Layer, target: Canvas, scale: f64) void {
        const comp = self.comp;
        const s = scale;
        const ox: f64 = @floatFromInt(self.rect.x - self.output.x);
        const oy: f64 = @floatFromInt(self.rect.y - self.output.y);
        for (self.previews.items) |preview| {
            const toplevel = comp.findWindow(preview.id[0..preview.id_len]) orelse continue;
            const v = preview.values;
            const dest_x = (ox + v[0]) * s;
            const dest_y = (oy + v[1]) * s;
            const dest_w = v[2] * s;
            const dest_h = v[3] * s;
            const clip: Rect = .{
                .x = @intFromFloat(@floor((ox + v[4]) * s)),
                .y = @intFromFloat(@floor((oy + v[5]) * s)),
                .width = @intFromFloat(@ceil(v[6] * s)),
                .height = @intFromFloat(@ceil(v[7] * s)),
            };
            if (target == .gl) {
                // Straight from the window's textures: no CPU copy per frame.
                const xdg = toplevel.xdg orelse continue;
                const surface = xdg.surface orelse continue;
                const geometry = xdg.windowGeometry();
                if (geometry.width <= 0 or geometry.height <= 0) continue;
                const fx = dest_w / @as(f64, @floatFromInt(geometry.width));
                const fy = dest_h / @as(f64, @floatFromInt(geometry.height));
                const gl_clip: Gl.Clip = .{ .x = clip.x, .y = clip.y, .width = clip.width, .height = clip.height };
                surface.drawGpu(target.gl, dest_x - @as(f64, @floatFromInt(geometry.x)) * fx, dest_y - @as(f64, @floatFromInt(geometry.y)) * fy, fx, fy, gl_clip, @floatCast(v[8]));
                continue;
            }
            const size = CaptureSession.size(toplevel);
            const pixels = comp.a.alloc(u32, @as(usize, size[0]) * size[1]) catch continue;
            defer comp.a.free(pixels);
            @memset(pixels, 0);
            if (!toplevel.render(.{ .pixels = pixels, .width = size[0], .height = size[1] })) continue;
            const cpu_clip: raster.Region = .{ .x = clip.x, .y = clip.y, .width = @intCast(@max(0, clip.width)), .height = @intCast(@max(0, clip.height)) };
            target.image(pixels, size[0], size[1], .{ .x = dest_x, .y = dest_y, .width = dest_w, .height = dest_h }, cpu_clip, v[8]);
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
        self.comp.broadcastOverview();
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
        if (self.preview_owner) |owner| if (owner.building == self) {
            owner.building = null;
        };
        if (comp.focused_layer == self) comp.focused_layer = null;
        comp.a.free(self.namespace);
        self.previews.deinit(comp.a);
        self.pending_previews.deinit(comp.a);
        comp.a.destroy(self);
        // The layer is out of the list, so the overview state is current.
        comp.broadcastOverview();
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
    /// The lock serial of the last frame shown on screen while locked.
    lock_serial: u32 = 0,
    /// The lock serial of a frame queued for a page flip, not yet on screen.
    pending_lock_serial: ?u32 = null,
    enabled: bool = true,
    global: ?*wire.Global = null,
    /// The window showing this output, with the nested backend.
    nested: ?*Nested.Window = null,
    /// The display showing this output, with the DRM backend.
    display: ?*Drm.kms.Display = null,
    /// A rendered frame waits for the display's previous flip.
    unpresented: bool = false,
    /// The pending repaint only answers frame callbacks: nothing on screen changed.
    frame_only: bool = false,
    /// What changed since the last frame (output pixels), whether everything
    /// did, and the damage of recent frames for buffers that are reused.
    damage: ?Gl.Clip = null,
    damage_full: bool = true,
    damage_history: [4]?Gl.Clip = @splat(null),
    history_len: u32 = 0,
    /// How the display is turned (a wl_output transform); `width` and
    /// `height` are the upright scene's, swapped from the mode's by quarter turns.
    transform: u32 = 0,
    /// The hot corner's barriers at this output's top-left corner.
    pressure: @import("desktop-hot-corner.zig").Pressure = .{},
    /// The GPU scanout target, when the DRM backend renders with GLES.
    target: ?*Gl.Target = null,
    /// Whether `pixels` holds the latest frame; GPU frames are drawn again
    /// on the CPU when a capture needs them.
    pixels_valid: bool = false,
    make: []const u8 = "Headless",
    model: []const u8 = "Headless output",
    refresh: i32 = 60000,
    physical: [2]i32 = .{ 0, 0 },

    fn create(comp: *Compositor, index: usize, width: u32, height: u32) !*Output {
        const self = try comp.a.create(Output);
        errdefer comp.a.destroy(self);
        self.* = .{ .comp = comp, .width = width, .height = height, .pixels = try comp.a.alloc(u32, @as(usize, width) * height) };
        errdefer comp.a.free(self.pixels);
        self.name_len = (std.fmt.bufPrint(&self.name_buffer, "HEADLESS-{d}", .{index + 1}) catch unreachable).len;
        self.repaint = try comp.server.loop.timer(self, &repaintReady);
        errdefer comp.server.loop.remove(self.repaint);
        self.global = try comp.server.createGlobal(&ws.wl_output.interface, 4, self, &bind);
        return self;
    }

    fn destroy(self: *Output) void {
        const a = self.comp.a;
        self.pressure.deinit(a);
        self.resources.deinit(a);
        self.xdg_outputs.deinit(a);
        a.free(self.pixels);
        a.destroy(self);
    }

    fn name(self: *const Output) []const u8 {
        return self.name_buffer[0..self.name_len];
    }

    /// The physical (untransformed) mode size in pixels.
    fn physicalSize(self: *const Output) [2]u32 {
        return if (self.transform & 1 != 0) .{ self.height, self.width } else .{ self.width, self.height };
    }

    /// The modes output management offers: the connector's, or the current size.
    fn modeList(self: *const Output, buffer: []OutputMode) []OutputMode {
        const display = self.display orelse {
            buffer[0] = .{ .size = self.physicalSize(), .refresh = @intCast(self.refresh), .preferred = true };
            return buffer[0..1];
        };
        var count: usize = 0;
        for (display.modes) |mode| {
            const entry: OutputMode = .{ .size = .{ mode.hdisplay, mode.vdisplay }, .refresh = mode.refreshMilli(), .preferred = mode.type & Drm.kms.ModeInfo.type_preferred != 0 };
            const duplicate = for (buffer[0..count]) |seen| {
                if (seen.size[0] == entry.size[0] and seen.size[1] == entry.size[1] and seen.refresh == entry.refresh) break true;
            } else false;
            if (duplicate or count == buffer.len) continue;
            buffer[count] = entry;
            count += 1;
        }
        return buffer[0..count];
    }

    fn setName(self: *Output, text: []const u8) void {
        const len = @min(text.len, self.name_buffer.len);
        @memcpy(self.name_buffer[0..len], text[0..len]);
        self.name_len = len;
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
        const size = self.physicalSize();
        output.sendGeometry(self.x, self.y, self.physical[0], self.physical[1], ws.wl_output.Subpixel.unknown, self.make, self.model, @intCast(self.transform));
        output.sendMode(ws.wl_output.Mode.current | ws.wl_output.Mode.preferred, @intCast(size[0]), @intCast(size[1]), self.refresh);
        if (output.version() >= 2) output.sendScale(self.bufferScale());
        if (output.version() >= 4) {
            output.sendName(self.name());
            output.sendDescription(self.model);
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

    /// Redraws the whole output at the next frame.
    fn scheduleRepaint(self: *Output) void {
        self.damage_full = true;
        self.armRepaint();
    }

    /// Redraws `box` (output pixels) at the next frame.
    fn addDamage(self: *Output, area: Gl.Clip) void {
        const left = @max(0, area.x);
        const top = @max(0, area.y);
        const right = @min(@as(i32, @intCast(self.width)), area.x + area.width);
        const bottom = @min(@as(i32, @intCast(self.height)), area.y + area.height);
        if (right <= left or bottom <= top) return;
        const clipped: Gl.Clip = .{ .x = left, .y = top, .width = right - left, .height = bottom - top };
        self.damage = if (self.damage) |current| unionClip(current, clipped) else clipped;
        self.armRepaint();
    }

    /// The region to redraw into a buffer `age` frames old, consuming this frame's damage.
    fn takeDamage(self: *Output, age: u32) ?Gl.Clip {
        const full = self.damage_full or self.damage == null;
        const frame: ?Gl.Clip = if (full) null else self.damage;
        self.damage = null;
        self.damage_full = false;
        defer {
            var index = self.damage_history.len - 1;
            while (index > 0) : (index -= 1) self.damage_history[index] = self.damage_history[index - 1];
            self.damage_history[0] = frame;
            self.history_len = @min(self.history_len + 1, self.damage_history.len);
        }
        var region = frame orelse return null;
        // The buffer misses the frames drawn since it was last shown.
        if (age == 0 or age > self.history_len + 1) return null;
        for (self.damage_history[0 .. age - 1]) |older| region = unionClip(region, older orelse return null);
        return region;
    }

    fn armRepaint(self: *Output) void {
        if (!self.enabled) return;
        // Damage turns a pending frame-callback-only repaint into a real one, soon.
        const was_frame_only = self.frame_only;
        self.frame_only = false;
        // While a page flip is in flight, draw right when it completes instead of waking a 1 ms timer.
        if (self.display) |display| if (display.flipping) {
            self.unpresented = true;
            return;
        };
        if (self.scheduled and !was_frame_only) return;
        self.scheduled = true;
        // Displays are paced by their page flips (a frame waits for the last one),
        // so draw almost at once and keep up with fast panels. Headless and
        // nested outputs composite at most once per 60 Hz frame.
        wire.Loop.arm(self.repaint, if (self.display != null) 1 else 16);
    }

    /// Answers frame callbacks at the display's next refresh, for commits that
    /// changed nothing on screen. Clients such as Firefox pace themselves this
    /// way, committing a frame request without new content.
    fn scheduleFrame(self: *Output) void {
        if (self.scheduled or !self.enabled) return;
        self.scheduled = true;
        self.frame_only = true;
        wire.Loop.arm(self.repaint, self.msToRefresh());
    }

    /// Milliseconds until the display's next refresh, judged from its last flip.
    fn msToRefresh(self: *const Output) u32 {
        const refresh: i64 = if (self.refresh > 0) self.refresh else 60000;
        const period = @divTrunc(1_000_000_000, refresh); // microseconds
        const display = self.display orelse return @intCast(@divTrunc(period + 999, 1000));
        const last = @as(i64, display.flip_time[0]) * std.time.us_per_s + display.flip_time[1];
        const now = util.monotonicTime();
        const until = if (last > 0 and now >= last) period - @mod(now - last, period) else period;
        return @intCast(@max(1, @divTrunc(until + 999, 1000)));
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
        // A display turned off on the lock screen shows nothing until woken.
        if (comp.blanked and self.display != null) return;
        if (self.display) |display| if (display.flipping or !display.card.active) {
            // The next frame is drawn once the last one is on screen.
            self.unpresented = true;
            return;
        };
        if (self.scheduled) {
            self.scheduled = false;
            wire.Loop.arm(self.repaint, 0);
        }
        if (self.frame_only) {
            self.frame_only = false;
            self.sendFrameDone();
            return;
        }
        if (self.target) |target| {
            const backend = comp.drm.?;
            const renderer = backend.renderer.?;
            const region = self.takeDamage(renderer.bufferAge(target));
            if (renderer.begin(target, self.backgroundColor(), region, self.transform)) {
                self.drawScene(.{ .gl = renderer });
                self.pixels_valid = false;
                backend.showGpu(self, target);
            }
        } else if (self.display == null) {
            self.drawCpu();
            if (self.nested) |window| window.present();
            if (comp.locked) self.confirmLock(comp.lock_serial);
        }
        // Displays report when the frame is on screen, at its page flip.
        if (self.display != null and self.target != null) comp.drawnFor(self) else comp.presented(self);
        self.frames += 1;
        self.sendFrameDone();
    }

    /// Records that `serial` is now visible on this output and acknowledges any pending lock.
    fn confirmLock(self: *Output, serial: u32) void {
        self.lock_serial = serial;
        if (self.comp.lock) |lock| lock.acknowledge();
    }

    fn sendFrameDone(self: *Output) void {
        const time = nowMs();
        const area = self.box();
        const flushTree = struct {
            fn f(surface: *Surface, t: u32) void {
                for (surface.frames.items) |callback| callback.sendDone(t);
                surface.frames.clearRetainingCapacity();
                for (surface.children.items) |child| if (child.surface) |inner| f(inner, t);
            }
        }.f;
        var roots: [256]Root = undefined;
        for (self.comp.stack(&roots)) |root| {
            const w = root.surface.logicalWidth();
            const h = root.surface.logicalHeight();
            const overlaps = root.x < area.x + area.width and root.y < area.y + area.height and root.x +| w > area.x and root.y +| h > area.y;
            if (overlaps or root.surface.entered == self) flushTree(root.surface, time);
            if (root.surface.layer) |layer| if (layer.output == self) for (layer.previews.items) |preview| {
                if (self.comp.findWindow(preview.id[0..preview.id_len])) |toplevel| if (toplevel.xdg) |xdg| if (xdg.surface) |surface| flushTree(surface, time);
            };
        }
        if (self.comp.drag) |drag| if (drag.icon) |icon| if (self.contains(self.comp.seat.pointer_x, self.comp.seat.pointer_y)) flushTree(icon, time);
        if (self.comp.seat.cursor) |cursor| if (self.contains(self.comp.seat.pointer_x, self.comp.seat.pointer_y)) flushTree(cursor, time);
    }

    fn backgroundColor(self: *const Output) u32 {
        return if (self.comp.locked) 0xff000000 else self.comp.background;
    }

    fn drawScene(self: *Output, canvas: Canvas) void {
        var roots: [256]Root = undefined;
        for (self.comp.stack(&roots)) |root| {
            root.surface.draw(canvas, root.x - self.x, root.y - self.y, self.scale);
            if (root.surface.layer) |layer| if (layer.previews.items.len > 0 and layer.output == self) layer.drawPreviews(canvas, self.scale);
        }
        // The drag icon follows the pointer, above everything else.
        if (self.comp.drag) |drag| if (drag.icon) |icon| if (self.contains(self.comp.seat.pointer_x, self.comp.seat.pointer_y)) {
            icon.draw(canvas, @as(i32, @intFromFloat(@floor(self.comp.seat.pointer_x))) - self.x, @as(i32, @intFromFloat(@floor(self.comp.seat.pointer_y))) - self.y, self.scale);
        };
        if (self.display != null) if (self.comp.drm) |backend| backend.drawSoftwareCursor(self, canvas);
    }

    fn drawCpu(self: *Output) void {
        @memset(self.pixels, self.backgroundColor());
        self.drawScene(.{ .cpu = .{ .pixels = self.pixels, .width = self.width, .height = self.height } });
        self.pixels_valid = true;
    }

    /// Pending commits drawn into `pixels`, for captures.
    fn capturePixels(self: *Output) void {
        self.flush();
        if (!self.pixels_valid) self.drawCpu();
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

/// Shared-memory formats clients may use, as wlroots' renderers accept them;
/// they are converted to premultiplied ARGB8888 when committed.
const shm_formats = [_]u32{ 0, 1, 0x34324241, 0x34324258, 0x36314752, 0x30335241, 0x30335258, 0x30334241, 0x30334258 };

fn shmLayout(format: u32) ?struct { bytes: usize, opaque_pixels: bool } {
    return switch (format) {
        0, 0x34324241, 0x30335241, 0x30334241 => .{ .bytes = 4, .opaque_pixels = false },
        1, 0x34324258, 0x30335258, 0x30334258 => .{ .bytes = 4, .opaque_pixels = true },
        0x36314752 => .{ .bytes = 2, .opaque_pixels = true }, // RGB565
        else => null,
    };
}

/// One pixel of a shared-memory buffer as premultiplied ARGB8888.
fn shmPixel(format: u32, bytes: []const u8) u32 {
    switch (format) {
        // ABGR8888 and XBGR8888: red and blue swap places.
        0x34324241, 0x34324258 => {
            const value = std.mem.readInt(u32, bytes[0..4], .little);
            const alpha = if (format == 0x34324258) 0xff000000 else value & 0xff000000;
            return alpha | (value & 0x0000ff00) | ((value & 0xff) << 16) | ((value >> 16) & 0xff);
        },
        0x36314752 => {
            const value = std.mem.readInt(u16, bytes[0..2], .little);
            const r: u32 = (value >> 11) & 0x1f;
            const g: u32 = (value >> 5) & 0x3f;
            const b: u32 = value & 0x1f;
            return 0xff000000 | (((r << 3) | (r >> 2)) << 16) | (((g << 2) | (g >> 4)) << 8) | ((b << 3) | (b >> 2));
        },
        // 10-bit channels with a 2-bit alpha, red or blue first from the top.
        0x30335241, 0x30335258, 0x30334241, 0x30334258 => {
            const value = std.mem.readInt(u32, bytes[0..4], .little);
            const high: u32 = (value >> 22) & 0xff;
            const middle: u32 = (value >> 12) & 0xff;
            const low: u32 = (value >> 2) & 0xff;
            const alpha: u32 = if (format == 0x30335258 or format == 0x30334258) 0xff else (value >> 30) * 0x55;
            const red_first = format == 0x30335241 or format == 0x30335258;
            const r = if (red_first) high else low;
            const b = if (red_first) low else high;
            return (alpha << 24) | (r << 16) | (middle << 8) | b;
        },
        else => return 0,
    }
}

fn unionClip(a: Gl.Clip, b: Gl.Clip) Gl.Clip {
    const left = @min(a.x, b.x);
    const top = @min(a.y, b.y);
    return .{ .x = left, .y = top, .width = @max(a.x + a.width, b.x + b.width) - left, .height = @max(a.y + a.height, b.y + b.height) - top };
}

fn clampInt(value: f64) i32 {
    return @intFromFloat(std.math.clamp(value, -1e9, 1e9));
}

/// Where a frame is drawn: CPU pixels (headless, nested, captures) or the GPU.
const Canvas = union(enum) {
    cpu: raster.Buffer,
    gl: *Gl.Renderer,

    /// Draws a surface's content stretched over `rect`, in output pixels.
    fn surface(self: Canvas, source: *Surface, rect: Gl.Rect) void {
        switch (self) {
            .cpu => |target| {
                if (!source.cpuReady()) return;
                var content: raster.Image = .{ .pixels = std.mem.sliceAsBytes(source.pixels), .width = source.width, .height = source.height, .stride = source.width * 4, .format = .argb };
                // The CPU path crops to whole pixels and leaves transforms to the GPU.
                if (source.source) |crop| if (source.transform == 0) {
                    const scale: f64 = @floatFromInt(@max(1, source.scale));
                    const x: u32 = @intFromFloat(@min(@round(crop[0] * scale), @as(f64, @floatFromInt(source.width - 1))));
                    const y: u32 = @intFromFloat(@min(@round(crop[1] * scale), @as(f64, @floatFromInt(source.height - 1))));
                    const w: u32 = @intFromFloat(@max(1, @min(@round(crop[2] * scale), @as(f64, @floatFromInt(source.width - x)))));
                    const h: u32 = @intFromFloat(@max(1, @min(@round(crop[3] * scale), @as(f64, @floatFromInt(source.height - y)))));
                    content.pixels = std.mem.sliceAsBytes(source.pixels[@as(usize, y) * source.width + x ..]);
                    content.width = w;
                    content.height = h;
                };
                raster.blit(target, content, .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height }, null) catch {};
            },
            .gl => |renderer| {
                source.syncTexture(renderer);
                renderer.drawMapped(source.texture, rect, source.uvMap(), null, 1, source.opaque_format);
            },
        }
    }

    /// Draws premultiplied ARGB pixels once, clipped and faded.
    fn image(self: Canvas, pixels: []const u32, width: u32, height: u32, rect: Gl.Rect, clip: raster.Region, opacity: f64) void {
        switch (self) {
            .cpu => |target| {
                const source: raster.Image = .{ .pixels = std.mem.sliceAsBytes(pixels), .width = width, .height = height, .stride = width * 4, .format = .argb };
                raster.blitWithOptions(target, source, .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height }, .{ .clip = clip, .opacity = opacity, .filter = .bilinear }) catch {};
            },
            .gl => |renderer| renderer.drawPixels(pixels, width, height, rect, .{ .x = @intCast(clip.x), .y = @intCast(clip.y), .width = @intCast(clip.width), .height = @intCast(clip.height) }, @floatCast(opacity)),
        }
    }
};

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
    /// What the pointer shows: the client's cursor surface, the built-in arrow, or nothing.
    cursor_mode: enum { default, surface, hidden } = .default,
    cursor_hotspot: [2]i32 = .{ 0, 0 },
    /// The themed cursor shown in `.default` mode, a wp_cursor_shape_device_v1 shape.
    cursor_shape: u32 = 1,
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
    /// Scrolling within a frame: whether its source was sent, and the
    /// fraction of a wheel click per axis not yet sent as a whole click.
    source_sent: bool = false,
    scroll_remainder: [2]i32 = .{ 0, 0 },
    /// The scroll source a virtual pointer set for its next axis events.
    pending_source: ?u32 = null,
    /// Keys a shortcut consumed; their release is withheld from clients too.
    consumed: [256]bool = @splat(false),
    /// Modifiers held by each pressed key, from the keymap's modifier_map.
    held: [256]u32 = @splat(0),

    fn init(self: *Seat) !void {
        self.default_keymap = self.configuredKeymap() orelse keymapFile(keymap_text) orelse return error.Keymap;
        self.active_keymap = self.default_keymap;
    }

    /// The system's layout: DESKTOP_KEYMAP or /etc/xdg/desktop-keymap.xkb,
    /// compiled from services.xserver.xkb when the system was built.
    fn configuredKeymap(self: *Seat) ?Keymap {
        const path: [*:0]const u8 = std.c.getenv("DESKTOP_KEYMAP") orelse "/etc/xdg/desktop-keymap.xkb";
        const fd = std.c.open(path, .{ .CLOEXEC = true });
        if (fd < 0) return null;
        defer _ = std.c.close(fd);
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(self.comp.a);
        var chunk: [16384]u8 = undefined;
        while (text.items.len < 4 * 1024 * 1024) {
            const count = std.c.read(fd, &chunk, chunk.len);
            if (count <= 0) break;
            text.appendSlice(self.comp.a, chunk[0..@intCast(count)]) catch return null;
        }
        const keymap = keymapFile(text.items) orelse {
            std.log.warn("compositor: {s} is not a keymap; using the built-in us layout", .{path});
            return null;
        };
        if (keymap.map == null) {
            keymap.deinit();
            std.log.warn("compositor: cannot read the keymap in {s}; using the built-in us layout", .{path});
            return null;
        }
        return keymap;
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

    fn pointerRequest(self: *Seat, resource: ws.wl_pointer, request: ws.wl_pointer.Request) void {
        switch (request) {
            .set_cursor => |args| {
                const focused = self.pointer_focus orelse return;
                if (focused.resource.client() != resource.client()) return;
                const surface = if (args.surface) |s| s.data(Surface) else null;
                if (surface) |cursor| {
                    if (cursor.role != .none and cursor.role != .cursor) return args.surface.?.postError(ws.wl_pointer.Error.role, "surface already has a role", .{});
                    cursor.role = .cursor;
                }
                self.cursor = surface;
                self.cursor_mode = if (surface != null) .surface else .hidden;
                self.cursor_hotspot = .{ args.hotspot_x, args.hotspot_y };
                self.comp.cursorChanged();
            },
            .release => {},
        }
    }

    fn pointerGone(self: *Seat, resource: ws.wl_pointer) void {
        removeItem(ws.wl_pointer, &self.pointers, resource);
    }

    fn surfaceGone(self: *Seat, surface: *Surface) void {
        if (self.keyboard_focus == surface) self.keyboard_focus = null;
        if (self.cursor == surface) {
            self.cursor = null;
            self.cursor_mode = .default;
            self.cursor_shape = 1;
            self.comp.cursorChanged();
        }
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
        self.comp.ime.focusChanged();
    }

    /// Sends `keymap` to every keyboard unless clients already have it.
    fn useKeymap(self: *Seat, keymap: Keymap) void {
        if (keymap.fd == self.active_keymap.fd) return;
        self.active_keymap = keymap;
        for (self.keyboards.items) |keyboard| keyboard.sendKeymap(ws.wl_keyboard.KeymapFormat.xkb_v1, keymap.fd, keymap.size);
        if (self.comp.ime.method) |method| if (method.grab) |grab| grab.sendKeymap(ws.wl_keyboard.KeymapFormat.xkb_v1, keymap.fd, keymap.size);
        // Modifiers are re-read under the new keymap, as wlroots does when the seat changes keyboards.
        const surface = self.keyboard_focus orelse return;
        for (self.keyboards.items) |keyboard| {
            if (keyboard.client() == surface.resource.client()) keyboard.sendModifiers(self.comp.server.nextSerial(), self.modifiers[0], self.modifiers[1], self.modifiers[2], self.modifiers[3]);
        }
    }

    fn key(self: *Seat, keymap: Keymap, time: u32, code: u32, state: u32, source: ?*wire.Client) void {
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
        if (!handled) if (self.comp.ime.grabFor(source)) |grab| {
            grab.sendKey(self.comp.server.nextSerial(), time, code, state);
            handled = true;
        };
        if (!handled) if (self.keyboard_focus) |surface| for (self.keyboards.items) |keyboard| {
            if (keyboard.client() == surface.resource.client()) keyboard.sendKey(self.comp.server.nextSerial(), time, code, state);
        };
        if (keymap.map) |map| self.trackModifiers(keymap, map, code, pressed);
    }

    /// Derives modifier state from modifier keys, as xkbcommon does for SetMods
    /// and LockMods: held keys set depressed modifiers, lock keys toggle locked ones.
    fn trackModifiers(self: *Seat, keymap: Keymap, map: *const xkb.Keymap, code: u32, pressed: bool) void {
        // Layout switching (grp:* options) locks another group, as LockGroup does.
        if (pressed) {
            var state: xkb.State = .{ .keymap = map };
            state.update(self.modifiers[0], self.modifiers[1], self.modifiers[2], self.modifiers[3]);
            const count = map.groupCount();
            const group = self.modifiers[3] % count;
            const next: ?u32 = switch (state.keysym(code + 8)) {
                keysyms.ISO_Next_Group => (group + 1) % count,
                keysyms.ISO_Prev_Group => (group + count - 1) % count,
                keysyms.ISO_First_Group => 0,
                keysyms.ISO_Last_Group => count - 1,
                else => null,
            };
            if (next) |value| if (value != self.modifiers[3]) {
                var values = self.modifiers;
                values[3] = value;
                self.setModifiers(keymap, values);
            };
        }
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
        if (self.comp.drm) |backend| if (keymap.map) |map| backend.updateLeds(map, values[2]);
        if (self.comp.ime.grabFor(null)) |grab| grab.sendModifiers(self.comp.server.nextSerial(), values[0], values[1], values[2], values[3]);
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
        // The new client sets its own cursor on enter; the desktop shows the arrow.
        self.cursor = null;
        self.cursor_mode = .default;
        self.cursor_shape = 1;
        self.comp.cursorChanged();
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
        defer self.comp.cursorMoved();
        if (self.comp.grab != null) return self.comp.grabMotion();
        if (self.comp.drag != null) return self.comp.dragMotion(time);
        // An implicit grab keeps events on the pressed surface until release.
        if (self.buttons == 0) self.updatePointerFocus();
        const surface = self.pointer_focus orelse return;
        for (self.pointers.items) |pointer| {
            if (pointer.client() == surface.resource.client()) pointer.sendMotion(time, self.pointer_x - self.focus_origin[0], self.pointer_y - self.focus_origin[1]);
        }
    }

    /// Relative motion, which can press against the hot corner's barriers.
    fn moveBy(self: *Seat, dx: f64, dy: f64, time: u32) void {
        const next = self.comp.cornerMotion(self.pointer_x, self.pointer_y, dx, dy, time);
        self.moveTo(next[0], next[1], time);
    }

    /// Absolute motion has no pressure; it releases barriers it leaves.
    fn moveToAbsolute(self: *Seat, x: f64, y: f64, time: u32) void {
        self.moveTo(x, y, time);
        self.comp.cornerReleased();
    }

    fn button(self: *Seat, time: u32, code: u32, pressed: bool) void {
        self.comp.activity();
        // Releasing a button ends moving or resizing a window.
        if (!pressed) self.comp.grab = null;
        if (self.comp.drag != null) {
            if (pressed) {
                self.buttons += 1;
            } else {
                self.buttons -|= 1;
                if (self.buttons == 0) self.comp.dragDrop();
            }
            return;
        }
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

    const Scroll = struct {
        time: u32,
        axis: u32,
        value: f64 = 0,
        /// High-resolution wheel motion, 120 to a click.
        value120: ?i32 = null,
        /// wl_pointer.axis_source: wheel, finger, continuous or tilt.
        source: ?u32 = null,
        /// Natural scrolling: content follows the fingers.
        inverted: bool = false,
        /// Fingers left the touchpad: kinetic scrolling may start.
        stop: bool = false,
    };

    /// Sends one axis of scrolling, as wlroots' seat passed it on: the source
    /// once per frame, the direction, then a stop or the value with its
    /// high-resolution or whole-click steps.
    fn scroll(self: *Seat, event: Scroll) void {
        self.comp.activity();
        const surface = self.pointer_focus orelse return;
        const index = @min(event.axis, 1);
        // Clients before high-resolution scrolling get whole clicks as they add up.
        var clicks: i32 = 0;
        if (event.value120) |v120| {
            self.scroll_remainder[index] += v120;
            clicks = @divTrunc(self.scroll_remainder[index], 120);
            self.scroll_remainder[index] -= clicks * 120;
        }
        const first_in_frame = !self.source_sent;
        self.source_sent = true;
        for (self.pointers.items) |pointer| {
            if (pointer.client() != surface.resource.client()) continue;
            const version = pointer.version();
            if (version >= 5) if (event.source) |source| if (first_in_frame) {
                pointer.sendAxisSource(if (source == ws.wl_pointer.AxisSource.wheel_tilt and version < 6) ws.wl_pointer.AxisSource.wheel else source);
            };
            if (version >= 9) pointer.sendAxisRelativeDirection(event.axis, if (event.inverted) ws.wl_pointer.AxisRelativeDirection.inverted else ws.wl_pointer.AxisRelativeDirection.identical);
            if (event.stop) {
                if (version >= 5) pointer.sendAxisStop(event.time, event.axis);
                continue;
            }
            if (event.value120) |v120| {
                if (version >= 8) pointer.sendAxisValue120(event.axis, v120) else if (version >= 5 and clicks != 0) pointer.sendAxisDiscrete(event.axis, clicks);
            }
            pointer.sendAxis(event.time, event.axis, event.value);
        }
    }

    fn frame(self: *Seat) void {
        self.source_sent = false;
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
                seat.key(keymap, args.time, args.key, args.state, resource.client());
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

    fn handle(self: *VirtualPointer, _: ws.zwlr_virtual_pointer_v1, request: ws.zwlr_virtual_pointer_v1.Request) void {
        const seat = &self.comp.seat;
        const area = self.comp.layoutBox();
        switch (request) {
            .motion => |args| seat.moveBy(args.dx, args.dy, args.time),
            .motion_absolute => |args| {
                if (args.x_extent == 0 or args.y_extent == 0) return;
                const x = @as(f64, @floatFromInt(area.x)) + @as(f64, @floatFromInt(args.x)) * @as(f64, @floatFromInt(area.width)) / @as(f64, @floatFromInt(args.x_extent));
                const y = @as(f64, @floatFromInt(area.y)) + @as(f64, @floatFromInt(args.y)) * @as(f64, @floatFromInt(area.height)) / @as(f64, @floatFromInt(args.y_extent));
                seat.moveToAbsolute(x, y, args.time);
            },
            .button => |args| seat.button(args.time, args.button, args.state != 0),
            .axis => |args| seat.scroll(.{ .time = args.time, .axis = args.axis, .value = args.value, .source = seat.pending_source }),
            .axis_discrete => |args| seat.scroll(.{ .time = args.time, .axis = args.axis, .value = args.value, .value120 = args.discrete * 120, .source = seat.pending_source }),
            .axis_source => |args| seat.pending_source = args.axis_source,
            .axis_stop => |args| seat.scroll(.{ .time = args.time, .axis = args.axis, .source = seat.pending_source, .stop = true }),
            .frame => {
                seat.pending_source = null;
                seat.frame();
            },
            .destroy => {},
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
        // Task lists see whether the window is active, maximized or fullscreen.
        var states: [3]u32 = undefined;
        var count: usize = 0;
        const State = ws.zwlr_foreign_toplevel_handle_v1.State;
        for ([_]struct { bool, u32 }{ .{ toplevel.activated, State.activated }, .{ toplevel.maximized and !toplevel.fullscreen, State.maximized }, .{ toplevel.fullscreen, State.fullscreen } }) |entry| if (entry[0]) {
            states[count] = entry[1];
            count += 1;
        };
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
        if (!output.enabled) return resource.sendFailed();
        output.capturePixels();
        if (self.rect.x < 0 or self.rect.y < 0 or @as(usize, @intCast(self.rect.x)) + width > output.width or @as(usize, @intCast(self.rect.y)) + height > output.height or output.pixels.len < @as(usize, output.width) * output.height)
            return resource.sendFailed();
        if (!buffer.writeRect(output.pixels, output.width, @intCast(self.rect.x), @intCast(self.rect.y), true))
            return resource.sendFailed();
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

    /// A zwlr_output_mode_v1: one of a head's modes. It outlives its head
    /// until the client lets go of it, so configurations can still name it.
    const ModeObject = struct {
        head: *Head,
        resource: ws.zwlr_output_mode_v1,
        size: [2]u32,
        refresh: u32,
        /// No longer offered; choosing it fails the configuration.
        finished: bool = false,

        fn request(_: *ModeObject, _: ws.zwlr_output_mode_v1, _: ws.zwlr_output_mode_v1.Request) void {}

        fn gone(self: *ModeObject, _: ws.zwlr_output_mode_v1) void {
            const head = self.head;
            removeItem(*ModeObject, &head.modes, self);
            head.live -= 1;
            std.heap.c_allocator.destroy(self);
            if (head.head == null and head.live == 0) {
                head.modes.deinit(std.heap.c_allocator);
                std.heap.c_allocator.destroy(head);
            }
        }
    };

    const Head = struct {
        owner: ?*HeadManager,
        output: *Output,
        head: ?ws.zwlr_output_head_v1 = null,
        /// Mode objects still held by the client, and how many there are.
        modes: std.ArrayList(*ModeObject) = .empty,
        live: u32 = 0,

        fn request(_: *Head, _: ws.zwlr_output_head_v1, _: ws.zwlr_output_head_v1.Request) void {}

        fn gone(self: *Head, _: ws.zwlr_output_head_v1) void {
            self.head = null;
            if (self.owner) |owner| removeItem(*Head, &owner.heads, self);
            if (self.live == 0) {
                self.modes.deinit(std.heap.c_allocator);
                std.heap.c_allocator.destroy(self);
            }
        }

        /// Announces the output's modes, finishing ones it no longer has.
        fn announceModes(self: *Head) void {
            const head = self.head orelse return;
            var wanted: [128]OutputMode = undefined;
            const list = self.output.modeList(&wanted);
            for (self.modes.items) |mode| if (!mode.finished) {
                const kept = for (list) |entry| {
                    if (entry.size[0] == mode.size[0] and entry.size[1] == mode.size[1] and entry.refresh == mode.refresh) break true;
                } else false;
                if (!kept) {
                    mode.finished = true;
                    mode.resource.sendFinished();
                }
            };
            for (list) |entry| {
                const known = for (self.modes.items) |mode| {
                    if (!mode.finished and mode.size[0] == entry.size[0] and mode.size[1] == entry.size[1] and mode.refresh == entry.refresh) break true;
                } else false;
                if (known) continue;
                const resource = head.sendMode();
                if (!resource.alive()) continue;
                const mode = std.heap.c_allocator.create(ModeObject) catch {
                    resource.destroyResource();
                    continue;
                };
                mode.* = .{ .head = self, .resource = resource, .size = entry.size, .refresh = entry.refresh };
                self.modes.append(std.heap.c_allocator, mode) catch {
                    std.heap.c_allocator.destroy(mode);
                    resource.destroyResource();
                    continue;
                };
                self.live += 1;
                resource.setHandler(ModeObject, mode, ModeObject.request, ModeObject.gone);
                resource.sendSize(@intCast(entry.size[0]), @intCast(entry.size[1]));
                resource.sendRefresh(@intCast(entry.refresh));
                if (entry.preferred) resource.sendPreferred();
            }
        }

        /// The state that configurations change.
        fn describe(self: *Head) void {
            const head = self.head orelse return;
            const output = self.output;
            head.sendEnabled(@intFromBool(output.enabled));
            if (!output.enabled) return;
            self.announceModes();
            const physical = output.physicalSize();
            for (self.modes.items) |mode| if (!mode.finished and mode.size[0] == physical[0] and mode.size[1] == physical[1] and mode.refresh == @as(u32, @intCast(output.refresh))) {
                head.sendCurrentMode(mode.resource);
                break;
            };
            head.sendPosition(output.x, output.y);
            if (head.version() >= 4) {
                const enabled = if (output.display) |display| display.vrr_enabled else false;
                head.sendAdaptiveSync(if (enabled) ws.zwlr_output_head_v1.AdaptiveSyncState.enabled else ws.zwlr_output_head_v1.AdaptiveSyncState.disabled);
            }
            head.sendTransform(@intCast(output.transform));
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
        resource.sendDescription(output.model);
        resource.sendPhysicalSize(0, 0);
        head.describe();
        if (resource.version() >= 2) {
            resource.sendMake(output.make);
            resource.sendModel(output.model);
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
            if (head.stale) return resource.sendFailed();
            if (head.size) |size| if (size[0] == 0 or size[1] == 0 or size[0] > 8192 or size[1] > 8192) return resource.sendFailed();
            // Displays only take the modes their connector offers.
            if (head.size) |size| if (head.output.display) |display| if (findMode(display, size, head.refresh) == null) return resource.sendFailed();
            // Variable refresh needs a display that supports it.
            if (head.adaptive_sync) |enabled| if (enabled) if (head.output.display == null or !head.output.display.?.vrr_capable) return resource.sendFailed();
        }
        if (apply) {
            var ok = true;
            for (self.disabled.items) |output| comp.setOutputEnabled(output, false);
            for (self.heads.items) |head| {
                comp.setOutputEnabled(head.output, true);
                var mode_ok = true;
                if (head.size) |size| if (head.output.display) |display| if (findMode(display, size, head.refresh)) |mode| {
                    if (comp.drm) |backend| if (!backend.switchMode(head.output, display, mode)) {
                        mode_ok = false;
                        ok = false;
                    };
                };
                if (comp.drm) |backend| if (head.output.display != null and head.output.target == null) {
                    if (!backend.attachTarget(head.output)) ok = false;
                };
                if (head.adaptive_sync) |enabled| if (head.output.display) |display| {
                    if (!display.setAdaptiveSync(enabled)) {
                        std.log.warn("compositor: {s}: variable refresh could not be {s}", .{ display.name(), if (enabled) "enabled" else "disabled" });
                        ok = false;
                    }
                };
                // The scene is the mode's size, its sides swapped by quarter turns.
                const transform = head.transform orelse head.output.transform;
                var size = if (mode_ok) head.size else null;
                if (transform != head.output.transform or size != null) {
                    const base = size orelse if (head.output.display) |display| [2]u32{ display.width(), display.height() } else if (head.output.transform & 1 != 0) [2]u32{ head.output.height, head.output.width } else [2]u32{ head.output.width, head.output.height };
                    size = if (transform & 1 != 0) .{ base[1], base[0] } else base;
                }
                const transform_changed = transform != head.output.transform;
                if (transform_changed) {
                    head.output.transform = transform;
                    // The cursor plane is not turned; rotated displays draw the cursor into frames.
                    if (comp.drm) |backend| backend.updateCursorHardware();
                }
                const prev_scale = head.output.scale;
                const prev_w = head.output.width;
                const prev_h = head.output.height;
                const prev_x = head.output.x;
                const prev_y = head.output.y;
                head.output.configure(head.scale orelse head.output.scale, size, head.position);
                if (transform_changed and head.output.scale == prev_scale and head.output.width == prev_w and head.output.height == prev_h and head.output.x == prev_x and head.output.y == prev_y) {
                    head.output.announce();
                    head.output.scheduleRepaint();
                }
            }
            comp.outputChanged();
            if (!ok) return resource.sendFailed();
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

/// The connector's mode of `size`, at `refresh` mHz if asked (within 1 Hz),
/// else the fastest.
fn findMode(display: *const Drm.kms.Display, size: [2]u32, refresh: u32) ?Drm.kms.ModeInfo {
    var best: ?Drm.kms.ModeInfo = null;
    for (display.modes) |mode| {
        if (mode.hdisplay != size[0] or mode.vdisplay != size[1]) continue;
        const rate = mode.refreshMilli();
        if (refresh != 0) {
            if (@max(rate, refresh) - @min(rate, refresh) <= 1000) return mode;
            continue;
        }
        if (best == null or rate > best.?.refreshMilli()) best = mode;
    }
    return best;
}

/// A mode as output management lists it.
const OutputMode = struct { size: [2]u32, refresh: u32, preferred: bool = false };

const ConfigHead = struct {
    comp: *Compositor,
    config: ?*OutputConfig,
    output: *Output,
    scale: ?f64 = null,
    size: ?[2]u32 = null,
    /// The refresh rate asked for, in mHz; 0 takes any.
    refresh: u32 = 0,
    /// A mode that is no longer offered was chosen.
    stale: bool = false,
    adaptive_sync: ?bool = null,
    transform: ?u32 = null,
    position: ?[2]i32 = null,

    fn handle(self: *ConfigHead, _: ws.zwlr_output_configuration_head_v1, request: ws.zwlr_output_configuration_head_v1.Request) void {
        switch (request) {
            .set_scale => |args| self.scale = args.scale,
            .set_mode => |args| if (args.mode.data(HeadManager.ModeObject)) |mode| {
                self.size = mode.size;
                self.refresh = mode.refresh;
                self.stale = mode.finished or mode.head.output != self.output;
            },
            .set_custom_mode => |args| if (args.width > 0 and args.height > 0) {
                self.size = .{ @intCast(args.width), @intCast(args.height) };
                self.refresh = if (args.refresh > 0) @intCast(args.refresh) else 0;
            },
            .set_position => |args| self.position = .{ args.x, args.y },
            .set_adaptive_sync => |args| self.adaptive_sync = args.state == ws.zwlr_output_head_v1.AdaptiveSyncState.enabled,
            .set_transform => |args| self.transform = if (args.transform >= 0 and args.transform <= 7) @intCast(args.transform) else null,
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
    comp: *Compositor,
    toplevel: ?*Toplevel,
    output: ?*Output = null,

    fn destroyed(self: *CaptureSource, _: ws.ext_image_capture_source_v1) void {
        if (self.toplevel) |toplevel| removeItem(*CaptureSource, &toplevel.sources, self);
        self.comp.a.destroy(self);
    }
};

/// An ext_image_copy_capture_session_v1 copying one window.
const CaptureSession = struct {
    comp: *Compositor,
    resource: ws.ext_image_copy_capture_session_v1,
    toplevel: ?*Toplevel,
    /// Set for output captures instead of `toplevel`.
    output: ?*Output = null,
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
        const dimensions: [2]u32 = if (self.output) |output| .{ output.width, output.height } else if (self.toplevel) |toplevel| size(toplevel) else return;
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
                const frame = create(CopyFrame, self.comp, .{ .comp = self.comp, .session = self }) orelse return;
                self.comp.copy_frames.append(self.comp.a, frame) catch {
                    self.comp.a.destroy(frame);
                    return;
                };
                args.frame.setHandler(CopyFrame, frame, CopyFrame.handle, CopyFrame.destroyed);
            },
            .destroy => {},
        }
    }

    fn stop(self: *CaptureSession) void {
        self.toplevel = null;
        self.output = null;
        self.resource.sendStopped();
    }

    fn destroyed(self: *CaptureSession, _: ws.ext_image_copy_capture_session_v1) void {
        for (self.comp.copy_frames.items) |frame| if (frame.session == self) {
            frame.session = null;
        };
        removeItem(*CaptureSession, &self.comp.output_sessions, self);
        if (self.toplevel) |toplevel| removeItem(*CaptureSession, &toplevel.sessions, self);
        self.comp.a.destroy(self);
    }
};

const CopyFrame = struct {
    comp: *Compositor,
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
        const buffer = self.buffer orelse return resource.sendFailed(Reason.buffer_constraints);
        if (session.output == null and session.toplevel == null) return resource.sendFailed(Reason.stopped);
        if (buffer.width != session.width or buffer.height != session.height or buffer.stride < buffer.width * 4 or (buffer.format != ws.wl_shm.Format.argb8888 and buffer.format != ws.wl_shm.Format.xrgb8888))
            return resource.sendFailed(Reason.buffer_constraints);
        const comp = session.comp;
        const pixels = comp.a.alloc(u32, @as(usize, buffer.width) * buffer.height) catch return resource.sendFailed(Reason.unknown);
        defer comp.a.free(pixels);
        @memset(pixels, 0);
        if (session.output) |output| {
            output.capturePixels();
            if (output.pixels.len != pixels.len) return resource.sendFailed(Reason.buffer_constraints);
            @memcpy(pixels, output.pixels);
        } else if (!session.toplevel.?.render(.{ .pixels = pixels, .width = buffer.width, .height = buffer.height })) return resource.sendFailed(Reason.unknown);
        if (!buffer.write(pixels, buffer.format == ws.wl_shm.Format.xrgb8888)) return resource.sendFailed(Reason.unknown);
        resource.sendTransform(ws.wl_output.Transform.normal);
        resource.sendDamage(0, 0, @intCast(buffer.width), @intCast(buffer.height));
        const now = util.monotonicTime();
        const seconds: u64 = @intCast(@divTrunc(now, std.time.us_per_s));
        resource.sendPresentationTime(@truncate(seconds >> 32), @truncate(seconds), @intCast(@mod(now, std.time.us_per_s) * 1000));
        resource.sendReady();
    }

    fn destroyed(self: *CopyFrame, _: ws.ext_image_copy_capture_frame_v1) void {
        removeItem(*CopyFrame, &self.comp.copy_frames, self);
        self.comp.a.destroy(self);
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
                comp.locked = false;
                comp.wakeDisplays(false);
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

// ------------------------------------------------------------------ Presentation

/// A wp_presentation_feedback waiting for its surface's commit to be shown.
const Presentation = struct {
    comp: *Compositor,
    resource: ws.wp_presentation_feedback,
    surface: ?*Surface,
    /// Set by the surface's next commit; earlier frames do not show it.
    committed: bool = false,
    /// Drawn into a frame still waiting to reach a display.
    in_frame: ?*Output = null,

    fn destroyed(self: *Presentation, _: ws.wp_presentation_feedback) void {
        removeItem(*Presentation, &self.comp.presentations, self);
        self.comp.a.destroy(self);
    }
};

// ------------------------------------------------------------------ Input method

/// A zwp_text_input_v3 with its double-buffered state.
const TextInput = struct {
    comp: *Compositor,
    resource: ws.zwp_text_input_v3,
    pending: State = .{},
    current: State = .{},
    commits: u32 = 0,
    /// The surface this text input was sent enter for.
    entered: ?*Surface = null,

    const State = struct {
        enabled: bool = false,
        surrounding: [4000]u8 = undefined,
        surrounding_len: usize = 0,
        has_surrounding: bool = false,
        cursor: i32 = 0,
        anchor: i32 = 0,
        cause: u32 = 0,
        hint: u32 = 0,
        purpose: u32 = 0,
        rect: Rect = .{},
    };

    fn handle(self: *TextInput, _: ws.zwp_text_input_v3, request: ws.zwp_text_input_v3.Request) void {
        switch (request) {
            // Enabling starts from a fresh state, as the protocol requires.
            .enable => self.pending = .{ .enabled = true },
            .disable => self.pending.enabled = false,
            .set_surrounding_text => |args| {
                const length = @min(args.text.len, self.pending.surrounding.len);
                @memcpy(self.pending.surrounding[0..length], args.text[0..length]);
                self.pending.surrounding_len = length;
                self.pending.has_surrounding = true;
                self.pending.cursor = args.cursor;
                self.pending.anchor = args.anchor;
            },
            .set_text_change_cause => |args| self.pending.cause = args.cause,
            .set_content_type => |args| {
                self.pending.hint = args.hint;
                self.pending.purpose = args.purpose;
            },
            .set_cursor_rectangle => |args| self.pending.rect = .{ .x = args.x, .y = args.y, .width = args.width, .height = args.height },
            .commit => {
                self.current = self.pending;
                self.commits +%= 1;
                self.comp.ime.sync();
            },
            .set_available_actions, .show_input_panel, .hide_input_panel, .destroy => {},
        }
    }

    /// Sends enter or leave so the text input follows keyboard focus.
    fn follow(self: *TextInput, focus: ?*Surface) void {
        const target = if (focus) |surface| (if (surface.resource.client() == self.resource.client()) surface else null) else null;
        if (target == self.entered) return;
        if (self.entered) |old| self.resource.sendLeave(old.resource);
        self.entered = target;
        if (target) |surface| self.resource.sendEnter(surface.resource);
    }

    fn destroyed(self: *TextInput, _: ws.zwp_text_input_v3) void {
        const ime = &self.comp.ime;
        removeItem(*TextInput, &ime.texts, self);
        if (ime.active == self) ime.active = null;
        ime.sync();
        self.comp.a.destroy(self);
    }
};

/// The zwp_input_method_v2 of the seat, if an input method is running.
const InputMethod = struct {
    comp: *Compositor,
    resource: ws.zwp_input_method_v2,
    commit_text: ?[]u8 = null,
    preedit: ?[]u8 = null,
    preedit_begin: i32 = 0,
    preedit_end: i32 = 0,
    delete_before: u32 = 0,
    delete_after: u32 = 0,
    /// Whether the compositor told it activate.
    active: bool = false,
    done_count: u32 = 0,
    grab: ?ws.zwp_input_method_keyboard_grab_v2 = null,

    fn handle(self: *InputMethod, _: ws.zwp_input_method_v2, request: ws.zwp_input_method_v2.Request) void {
        const a = self.comp.a;
        const ime = &self.comp.ime;
        switch (request) {
            .commit_string => |args| {
                if (self.commit_text) |old| a.free(old);
                self.commit_text = a.dupe(u8, args.text) catch null;
            },
            .set_preedit_string => |args| {
                if (self.preedit) |old| a.free(old);
                self.preedit = a.dupe(u8, args.text) catch null;
                self.preedit_begin = args.cursor_begin;
                self.preedit_end = args.cursor_end;
            },
            .delete_surrounding_text => |args| {
                self.delete_before = args.before_length;
                self.delete_after = args.after_length;
            },
            .commit => |args| {
                defer self.reset();
                // Only a commit answering the latest done applies to the focused text input.
                if (args.serial != self.done_count or !self.active) return;
                const text = ime.active orelse return;
                if (!text.current.enabled or text.entered != self.comp.seat.keyboard_focus) return;
                text.resource.sendPreeditString(self.preedit, self.preedit_begin, self.preedit_end);
                text.resource.sendCommitString(self.commit_text);
                text.resource.sendDeleteSurroundingText(self.delete_before, self.delete_after);
                text.resource.sendDone(text.commits);
            },
            .get_input_popup_surface => |args| {
                const surface = args.surface.data(Surface) orelse return;
                if (surface.role != .none) return args.surface.postError(ws.zwp_input_method_v2.Error.role, "surface already has a role", .{});
                const popup = create(ImePopup, self.comp, .{ .comp = self.comp, .resource = args.id, .surface = surface }) orelse return;
                surface.role = .ime_popup;
                surface.ime_popup = popup;
                ime.popups.append(a, popup) catch {};
                args.id.setHandler(ImePopup, popup, null, ImePopup.destroyed);
                ime.placePopups();
            },
            .grab_keyboard => |args| {
                if (self.grab) |old| old.setHandler(InputMethod, self, null, null);
                const grab = args.keyboard;
                grab.setHandler(InputMethod, self, null, grabGone);
                self.grab = grab;
                const keymap = self.comp.seat.active_keymap;
                grab.sendKeymap(ws.wl_keyboard.KeymapFormat.xkb_v1, keymap.fd, keymap.size);
                grab.sendRepeatInfo(25, 600);
                const m = self.comp.seat.modifiers;
                grab.sendModifiers(self.comp.server.nextSerial(), m[0], m[1], m[2], m[3]);
            },
            .destroy => {},
        }
    }

    fn reset(self: *InputMethod) void {
        const a = self.comp.a;
        if (self.commit_text) |old| a.free(old);
        if (self.preedit) |old| a.free(old);
        self.commit_text = null;
        self.preedit = null;
        self.preedit_begin = 0;
        self.preedit_end = 0;
        self.delete_before = 0;
        self.delete_after = 0;
    }

    fn grabGone(self: *InputMethod, _: ws.zwp_input_method_keyboard_grab_v2) void {
        self.grab = null;
    }

    fn done(self: *InputMethod) void {
        self.resource.sendDone();
        self.done_count +%= 1;
    }

    fn destroyed(self: *InputMethod, _: ws.zwp_input_method_v2) void {
        const ime = &self.comp.ime;
        if (ime.method == self) {
            ime.method = null;
            // The text input loses the composition in progress.
            if (ime.active) |text| {
                text.resource.sendPreeditString("", 0, 0);
                text.resource.sendDone(text.commits);
            }
        }
        if (self.grab) |grab| grab.setHandler(InputMethod, self, null, null);
        self.reset();
        self.comp.a.destroy(self);
    }
};

/// A zwp_input_popup_surface_v2, shown at the text cursor of the active text input.
const ImePopup = struct {
    comp: *Compositor,
    resource: ws.zwp_input_popup_surface_v2,
    surface: ?*Surface,
    x: i32 = 0,
    y: i32 = 0,
    visible: bool = false,

    fn destroyed(self: *ImePopup, _: ws.zwp_input_popup_surface_v2) void {
        removeItem(*ImePopup, &self.comp.ime.popups, self);
        if (self.surface) |surface| {
            surface.ime_popup = null;
            surface.role = .none;
        }
        self.comp.scheduleRepaint();
        self.comp.a.destroy(self);
    }
};

/// Relays between text inputs and the input method.
const Ime = struct {
    comp: *Compositor,
    texts: std.ArrayList(*TextInput) = .empty,
    popups: std.ArrayList(*ImePopup) = .empty,
    method: ?*InputMethod = null,
    active: ?*TextInput = null,

    fn deinit(self: *Ime) void {
        self.texts.deinit(self.comp.a);
        self.popups.deinit(self.comp.a);
    }

    /// Keyboard focus moved: text inputs follow it, then the method is updated.
    fn focusChanged(self: *Ime) void {
        for (self.texts.items) |text| text.follow(self.comp.seat.keyboard_focus);
        self.sync();
    }

    /// Activates the input method for the enabled text input on the focused surface.
    fn sync(self: *Ime) void {
        const focus = self.comp.seat.keyboard_focus;
        var next: ?*TextInput = null;
        for (self.texts.items) |text| if (text.current.enabled and text.entered != null and text.entered == focus) {
            next = text;
            break;
        };
        const previous = self.active;
        self.active = next;
        if (self.method) |method| {
            if ((previous != next or next == null) and method.active) {
                method.active = false;
                method.resource.sendDeactivate();
                method.done();
            }
            if (next) |text| {
                if (!method.active) {
                    method.active = true;
                    method.resource.sendActivate();
                }
                const state = &text.current;
                if (state.has_surrounding) method.resource.sendSurroundingText(state.surrounding[0..state.surrounding_len], @intCast(@max(0, state.cursor)), @intCast(@max(0, state.anchor)));
                method.resource.sendTextChangeCause(state.cause);
                method.resource.sendContentType(state.hint, state.purpose);
                method.done();
            }
        }
        self.placePopups();
    }

    /// The keyboard grab keys go to instead of the focused client, if any.
    /// Keys from the input method's own virtual keyboard still reach the client.
    fn grabFor(self: *Ime, source: ?*wire.Client) ?ws.zwp_input_method_keyboard_grab_v2 {
        const method = self.method orelse return null;
        if (self.active == null or !method.active) return null;
        if (source) |client| if (client == method.resource.client()) return null;
        return method.grab;
    }

    /// Positions popups below the text cursor, or above it when there is no room.
    fn placePopups(self: *Ime) void {
        for (self.popups.items) |popup| {
            popup.visible = false;
            const text = self.active orelse continue;
            const surface = text.entered orelse continue;
            const popup_surface = popup.surface orelse continue;
            const origin = self.comp.surfaceOrigin(surface) orelse continue;
            const box: Rect = .{ .x = origin[0], .y = origin[1], .width = surface.logicalWidth(), .height = surface.logicalHeight() };
            const rect = text.current.rect;
            const width = popup_surface.logicalWidth();
            const height = popup_surface.logicalHeight();
            popup.x = std.math.clamp(box.x + rect.x, box.x, @max(box.x, box.x + box.width - width));
            popup.y = if (rect.y + rect.height + height <= box.height) box.y + rect.y + rect.height else @max(box.y, box.y + rect.y - height);
            popup.visible = true;
            popup.resource.sendTextInputRectangle(rect.x + box.x - popup.x, rect.y + box.y - popup.y, rect.width, rect.height);
        }
        self.comp.scheduleRepaint();
    }
};

// ------------------------------------------------------------------ Clipboard

/// Which protocol a clipboard object belongs to.
const Clip = enum { core, control, primary };

/// A selection source. Core and data-control sources may become the selection;
/// primary-selection and data-control sources may become the primary selection.
const DataSource = struct {
    comp: *Compositor,
    resource: wire.Resource,
    kind: Clip,
    mimes: std.ArrayList([]u8) = .empty,
    /// Offers made from this source; they stop working when it goes away.
    offers: std.ArrayList(*Offer) = .empty,
    /// Drag-and-drop actions the source supports (wl_data_device_manager.dnd_action).
    actions: u32 = 0,

    fn addMime(self: *DataSource, mime_type: []const u8) void {
        for (self.mimes.items) |mime| if (std.mem.eql(u8, mime, mime_type)) return;
        const copy = self.comp.a.dupe(u8, mime_type) catch return;
        self.mimes.append(self.comp.a, copy) catch self.comp.a.free(copy);
    }

    fn coreRequest(self: *DataSource, _: ws.wl_data_source, request: ws.wl_data_source.Request) void {
        switch (request) {
            .offer => |args| self.addMime(args.mime_type),
            .destroy => {},
            .set_actions => |args| {
                self.actions = args.dnd_actions;
                self.comp.updateDragAction();
            },
        }
    }

    fn controlRequest(self: *DataSource, _: ws.zwlr_data_control_source_v1, request: ws.zwlr_data_control_source_v1.Request) void {
        switch (request) {
            .offer => |args| self.addMime(args.mime_type),
            .destroy => {},
        }
    }

    fn primaryRequest(self: *DataSource, _: ws.zwp_primary_selection_source_v1, request: ws.zwp_primary_selection_source_v1.Request) void {
        switch (request) {
            .offer => |args| self.addMime(args.mime_type),
            .destroy => {},
        }
    }

    fn send(self: *DataSource, mime_type: []const u8, fd: wire.Fd) void {
        switch (self.kind) {
            .core => (ws.wl_data_source{ .resource = self.resource }).sendSend(mime_type, fd),
            .control => (ws.zwlr_data_control_source_v1{ .resource = self.resource }).sendSend(mime_type, fd),
            .primary => (ws.zwp_primary_selection_source_v1{ .resource = self.resource }).sendSend(mime_type, fd),
        }
    }

    fn cancel(self: *DataSource) void {
        switch (self.kind) {
            .core => (ws.wl_data_source{ .resource = self.resource }).sendCancelled(),
            .control => (ws.zwlr_data_control_source_v1{ .resource = self.resource }).sendCancelled(),
            .primary => (ws.zwp_primary_selection_source_v1{ .resource = self.resource }).sendCancelled(),
        }
    }

    fn gone(self: *DataSource) void {
        const comp = self.comp;
        if (comp.drag) |*drag| if (drag.source == self) {
            drag.source = null;
            comp.endDrag();
        };
        for (self.offers.items) |offer| offer.source = null;
        self.offers.deinit(comp.a);
        for (self.mimes.items) |mime| comp.a.free(mime);
        self.mimes.deinit(comp.a);
        if (comp.selection == self) comp.setSelection(null, false);
        if (comp.primary_selection == self) comp.setSelection(null, true);
        comp.a.destroy(self);
    }

    fn coreGone(self: *DataSource, _: ws.wl_data_source) void {
        self.gone();
    }
    fn controlGone(self: *DataSource, _: ws.zwlr_data_control_source_v1) void {
        self.gone();
    }
    fn primaryGone(self: *DataSource, _: ws.zwp_primary_selection_source_v1) void {
        self.gone();
    }
};

const Offer = struct {
    comp: *Compositor,
    source: ?*DataSource,
    /// Drag-and-drop offers: whether the target accepts a type, and the
    /// actions it supports and prefers.
    drag: bool = false,
    accepted: bool = false,
    actions: u32 = 0,
    preferred: u32 = 0,
    resource: ?ws.wl_data_offer = null,

    fn receive(self: *Offer, mime_type: []const u8, fd: wire.Fd) void {
        defer _ = std.c.close(fd);
        // A replaced selection no longer answers; the pipe closes empty.
        const source = self.source orelse return;
        source.send(mime_type, fd);
    }

    fn coreRequest(self: *Offer, _: ws.wl_data_offer, request: ws.wl_data_offer.Request) void {
        switch (request) {
            .receive => |args| self.receive(args.mime_type, args.fd),
            .destroy => {},
            .accept => |args| if (self.drag) {
                self.accepted = args.mime_type != null;
                if (self.source) |source| (ws.wl_data_source{ .resource = source.resource }).sendTarget(args.mime_type);
            },
            .set_actions => |args| if (self.drag) {
                self.actions = args.dnd_actions;
                self.preferred = args.preferred_action;
                self.comp.updateDragAction();
            },
            .finish => if (self.drag) if (self.source) |source| {
                const resource: ws.wl_data_source = .{ .resource = source.resource };
                if (resource.version() >= 3) resource.sendDndFinished();
            },
        }
    }

    fn controlRequest(self: *Offer, _: ws.zwlr_data_control_offer_v1, request: ws.zwlr_data_control_offer_v1.Request) void {
        switch (request) {
            .receive => |args| self.receive(args.mime_type, args.fd),
            .destroy => {},
        }
    }

    fn primaryRequest(self: *Offer, _: ws.zwp_primary_selection_offer_v1, request: ws.zwp_primary_selection_offer_v1.Request) void {
        switch (request) {
            .receive => |args| self.receive(args.mime_type, args.fd),
            .destroy => {},
        }
    }

    fn gone(self: *Offer) void {
        if (self.comp.drag) |*drag| if (drag.offer == self) {
            drag.offer = null;
        };
        if (self.source) |source| removeItem(*Offer, &source.offers, self);
        self.comp.a.destroy(self);
    }

    fn coreGone(self: *Offer, _: ws.wl_data_offer) void {
        self.gone();
    }
    fn controlGone(self: *Offer, _: ws.zwlr_data_control_offer_v1) void {
        self.gone();
    }
    fn primaryGone(self: *Offer, _: ws.zwp_primary_selection_offer_v1) void {
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

/// A drag-and-drop operation, from start_drag until the button is released.
const Drag = struct {
    source: ?*DataSource,
    origin: *Surface,
    icon: ?*Surface,
    /// The surface under the pointer that was sent enter, and its offer.
    focus: ?*Surface = null,
    offer: ?*Offer = null,
    action: u32 = 0,
};

/// A wl_data_device, primary-selection device or wlr-data-control device.
const DataDevice = struct {
    comp: *Compositor,
    resource: wire.Resource,
    kind: Clip,

    fn replace(self: *DataDevice, source: ?*DataSource, primary: bool) void {
        const comp = self.comp;
        const current = if (primary) comp.primary_selection else comp.selection;
        if (current == source) return;
        if (current) |old| old.cancel();
        comp.setSelection(source, primary);
    }

    fn coreRequest(self: *DataDevice, _: ws.wl_data_device, request: ws.wl_data_device.Request) void {
        switch (request) {
            .set_selection => |args| self.replace(if (args.source) |resource| resource.data(DataSource) else null, false),
            .start_drag => |args| self.comp.startDrag(self, args.source, args.origin, args.icon),
            .release => {},
        }
    }

    fn primaryRequest(self: *DataDevice, _: ws.zwp_primary_selection_device_v1, request: ws.zwp_primary_selection_device_v1.Request) void {
        switch (request) {
            .set_selection => |args| self.replace(if (args.source) |resource| resource.data(DataSource) else null, true),
            .destroy => {},
        }
    }

    fn controlRequest(self: *DataDevice, resource: ws.zwlr_data_control_device_v1, request: ws.zwlr_data_control_device_v1.Request) void {
        switch (request) {
            .set_selection => |args| self.controlSet(resource, args.source, false),
            .set_primary_selection => |args| self.controlSet(resource, args.source, true),
            .destroy => {},
        }
    }

    fn controlSet(self: *DataDevice, resource: ws.zwlr_data_control_device_v1, source_resource: ?ws.zwlr_data_control_source_v1, primary: bool) void {
        const source = if (source_resource) |s| s.data(DataSource) else null;
        if (source) |value| if (value == self.comp.selection or value == self.comp.primary_selection) return resource.postError(ws.zwlr_data_control_device_v1.Error.used_source, "source already used", .{});
        self.replace(source, primary);
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
    fn primaryGone(self: *DataDevice, _: ws.zwp_primary_selection_device_v1) void {
        self.gone();
    }

    /// Whether this device reports the selection, or the primary selection.
    fn carries(self: *const DataDevice, primary: bool) bool {
        return switch (self.kind) {
            .core => !primary,
            .primary => primary,
            .control => !primary or self.resource.version() >= 2,
        };
    }

    /// Sends a selection to this device's client.
    fn offer(self: *DataDevice, source: ?*DataSource, primary: bool) void {
        switch (self.kind) {
            .control => self.offerTyped(ws.zwlr_data_control_device_v1, Offer.controlRequest, Offer.controlGone, source, primary),
            .core => self.offerTyped(ws.wl_data_device, Offer.coreRequest, Offer.coreGone, source, false),
            .primary => self.offerTyped(ws.zwp_primary_selection_device_v1, Offer.primaryRequest, Offer.primaryGone, source, false),
        }
    }

    fn offerTyped(self: *DataDevice, comptime Device: type, comptime request: anytype, comptime gone_fn: anytype, source: ?*DataSource, primary: bool) void {
        const device: Device = .{ .resource = self.resource };
        const current = source orelse {
            if (comptime @hasDecl(Device, "sendPrimarySelection")) {
                if (primary) return device.sendPrimarySelection(null);
            }
            return device.sendSelection(null);
        };
        const record = Offer.make(self.comp, current) orelse return;
        const resource = device.sendDataOffer();
        if (!resource.alive()) return record.gone();
        resource.setHandler(Offer, record, request, gone_fn);
        for (current.mimes.items) |mime| resource.sendOffer(mime);
        if (comptime @hasDecl(Device, "sendPrimarySelection")) {
            if (primary) return device.sendPrimarySelection(resource);
        }
        device.sendSelection(resource);
    }
};

// ------------------------------------------------------------------ Globals

const Compositor = struct {
    a: std.mem.Allocator,
    server: *wire.Server,
    /// Session compositors publish the switcher UI and end the session when they stop.
    show_ui: bool = false,
    /// The greeter serves the login screen without desktop shortcuts.
    greeter: bool = false,
    outputs: std.ArrayList(*Output) = .empty,
    nested: ?*Nested = null,
    drm: ?*Drm = null,
    /// linux-dmabuf: the formats GPU buffers may use, shared as a sealed table.
    dmabuf_formats: []Gl.FormatModifier = &.{},
    dmabuf_table: i32 = -1,
    /// The card's dev_t, as feedback main_device sends it.
    dmabuf_device: [8]u8 = @splat(0),
    /// The DRM device clients' timelines are imported into.
    sync_device: i32 = -1,
    /// The overview state last broadcast.
    overview_sent: bool = false,
    /// Themed cursors by shape and size, and where themes are searched.
    cursor_cache: std.ArrayList(struct { shape: u32, size: u32, image: ?Xcursor.Image }) = .empty,
    cursor_path: [4096]u8 = undefined,
    cursor_path_len: usize = 0,
    /// The drag-and-drop operation in progress.
    drag: ?Drag = null,
    /// A window being moved or resized with the pointer.
    grab: ?struct { toplevel: *Toplevel, edges: u32, start: [2]f64, box: Rect } = null,
    /// GNOME's enable-hot-corners setting, read in sessions.
    corner_settings: ?*@import("desktop-gsettings.zig").Settings = null,
    /// Turns displays off while locked; set while they are off.
    blank_timer: ?*wire.Loop.Source = null,
    blanked: bool = false,
    /// Set once start-up finished; later outputs are hotplugged.
    started: bool = false,
    seat: Seat = undefined,
    ime: Ime = undefined,
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
    primary_selection: ?*DataSource = null,
    data_devices: std.ArrayList(*DataDevice) = .empty,
    foreign_managers: std.ArrayList(ws.zwlr_foreign_toplevel_manager_v1) = .empty,
    head_managers: std.ArrayList(*HeadManager) = .empty,
    output_sessions: std.ArrayList(*CaptureSession) = .empty,
    copy_frames: std.ArrayList(*CopyFrame) = .empty,
    activation_tokens: std.ArrayList([24]u8) = .empty,
    next_token: u64 = 0,
    presentations: std.ArrayList(*Presentation) = .empty,
    frame_sequence: u64 = 0,
    /// Changes whenever the output configuration does.
    output_serial: u32 = 1,
    background: u32 = 0xff303030,

    /// Creates `count` outputs side by side, as wlroots lays them out, shown by `backend`.
    fn init(self: *Compositor, backend: Backend, width: u32, height: u32, count: usize) !void {
        self.seat = .{ .comp = self };
        self.ime = .{ .comp = self };
        if (backend == .wayland) self.nested = try Nested.create(self);
        if (backend == .drm) self.drm = try Drm.create(self);
        for (0..if (backend == .drm) 0 else count) |index| {
            const output = try Output.create(self, index, width, height);
            errdefer output.destroy();
            output.x = @intCast(index * width);
            output.usable = output.box();
            try self.outputs.append(self.a, output);
            if (self.nested) |nested| try nested.addOutput(output);
        }
        try self.seat.init();
        self.blank_timer = try self.server.loop.timer(self, &blankTimeout);
        if (self.show_ui) self.corner_settings = @import("desktop-gsettings.zig").Settings.open(self.a, "org.gnome.desktop.interface", "enable-hot-corners");
        const server = self.server;
        try self.expose(ws.wl_compositor, 6, compositorRequest);
        try self.expose(ws.wl_subcompositor, 1, subcompositorRequest);
        _ = try server.createGlobal(&ws.wl_shm.interface, 2, self, &bindShm);
        try self.expose(ws.xdg_wm_base, 6, wmBaseRequest);
        try self.expose(ws.zxdg_output_manager_v1, 3, outputManagerRequest);
        _ = try server.createGlobal(&ws.wl_seat.interface, 9, &self.seat, &Seat.bind);
        try self.expose(ws.wl_data_device_manager, 3, dataDeviceManagerRequest);
        try self.expose(ws.zwlr_data_control_manager_v1, 2, dataControlManagerRequest);
        try self.expose(ws.zwp_primary_selection_device_manager_v1, 1, primarySelectionRequest);
        try self.expose(ws.zwlr_layer_shell_v1, 4, layerShellRequest);
        try self.expose(ws.zwp_virtual_keyboard_manager_v1, 1, virtualKeyboardManagerRequest);
        try self.expose(ws.zwlr_virtual_pointer_manager_v1, 2, virtualPointerManagerRequest);
        _ = try server.createGlobal(&ws.zwlr_foreign_toplevel_manager_v1.interface, 3, self, &bindForeignManager);
        try self.expose(ws.zwlr_screencopy_manager_v1, 3, screencopyRequest);
        _ = try server.createGlobal(&ws.zwlr_output_manager_v1.interface, 4, self, &bindOutputManagement);
        try self.expose(ws.zxdg_decoration_manager_v1, 1, decorationManagerRequest);
        _ = try server.createGlobal(&ws.org_kde_kwin_server_decoration_manager.interface, 1, self, &bindKdeDecoration);
        _ = try server.createGlobal(&ws.ext_foreign_toplevel_list_v1.interface, 1, self, &bindToplevelList);
        try self.expose(ws.ext_foreign_toplevel_image_capture_source_manager_v1, 1, captureSourceRequest);
        try self.expose(ws.ext_image_copy_capture_manager_v1, 1, imageCopyRequest);
        _ = try server.createGlobal(&ws.dotfiles_overview_v1.interface, 3, self, &bindOverview);
        try self.expose(ws.wp_viewporter, 1, viewporterRequest);
        try self.expose(ws.ext_session_lock_manager_v1, 1, lockManagerRequest);
        try self.expose(ws.wp_fractional_scale_manager_v1, 1, fractionalScaleRequest);
        try self.expose(ws.ext_idle_notifier_v1, 2, idleNotifierRequest);
        try self.expose(ws.zwp_idle_inhibit_manager_v1, 1, idleInhibitRequest);
        try self.expose(ws.ext_output_image_capture_source_manager_v1, 1, outputSourceRequest);
        try self.expose(ws.wp_single_pixel_buffer_manager_v1, 1, singlePixelRequest);
        try self.expose(ws.wp_cursor_shape_manager_v1, 1, cursorShapeRequest);
        try self.expose(ws.xdg_activation_v1, 1, activationRequest);
        _ = try server.createGlobal(&ws.wp_presentation.interface, 1, self, &bindPresentation);
        try self.expose(ws.zwp_text_input_manager_v3, 1, textInputRequest);
        try self.expose(ws.zwp_input_method_manager_v2, 1, inputMethodRequest);
        for (self.outputs.items) |output| output.render();
        self.cursorChanged();
        self.started = true;
    }

    fn expose(self: *Compositor, comptime T: type, version: u32, comptime handler: fn (*Compositor, T, T.Request) void) !void {
        const Bind = struct {
            fn bind(data: ?*anyopaque, resource: wire.Resource) void {
                const comp: *Compositor = @ptrCast(@alignCast(data));
                (T{ .resource = resource }).setHandler(Compositor, comp, handler, null);
            }
        };
        _ = try self.server.createGlobal(&T.interface, version, self, &Bind.bind);
    }

    fn deinit(self: *Compositor) void {
        // Disconnect clients while compositor lists and the GPU renderer are still live.
        self.server.disconnectAll();
        if (self.nested) |nested| nested.destroy();
        if (self.drm) |backend| backend.destroy();
        // Clients' surfaces are already gone; clear pointers before freeing the rest.
        self.drm = null;
        self.sync_device = -1;
        self.a.free(self.dmabuf_formats);
        if (self.dmabuf_table >= 0) _ = std.c.close(self.dmabuf_table);
        if (self.corner_settings) |settings| settings.close();
        for (self.cursor_cache.items) |entry| if (entry.image) |image| image.deinit(self.a);
        self.cursor_cache.deinit(self.a);
        self.seat.deinit();
        self.ime.deinit();
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
        self.output_sessions.deinit(self.a);
        self.copy_frames.deinit(self.a);
        self.activation_tokens.deinit(self.a);
        self.presentations.deinit(self.a);
        for (self.outputs.items) |output| output.destroy();
        self.outputs.deinit(self.a);
    }

    fn scheduleRepaint(self: *Compositor) void {
        for (self.outputs.items) |output| output.scheduleRepaint();
    }

    /// Redraws the part of the outputs a committed surface damaged.
    fn surfaceDamaged(self: *Compositor, surface: *Surface, damage: ?Rect) void {
        const box = damage orelse {
            // A shown surface that asks for a frame without new content still
            // gets its callback at the next refresh, as wlroots' scene does.
            if (surface.frames.items.len > 0 and self.surfaceOrigin(surface) != null) {
                for (self.outputs.items) |output| output.scheduleFrame();
            }
            return;
        };
        // Previews and the drag icon show surfaces outside the stack.
        for (self.layers.items) |layer| if (layer.previews.items.len > 0) return self.scheduleRepaint();
        if (self.drag) |drag| if (drag.icon == surface) return self.scheduleRepaint();
        const origin = self.surfaceOrigin(surface) orelse return;
        for (self.outputs.items) |output| {
            if (!output.enabled) continue;
            const s = output.scale;
            const x: f64 = @floatFromInt(origin[0] + box.x - output.x);
            const y: f64 = @floatFromInt(origin[1] + box.y - output.y);
            // One pixel more each side covers filtering at fractional scales.
            const left = clampInt(@floor(x * s) - 1);
            const top = clampInt(@floor(y * s) - 1);
            const right = clampInt(@ceil((x + @as(f64, @floatFromInt(box.width))) * s) + 1);
            const bottom = clampInt(@ceil((y + @as(f64, @floatFromInt(box.height))) * s) + 1);
            output.addDamage(.{ .x = left, .y = top, .width = right -| left, .height = bottom -| top });
        }
    }

    /// Where a shown surface is, in global coordinates: a root of the stack
    /// or a subsurface of one.
    fn surfaceOrigin(self: *Compositor, surface: *Surface) ?[2]i32 {
        var roots: [256]Root = undefined;
        for (self.stack(&roots)) |root| if (findIn(root.surface, surface, root.x, root.y)) |found| return found;
        return null;
    }

    fn findIn(tree: *Surface, wanted: *Surface, x: i32, y: i32) ?[2]i32 {
        if (tree == wanted) return .{ x, y };
        for (tree.children.items) |child| if (child.surface) |surface| {
            if (findIn(surface, wanted, x + child.x, y + child.y)) |found| return found;
        };
        return null;
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
            result = if (result) |r| r.merge(b) else b;
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
        for (self.data_devices.items) |device| {
            if (device.kind == .control or device.resource.client != surface.resource.client()) continue;
            if (device.carries(false)) device.offer(self.selection, false);
            if (device.carries(true)) device.offer(self.primary_selection, true);
        }
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

    /// Tells overview clients (the panel) when the overview opens or closes.
    fn broadcastOverview(self: *Compositor) void {
        const active = self.overviewActive();
        if (active == self.overview_sent) return;
        self.overview_sent = active;
        for (self.overviews.items) |overview| if (overview.resource.version() >= 2) overview.resource.sendOverview(@intFromBool(active));
    }

    // ---------------------------------------------------------- Shortcuts

    const Mods = struct { shift: bool, alt: bool, logo: bool };

    /// Handles a key before clients see it; returns whether it was consumed.
    fn shortcut(self: *Compositor, sym: u32, mods: Mods, pressed: bool) bool {
        if (self.locked or self.greeter) return false;
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
                keysyms.Down => {
                    self.cycle_app = true;
                    self.showSwitcher();
                },
                keysyms.Up => {
                    self.cycle_app = false;
                    self.showSwitcher();
                },
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
                    // The UI thread ends a session; a bare compositor stops its loop.
                    if (self.show_ui) _ = std.c.kill(libc.getpid(), std.c.SIG.TERM) else self.server.quit = true;
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
            self.showSwitcher();
            return;
        }
        if (same_app) self.cycle(reverse, false) else self.finishCycle(true);
    }

    /// Publishes the switcher's contents to the UI thread.
    fn showSwitcher(self: *Compositor) void {
        if (!self.show_ui) return;
        const ui = @import("desktop-switcher.zig");
        var snapshot: ui.Snapshot = .{ .visible = true, .window_selection = self.cycle_app };
        if (self.focusedOutput()) |output| {
            const b = output.box();
            snapshot.output_x = b.x + @divTrunc(b.width, 2);
            snapshot.output_y = b.y + @divTrunc(b.height, 2);
        }
        for (self.recent.items) |toplevel| {
            if (!toplevel.mapped or toplevel.workspace != self.workspace or snapshot.len == snapshot.items.len) continue;
            var item = &snapshot.items[snapshot.len];
            const label = if (toplevel.title.len > 0) toplevel.title else toplevel.app_id;
            const id = toplevel.identifier();
            @memcpy(item.id[0..@min(id.len, 255)], id[0..@min(id.len, 255)]);
            @memcpy(item.app_id[0..@min(toplevel.app_id.len, 255)], toplevel.app_id[0..@min(toplevel.app_id.len, 255)]);
            @memcpy(item.title[0..@min(label.len, 255)], label[0..@min(label.len, 255)]);
            item.selected = toplevel == self.cycle_selected;
            snapshot.len += 1;
        }
        @import("desktop-switcher.zig").publish(self.a, snapshot);
    }

    fn finishCycle(self: *Compositor, cancel: bool) void {
        const selected = if (cancel) self.cycle_origin else self.cycle_selected;
        self.cycling = false;
        self.cycle_origin = null;
        self.cycle_selected = null;
        if (self.show_ui) @import("desktop-switcher.zig").publish(self.a, .{});
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
        // The topmost grabbing popup of the focused client takes the keyboard.
        if (target) |focused| {
            var index = self.popups.items.len;
            while (index > 0) {
                index -= 1;
                const popup = self.popups.items[index];
                if (!popup.grabbed or !popup.mapped) continue;
                const surface = (popup.xdg orelse continue).surface orelse continue;
                if (surface.resource.client() != focused.resource.client()) continue;
                target = surface;
                break;
            }
        }
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
    /// The topmost window of the current workspace on `output`.
    fn frontToplevel(self: *Compositor, output: *Output) ?*Toplevel {
        var index = self.toplevels.items.len;
        while (index > 0) {
            index -= 1;
            const toplevel = self.toplevels.items[index];
            if (toplevel.mapped and toplevel.workspace == self.workspace and toplevel.output == output) return toplevel;
        }
        return null;
    }

    // ---------------------------------------------------------- Moving and resizing

    /// Starts moving (no edges) or resizing a window from a button press on it.
    fn beginGrab(self: *Compositor, toplevel: *Toplevel, edges: u32) void {
        if (self.locked or toplevel.fullscreen or !toplevel.mapped or self.seat.buttons == 0) return;
        const pressed_on = self.seat.pointer_focus orelse return;
        if (pressed_on.resource.client() != toplevel.resource.client()) return;
        const xdg = toplevel.xdg orelse return;
        const geometry = xdg.windowGeometry();
        const box: Rect = .{ .x = toplevel.x, .y = toplevel.y, .width = geometry.width, .height = geometry.height };
        self.grab = .{ .toplevel = toplevel, .edges = edges, .start = .{ self.seat.pointer_x, self.seat.pointer_y }, .box = box };
        toplevel.floating = box;
        toplevel.maximized = false;
        toplevel.tile = .none;
        toplevel.reconfigure(false);
    }

    fn grabMotion(self: *Compositor) void {
        const grab = self.grab orelse return;
        const toplevel = grab.toplevel;
        const dx: i32 = @intFromFloat(self.seat.pointer_x - grab.start[0]);
        const dy: i32 = @intFromFloat(self.seat.pointer_y - grab.start[1]);
        var box = grab.box;
        const Edge = ws.xdg_toplevel.ResizeEdge;
        if (grab.edges == 0) {
            box.x += dx;
            box.y += dy;
        } else {
            if (grab.edges & Edge.left != 0) box.width -= dx;
            if (grab.edges & Edge.right != 0) box.width += dx;
            if (grab.edges & Edge.top != 0) box.height -= dy;
            if (grab.edges & Edge.bottom != 0) box.height += dy;
            box.width = @max(toplevel.min_size[0], @max(64, box.width));
            box.height = @max(toplevel.min_size[1], @max(48, box.height));
            if (grab.edges & Edge.left != 0) box.x = grab.box.x + (grab.box.width - box.width);
            if (grab.edges & Edge.top != 0) box.y = grab.box.y + (grab.box.height - box.height);
        }
        toplevel.floating = box;
        toplevel.reconfigure(false);
        toplevel.place();
        self.scheduleRepaint();
    }

    // ---------------------------------------------------------- Hot corner

    /// Relative motion against the top-left corner's barriers, as GNOME Shell's
    /// pressure barriers: enough pressure opens the overview. Returns where
    /// the pointer goes, held at a barrier it presses against.
    fn cornerMotion(self: *Compositor, x: f64, y: f64, dx: f64, dy: f64, time: u32) [2]f64 {
        var next_x = x + dx;
        var next_y = y + dy;
        const enabled = if (self.corner_settings) |settings| settings.boolean("enable-hot-corners") else true;
        var allowed = enabled and !self.locked and !self.greeter and !self.cycling and self.grab == null and self.drag == null;
        var in_overview = false;
        for (self.layers.items) |layer| {
            if (!layer.mapped) continue;
            if (std.mem.eql(u8, layer.namespace, "desktop-overview")) {
                in_overview = true;
            } else if (layer.current.interactivity == 1) allowed = false;
        }
        var toggle = false;
        for (self.outputs.items, 0..) |output, index| {
            const area = output.box();
            const left: f64 = @floatFromInt(area.x);
            const top: f64 = @floatFromInt(area.y);
            // GNOME always enables the primary corner; others need no monitor above or to their left.
            var exposed = true;
            if (index != 0) for (self.outputs.items) |other| {
                if (other == output or !other.enabled) continue;
                if (other.contains(left - 1, top) or other.contains(left, top - 1)) exposed = false;
            };
            if (!allowed or !exposed or !output.enabled) {
                output.pressure.reset();
                continue;
            }
            const size = self.barrierSize(output);
            output.pressure.leave(x <= left and y >= top and y <= top + size, y <= top and x >= left and x <= left + size);
            var triggered = false;
            var vertical = false;
            var horizontal = false;
            if (dx < 0 and x >= left and next_x <= left) {
                const cross_y = y + dy * ((left - x) / dx);
                vertical = cross_y >= top and cross_y <= top + size;
            }
            if (dy < 0 and y >= top and next_y <= top) {
                const cross_x = x + dx * ((top - y) / dy);
                horizontal = cross_x >= left and cross_x <= left + size;
            }
            // After hitting one arm, the remaining motion can hit the other.
            if (vertical and dy < 0 and next_y <= top) horizontal = true;
            if (horizontal and dx < 0 and next_x <= left) vertical = true;
            if (vertical) {
                next_x = left;
                triggered = output.pressure.hit(self.a, true, dx, dy, time) or triggered;
            }
            if (horizontal) {
                next_y = top;
                triggered = output.pressure.hit(self.a, false, dx, dy, time) or triggered;
            }
            output.pressure.leave(next_x <= left and next_y >= top and next_y <= top + size, next_y <= top and next_x >= left and next_x <= left + size);
            const fullscreen = if (self.frontToplevel(output)) |front| front.fullscreen else false;
            if (triggered and (!fullscreen or in_overview)) toggle = true;
        }
        if (toggle) launch(self.a, "overview-corner");
        return .{ next_x, next_y };
    }

    /// Absolute pointers have no pressure; leaving a barrier releases it.
    fn cornerReleased(self: *Compositor) void {
        const x = self.seat.pointer_x;
        const y = self.seat.pointer_y;
        for (self.outputs.items) |output| {
            const area = output.box();
            const left: f64 = @floatFromInt(area.x);
            const top: f64 = @floatFromInt(area.y);
            const size = self.barrierSize(output);
            output.pressure.leave(x <= left and y >= top and y <= top + size, y <= top and x >= left and x <= left + size);
        }
    }

    /// The barriers reach as far as the panel is tall.
    fn barrierSize(self: *Compositor, output: *Output) f64 {
        for (self.layers.items) |layer| {
            if (layer.output == output and std.mem.eql(u8, layer.namespace, "desktop-panel") and layer.current.zone > 0) return @floatFromInt(layer.current.zone);
        }
        return 32;
    }

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
        // The panel stays above other top-layer surfaces, such as the overview,
        // and hides over a fullscreen window unless the overview is open.
        const overview = self.overviewActive();
        for ([_]bool{ false, true }) |panel| for (self.layers.items) |layer| {
            if (!layer.mapped or layer.current.layer != 2 or std.mem.eql(u8, layer.namespace, "desktop-panel") != panel) continue;
            if (panel and !overview) if (self.frontToplevel(layer.output)) |front| if (front.fullscreen) continue;
            add(out, &count, layer.surface, layer.rect.x, layer.rect.y);
        };
        for (self.popups.items) |popup| {
            if (!popup.mapped) continue;
            if (popup.toplevelRoot()) |owner| if (owner.workspace != self.workspace) continue;
            const xdg = popup.xdg orelse continue;
            const origin = popup.parentOrigin() orelse continue;
            const geometry = xdg.windowGeometry();
            add(out, &count, xdg.surface, origin[0] + popup.rect.x - geometry.x, origin[1] + popup.rect.y - geometry.y);
        }
        for (self.ime.popups.items) |popup| if (popup.visible) add(out, &count, popup.surface, popup.x, popup.y);
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
        for (shm_formats) |format| shm.sendFormat(format);
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
                const layout = shmLayout(args.format) orelse
                    return resource.postError(ws.wl_shm.Error.invalid_format, "unsupported format {d}", .{args.format});
                if (args.width <= 0 or args.height <= 0 or args.offset < 0 or args.width > 1 << 16 or args.stride < args.width * @as(i32, @intCast(layout.bytes)) or args.stride > 1 << 20)
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
        buffer.alive = false;
        for (comp.surfaces.items) |surface| {
            if (surface.pending_buffer == buffer) surface.pending_buffer = null;
        }
        for (comp.copy_frames.items) |frame| {
            if (frame.buffer == buffer) frame.buffer = null;
        }
        buffer.unref();
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
                    xdg_output.sendDescription(output.model);
                }
                if (xdg_output.version() < 3) xdg_output.sendDone();
                // wl_output.done completes xdg_output state since version 3.
                for (output.resources.items) |wl_output| if (wl_output.client() == xdg_output.client() and wl_output.version() >= 2) wl_output.sendDone();
            },
        }
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

    fn virtualKeyboardManagerRequest(self: *Compositor, _: ws.zwp_virtual_keyboard_manager_v1, request: ws.zwp_virtual_keyboard_manager_v1.Request) void {
        switch (request) {
            .create_virtual_keyboard => |args| {
                const keyboard = create(VirtualKeyboard, self, .{ .comp = self }) orelse return;
                args.id.setHandler(VirtualKeyboard, keyboard, VirtualKeyboard.handle, VirtualKeyboard.destroyed);
            },
        }
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
                self.armBlank();
                self.updateInhibition();
                self.lock_serial +%= 1;
                self.cycling = false;
                self.cycle_origin = null;
                self.cycle_selected = null;
                self.super_alone = false;
                self.grab = null;
                if (self.drag) |drag| {
                    self.dragLeave();
                    if (drag.source) |source| source.cancel();
                    self.endDrag();
                }
                self.dismissPopups();
                if (self.show_ui) @import("desktop-switcher.zig").publish(self.a, .{});
                self.seat.focusSurface(null);
                self.seat.updatePointerFocus();
                self.scheduleRepaint();
            },
        }
    }

    /// User input resets idle timers.
    fn activity(self: *Compositor) void {
        for (self.idle_notifications.items) |notification| notification.activity();
        // Input on the lock screen lights the displays for another while.
        if (self.locked) self.wakeDisplays(true);
    }

    /// Displays turn off a while after the lock screen is up, as the wlroots
    /// compositor did, until input or unlocking.
    const lock_blank_ms = 10_000;

    fn armBlank(self: *Compositor) void {
        if (self.blank_timer) |timer| wire.Loop.arm(timer, lock_blank_ms);
    }

    fn blankTimeout(data: ?*anyopaque, _: u32) void {
        const self: *Compositor = @ptrCast(@alignCast(data));
        if (!self.locked) return;
        const lock = self.lock orelse return;
        // Not before the lock screen has been shown.
        if (!lock.acknowledged) return self.armBlank();
        self.blanked = true;
        for (self.outputs.items) |output| if (output.display) |display| display.disable();
        if (self.drm != null) std.log.info("compositor: displays off on the lock screen", .{});
    }

    fn wakeDisplays(self: *Compositor, rearm: bool) void {
        if (self.blank_timer) |timer| wire.Loop.arm(timer, if (rearm) lock_blank_ms else 0);
        if (!self.blanked) return;
        self.blanked = false;
        if (self.drm != null) std.log.info("compositor: displays on", .{});
        for (self.outputs.items) |output| if (output.display != null) {
            output.unpresented = false;
            output.scheduleRepaint();
        };
        self.cursorChanged();
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

    fn outputSourceRequest(self: *Compositor, _: ws.ext_output_image_capture_source_manager_v1, request: ws.ext_output_image_capture_source_manager_v1.Request) void {
        switch (request) {
            .create_source => |args| {
                const source = create(CaptureSource, self, .{ .comp = self, .toplevel = null, .output = self.findOutput(args.output) }) orelse return;
                args.source.setHandler(CaptureSource, source, null, CaptureSource.destroyed);
            },
            .destroy => {},
        }
    }

    fn singlePixelRequest(self: *Compositor, _: ws.wp_single_pixel_buffer_manager_v1, request: ws.wp_single_pixel_buffer_manager_v1.Request) void {
        switch (request) {
            .destroy => {},
            .create_u32_rgba_buffer => |args| {
                // Channels are premultiplied 32-bit values.
                const channel = struct {
                    fn f(value: u32) u32 {
                        return value >> 24;
                    }
                }.f;
                const solid = channel(args.a) << 24 | channel(args.r) << 16 | channel(args.g) << 8 | channel(args.b);
                const buffer = create(Buffer, self, .{ .comp = self, .resource = args.id, .pool = null, .solid = solid, .offset = 0, .width = 1, .height = 1, .stride = 4, .format = ws.wl_shm.Format.argb8888 }) orelse return;
                args.id.setHandler(Buffer, buffer, bufferRequest, bufferGone);
            },
        }
    }

    fn cursorShapeDevice(self: *Compositor, resource: ws.wp_cursor_shape_device_v1, request: ws.wp_cursor_shape_device_v1.Request) void {
        switch (request) {
            .set_shape => |args| {
                const focused = self.seat.pointer_focus orelse return;
                if (focused.resource.client() != resource.client()) return;
                if (args.shape < 1 or args.shape >= cursor_names.len) return;
                self.seat.cursor = null;
                self.seat.cursor_mode = .default;
                self.seat.cursor_shape = args.shape;
                self.cursorChanged();
            },
            .destroy => {},
        }
    }

    // ---------------------------------------------------------- Drag and drop

    /// Starts a drag from a button press on the requesting client's surface.
    fn startDrag(self: *Compositor, device: *DataDevice, source_resource: ?ws.wl_data_source, origin_resource: ws.wl_surface, icon_resource: ?ws.wl_surface) void {
        const source = if (source_resource) |resource| resource.data(DataSource) else null;
        const origin = origin_resource.data(Surface) orelse return;
        const pressed_on = self.seat.pointer_focus;
        // Only during an implicit grab of this client's surface, as wlroots checks.
        if (self.drag != null or self.seat.buttons == 0 or pressed_on == null or pressed_on.?.resource.client() != device.resource.client) {
            if (source) |value| value.cancel();
            return;
        }
        var icon: ?*Surface = null;
        if (icon_resource) |resource| if (resource.data(Surface)) |surface| {
            if (surface.role != .none and surface.role != .drag_icon) return resource.postError(ws.wl_data_device.Error.role, "surface already has a role", .{});
            surface.role = .drag_icon;
            icon = surface;
        };
        self.drag = .{ .source = source, .origin = origin, .icon = icon };
        // The pointer leaves its surface while dragging; drag events take over.
        if (self.seat.pointer_focus) |old| for (self.seat.pointers.items) |pointer| {
            if (pointer.client() != old.resource.client()) continue;
            pointer.sendLeave(self.server.nextSerial(), old.resource);
            if (pointer.version() >= 5) pointer.sendFrame();
        };
        self.seat.pointer_focus = null;
        self.dragMotion(nowMs());
    }

    /// Sends drag enter, leave and motion to the clients under the pointer.
    fn dragMotion(self: *Compositor, time: u32) void {
        const drag = &(self.drag orelse return);
        const seat = &self.seat;
        const hit = self.surfaceAt(seat.pointer_x, seat.pointer_y);
        var target = if (hit) |value| value.surface else null;
        // A drag without a source stays within its own client.
        if (drag.source == null) if (target) |surface| if (surface.resource.client() != drag.origin.resource.client()) {
            target = null;
        };
        if (target != drag.focus) {
            self.dragLeave();
            if (target) |surface| self.dragEnter(surface, seat.pointer_x - @as(f64, @floatFromInt(hit.?.x)), seat.pointer_y - @as(f64, @floatFromInt(hit.?.y)));
        } else if (drag.focus) |surface| {
            const x = seat.pointer_x - @as(f64, @floatFromInt(hit.?.x));
            const y = seat.pointer_y - @as(f64, @floatFromInt(hit.?.y));
            for (self.data_devices.items) |device| if (device.kind == .core and device.resource.client == surface.resource.client()) {
                (ws.wl_data_device{ .resource = device.resource }).sendMotion(time, x, y);
            };
        }
        if (drag.icon != null) self.scheduleRepaint();
    }

    fn dragEnter(self: *Compositor, surface: *Surface, x: f64, y: f64) void {
        const drag = &(self.drag orelse return);
        drag.focus = surface;
        drag.action = 0;
        const serial = self.server.nextSerial();
        for (self.data_devices.items) |device| {
            if (device.kind != .core or device.resource.client != surface.resource.client()) continue;
            const data_device: ws.wl_data_device = .{ .resource = device.resource };
            var offer_resource: ?ws.wl_data_offer = null;
            if (drag.source) |source| {
                const record = Offer.make(self, source) orelse continue;
                const resource = data_device.sendDataOffer();
                if (!resource.alive()) {
                    record.gone();
                    continue;
                }
                record.drag = true;
                record.resource = resource;
                resource.setHandler(Offer, record, Offer.coreRequest, Offer.coreGone);
                for (source.mimes.items) |mime| resource.sendOffer(mime);
                if (resource.version() >= 3) resource.sendSourceActions(source.actions);
                drag.offer = record;
                offer_resource = resource;
            }
            data_device.sendEnter(serial, surface.resource, x, y, offer_resource);
        }
    }

    fn dragLeave(self: *Compositor) void {
        const drag = &(self.drag orelse return);
        const surface = drag.focus orelse return;
        for (self.data_devices.items) |device| if (device.kind == .core and device.resource.client == surface.resource.client()) {
            (ws.wl_data_device{ .resource = device.resource }).sendLeave();
        };
        // An offer that was left no longer reaches the source.
        if (drag.offer) |offer| offer.drag = false;
        drag.offer = null;
        drag.focus = null;
        drag.action = 0;
    }

    /// Agrees an action both sides support, preferring the target's choice.
    fn updateDragAction(self: *Compositor) void {
        const drag = &(self.drag orelse return);
        const source = drag.source orelse return;
        const offer = drag.offer orelse return;
        const both = source.actions & offer.actions;
        var action: u32 = 0;
        if (both & offer.preferred != 0) {
            action = offer.preferred;
        } else if (both != 0) {
            action = both & (~both +% 1);
        }
        if (action == drag.action) return;
        drag.action = action;
        if (offer.resource) |resource| if (resource.version() >= 3) resource.sendAction(action);
        const source_resource: ws.wl_data_source = .{ .resource = source.resource };
        if (source_resource.version() >= 3) source_resource.sendAction(action);
    }

    /// The button was released: drop on an accepting target, or cancel.
    fn dragDrop(self: *Compositor) void {
        const drag = &(self.drag orelse return);
        var dropped = false;
        if (drag.focus) |surface| {
            const offer_ok = if (drag.source) |source| blk: {
                const offer = drag.offer orelse break :blk false;
                const version = (ws.wl_data_source{ .resource = source.resource }).version();
                break :blk offer.accepted and (version < 3 or drag.action != 0);
            } else true;
            if (offer_ok) {
                for (self.data_devices.items) |device| if (device.kind == .core and device.resource.client == surface.resource.client()) {
                    (ws.wl_data_device{ .resource = device.resource }).sendDrop();
                };
                if (drag.source) |source| {
                    const resource: ws.wl_data_source = .{ .resource = source.resource };
                    if (resource.version() >= 3) resource.sendDndDropPerformed();
                }
                dropped = true;
            }
        }
        if (!dropped) {
            self.dragLeave();
            if (drag.source) |source| source.cancel();
        }
        self.endDrag();
    }

    /// Ends the drag; the pointer goes back to the surface under it.
    fn endDrag(self: *Compositor) void {
        const drag = self.drag orelse return;
        if (drag.icon) |icon| icon.role = .none;
        self.drag = null;
        self.seat.updatePointerFocus();
        self.scheduleRepaint();
    }

    fn dragSurfaceGone(self: *Compositor, surface: *Surface) void {
        const drag = &(self.drag orelse return);
        if (drag.icon == surface) drag.icon = null;
        if (drag.focus == surface) {
            if (drag.offer) |offer| offer.drag = false;
            drag.focus = null;
            drag.offer = null;
        }
        if (drag.origin == surface) {
            if (drag.source) |source| source.cancel();
            self.endDrag();
        }
    }

    /// Offers linux-drm-syncobj on NVIDIA, whose clients synchronise
    /// explicitly; DESKTOP_EXPLICIT_SYNC=1 or 0 overrides the choice.
    fn enableExplicitSync(self: *Compositor, renderer: *Gl.Renderer, card_fd: i32) void {
        const wanted = if (std.c.getenv("DESKTOP_EXPLICIT_SYNC")) |value| std.mem.eql(u8, std.mem.span(value), "1") else std.mem.indexOf(u8, renderer.name(), "NVIDIA") != null;
        if (!wanted) return;
        if (renderer.dup_fence == null or !Syncobj.supported(card_fd)) {
            std.log.warn("compositor: explicit sync needs native fences and timeline syncobjs", .{});
            return;
        }
        self.sync_device = card_fd;
        self.expose(ws.wp_linux_drm_syncobj_manager_v1, 1, explicitSyncRequest) catch return;
        std.log.info("compositor: offering explicit sync", .{});
    }

    fn explicitSyncRequest(self: *Compositor, resource: ws.wp_linux_drm_syncobj_manager_v1, request: ws.wp_linux_drm_syncobj_manager_v1.Request) void {
        const Error = ws.wp_linux_drm_syncobj_manager_v1.Error;
        switch (request) {
            .destroy => {},
            .get_surface => |args| {
                const surface = args.surface.data(Surface) orelse return;
                if (surface.sync != null) return resource.postError(Error.surface_exists, "the surface already has explicit sync", .{});
                const sync = create(SyncSurface, self, .{ .comp = self, .resource = args.id, .surface = surface }) orelse return;
                surface.sync = sync;
                args.id.setHandler(SyncSurface, sync, SyncSurface.handle, SyncSurface.destroyed);
            },
            .import_timeline => |args| {
                defer _ = std.c.close(args.fd);
                const timeline = Syncobj.Timeline.import(self.sync_device, args.fd) orelse return resource.postError(Error.invalid_timeline, "not a DRM syncobj", .{});
                const object = create(SyncTimeline, self, .{ .comp = self, .timeline = timeline }) orelse return timeline.destroy();
                args.id.setHandler(SyncTimeline, object, SyncTimeline.handle, SyncTimeline.destroyed);
            },
        }
    }

    /// Offers linux-dmabuf, so GL and Vulkan clients share GPU buffers.
    fn enableDmabuf(self: *Compositor, renderer: *Gl.Renderer, major: u32, minor: u32) !void {
        const formats = try renderer.dmabufFormats(self.a);
        errdefer self.a.free(formats);
        if (formats.len == 0 or formats.len > std.math.maxInt(u16)) return error.NoDmabufFormats;
        // The table is a sealed memfd clients map read-only.
        const fd = libc.memfd_create("dmabuf-formats", 0x0001 | 0x0002); // CLOEXEC | ALLOW_SEALING
        if (fd < 0) return error.NoMemory;
        errdefer _ = std.c.close(fd);
        const bytes = std.mem.sliceAsBytes(formats);
        if (std.c.write(fd, bytes.ptr, bytes.len) != @as(isize, @intCast(bytes.len))) return error.NoMemory;
        // F_ADD_SEALS: no shrinking, growing or writing.
        _ = std.c.fcntl(fd, 1033, @as(c_int, 0x0002 | 0x0004 | 0x0008));
        const dev: u64 = (minor & 0xff) | ((@as(u64, major) & 0xfff) << 8) | ((@as(u64, minor) & ~@as(u64, 0xff)) << 12) | ((@as(u64, major) & ~@as(u64, 0xfff)) << 32);
        self.dmabuf_device = @bitCast(dev);
        self.dmabuf_formats = formats;
        self.dmabuf_table = fd;
        _ = try self.server.createGlobal(&ws.zwp_linux_dmabuf_v1.interface, 4, self, &bindDmabuf);
        std.log.info("compositor: sharing GPU buffers in {d} formats and layouts", .{formats.len});
    }

    fn bindDmabuf(data: ?*anyopaque, resource: wire.Resource) void {
        const self: *Compositor = @ptrCast(@alignCast(data));
        const dmabuf: ws.zwp_linux_dmabuf_v1 = .{ .resource = resource };
        dmabuf.setHandler(Compositor, self, dmabufRequest, null);
        // Before feedback (version 4), formats are announced on bind.
        if (dmabuf.version() < 4) for (self.dmabuf_formats) |entry| {
            if (dmabuf.version() >= 3) dmabuf.sendModifier(entry.format, @truncate(entry.modifier >> 32), @truncate(entry.modifier)) else if (entry.modifier == Gl.modifier_invalid) dmabuf.sendFormat(entry.format);
        };
    }

    fn dmabufRequest(self: *Compositor, _: ws.zwp_linux_dmabuf_v1, request: ws.zwp_linux_dmabuf_v1.Request) void {
        switch (request) {
            .destroy => {},
            .create_params => |args| {
                const params = create(DmabufParams, self, .{ .comp = self, .resource = args.params_id }) orelse return;
                args.params_id.setHandler(DmabufParams, params, DmabufParams.handle, DmabufParams.destroyed);
            },
            .get_default_feedback => |args| self.sendFeedback(args.id),
            .get_surface_feedback => |args| self.sendFeedback(args.id),
        }
    }

    /// One tranche: every format, rendered by the card that scans out.
    fn sendFeedback(self: *Compositor, feedback: ws.zwp_linux_dmabuf_feedback_v1) void {
        feedback.setHandler(Compositor, self, null, null);
        feedback.sendFormatTable(self.dmabuf_table, @intCast(self.dmabuf_formats.len * @sizeOf(Gl.FormatModifier)));
        feedback.sendMainDevice(&self.dmabuf_device);
        feedback.sendTrancheTargetDevice(&self.dmabuf_device);
        const indices = self.a.alloc(u16, self.dmabuf_formats.len) catch return;
        defer self.a.free(indices);
        for (indices, 0..) |*index, position| index.* = @intCast(position);
        feedback.sendTrancheFormats(std.mem.sliceAsBytes(indices));
        feedback.sendTrancheFlags(0);
        feedback.sendTrancheDone();
        feedback.sendDone();
    }

    /// The themed cursor `shape` near `size` pixels, loaded once per size.
    fn cursorImage(self: *Compositor, shape: u32, size: u32) ?*const Xcursor.Image {
        for (self.cursor_cache.items) |*entry| if (entry.shape == shape and entry.size == size) return if (entry.image) |*image| image else null;
        if (self.cursor_path_len == 0) self.cursor_path_len = Xcursor.searchPath(&self.cursor_path, @import("options").DATA_DIRS).len;
        const theme = if (std.c.getenv("XCURSOR_THEME")) |value| std.mem.span(value) else "Adwaita";
        const path = self.cursor_path[0..self.cursor_path_len];
        var image = Xcursor.load(self.a, path, theme, cursor_names[shape], size);
        // Themes without the CSS name may still have the default cursor.
        if (image == null and shape != 1) image = Xcursor.load(self.a, path, theme, "default", size);
        if (image == null) image = Xcursor.load(self.a, path, theme, "left_ptr", size);
        if (image == null) std.log.warn("compositor: no cursor {s} in theme {s}; showing the built-in arrow", .{ cursor_names[shape], theme });
        self.cursor_cache.append(self.a, .{ .shape = shape, .size = size, .image = image }) catch {
            if (image) |value| value.deinit(self.a);
            return null;
        };
        const entry = &self.cursor_cache.items[self.cursor_cache.items.len - 1];
        return if (entry.image) |*value| value else null;
    }

    fn cursorChanged(self: *Compositor) void {
        if (self.drm) |backend| backend.updateCursor();
    }

    fn cursorMoved(self: *Compositor) void {
        if (self.drm) |backend| backend.moveCursor();
    }

    fn cursorShapeRequest(self: *Compositor, _: ws.wp_cursor_shape_manager_v1, request: ws.wp_cursor_shape_manager_v1.Request) void {
        // Shapes are accepted; cursors are drawn once outputs are real displays.
        switch (request) {
            .destroy => {},
            .get_pointer => |args| args.cursor_shape_device.setHandler(Compositor, self, cursorShapeDevice, null),
            .get_tablet_tool_v2 => |args| args.cursor_shape_device.setHandler(Compositor, self, null, null),
        }
    }

    fn activationRequest(self: *Compositor, _: ws.xdg_activation_v1, request: ws.xdg_activation_v1.Request) void {
        switch (request) {
            .destroy => {},
            .get_activation_token => |args| args.id.setHandler(Compositor, self, activationTokenRequest, null),
            .activate => |args| {
                var known = false;
                for (self.activation_tokens.items, 0..) |token, index| if (std.mem.eql(u8, std.mem.sliceTo(&token, 0), args.token)) {
                    _ = self.activation_tokens.swapRemove(index);
                    known = true;
                    break;
                };
                if (!known) return;
                // An activated window is focused, as with the wlroots compositor.
                const surface = args.surface.data(Surface) orelse return;
                const xdg = surface.xdg orelse return;
                const toplevel = xdg.toplevel orelse return;
                if (toplevel.mapped) {
                    self.focused_layer = null;
                    self.focus(toplevel);
                }
            },
        }
    }

    fn activationTokenRequest(self: *Compositor, resource: ws.xdg_activation_token_v1, request: ws.xdg_activation_token_v1.Request) void {
        switch (request) {
            .commit => {
                self.next_token +%= 1;
                var token: [24]u8 = @splat(0);
                _ = std.fmt.bufPrint(token[0..23], "native-{x}", .{self.next_token}) catch {};
                // Unused tokens expire as newer ones arrive.
                if (self.activation_tokens.items.len >= 64) _ = self.activation_tokens.orderedRemove(0);
                self.activation_tokens.append(self.a, token) catch {};
                resource.sendDone(std.mem.sliceTo(&token, 0));
            },
            .set_serial, .set_app_id, .set_surface, .destroy => {},
        }
    }

    fn textInputRequest(self: *Compositor, _: ws.zwp_text_input_manager_v3, request: ws.zwp_text_input_manager_v3.Request) void {
        switch (request) {
            .destroy => {},
            .get_text_input => |args| {
                const text = create(TextInput, self, .{ .comp = self, .resource = args.id }) orelse return;
                args.id.setHandler(TextInput, text, TextInput.handle, TextInput.destroyed);
                self.ime.texts.append(self.a, text) catch {};
                text.follow(self.seat.keyboard_focus);
            },
        }
    }

    fn inputMethodRequest(self: *Compositor, _: ws.zwp_input_method_manager_v2, request: ws.zwp_input_method_manager_v2.Request) void {
        switch (request) {
            .destroy => {},
            .get_input_method => |args| {
                const method = create(InputMethod, self, .{ .comp = self, .resource = args.input_method }) orelse return;
                args.input_method.setHandler(InputMethod, method, InputMethod.handle, InputMethod.destroyed);
                // One input method per seat; later ones are told it is taken.
                if (self.ime.method != null) return args.input_method.sendUnavailable();
                self.ime.method = method;
                self.ime.sync();
            },
        }
    }

    fn bindPresentation(data: ?*anyopaque, resource: wire.Resource) void {
        const self: *Compositor = @ptrCast(@alignCast(data));
        const presentation: ws.wp_presentation = .{ .resource = resource };
        presentation.setHandler(Compositor, self, presentationRequest, null);
        presentation.sendClockId(1); // CLOCK_MONOTONIC
    }

    fn presentationRequest(self: *Compositor, _: ws.wp_presentation, request: ws.wp_presentation.Request) void {
        switch (request) {
            .destroy => {},
            .feedback => |args| {
                const entry = create(Presentation, self, .{ .comp = self, .resource = args.callback, .surface = args.surface.data(Surface) }) orelse return;
                args.callback.setHandler(Presentation, entry, null, Presentation.destroyed);
                self.presentations.append(self.a, entry) catch {};
            },
        }
    }

    /// Reports frames as presented once an output has drawn them.
    /// Marks feedback for this frame, to be presented when it reaches the screen.
    fn drawnFor(self: *Compositor, output: *Output) void {
        for (self.presentations.items) |entry| {
            const surface = entry.surface orelse continue;
            if (entry.committed and entry.in_frame == null and surface.entered == output) entry.in_frame = output;
        }
    }

    /// A display shows the frame drawn for `output`: feedback gets the vblank's
    /// time and sequence, from the hardware.
    fn flipPresented(self: *Compositor, output: *Output, display: *Drm.kms.Display) void {
        self.frame_sequence +%= 1;
        const seconds: u64 = display.flip_time[0];
        const nanoseconds: u32 = display.flip_time[1] * 1000;
        const refresh_mhz = display.mode.refreshMilli();
        const refresh: u32 = if (refresh_mhz > 0) @intCast(@min(1_000_000_000_000 / @as(u64, refresh_mhz), std.math.maxInt(u32))) else 0;
        const Kind = ws.wp_presentation_feedback.Kind;
        const flags = Kind.vsync | Kind.hw_clock | Kind.hw_completion;
        var index = self.presentations.items.len;
        while (index > 0) {
            index -= 1;
            const entry = self.presentations.items[index];
            if (entry.in_frame != output) continue;
            _ = self.presentations.swapRemove(index);
            for (output.resources.items) |resource| if (resource.client() == entry.resource.client()) entry.resource.sendSyncOutput(resource);
            entry.resource.sendPresented(@truncate(seconds >> 32), @truncate(seconds), nanoseconds, refresh, 0, display.flip_sequence, flags);
        }
    }

    fn presented(self: *Compositor, output: *Output) void {
        self.frame_sequence +%= 1;
        const now = util.monotonicTime();
        const seconds: u64 = @intCast(@divTrunc(now, std.time.us_per_s));
        const nanoseconds: u32 = @intCast(@mod(now, std.time.us_per_s) * 1000);
        var index = self.presentations.items.len;
        while (index > 0) {
            index -= 1;
            const entry = self.presentations.items[index];
            const surface = entry.surface orelse continue;
            if (!entry.committed) continue;
            if (surface.entered != output) continue;
            _ = self.presentations.swapRemove(index);
            for (output.resources.items) |resource| if (resource.client() == entry.resource.client()) entry.resource.sendSyncOutput(resource);
            entry.resource.sendPresented(@truncate(seconds >> 32), @truncate(seconds), nanoseconds, 16_666_666, @truncate(self.frame_sequence >> 32), @truncate(self.frame_sequence), 0);
        }
    }

    fn viewporterRequest(_: *Compositor, resource: ws.wp_viewporter, request: ws.wp_viewporter.Request) void {
        switch (request) {
            .destroy => {},
            .get_viewport => |args| {
                const surface = args.surface.data(Surface) orelse return;
                if (surface.viewport != null) return resource.postError(ws.wp_viewporter.Error.viewport_exists, "surface already has a viewport", .{});
                surface.viewport = args.id;
                args.id.setHandler(Surface, surface, viewportRequest, viewportGone);
            },
        }
    }

    fn inertViewportRequest(_: *Compositor, resource: ws.wp_viewport, request: ws.wp_viewport.Request) void {
        switch (request) {
            .destroy => {},
            .set_source, .set_destination => resource.postError(ws.wp_viewport.Error.no_surface, "the wl_surface was destroyed", .{}),
        }
    }

    fn viewportRequest(surface: *Surface, resource: ws.wp_viewport, request: ws.wp_viewport.Request) void {
        switch (request) {
            .destroy => {},
            .set_source => |args| {
                if (args.x == -1 and args.y == -1 and args.width == -1 and args.height == -1) {
                    surface.pending_source = null;
                } else if (args.x < 0 or args.y < 0 or args.width <= 0 or args.height <= 0) {
                    resource.postError(ws.wp_viewport.Error.bad_value, "invalid source rectangle", .{});
                } else surface.pending_source = .{ args.x, args.y, args.width, args.height };
            },
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
        surface.viewport = null;
        surface.pending_destination = null;
        surface.pending_source = null;
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

    fn captureSourceRequest(self: *Compositor, _: ws.ext_foreign_toplevel_image_capture_source_manager_v1, request: ws.ext_foreign_toplevel_image_capture_source_manager_v1.Request) void {
        switch (request) {
            .create_source => |args| {
                const handle = args.toplevel_handle.data(ListHandle);
                const toplevel = if (handle) |h| h.toplevel else null;
                const source = create(CaptureSource, self, .{ .comp = self, .toplevel = toplevel }) orelse return;
                if (toplevel) |owner| owner.sources.append(self.a, source) catch {
                    source.toplevel = null;
                };
                args.source.setHandler(CaptureSource, source, null, CaptureSource.destroyed);
            },
            .destroy => {},
        }
    }

    fn imageCopyRequest(self: *Compositor, _: ws.ext_image_copy_capture_manager_v1, request: ws.ext_image_copy_capture_manager_v1.Request) void {
        switch (request) {
            .create_session => |args| {
                const source = args.source.data(CaptureSource);
                const toplevel = if (source) |s| s.toplevel else null;
                const output = if (source) |s| s.output else null;
                const session = create(CaptureSession, self, .{ .comp = self, .resource = args.session, .toplevel = toplevel, .output = output }) orelse return;
                args.session.setHandler(CaptureSession, session, CaptureSession.handle, CaptureSession.destroyed);
                if (output) |o| {
                    if (!o.enabled) return session.stop();
                    self.output_sessions.append(self.a, session) catch return session.stop();
                    return session.constraints();
                }
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

    /// KDE's decoration protocol, for clients that only speak it: windows
    /// draw their own decorations, as with xdg-decoration.
    fn bindKdeDecoration(data: ?*anyopaque, resource: wire.Resource) void {
        const self: *Compositor = @ptrCast(@alignCast(data));
        const manager: ws.org_kde_kwin_server_decoration_manager = .{ .resource = resource };
        manager.setHandler(Compositor, self, kdeDecorationRequest, null);
        manager.sendDefaultMode(1); // Client
    }

    fn kdeDecorationRequest(self: *Compositor, _: ws.org_kde_kwin_server_decoration_manager, request: ws.org_kde_kwin_server_decoration_manager.Request) void {
        switch (request) {
            .create => |args| {
                args.id.setHandler(Compositor, self, kdeDecoration, null);
                args.id.sendMode(1);
            },
        }
    }

    fn kdeDecoration(_: *Compositor, resource: ws.org_kde_kwin_server_decoration, request: ws.org_kde_kwin_server_decoration.Request) void {
        switch (request) {
            .release => {},
            // Every request is answered with client-side decoration.
            .request_mode => resource.sendMode(1),
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
            if (output.display) |display| display.disable();
            if (output.global) |global| global.destroy();
            output.global = null;
            var index = self.output_sessions.items.len;
            while (index > 0) {
                index -= 1;
                const session = self.output_sessions.items[index];
                if (session.output == output) {
                    _ = self.output_sessions.swapRemove(index);
                    session.stop();
                }
            }
            var feedback = self.presentations.items.len;
            while (feedback > 0) {
                feedback -= 1;
                const entry = self.presentations.items[feedback];
                if (entry.in_frame != output) continue;
                _ = self.presentations.swapRemove(feedback);
                entry.resource.sendDiscarded();
            }
            for (self.layers.items) |layer| if (layer.output == output) layer.close();
            for (self.surfaces.items) |surface| if (surface.entered == output) {
                surface.entered = null;
            };
            // Windows move to an output that is still there.
            for (self.toplevels.items) |toplevel| if (toplevel.output == output) {
                toplevel.output = self.primary();
                if (toplevel.output) |other| if (toplevel.xdg) |xdg| if (xdg.surface) |surface| other.enter(surface);
            };
            if (self.drm) |backend| backend.updateCursorHardware();
            self.seat.clampPointer();
            self.updateKeyboardFocus();
            self.arrange();
            return;
        }
        output.global = self.server.createGlobal(&ws.wl_output.interface, 4, output, &Output.bind) catch null;
        if (self.drm) |backend| backend.updateCursorHardware();
        self.seat.clampPointer();
        self.arrange();
        output.scheduleRepaint();
    }

    /// Tells output management clients about the new configuration.
    fn outputChanged(self: *Compositor) void {
        self.output_serial +%= 1;
        for (self.head_managers.items) |manager| manager.describe();
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

    fn dataDeviceManagerRequest(self: *Compositor, _: ws.wl_data_device_manager, request: ws.wl_data_device_manager.Request) void {
        switch (request) {
            .create_data_source => |args| {
                const source = create(DataSource, self, .{ .comp = self, .resource = args.id.resource, .kind = .core }) orelse return;
                args.id.setHandler(DataSource, source, DataSource.coreRequest, DataSource.coreGone);
            },
            .get_data_device => |args| {
                const device = self.dataDevice(args.id.resource, .core) orelse return;
                args.id.setHandler(DataDevice, device, DataDevice.coreRequest, DataDevice.coreGone);
                self.offerToNewDevice(device);
            },
            .release => {},
        }
    }

    fn primarySelectionRequest(self: *Compositor, _: ws.zwp_primary_selection_device_manager_v1, request: ws.zwp_primary_selection_device_manager_v1.Request) void {
        switch (request) {
            .create_source => |args| {
                const source = create(DataSource, self, .{ .comp = self, .resource = args.id.resource, .kind = .primary }) orelse return;
                args.id.setHandler(DataSource, source, DataSource.primaryRequest, DataSource.primaryGone);
            },
            .get_device => |args| {
                const device = self.dataDevice(args.id.resource, .primary) orelse return;
                args.id.setHandler(DataDevice, device, DataDevice.primaryRequest, DataDevice.primaryGone);
                self.offerToNewDevice(device);
            },
            .destroy => {},
        }
    }

    fn dataControlManagerRequest(self: *Compositor, _: ws.zwlr_data_control_manager_v1, request: ws.zwlr_data_control_manager_v1.Request) void {
        switch (request) {
            .create_data_source => |args| {
                const source = create(DataSource, self, .{ .comp = self, .resource = args.id.resource, .kind = .control }) orelse return;
                args.id.setHandler(DataSource, source, DataSource.controlRequest, DataSource.controlGone);
            },
            .get_data_device => |args| {
                const device = self.dataDevice(args.id.resource, .control) orelse return;
                args.id.setHandler(DataDevice, device, DataDevice.controlRequest, DataDevice.controlGone);
                self.offerToNewDevice(device);
            },
            .destroy => {},
        }
    }

    fn dataDevice(self: *Compositor, resource: wire.Resource, kind: Clip) ?*DataDevice {
        const device = create(DataDevice, self, .{ .comp = self, .resource = resource, .kind = kind }) orelse return null;
        self.data_devices.append(self.a, device) catch {
            self.a.destroy(device);
            return null;
        };
        return device;
    }

    /// Clipboard managers learn the selections at once; others when they have keyboard focus.
    fn offerToNewDevice(self: *Compositor, device: *DataDevice) void {
        const focused = if (self.seat.keyboard_focus) |surface| surface.resource.client() == device.resource.client else false;
        if (device.kind != .control and !focused) return;
        if (device.carries(false)) device.offer(self.selection, false);
        if (device.carries(true)) device.offer(self.primary_selection, true);
    }

    /// Replaces a selection and tells data-control clients and the focused client.
    fn setSelection(self: *Compositor, source: ?*DataSource, is_primary: bool) void {
        if (is_primary) self.primary_selection = source else self.selection = source;
        const focus_client = if (self.seat.keyboard_focus) |surface| surface.resource.client() else null;
        for (self.data_devices.items) |device| {
            if (!device.carries(is_primary)) continue;
            if (device.kind == .control or device.resource.client == focus_client) device.offer(source, is_primary);
        }
    }
};

// ------------------------------------------------------------------ Explicit sync

const Syncobj = @import("desktop-syncobj.zig");

/// A client's DRM timeline (wp_linux_drm_syncobj_timeline_v1), kept while
/// points on it are pending even if the client destroys the object.
const SyncTimeline = struct {
    comp: *Compositor,
    timeline: Syncobj.Timeline,
    refs: u32 = 1,

    fn ref(self: *SyncTimeline) *SyncTimeline {
        self.refs += 1;
        return self;
    }

    fn unref(self: *SyncTimeline) void {
        self.refs -= 1;
        if (self.refs > 0) return;
        self.timeline.destroy();
        self.comp.a.destroy(self);
    }

    fn handle(_: *SyncTimeline, _: ws.wp_linux_drm_syncobj_timeline_v1, _: ws.wp_linux_drm_syncobj_timeline_v1.Request) void {}

    fn destroyed(self: *SyncTimeline, _: ws.wp_linux_drm_syncobj_timeline_v1) void {
        self.unref();
    }
};

const SyncPoint = struct { timeline: *SyncTimeline, value: u64 };

/// wp_linux_drm_syncobj_surface_v1: the points set for the next commit.
const SyncSurface = struct {
    comp: *Compositor,
    resource: ws.wp_linux_drm_syncobj_surface_v1,
    surface: ?*Surface,
    acquire: ?SyncPoint = null,
    release: ?SyncPoint = null,

    fn handle(self: *SyncSurface, resource: ws.wp_linux_drm_syncobj_surface_v1, request: ws.wp_linux_drm_syncobj_surface_v1.Request) void {
        switch (request) {
            .destroy => {},
            .set_acquire_point => |args| self.set(resource, &self.acquire, args.timeline, args.point_hi, args.point_lo),
            .set_release_point => |args| self.set(resource, &self.release, args.timeline, args.point_hi, args.point_lo),
        }
    }

    fn set(self: *SyncSurface, resource: ws.wp_linux_drm_syncobj_surface_v1, slot: *?SyncPoint, timeline: ws.wp_linux_drm_syncobj_timeline_v1, hi: u32, lo: u32) void {
        if (self.surface == null) return resource.postError(ws.wp_linux_drm_syncobj_surface_v1.Error.no_surface, "the surface is gone", .{});
        const target = timeline.data(SyncTimeline) orelse return;
        if (slot.*) |old| old.timeline.unref();
        slot.* = .{ .timeline = target.ref(), .value = (@as(u64, hi) << 32) | lo };
    }

    fn destroyed(self: *SyncSurface, _: ws.wp_linux_drm_syncobj_surface_v1) void {
        if (self.acquire) |point| point.timeline.unref();
        if (self.release) |point| point.timeline.unref();
        if (self.surface) |surface| surface.sync = null;
        self.comp.a.destroy(self);
    }
};

// ------------------------------------------------------------------ GPU buffers

/// zwp_linux_buffer_params_v1: the planes of a client's GPU buffer.
const DmabufParams = struct {
    comp: *Compositor,
    resource: ws.zwp_linux_buffer_params_v1,
    planes: [4]?Gl.Plane = .{ null, null, null, null },
    used: bool = false,

    const Error = ws.zwp_linux_buffer_params_v1.Error;

    fn handle(self: *DmabufParams, resource: ws.zwp_linux_buffer_params_v1, request: ws.zwp_linux_buffer_params_v1.Request) void {
        switch (request) {
            .destroy, .set_sampling_device => {},
            .add => |args| {
                if (self.used) {
                    _ = std.c.close(args.fd);
                    return resource.postError(Error.already_used, "params already used", .{});
                }
                if (args.plane_idx >= self.planes.len) {
                    _ = std.c.close(args.fd);
                    return resource.postError(Error.plane_idx, "plane index out of range", .{});
                }
                if (self.planes[args.plane_idx] != null) {
                    _ = std.c.close(args.fd);
                    return resource.postError(Error.plane_set, "plane already set", .{});
                }
                self.planes[args.plane_idx] = .{ .fd = args.fd, .offset = args.offset, .stride = args.stride, .modifier = (@as(u64, args.modifier_hi) << 32) | args.modifier_lo };
            },
            .create => |args| {
                const image = self.import(resource, args.width, args.height, args.format) orelse return resource.sendFailed();
                const buffer_resource = resource.sendCreated();
                if (!buffer_resource.alive()) {
                    if (self.comp.drm) |backend| if (backend.renderer) |renderer| renderer.destroyImage(image);
                    return;
                }
                self.wrap(buffer_resource, image, args.width, args.height, args.format);
            },
            .create_immed => |args| {
                const image = self.import(resource, args.width, args.height, args.format) orelse
                    return resource.postError(Error.invalid_wl_buffer, "buffer could not be imported", .{});
                self.wrap(args.buffer_id, image, args.width, args.height, args.format);
            },
        }
    }

    /// Imports the planes; the descriptors are closed either way.
    fn import(self: *DmabufParams, resource: ws.zwp_linux_buffer_params_v1, width: i32, height: i32, format: u32) Gl.EGLImage {
        defer self.closePlanes();
        if (self.used) {
            resource.postError(Error.already_used, "params already used", .{});
            return null;
        }
        self.used = true;
        var count: usize = 0;
        while (count < self.planes.len and self.planes[count] != null) count += 1;
        for (self.planes[count..]) |plane| if (plane != null) {
            resource.postError(Error.incomplete, "planes are not contiguous", .{});
            return null;
        };
        if (count == 0) {
            resource.postError(Error.incomplete, "no planes", .{});
            return null;
        }
        if (width <= 0 or height <= 0) {
            resource.postError(Error.invalid_dimensions, "invalid size", .{});
            return null;
        }
        const renderer = (self.comp.drm orelse return null).renderer orelse return null;
        var planes: [4]Gl.Plane = undefined;
        for (0..count) |index| planes[index] = self.planes[index].?;
        const image = renderer.importDmabuf(@intCast(width), @intCast(height), format, planes[0..count]);
        if (image == null) std.log.warn("compositor: could not import a {d}x{d} GPU buffer of format {x}", .{ width, height, format });
        return image;
    }

    fn wrap(self: *DmabufParams, resource: ws.wl_buffer, image: Gl.EGLImage, width: i32, height: i32, format: u32) void {
        const comp = self.comp;
        const buffer = create(Buffer, comp, .{ .comp = comp, .resource = resource, .pool = null, .image = image, .offset = 0, .width = @intCast(width), .height = @intCast(height), .stride = 0, .format = format }) orelse {
            if (comp.drm) |backend| if (backend.renderer) |renderer| renderer.destroyImage(image);
            return;
        };
        resource.setHandler(Buffer, buffer, Compositor.bufferRequest, Compositor.bufferGone);
    }

    fn closePlanes(self: *DmabufParams) void {
        for (&self.planes) |*plane| if (plane.*) |value| {
            _ = std.c.close(value.fd);
            plane.* = null;
        };
    }

    fn destroyed(self: *DmabufParams, _: ws.zwp_linux_buffer_params_v1) void {
        self.closePlanes();
        self.comp.a.destroy(self);
    }
};

// ------------------------------------------------------------------ DRM backend

/// Runs on the displays, as wlroots' DRM and libinput backends with a logind
/// session: frames are composited by the GPU and scanned out from GBM buffers.
const Drm = struct {
    const kms = @import("desktop-drm.zig");
    const logind = @import("desktop-logind.zig");
    const li = @import("desktop-libinput.zig");

    comp: *Compositor,
    session: *logind.Session,
    card: *kms.Card,
    card_device: logind.Device,
    udev: *li.Udev,
    monitor: ?*li.UdevMonitor = null,
    input: ?*li.Libinput = null,
    /// Input devices opened through the session, closed with it.
    devices: std.ArrayList(logind.Device) = .empty,
    /// Keyboards, whose LEDs follow Caps Lock and Num Lock.
    keyboards: std.ArrayList(*li.Device) = .empty,
    leds: c_int = 0,
    sources: std.ArrayList(*wire.Loop.Source) = .empty,
    active: bool = true,
    /// GLES on the card, which draws every display.
    renderer: ?*Gl.Renderer = null,
    /// The scale the cursor image was chosen for, and its copy for displays
    /// without a cursor plane.
    cursor_scale: f64 = 1,
    cursor_force_software: bool = false,
    software_cursor: []u32 = &.{},
    /// A display rejecting GPU buffers is reported once.
    fb_warned: bool = false,

    const interface: li.Interface = .{ .open_restricted = openRestricted, .close_restricted = closeRestricted };

    fn create(comp: *Compositor) !*Drm {
        const a = comp.a;
        const self = try a.create(Drm);
        errdefer a.destroy(self);
        self.* = .{ .comp = comp, .session = undefined, .card = undefined, .card_device = undefined, .udev = undefined };
        self.session = logind.Session.open(a, .{ .context = self, .pause = paused, .@"resume" = resumed, .active = activeChanged }) catch |err| {
            std.log.err("compositor: no logind session to take control of: {s}", .{@errorName(err)});
            return err;
        };
        errdefer self.session.close();
        try self.openCard();
        errdefer {
            self.card.deinit();
            self.session.releaseDevice(self.card_device);
        }
        self.card.on_remove = unplugged;
        self.card.remove_context = self;
        // DESKTOP_CURSOR=software draws the cursor into frames, as without a cursor plane.
        if (std.c.getenv("DESKTOP_CURSOR")) |value| if (std.mem.eql(u8, std.mem.span(value), "software")) {
            self.cursor_force_software = true;
            self.card.cursor_hardware = false;
        };
        // Displays are drawn by the GPU only: NVIDIA, or Intel and others through Mesa.
        const renderer = Gl.Renderer.init(comp.a, self.card.fd) catch |err| {
            std.log.err("compositor: no GPU renderer on the display's card ({s})", .{@errorName(err)});
            return err;
        };
        self.renderer = renderer;
        errdefer {
            for (comp.outputs.items) |output| self.detachTarget(output);
            renderer.deinit();
        }
        std.log.info("compositor: rendering with GLES on {s}{s}", .{ renderer.name(), if (renderer.buffer_age) ", redrawing only damage" else "" });
        for (comp.outputs.items) |output| if (!self.attachTarget(output)) return error.NoGpuTarget;
        comp.enableDmabuf(renderer, self.card_device.major, self.card_device.minor) catch |err| {
            std.log.warn("compositor: GPU buffers are not shared ({s}); GL clients copy through memory", .{@errorName(err)});
        };
        if (comp.dmabuf_formats.len > 0) comp.enableExplicitSync(renderer, self.card.fd);
        self.udev = li.udev_new() orelse return error.NoUdev;
        errdefer {
            for (self.sources.items) |source| comp.server.loop.remove(source);
            self.sources.deinit(a);
            if (self.input) |input| _ = li.libinput_unref(input);
            if (self.monitor) |monitor| _ = li.udev_monitor_unref(monitor);
            _ = li.udev_unref(self.udev);
        }
        try self.watch(self.session.getFd(), sessionReadable);
        try self.watch(self.card.fd, cardReadable);
        // Display hotplug arrives as udev "change" events on the card.
        if (li.udev_monitor_new_from_netlink(self.udev, "udev")) |monitor| {
            _ = li.udev_monitor_filter_add_match_subsystem_devtype(monitor, "drm", null);
            _ = li.udev_monitor_enable_receiving(monitor);
            self.monitor = monitor;
            try self.watch(li.udev_monitor_get_fd(monitor), hotplug);
        }
        if (li.libinput_udev_create_context(&interface, self, self.udev)) |input| {
            const seat = std.c.getenv("XDG_SEAT") orelse "seat0";
            if (li.libinput_udev_assign_seat(input, seat) == 0) {
                self.input = input;
                try self.watch(li.libinput_get_fd(input), inputReadable);
            } else _ = li.libinput_unref(input);
        }
        if (self.input == null) std.log.warn("compositor: no input devices (libinput)", .{});
        return self;
    }

    /// Takes the first card with a connected display, or DESKTOP_DRM_DEVICE
    /// (such as /dev/dri/card1) on machines with several GPUs.
    fn openCard(self: *Drm) !void {
        var path_buffer: [32]u8 = undefined;
        const chosen = std.c.getenv("DESKTOP_DRM_DEVICE");
        for (0..16) |index| {
            const path: [*:0]const u8 = if (chosen) |value| value else std.fmt.bufPrintSentinel(&path_buffer, "/dev/dri/card{d}", .{index}, 0) catch unreachable;
            if (chosen != null and index > 0) break;
            if (std.c.access(path, 0) != 0) continue;
            const device = self.session.takeDevice(path) catch continue;
            const card = kms.Card.init(self.comp.a, device.fd) catch {
                self.session.releaseDevice(device);
                continue;
            };
            var added: std.ArrayList(*kms.Display) = .empty;
            defer added.deinit(self.comp.a);
            card.scan(&added) catch {};
            if (added.items.len == 0) {
                card.deinit();
                self.session.releaseDevice(device);
                continue;
            }
            self.card = card;
            self.card_device = device;
            for (added.items) |display| try self.addDisplay(display);
            return;
        }
        std.log.err("compositor: no display connected to any /dev/dri card", .{});
        return error.NoDisplays;
    }

    fn watch(self: *Drm, fd: i32, callback: *const fn (?*anyopaque, u32) void) !void {
        try self.sources.append(self.comp.a, try self.comp.server.loop.add(fd, std.os.linux.EPOLL.IN, self, callback));
    }

    /// Shows a display as an output: a returning one gets its old output back.
    fn addDisplay(self: *Drm, display: *kms.Display) !void {
        const comp = self.comp;
        display.on_flip = flipped;
        for (comp.outputs.items) |output| if (output.display == null and std.mem.eql(u8, output.name(), display.name())) {
            output.display = display;
            display.context = output;
            const upright: [2]u32 = if (output.transform & 1 != 0) .{ display.height(), display.width() } else .{ display.width(), display.height() };
            output.configure(output.scale, upright, null);
            _ = self.attachTarget(output);
            comp.setOutputEnabled(output, true);
            comp.outputChanged();
            return;
        };
        const output = try Output.create(comp, comp.outputs.items.len, display.width(), display.height());
        errdefer output.destroy();
        output.display = display;
        display.context = output;
        _ = self.attachTarget(output);
        output.setName(display.name());
        output.make = "Display";
        output.model = "Display";
        output.refresh = @intCast(display.mode.refreshMilli());
        output.physical = .{ @intCast(display.mm_width), @intCast(display.mm_height) };
        // The laptop panel starts at the scale the wlroots compositor gave it.
        if (std.mem.eql(u8, display.name(), "eDP-1")) output.scale = 1.625;
        // New displays go to the right of the others, as wlroots' auto layout places them.
        var right: i32 = 0;
        for (comp.outputs.items) |other| if (other.enabled) {
            right = @max(right, other.x + other.logicalWidth());
        };
        output.x = right;
        output.usable = output.box();
        try comp.outputs.append(comp.a, output);
        // Outputs created after start-up are announced like hotplugged ones.
        if (comp.started) {
            for (comp.head_managers.items) |manager| manager.announce(output);
            comp.outputChanged();
            comp.arrange();
            output.scheduleRepaint();
        }
    }

    fn unplugged(context: ?*anyopaque, display: *kms.Display) void {
        const self: *Drm = @ptrCast(@alignCast(context));
        for (self.comp.outputs.items) |output| if (output.display == display) {
            self.detachTarget(output);
            output.display = null;
            self.comp.setOutputEnabled(output, false);
            self.comp.outputChanged();
        };
    }

    fn flipped(context: ?*anyopaque, primary: bool) void {
        const output: *Output = @ptrCast(@alignCast(context));
        if (primary) {
            if (output.target) |target| target.flipped();
            if (output.pending_lock_serial) |serial| {
                output.pending_lock_serial = null;
                output.confirmLock(serial);
            }
            if (output.display) |display| if (output.target != null) output.comp.flipPresented(output, display);
        }
        if (output.unpresented) {
            output.unpresented = false;
            output.render();
        }
    }

    /// Switches a display's mode; its buffers follow the new size.
    fn switchMode(self: *Drm, output: *Output, display: *kms.Display, mode: kms.ModeInfo) bool {
        if (std.meta.eql(mode, display.mode)) return true;
        const previous_mode = display.mode;
        const previous_refresh = output.refresh;
        self.detachTarget(output);
        display.setMode(mode);
        output.refresh = @intCast(mode.refreshMilli());
        if (!self.attachTarget(output)) {
            display.setMode(previous_mode);
            output.refresh = previous_refresh;
            _ = self.attachTarget(output);
            return false;
        }
        std.log.info("compositor: {s} now {d}x{d} at {d} mHz", .{ display.name(), mode.hdisplay, mode.vdisplay, mode.refreshMilli() });
        return true;
    }

    /// GPU frames go to a GBM surface the size of the display.
    /// Returns false when the GPU cannot draw for the display; it then shows nothing.
    fn attachTarget(self: *Drm, output: *Output) bool {
        const renderer = self.renderer orelse return false;
        const display = output.display orelse return false;
        if (output.target != null) return true;
        output.target = renderer.createTarget(display.width(), display.height()) catch |err| {
            std.log.err("compositor: {s}: the GPU cannot draw for this display ({s})", .{ display.name(), @errorName(err) });
            return false;
        };
        return true;
    }

    fn detachTarget(self: *Drm, output: *Output) void {
        _ = self;
        if (output.target) |target| target.destroy();
        output.target = null;
        output.pending_lock_serial = null;
    }

    /// Scans out the frame just drawn into `target`.
    fn showGpu(self: *Drm, output: *Output, target: *Gl.Target) void {
        const renderer = self.renderer orelse return;
        const display = output.display orelse return;
        const frame_lock_serial: ?u32 = if (self.comp.locked) self.comp.lock_serial else null;
        const bo = renderer.finish(target) orelse return;
        const fb = self.framebuffer(bo) orelse return target.discard(bo);
        switch (display.show(fb)) {
            .shown => {
                // A mode set shows the frame at once, without a flip event.
                target.pending = bo;
                target.flipped();
                const now = util.monotonicTime();
                display.flip_time = .{ @intCast(@divTrunc(now, std.time.us_per_s)), @intCast(@mod(now, std.time.us_per_s)) };
                self.comp.drawnFor(output);
                self.comp.flipPresented(output, display);
                output.pending_lock_serial = null;
                if (frame_lock_serial) |serial| output.confirmLock(serial);
            },
            .flipping => {
                target.pending = bo;
                output.pending_lock_serial = frame_lock_serial;
            },
            .failed => {
                target.discard(bo);
                output.unpresented = true;
                if (self.card.active) output.scheduleRepaint();
            },
        }
    }

    const Framebuffer = struct { card: *kms.Card, id: u32 };

    /// The framebuffer of a GBM buffer, registered on first use and removed with it.
    fn framebuffer(self: *Drm, bo: *Gl.GbmBo) ?u32 {
        if (Gl.gbm_bo_get_user_data(bo)) |data| return @as(*Framebuffer, @ptrCast(@alignCast(data))).id;
        var planes: [4]kms.Card.FramePlane = undefined;
        const count: usize = @intCast(std.math.clamp(Gl.gbm_bo_get_plane_count(bo), 1, 4));
        for (planes[0..count], 0..) |*plane, index| {
            const number: c_int = @intCast(index);
            plane.* = .{ .handle = @truncate(Gl.gbm_bo_get_handle_for_plane(bo, number)), .stride = Gl.gbm_bo_get_stride_for_plane(bo, number), .offset = Gl.gbm_bo_get_offset(bo, number) };
        }
        const id = self.card.addFramebuffer(Gl.gbm_bo_get_width(bo), Gl.gbm_bo_get_height(bo), Gl.gbm_bo_get_format(bo), planes[0..count], Gl.gbm_bo_get_modifier(bo)) orelse {
            if (self.fb_warned) return null;
            self.fb_warned = true;
            std.log.warn("compositor: the display rejected a {d}x{d} buffer with layout {x}", .{ Gl.gbm_bo_get_width(bo), Gl.gbm_bo_get_height(bo), Gl.gbm_bo_get_modifier(bo) });
            return null;
        };
        const entry = std.heap.c_allocator.create(Framebuffer) catch {
            self.card.removeFramebuffer(id);
            return null;
        };
        entry.* = .{ .card = self.card, .id = id };
        Gl.gbm_bo_set_user_data(bo, entry, releaseFramebuffer);
        return id;
    }

    fn releaseFramebuffer(_: *Gl.GbmBo, data: ?*anyopaque) callconv(.c) void {
        const entry: *Framebuffer = @ptrCast(@alignCast(data orelse return));
        entry.card.removeFramebuffer(entry.id);
        std.heap.c_allocator.destroy(entry);
    }

    // ---------------------------------------------------------- Cursor

    /// Sends the pointer image to the cursor plane: the client's cursor
    /// surface, a built-in arrow, or nothing when the client hid it.
    fn updateCursor(self: *Drm) void {
        const seat = &self.comp.seat;
        switch (seat.cursor_mode) {
            .hidden => self.card.setCursor(null, 0, .{ 0, 0 }),
            .surface => if (seat.cursor) |surface| {
                if (!surface.mapped() or !surface.cpuReady()) {
                    self.card.setCursor(null, 0, .{ 0, 0 });
                } else {
                    const scale = @max(1, surface.scale);
                    self.card.setCursor(surface.pixels, surface.width, .{ seat.cursor_hotspot[0] * scale, seat.cursor_hotspot[1] * scale });
                }
            } else self.card.setCursor(null, 0, .{ 0, 0 }),
            .default => {
                // XCURSOR_SIZE logical pixels at the scale of the output under the pointer.
                const base: f64 = if (std.c.getenv("XCURSOR_SIZE")) |value| std.fmt.parseFloat(f64, std.mem.span(value)) catch 24 else 24;
                const output = self.comp.outputAt(seat.pointer_x, seat.pointer_y) orelse self.comp.primary();
                const scale = if (output) |o| o.scale else 1;
                const size: u32 = @intFromFloat(std.math.clamp(@round(base * scale), 8, 256));
                if (self.comp.cursorImage(seat.cursor_shape, size)) |image| {
                    self.card.setCursor(image.pixels, image.width, image.hotspot);
                } else self.card.setCursor(&default_cursor.data, default_cursor.width_pixels, .{ 0, 0 });
            },
        }
        self.cursor_scale = if (self.comp.outputAt(seat.pointer_x, seat.pointer_y)) |o| o.scale else self.cursor_scale;
        self.keepSoftwareCursor();
        self.moveCursor();
    }

    fn updateCursorHardware(self: *Drm) void {
        var rotated = false;
        for (self.comp.outputs.items) |output| if (output.enabled and output.transform != 0) {
            rotated = true;
            break;
        };
        const want_hardware = !self.cursor_force_software and !rotated;
        if (self.card.cursor_hardware == want_hardware) return;
        if (!want_hardware) self.card.setCursor(null, 0, .{ 0, 0 });
        self.card.cursor_hardware = want_hardware;
        self.updateCursor();
    }

    /// Without a cursor plane, the image is kept to be drawn into frames.
    fn keepSoftwareCursor(self: *Drm) void {
        if (self.card.cursor_hardware) return;
        const a = self.comp.a;
        a.free(self.software_cursor);
        self.software_cursor = &.{};
        if (!self.card.cursor_visible) return;
        const cursor = self.card.cursorBuffer();
        const memory = cursor.memory orelse return;
        const width = self.card.cursor_size[0];
        const height = self.card.cursor_size[1];
        self.software_cursor = a.alloc(u32, @as(usize, width) * height) catch return;
        for (0..height) |row| {
            const line: [*]const u32 = @ptrCast(@alignCast(memory + row * cursor.pitch));
            @memcpy(self.software_cursor[row * width ..][0..width], line[0..width]);
        }
    }

    /// Draws the cursor into a frame where the display has no cursor plane.
    fn drawSoftwareCursor(self: *Drm, output: *Output, canvas: Canvas) void {
        if (self.card.cursor_hardware) return;
        if (self.software_cursor.len == 0) self.keepSoftwareCursor();
        if (self.software_cursor.len == 0) return;
        const seat = &self.comp.seat;
        if (!output.contains(seat.pointer_x, seat.pointer_y)) return;
        const x = (seat.pointer_x - @as(f64, @floatFromInt(output.x))) * output.scale - @as(f64, @floatFromInt(self.card.cursor_hotspot[0]));
        const y = (seat.pointer_y - @as(f64, @floatFromInt(output.y))) * output.scale - @as(f64, @floatFromInt(self.card.cursor_hotspot[1]));
        const width = self.card.cursor_size[0];
        const height = self.card.cursor_size[1];
        canvas.image(self.software_cursor, width, height, .{ .x = @floor(x), .y = @floor(y), .width = @floatFromInt(width), .height = @floatFromInt(height) }, .{ .x = 0, .y = 0, .width = @intCast(output.width), .height = @intCast(output.height) }, 1);
    }

    fn moveCursor(self: *Drm) void {
        const seat = &self.comp.seat;
        // Crossing to an output of another scale needs a cursor of its size.
        if (self.comp.outputAt(seat.pointer_x, seat.pointer_y)) |output| if (output.scale != self.cursor_scale) return self.updateCursor();
        if (!self.card.cursor_hardware) {
            for (self.comp.outputs.items) |output| if (output.display != null) output.scheduleRepaint();
            return;
        }
        for (self.comp.outputs.items) |output| if (output.display) |display| {
            const x = (seat.pointer_x - @as(f64, @floatFromInt(output.x))) * output.scale;
            const y = (seat.pointer_y - @as(f64, @floatFromInt(output.y))) * output.scale;
            // The plane is placed by its top-left corner.
            display.moveCursor(@as(i32, @intFromFloat(@floor(x))) - self.card.cursor_hotspot[0], @as(i32, @intFromFloat(@floor(y))) - self.card.cursor_hotspot[1]);
        };
    }

    // ---------------------------------------------------------- Session

    fn sessionReadable(data: ?*anyopaque, _: u32) void {
        const self: *Drm = @ptrCast(@alignCast(data));
        self.session.dispatch();
    }

    /// Handles signals that arrived during blocking session calls.
    fn idle(self: *Drm) void {
        if (self.session.backlog) self.session.dispatch();
    }

    fn paused(context: ?*anyopaque, major: u32, minor: u32) void {
        const self: *Drm = @ptrCast(@alignCast(context));
        std.log.info("compositor: session paused device {d}:{d}", .{ major, minor });
        if (major == self.card_device.major and minor == self.card_device.minor) {
            self.card.pause();
            // A flip still pending when the session left will not report back.
            for (self.comp.outputs.items) |output| if (output.target) |target| if (target.pending != null) target.flipped();
            // The card pauses when the session is switched away, as wlroots' logind backend took it.
            setActive(self, false);
        }
    }

    fn resumed(context: ?*anyopaque, major: u32, minor: u32, fd: i32) void {
        const self: *Drm = @ptrCast(@alignCast(context));
        std.log.info("compositor: session resumed device {d}:{d}", .{ major, minor });
        // The card keeps its descriptor; logind made it master again.
        _ = std.c.close(fd);
        if (major != self.card_device.major or minor != self.card_device.minor) return;
        self.card.resumeWith(self.card.fd);
        setActive(self, true);
        for (self.comp.outputs.items) |output| if (output.display != null) {
            output.unpresented = true;
            output.scheduleRepaint();
        };
        self.updateCursor();
    }

    fn activeChanged(context: ?*anyopaque, active: bool) void {
        setActive(@ptrCast(@alignCast(context)), active);
    }

    /// Switching VTs: input devices close with the session and reopen on return.
    fn setActive(self: *Drm, active: bool) void {
        if (self.active == active) return;
        self.active = active;
        std.log.info("compositor: session {s}", .{if (active) "active" else "inactive"});
        const seat = &self.comp.seat;
        if (self.input) |input| {
            if (active) _ = li.libinput_resume(input) else li.libinput_suspend(input);
        }
        if (!active) {
            // Keys held while switching away are released.
            seat.held = @splat(0);
            seat.setModifiers(seat.default_keymap, .{ 0, 0, seat.modifiers[2], seat.modifiers[3] });
        }
    }

    // ---------------------------------------------------------- Displays

    fn cardReadable(data: ?*anyopaque, _: u32) void {
        const self: *Drm = @ptrCast(@alignCast(data));
        self.card.dispatch();
    }

    fn hotplug(data: ?*anyopaque, _: u32) void {
        const self: *Drm = @ptrCast(@alignCast(data));
        const monitor = self.monitor orelse return;
        while (li.udev_monitor_receive_device(monitor)) |device| _ = li.udev_device_unref(device);
        var added: std.ArrayList(*kms.Display) = .empty;
        defer added.deinit(self.comp.a);
        self.card.scan(&added) catch return;
        for (added.items) |display| self.addDisplay(display) catch {};
        self.updateCursor();
    }

    // ---------------------------------------------------------- Input

    fn openRestricted(path: [*:0]const u8, flags: c_int, user_data: ?*anyopaque) callconv(.c) c_int {
        _ = flags;
        const self: *Drm = @ptrCast(@alignCast(user_data));
        const device = self.session.takeDevice(path) catch return -@as(c_int, @backingInt(std.os.linux.E.ACCES));
        // libinput expects non-blocking descriptors.
        const current = std.c.fcntl(device.fd, std.c.F.GETFL);
        _ = std.c.fcntl(device.fd, std.c.F.SETFL, current | @as(c_int, @bitCast(std.c.O{ .NONBLOCK = true })));
        self.devices.append(self.comp.a, device) catch {};
        return device.fd;
    }

    fn closeRestricted(fd: c_int, user_data: ?*anyopaque) callconv(.c) void {
        const self: *Drm = @ptrCast(@alignCast(user_data));
        for (self.devices.items, 0..) |device, index| if (device.fd == fd) {
            _ = self.devices.swapRemove(index);
            self.session.releaseDevice(device);
            return;
        };
        _ = std.c.close(fd);
    }

    fn inputReadable(data: ?*anyopaque, _: u32) void {
        const self: *Drm = @ptrCast(@alignCast(data));
        const input = self.input orelse return;
        _ = li.libinput_dispatch(input);
        var moved = false;
        while (li.libinput_get_event(input)) |event| {
            defer li.libinput_event_destroy(event);
            moved = self.handleInput(event) or moved;
        }
        if (moved) self.comp.seat.frame();
    }

    /// Returns whether a pointer frame should follow.
    fn handleInput(self: *Drm, event: *li.Event) bool {
        const seat = &self.comp.seat;
        const kind = li.libinput_event_get_type(event);
        switch (kind) {
            li.EventType.device_removed => {
                const device = li.libinput_event_get_device(event);
                for (self.keyboards.items, 0..) |keyboard, index| if (keyboard == device) {
                    _ = self.keyboards.swapRemove(index);
                    _ = li.libinput_device_unref(device);
                    break;
                };
            },
            li.EventType.device_added => {
                const device = li.libinput_event_get_device(event);
                // Keyboards show the lock state on their LEDs.
                if (li.libinput_device_has_capability(device, li.capability_keyboard) != 0) {
                    self.keyboards.append(self.comp.a, li.libinput_device_ref(device)) catch {
                        _ = li.libinput_device_unref(device);
                    };
                    li.libinput_device_led_update(device, self.leds);
                }
                // Touchpads keep the desktop's settings: no tap to click, natural scrolling.
                if (li.libinput_device_config_tap_get_finger_count(device) > 0) {
                    _ = li.libinput_device_config_tap_set_enabled(device, li.tap_disabled);
                    _ = li.libinput_device_config_scroll_set_natural_scroll_enabled(device, 1);
                }
            },
            li.EventType.keyboard_key => {
                const key = li.libinput_event_get_keyboard_event(event);
                const code = li.libinput_event_keyboard_get_key(key);
                const pressed = li.libinput_event_keyboard_get_key_state(key) == 1;
                if (pressed and self.switchVt(code)) return false;
                seat.key(seat.default_keymap, li.libinput_event_keyboard_get_time(key), code, @intFromBool(pressed), null);
            },
            li.EventType.pointer_motion => {
                const pointer = li.libinput_event_get_pointer_event(event);
                seat.moveBy(li.libinput_event_pointer_get_dx(pointer), li.libinput_event_pointer_get_dy(pointer), li.libinput_event_pointer_get_time(pointer));
                return true;
            },
            li.EventType.pointer_motion_absolute => {
                // Tablets and virtual machines' pointers span the whole layout.
                const pointer = li.libinput_event_get_pointer_event(event);
                const b = self.comp.layoutBox();
                const x = li.libinput_event_pointer_get_absolute_x_transformed(pointer, @intCast(@max(1, b.width)));
                const y = li.libinput_event_pointer_get_absolute_y_transformed(pointer, @intCast(@max(1, b.height)));
                seat.moveToAbsolute(@as(f64, @floatFromInt(b.x)) + x, @as(f64, @floatFromInt(b.y)) + y, li.libinput_event_pointer_get_time(pointer));
                return true;
            },
            li.EventType.pointer_button => {
                const pointer = li.libinput_event_get_pointer_event(event);
                seat.button(li.libinput_event_pointer_get_time(pointer), li.libinput_event_pointer_get_button(pointer), li.libinput_event_pointer_get_button_state(pointer) == 1);
                return true;
            },
            li.EventType.pointer_scroll_wheel, li.EventType.pointer_scroll_finger, li.EventType.pointer_scroll_continuous => {
                const pointer = li.libinput_event_get_pointer_event(event);
                const time = li.libinput_event_pointer_get_time(pointer);
                var scrolled = false;
                const Source = ws.wl_pointer.AxisSource;
                const source = if (kind == li.EventType.pointer_scroll_wheel) Source.wheel else if (kind == li.EventType.pointer_scroll_finger) Source.finger else Source.continuous;
                const inverted = li.libinput_device_config_scroll_get_natural_scroll_enabled(li.libinput_event_get_device(event)) != 0;
                for ([_]c_int{ li.axis_vertical, li.axis_horizontal }) |axis| {
                    if (li.libinput_event_pointer_has_axis(pointer, axis) == 0) continue;
                    const value = li.libinput_event_pointer_get_scroll_value(pointer, axis);
                    const value120: ?i32 = if (kind == li.EventType.pointer_scroll_wheel) @intFromFloat(li.libinput_event_pointer_get_scroll_value_v120(pointer, axis)) else null;
                    // A zero from fingers or a continuous device ends the scroll.
                    seat.scroll(.{ .time = time, .axis = @intCast(axis), .value = value, .value120 = value120, .source = source, .inverted = inverted, .stop = kind != li.EventType.pointer_scroll_wheel and value == 0 });
                    scrolled = true;
                }
                return scrolled;
            },
            else => {},
        }
        return false;
    }

    /// Lights Caps Lock and Num Lock as the locked modifiers say, as wlroots did.
    fn updateLeds(self: *Drm, map: *const xkb.Keymap, locked: u32) void {
        var state: xkb.State = .{ .keymap = map };
        state.update(0, 0, locked, 0);
        var leds: c_int = 0;
        if (state.active("Lock")) leds |= li.led_caps_lock;
        if (state.active("Mod2")) leds |= li.led_num_lock;
        if (leds == self.leds) return;
        self.leds = leds;
        for (self.keyboards.items) |keyboard| li.libinput_device_led_update(keyboard, leds);
    }

    /// Ctrl+Alt+Fn switches virtual terminals.
    fn switchVt(self: *Drm, code: u32) bool {
        const seat = &self.comp.seat;
        const map = seat.default_keymap.map orelse return false;
        var state: xkb.State = .{ .keymap = map };
        state.update(seat.modifiers[0], seat.modifiers[1], seat.modifiers[2], seat.modifiers[3]);
        const sym = state.keysym(code + 8);
        if (sym < keysyms.XF86Switch_VT_1 or sym > keysyms.XF86Switch_VT_12) return false;
        if (code < seat.consumed.len) seat.consumed[code] = true;
        self.session.switchTo(sym - keysyms.XF86Switch_VT_1 + 1);
        return true;
    }

    fn destroy(self: *Drm) void {
        const a = self.comp.a;
        for (self.sources.items) |source| self.comp.server.loop.remove(source);
        self.sources.deinit(a);
        for (self.keyboards.items) |keyboard| _ = li.libinput_device_unref(keyboard);
        self.keyboards.deinit(a);
        if (self.input) |input| _ = li.libinput_unref(input);
        for (self.devices.items) |device| self.session.releaseDevice(device);
        self.devices.deinit(a);
        if (self.monitor) |monitor| _ = li.udev_monitor_unref(monitor);
        _ = li.udev_unref(self.udev);
        for (self.comp.outputs.items) |output| {
            self.detachTarget(output);
            output.display = null;
        }
        if (self.renderer) |renderer| renderer.deinit();
        a.free(self.software_cursor);
        self.card.deinit();
        self.session.releaseDevice(self.card_device);
        self.session.close();
        a.destroy(self);
    }
};

/// Xcursor names of wp_cursor_shape_device_v1 shapes, by enum value.
const cursor_names = [_][]const u8{ "default", "default", "context-menu", "help", "pointer", "progress", "wait", "cell", "crosshair", "text", "vertical-text", "alias", "copy", "move", "no-drop", "not-allowed", "grab", "grabbing", "e-resize", "n-resize", "ne-resize", "nw-resize", "s-resize", "se-resize", "sw-resize", "w-resize", "ew-resize", "ns-resize", "nesw-resize", "nwse-resize", "col-resize", "row-resize", "all-scroll", "zoom-in", "zoom-out", "dnd-ask", "all-resize" };

/// The pointer shown when no cursor theme is installed: a
/// white arrow with a black outline, premultiplied ARGB.
const default_cursor = blk: {
    const rows = [_][]const u8{
        "X           ",
        "XX          ",
        "X.X         ",
        "X..X        ",
        "X...X       ",
        "X....X      ",
        "X.....X     ",
        "X......X    ",
        "X.......X   ",
        "X........X  ",
        "X.........X ",
        "X......XXXXX",
        "X...X..X    ",
        "X..XX..X    ",
        "X.X  X..X   ",
        "XX   X..X   ",
        "X     X..X  ",
        "      X..X  ",
        "       XX   ",
    };
    const width = 12;
    var pixels: [width * rows.len]u32 = undefined;
    for (rows, 0..) |row, y| for (row, 0..) |char, x| {
        pixels[y * width + x] = switch (char) {
            'X' => 0xff000000,
            '.' => 0xffffffff,
            else => 0,
        };
    };
    const image: [pixels.len]u32 = pixels;
    break :blk struct {
        const data = image;
        const width_pixels = width;
    };
};

// ------------------------------------------------------------------ Nested backend

/// Runs the compositor as windows of another Wayland session, as wlroots'
/// wayland backend: one window per output, with that session's keyboard and pointer.
const Nested = struct {
    const client_wire = @import("wayland-wire");
    const wl = @import("wayland-client");

    comp: *Compositor,
    connection: *client_wire.Connection,
    compositor: ?wl.wl_compositor = null,
    shm: ?wl.wl_shm = null,
    wm_base: ?wl.xdg_wm_base = null,
    seat: ?wl.wl_seat = null,
    pointer: ?wl.wl_pointer = null,
    keyboard: ?wl.wl_keyboard = null,
    keymap: ?Keymap = null,
    windows: std.ArrayList(*Window) = .empty,
    /// The window the parent pointer is over.
    hovered: ?*Window = null,
    /// The parent's scroll details within a pointer frame.
    scroll_source: ?u32 = null,
    value120: [2]?i32 = .{ null, null },
    inverted: [2]bool = .{ false, false },
    source: ?*wire.Loop.Source = null,

    const Window = struct {
        nested: *Nested,
        output: *Output,
        surface: wl.wl_surface,
        xdg_surface: wl.xdg_surface,
        toplevel: wl.xdg_toplevel,
        buffers: [2]Frame = .{ .{}, .{} },
        configured: bool = false,

        const Frame = struct {
            buffer: ?wl.wl_buffer = null,
            memory: ?[*]u8 = null,
            length: usize = 0,
            width: u32 = 0,
            height: u32 = 0,
            busy: bool = false,

            fn release(self: *Frame, _: wl.wl_buffer, _: wl.wl_buffer.Event) void {
                self.busy = false;
            }

            fn free(self: *Frame) void {
                if (self.buffer) |buffer| buffer.destroy();
                if (self.memory) |memory| _ = libc.munmap(memory, self.length);
                self.* = .{};
            }
        };

        fn xdgEvent(self: *Window, surface: wl.xdg_surface, event: wl.xdg_surface.Event) void {
            surface.ack_configure(event.configure.serial);
            self.configured = true;
            self.output.scheduleRepaint();
        }

        fn toplevelEvent(self: *Window, _: wl.xdg_toplevel, event: wl.xdg_toplevel.Event) void {
            switch (event) {
                // The window's size is the output's mode.
                .configure => |args| if (args.width > 0 and args.height > 0) {
                    self.output.configure(self.output.scale, .{ @intCast(args.width), @intCast(args.height) }, null);
                    self.nested.comp.outputChanged();
                },
                .close => self.nested.comp.server.quit = true,
                else => {},
            }
        }

        /// Shows a rendered frame in the window.
        fn present(self: *Window) void {
            if (!self.configured) return;
            const output = self.output;
            const frame = for (&self.buffers) |*candidate| {
                if (!candidate.busy) break candidate;
            } else return output.scheduleRepaint();
            if (frame.buffer == null or frame.width != output.width or frame.height != output.height) {
                frame.free();
                self.allocate(frame, output.width, output.height) catch return;
            }
            const pixels: [*]u32 = @ptrCast(@alignCast(frame.memory.?));
            @memcpy(pixels[0..output.pixels.len], output.pixels);
            frame.busy = true;
            self.surface.attach(frame.buffer.?, 0, 0);
            self.surface.damage(0, 0, @intCast(output.width), @intCast(output.height));
            self.surface.commit();
        }

        fn allocate(self: *Window, frame: *Frame, width: u32, height: u32) !void {
            const shm = self.nested.shm orelse return error.NoShm;
            const length = @as(usize, width) * height * 4;
            const fd = libc.memfd_create("desktop-nested", 0x0001);
            if (fd < 0) return error.NoMemory;
            defer _ = std.c.close(fd);
            if (libc.ftruncate(fd, @intCast(length)) != 0) return error.NoMemory;
            const memory = libc.mmap(null, length, libc.PROT_READ | libc.PROT_WRITE, libc.MAP_SHARED, fd, 0) orelse return error.NoMemory;
            if (memory == libc.MAP_FAILED) return error.NoMemory;
            const pool = shm.create_pool(fd, @intCast(length));
            const buffer = pool.create_buffer(0, @intCast(width), @intCast(height), @intCast(width * 4), wl.wl_shm.Format.xrgb8888);
            pool.destroy();
            frame.* = .{ .buffer = buffer, .memory = @ptrCast(memory), .length = length, .width = width, .height = height };
            buffer.listen(Frame, frame, Frame.release);
        }

        fn destroy(self: *Window) void {
            for (&self.buffers) |*frame| frame.free();
            self.toplevel.destroy();
            self.xdg_surface.destroy();
            self.surface.destroy();
        }
    };

    /// Connects to the session in WAYLAND_DISPLAY, before this compositor replaces it for clients.
    fn create(comp: *Compositor) !*Nested {
        const connection = client_wire.Connection.connect(comp.a) catch return error.NoParentDisplay;
        errdefer connection.deinit();
        const self = try comp.a.create(Nested);
        errdefer comp.a.destroy(self);
        self.* = .{ .comp = comp, .connection = connection };
        const registry = (wl.wl_display{ .proxy = connection.display() }).get_registry();
        registry.listen(Nested, self, global);
        try connection.roundtrip();
        if (self.compositor == null or self.shm == null or self.wm_base == null) return error.MissingParentGlobals;
        try connection.roundtrip();
        self.source = try comp.server.loop.add(connection.getFd(), std.os.linux.EPOLL.IN, self, &readable);
        return self;
    }

    fn global(self: *Nested, registry: wl.wl_registry, event: wl.wl_registry.Event) void {
        switch (event) {
            .global => |g| {
                if (std.mem.eql(u8, g.interface, "wl_compositor")) self.compositor = registry.bind(g.name, wl.wl_compositor, 4);
                if (std.mem.eql(u8, g.interface, "wl_shm")) self.shm = registry.bind(g.name, wl.wl_shm, 1);
                if (std.mem.eql(u8, g.interface, "xdg_wm_base")) {
                    const base = registry.bind(g.name, wl.xdg_wm_base, 1);
                    base.listen(Nested, self, ping);
                    self.wm_base = base;
                }
                if (std.mem.eql(u8, g.interface, "wl_seat") and self.seat == null) {
                    const seat = registry.bind(g.name, wl.wl_seat, @min(g.version, 9));
                    seat.listen(Nested, self, seatEvent);
                    self.seat = seat;
                }
            },
            .global_remove => {},
        }
    }

    fn ping(_: *Nested, base: wl.xdg_wm_base, event: wl.xdg_wm_base.Event) void {
        base.pong(event.ping.serial);
    }

    fn seatEvent(self: *Nested, seat: wl.wl_seat, event: wl.wl_seat.Event) void {
        switch (event) {
            .capabilities => |args| {
                if (args.capabilities & wl.wl_seat.Capability.pointer != 0 and self.pointer == null) {
                    const pointer = seat.get_pointer();
                    pointer.listen(Nested, self, pointerEvent);
                    self.pointer = pointer;
                }
                if (args.capabilities & wl.wl_seat.Capability.keyboard != 0 and self.keyboard == null) {
                    const keyboard = seat.get_keyboard();
                    keyboard.listen(Nested, self, keyboardEvent);
                    self.keyboard = keyboard;
                }
            },
            .name => {},
        }
    }

    /// Opens a window for an output.
    fn addOutput(self: *Nested, output: *Output) !void {
        const window = try self.comp.a.create(Window);
        errdefer self.comp.a.destroy(window);
        const surface = self.compositor.?.create_surface();
        const xdg_surface = self.wm_base.?.get_xdg_surface(surface);
        const toplevel = xdg_surface.get_toplevel();
        window.* = .{ .nested = self, .output = output, .surface = surface, .xdg_surface = xdg_surface, .toplevel = toplevel };
        xdg_surface.listen(Window, window, Window.xdgEvent);
        toplevel.listen(Window, window, Window.toplevelEvent);
        var title: [64]u8 = undefined;
        toplevel.set_title(std.fmt.bufPrintSentinel(&title, "Desktop compositor — {s}", .{output.name()}, 0) catch "Desktop compositor");
        toplevel.set_app_id("org.dotfiles.Compositor");
        surface.commit();
        try self.windows.append(self.comp.a, window);
        output.nested = window;
    }

    fn windowFor(self: *Nested, surface: wl.wl_surface) ?*Window {
        for (self.windows.items) |window| if (window.surface.proxy.id == surface.proxy.id) return window;
        return null;
    }

    fn pointerEvent(self: *Nested, _: wl.wl_pointer, event: wl.wl_pointer.Event) void {
        const seat = &self.comp.seat;
        switch (event) {
            .enter => |args| {
                self.hovered = self.windowFor(args.surface);
                if (self.hovered) |window| seat.moveTo(@as(f64, @floatFromInt(window.output.x)) + args.surface_x, @as(f64, @floatFromInt(window.output.y)) + args.surface_y, nowMs());
            },
            .leave => self.hovered = null,
            .motion => |args| if (self.hovered) |window| {
                seat.moveTo(@as(f64, @floatFromInt(window.output.x)) + args.surface_x, @as(f64, @floatFromInt(window.output.y)) + args.surface_y, args.time);
            },
            .button => |args| seat.button(args.time, args.button, args.state == 1),
            // The parent session's scrolling passes through with its source and steps.
            .axis => |args| seat.scroll(.{ .time = args.time, .axis = args.axis, .value = args.value, .value120 = self.value120[@min(args.axis, 1)], .source = self.scroll_source, .inverted = self.inverted[@min(args.axis, 1)] }),
            .axis_source => |args| self.scroll_source = args.axis_source,
            .axis_value120 => |args| self.value120[@min(args.axis, 1)] = args.value120,
            .axis_discrete => |args| self.value120[@min(args.axis, 1)] = args.discrete * 120,
            .axis_relative_direction => |args| self.inverted[@min(args.axis, 1)] = args.direction == 1,
            .axis_stop => |args| seat.scroll(.{ .time = args.time, .axis = args.axis, .source = self.scroll_source, .stop = true }),
            .frame => {
                self.scroll_source = null;
                self.value120 = .{ null, null };
                self.inverted = .{ false, false };
                seat.frame();
            },
            else => {},
        }
    }

    fn keyboardEvent(self: *Nested, _: wl.wl_keyboard, event: wl.wl_keyboard.Event) void {
        const seat = &self.comp.seat;
        switch (event) {
            // The parent session's keymap becomes this keyboard's.
            .keymap => |args| {
                if (self.keymap) |old| {
                    if (seat.active_keymap.fd == old.fd) seat.useKeymap(seat.default_keymap);
                    old.deinit();
                }
                self.keymap = clientKeymap(self.comp.a, args.fd, args.size);
            },
            .key => |args| if (self.keymap) |keymap| seat.key(keymap, args.time, args.key, args.state, null),
            .modifiers => |args| if (self.keymap) |keymap| seat.setModifiers(keymap, .{ args.mods_depressed, args.mods_latched, args.mods_locked, args.group }),
            // Keys held when focus leaves the window are released.
            .leave => if (self.keymap) |keymap| {
                seat.held = @splat(0);
                seat.setModifiers(keymap, .{ 0, 0, seat.modifiers[2], seat.modifiers[3] });
            },
            .enter, .repeat_info => {},
        }
    }

    fn readable(data: ?*anyopaque, _: u32) void {
        const self: *Nested = @ptrCast(@alignCast(data));
        self.connection.readAndDispatch() catch {
            // The parent session went away.
            self.comp.server.quit = true;
        };
    }

    /// Sends requests queued while handling clients.
    fn flush(self: *Nested) void {
        self.connection.flush() catch {
            self.comp.server.quit = true;
        };
    }

    fn destroy(self: *Nested) void {
        for (self.windows.items) |window| {
            window.destroy();
            self.comp.a.destroy(window);
        }
        self.windows.deinit(self.comp.a);
        if (self.keymap) |keymap| keymap.deinit();
        if (self.source) |source| self.comp.server.loop.remove(source);
        self.connection.flush() catch {};
        self.connection.deinit();
        self.comp.a.destroy(self);
    }
};

// ------------------------------------------------------------------ Thread

pub const Mode = enum { session, headless, greeter };

/// Where outputs are shown: memory only, windows of another session, or displays.
pub const Backend = enum { headless, wayland, drm };

/// Chooses the backend as wlroots does: WLR_BACKENDS, else nested when a
/// session is running, else the displays.
fn selectBackend() Backend {
    if (std.c.getenv("WLR_BACKENDS")) |value| {
        const text = std.mem.span(value);
        if (std.mem.indexOf(u8, text, "headless") != null) return .headless;
        if (std.mem.indexOf(u8, text, "wayland") != null) return .wayland;
        return .drm;
    }
    return if (std.c.getenv("WAYLAND_DISPLAY") != null or std.c.getenv("WAYLAND_SOCKET") != null) .wayland else .drm;
}

pub const Handle = struct {
    allocator: std.mem.Allocator,
    mode: Mode = .headless,
    stopping: std.atomic.Value(bool) = .init(false),
    /// Overrides the environment's backend choice; tests run headless.
    backend: ?Backend = null,
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
    pub fn start(allocator: std.mem.Allocator, mode: Mode) !*Handle {
        return startWith(allocator, mode, null);
    }

    /// Starts with a fixed backend instead of the environment's choice.
    pub fn startWith(allocator: std.mem.Allocator, mode: Mode, backend: ?Backend) !*Handle {
        const self = try allocator.create(Handle);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .mode = mode, .backend = backend };
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
        self.stopping.store(true, .release);
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
        var comp: Compositor = .{ .a = a, .server = server, .show_ui = self.mode == .session, .greeter = self.mode == .greeter };
        comp.seat = .{ .comp = &comp };
        comp.ime = .{ .comp = &comp };
        defer comp.deinit();
        const backend = self.backend orelse selectBackend();
        comp.init(backend, self.width, self.height, if (backend == .headless) headlessOutputs() else 1) catch |err| {
            std.log.err("compositor: {s} backend: {s}", .{ @tagName(backend), @errorName(err) });
            self.failed = true;
            self.signal();
            return;
        };
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
            // Headless tests read frames back; displays and nested windows do not need a copy of each.
            if (output.frames != before and comp.drm == null and comp.nested == null) self.publish(output);
            if (comp.nested) |nested| nested.flush();
            if (comp.drm) |display_backend| display_backend.idle();
        }
        // A shortcut or failure that ends the compositor also ends the UI and the session.
        if (self.mode == .session and !self.stopping.load(.acquire)) _ = std.c.kill(libc.getpid(), std.c.SIG.TERM);
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

const TestEnv = struct {
    handle: *Handle = undefined,
    runtime_buf: [64]u8 = undefined,
    runtime_len: usize = 0,
    previous_runtime: ?[*:0]const u8 = null,

    fn start(self: *TestEnv, a: std.mem.Allocator, tag: []const u8) !void {
        const dir = try std.fmt.bufPrintSentinel(&self.runtime_buf, "/tmp/desktop-native-{s}-{d}", .{ tag, libc.getpid() }, 0);
        self.runtime_len = dir.len;
        _ = libc.mkdir(dir, 0o700);
        self.previous_runtime = std.c.getenv("XDG_RUNTIME_DIR");
        _ = libc.setenv("XDG_RUNTIME_DIR", dir, 1);
        self.handle = try Handle.startWith(a, .headless, .headless);
    }

    fn stop(self: *TestEnv) void {
        self.handle.stop();
        if (self.previous_runtime) |value| _ = libc.setenv("XDG_RUNTIME_DIR", value, 1);
        _ = libc.rmdir(self.runtime_buf[0..self.runtime_len :0]);
    }
};

const TestClient = struct {
    const client_wire = @import("wayland-wire");
    const wl = @import("wayland-client");

    conn: *client_wire.Connection = undefined,
    compositor: ?wl.wl_compositor = null,
    shm: ?wl.wl_shm = null,
    wm_base: ?wl.xdg_wm_base = null,
    seat: ?wl.wl_seat = null,
    output: ?wl.wl_output = null,
    layers: ?wl.zwlr_layer_shell_v1 = null,
    data: ?wl.wl_data_device_manager = null,
    pointers: ?wl.zwlr_virtual_pointer_manager_v1 = null,
    keyboards: ?wl.zwp_virtual_keyboard_manager_v1 = null,
    texts: ?wl.zwp_text_input_manager_v3 = null,
    methods: ?wl.zwp_input_method_manager_v2 = null,
    list: ?wl.ext_foreign_toplevel_list_v1 = null,
    sources: ?wl.ext_foreign_toplevel_image_capture_source_manager_v1 = null,
    copy: ?wl.ext_image_copy_capture_manager_v1 = null,
    output_manager: ?wl.zwlr_output_manager_v1 = null,
    viewporter: ?wl.wp_viewporter = null,
    fractional: ?wl.wp_fractional_scale_manager_v1 = null,
    presentation: ?wl.wp_presentation = null,

    fn connect(self: *TestClient, a: std.mem.Allocator) !void {
        self.* = .{ .conn = try client_wire.Connection.connect(a) };
        errdefer self.conn.deinit();
        const registry = (wl.wl_display{ .proxy = self.conn.display() }).get_registry();
        registry.listen(TestClient, self, global);
        try self.conn.roundtrip();
    }

    fn deinit(self: *TestClient) void {
        self.conn.deinit();
    }

    fn global(self: *TestClient, registry: wl.wl_registry, event: wl.wl_registry.Event) void {
        switch (event) {
            .global => |g| {
                const binds = .{
                    .{ "wl_compositor", "compositor", wl.wl_compositor, 6 },
                    .{ "wl_shm", "shm", wl.wl_shm, 1 },
                    .{ "xdg_wm_base", "wm_base", wl.xdg_wm_base, 6 },
                    .{ "wl_seat", "seat", wl.wl_seat, 9 },
                    .{ "wl_output", "output", wl.wl_output, 4 },
                    .{ "zwlr_layer_shell_v1", "layers", wl.zwlr_layer_shell_v1, 4 },
                    .{ "wl_data_device_manager", "data", wl.wl_data_device_manager, 3 },
                    .{ "zwlr_virtual_pointer_manager_v1", "pointers", wl.zwlr_virtual_pointer_manager_v1, 2 },
                    .{ "zwp_virtual_keyboard_manager_v1", "keyboards", wl.zwp_virtual_keyboard_manager_v1, 1 },
                    .{ "zwp_text_input_manager_v3", "texts", wl.zwp_text_input_manager_v3, 1 },
                    .{ "zwp_input_method_manager_v2", "methods", wl.zwp_input_method_manager_v2, 1 },
                    .{ "ext_foreign_toplevel_list_v1", "list", wl.ext_foreign_toplevel_list_v1, 1 },
                    .{ "ext_foreign_toplevel_image_capture_source_manager_v1", "sources", wl.ext_foreign_toplevel_image_capture_source_manager_v1, 1 },
                    .{ "ext_image_copy_capture_manager_v1", "copy", wl.ext_image_copy_capture_manager_v1, 1 },
                    .{ "zwlr_output_manager_v1", "output_manager", wl.zwlr_output_manager_v1, 4 },
                    .{ "wp_viewporter", "viewporter", wl.wp_viewporter, 1 },
                    .{ "wp_fractional_scale_manager_v1", "fractional", wl.wp_fractional_scale_manager_v1, 1 },
                    .{ "wp_presentation", "presentation", wl.wp_presentation, 1 },
                };
                inline for (binds) |entry| {
                    if (std.mem.eql(u8, g.interface, entry[0])) @field(self, entry[1]) = registry.bind(g.name, entry[2], entry[3]);
                }
            },
            .global_remove => {},
        }
    }

    fn shmBuffer(self: *TestClient, width: usize, height: usize, color: ?u32) !wl.wl_buffer {
        const size = width * height * 4;
        const fd = libc.memfd_create("buffer", 0x0001);
        defer _ = std.c.close(fd);
        if (libc.ftruncate(fd, @intCast(size)) != 0) return error.NoMemory;
        if (color) |fill| {
            const memory = libc.mmap(null, size, libc.PROT_READ | libc.PROT_WRITE, libc.MAP_SHARED, fd, 0).?;
            defer _ = libc.munmap(memory, size);
            @memset(@as([*]u32, @ptrCast(@alignCast(memory)))[0 .. width * height], fill);
        }
        const pool = self.shm.?.create_pool(fd, @intCast(size));
        defer pool.destroy();
        return pool.create_buffer(0, @intCast(width), @intCast(height), @intCast(width * 4), 0);
    }
};

test "native compositor maps an xdg toplevel from shared memory and composites it" {
    const wl = @import("wayland-client");
    const a = std.testing.allocator;
    var env: TestEnv = .{};
    try env.start(a, "test");
    defer env.stop();
    var client: TestClient = undefined;
    try client.connect(a);
    defer client.deinit();
    try std.testing.expect(client.compositor != null and client.shm != null and client.wm_base != null and client.seat != null and client.output != null);

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
    const keyboard = client.seat.?.get_keyboard();
    keyboard.listen(Window, &window, Window.keyboard);
    const surface = client.compositor.?.create_surface();
    const xdg_surface = client.wm_base.?.get_xdg_surface(surface);
    xdg_surface.listen(Window, &window, Window.xdgSurface);
    const toplevel = xdg_surface.get_toplevel();
    toplevel.listen(Window, &window, Window.toplevel);
    toplevel.set_title("native test");
    surface.commit();
    try client.conn.roundtrip();
    try std.testing.expectEqual(@as(u32, 1), window.configured);
    try std.testing.expect(window.keymap_size > 1000);

    // A 100x50 opaque red buffer.
    const buffer = try client.shmBuffer(100, 50, 0xffff0000);
    buffer.listen(Window, &window, Window.buffer);
    surface.attach(buffer, 0, 0);
    surface.damage_buffer(0, 0, 100, 50);
    const callback = surface.frame();
    callback.listen(Window, &window, Window.frame);
    surface.commit();
    var deadline = util.monotonicTime() + 3_000_000;
    while (!window.frame_done and util.monotonicTime() < deadline) _ = try client.conn.dispatchTimeout(100);
    try std.testing.expect(window.frame_done);
    try std.testing.expect(window.released);
    try std.testing.expect(window.activated);
    try std.testing.expect(window.entered);
    // Windows open maximized; this one draws less than it was offered, from the corner.
    deadline = util.monotonicTime() + 3_000_000;
    while (env.handle.pixel(50, 25).value != 0xffff0000 and util.monotonicTime() < deadline) {
        std.testing.io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expectEqual(@as(u32, 0xffff0000), env.handle.pixel(50, 25).value);
    try std.testing.expectEqual(@as(u32, 0xff303030), env.handle.pixel(640, 360).value);
    buffer.destroy();
    toplevel.destroy();
    xdg_surface.destroy();
    surface.destroy();
    try client.conn.roundtrip();
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
    const ISO_Next_Group: u32 = 0xfe08;
    const ISO_Prev_Group: u32 = 0xfe0a;
    const ISO_First_Group: u32 = 0xfe0c;
    const ISO_Last_Group: u32 = 0xfe0e;
    const Num_Lock: u32 = 0xff7f;
    const Print: u32 = 0xff61;
    const a: u32 = 0x61;
    const d: u32 = 0x64;
    const e: u32 = 0x65;
    const E: u32 = 0x45;
    const l: u32 = 0x6c;
    const XF86Switch_VT_1: u32 = 0x1008fe01;
    const XF86Switch_VT_12: u32 = 0x1008fe0c;
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

test "native compositor relays text input to an input method and its keyboard grab" {
    const client_wire = @import("wayland-wire");
    const wl = @import("wayland-client");
    const a = std.testing.allocator;
    var env: TestEnv = .{};
    try env.start(a, "ime");
    defer env.stop();

    // The application: a focused window with an enabled text input.
    var app: TestClient = undefined;
    try app.connect(a);
    defer app.deinit();
    // The input method, on its own connection.
    var ime: TestClient = undefined;
    try ime.connect(a);
    defer ime.deinit();
    try std.testing.expect(app.texts != null and ime.methods != null);

    const App = struct {
        entered: bool = false,
        committed: [64]u8 = @splat(0),
        committed_len: usize = 0,
        done: u32 = 0,
        keys: u32 = 0,
        fn xdgSurface(_: *@This(), surface: wl.xdg_surface, event: wl.xdg_surface.Event) void {
            surface.ack_configure(event.configure.serial);
        }
        fn text(self: *@This(), _: wl.zwp_text_input_v3, event: wl.zwp_text_input_v3.Event) void {
            switch (event) {
                .enter => self.entered = true,
                .commit_string => |args| if (args.text) |value| {
                    @memcpy(self.committed[0..value.len], value);
                    self.committed_len = value.len;
                },
                .done => self.done += 1,
                else => {},
            }
        }
        fn keyboard(self: *@This(), _: wl.wl_keyboard, event: wl.wl_keyboard.Event) void {
            switch (event) {
                .keymap => |args| _ = std.c.close(args.fd),
                .key => self.keys += 1,
                else => {},
            }
        }
    };
    const Method = struct {
        active: bool = false,
        purpose: u32 = 0,
        dones: u32 = 0,
        grabbed_keys: u32 = 0,
        fn method(self: *@This(), _: wl.zwp_input_method_v2, event: wl.zwp_input_method_v2.Event) void {
            switch (event) {
                .activate => self.active = true,
                .deactivate => self.active = false,
                .content_type => |args| self.purpose = args.purpose,
                .done => self.dones += 1,
                else => {},
            }
        }
        fn grab(self: *@This(), _: wl.zwp_input_method_keyboard_grab_v2, event: wl.zwp_input_method_keyboard_grab_v2.Event) void {
            switch (event) {
                .keymap => |args| _ = std.c.close(args.fd),
                .key => self.grabbed_keys += 1,
                else => {},
            }
        }
    };
    var app_state: App = .{};
    var method_state: Method = .{};
    const pump = struct {
        fn until(connections: []const *client_wire.Connection, flag: *const bool) !void {
            const deadline = util.monotonicTime() + 3_000_000;
            while (!flag.* and util.monotonicTime() < deadline) {
                for (connections) |connection| _ = try connection.dispatchTimeout(20);
            }
        }
    };

    const keyboard = app.seat.?.get_keyboard();
    keyboard.listen(App, &app_state, App.keyboard);
    const text = app.texts.?.get_text_input(app.seat.?);
    text.listen(App, &app_state, App.text);
    const method = ime.methods.?.get_input_method(ime.seat.?);
    method.listen(Method, &method_state, Method.method);
    try ime.conn.roundtrip();

    // Map a window so it gets keyboard focus, then enable text input on it.
    const surface = app.compositor.?.create_surface();
    const xdg_surface = app.wm_base.?.get_xdg_surface(surface);
    xdg_surface.listen(App, &app_state, App.xdgSurface);
    const toplevel = xdg_surface.get_toplevel();
    surface.commit();
    try app.conn.roundtrip();
    const buffer = try app.shmBuffer(1, 1, null);
    surface.attach(buffer, 0, 0);
    surface.commit();
    try pump.until(&.{app.conn}, &app_state.entered);
    try std.testing.expect(app_state.entered);
    text.enable();
    text.set_content_type(0, 8); // ZWP_TEXT_INPUT_V3_CONTENT_PURPOSE_EMAIL
    text.commit();
    try app.conn.roundtrip();
    try pump.until(&.{ime.conn}, &method_state.active);
    try std.testing.expect(method_state.active);
    try std.testing.expectEqual(@as(u32, 8), method_state.purpose);

    // A commit answering the latest done reaches the application.
    method.commit_string("日本");
    method.commit(method_state.dones);
    try ime.conn.roundtrip();
    var done = false;
    const deadline = util.monotonicTime() + 3_000_000;
    while (!done and util.monotonicTime() < deadline) {
        _ = try app.conn.dispatchTimeout(20);
        done = app_state.committed_len > 0;
    }
    try std.testing.expectEqualStrings("日本", app_state.committed[0..app_state.committed_len]);

    // With a keyboard grab, keys from another client's virtual keyboard go to the input method.
    const grab = method.grab_keyboard();
    grab.listen(Method, &method_state, Method.grab);
    try ime.conn.roundtrip();
    const virtual = app.keyboards.?.create_virtual_keyboard(app.seat.?);
    const keymap = keymapFile(keymap_text).?;
    defer keymap.deinit();
    virtual.keymap(1, keymap.fd, keymap.size);
    virtual.key(0, 30, 1);
    virtual.key(0, 30, 0);
    try app.conn.roundtrip();
    var grabbed = false;
    const grab_deadline = util.monotonicTime() + 3_000_000;
    while (!grabbed and util.monotonicTime() < grab_deadline) {
        _ = try ime.conn.dispatchTimeout(20);
        grabbed = method_state.grabbed_keys == 2;
    }
    try std.testing.expectEqual(@as(u32, 2), method_state.grabbed_keys);
    try app.conn.roundtrip();
    try std.testing.expectEqual(@as(u32, 0), app_state.keys);

    virtual.destroy();
    grab.release();
    method.destroy();
    text.destroy();
    buffer.destroy();
    toplevel.destroy();
    xdg_surface.destroy();
    surface.destroy();
    keyboard.release();
    try app.conn.roundtrip();
    try ime.conn.roundtrip();
}

test "popups flip, slide and shrink into the output as their positioner allows" {
    const A = ws.xdg_positioner.Anchor;
    const G = ws.xdg_positioner.Gravity;
    const CA = ws.xdg_positioner.ConstraintAdjustment;
    const bounds: Rect = .{ .x = 0, .y = 0, .width = 1000, .height = 600 };
    // A submenu to the right of an item near the right edge opens to its left.
    var menu: Positioner = .{ .width = 200, .height = 100, .anchor_rect = .{ .x = 850, .y = 100, .width = 100, .height = 20 }, .anchor = A.top_right, .gravity = G.bottom_right, .adjustment = CA.flip_x | CA.slide_y };
    const flipped = menu.constrain(menu.place(), bounds);
    try std.testing.expectEqual(@as(i32, 650), flipped.x);
    try std.testing.expectEqual(@as(i32, 100), flipped.y);
    // Without room either way, sliding keeps it on screen.
    menu.adjustment = CA.slide_x;
    try std.testing.expectEqual(@as(i32, 800), menu.constrain(menu.place(), bounds).x);
    // A list taller than the output shrinks to fit below its anchor.
    var list: Positioner = .{ .width = 300, .height = 900, .anchor_rect = .{ .x = 100, .y = 50, .width = 100, .height = 20 }, .anchor = A.bottom_left, .gravity = G.bottom_right, .adjustment = CA.resize_y };
    const shrunk = list.constrain(list.place(), bounds);
    try std.testing.expectEqual(@as(i32, 70), shrunk.y);
    try std.testing.expectEqual(@as(i32, 530), shrunk.height);
    list.adjustment = 0;
    try std.testing.expectEqual(@as(i32, 900), list.constrain(list.place(), bounds).height);
}

test "viewport crops and buffer transforms map to texture coordinates" {
    var surface: Surface = .{ .comp = undefined, .resource = undefined, .width = 200, .height = 100 };
    // A crop of the right half, in a buffer of scale 1.
    surface.source = .{ 100, 0, 100, 100 };
    var map = surface.uvMap();
    try std.testing.expectEqual([2]f32{ 0.5, 0 }, map.origin);
    try std.testing.expectEqual([2]f32{ 0.5, 0 }, map.x);
    try std.testing.expectEqual([2]f32{ 0, 1 }, map.y);
    try std.testing.expectEqual(@as(i32, 100), surface.logicalWidth());
    // A buffer turned a quarter counter-clockwise: the shown top-left is the
    // buffer's bottom-left, and the sides swap.
    surface.source = null;
    surface.transform = 1;
    map = surface.uvMap();
    try std.testing.expectEqual([2]f32{ 0, 1 }, map.origin);
    try std.testing.expectEqual([2]f32{ 0, -1 }, map.x);
    try std.testing.expectEqual([2]f32{ 1, 0 }, map.y);
    try std.testing.expectEqual(@as(i32, 100), surface.logicalWidth());
    try std.testing.expectEqual(@as(i32, 200), surface.logicalHeight());
    // Flipped: mirrored left to right.
    surface.transform = 4;
    map = surface.uvMap();
    try std.testing.expectEqual([2]f32{ 1, 0 }, map.origin);
    try std.testing.expectEqual([2]f32{ -1, 0 }, map.x);
}

test "native compositor carries a drag from press to drop with negotiated actions" {
    const client_wire = @import("wayland-wire");
    const wl = @import("wayland-client");
    const a = std.testing.allocator;
    var env: TestEnv = .{};
    try env.start(a, "dnd");
    defer env.stop();
    var client: TestClient = undefined;
    try client.connect(a);
    defer client.deinit();
    try std.testing.expect(client.data != null and client.pointers != null);

    const Dnd = struct {
        press_serial: u32 = 0,
        pointer_entered: bool = false,
        offer: ?wl.wl_data_offer = null,
        offered_text: bool = false,
        source_actions: u32 = 0,
        enters: u32 = 0,
        enter_serial: u32 = 0,
        offer_action: u32 = 0,
        source_action: u32 = 0,
        target_text: bool = false,
        dropped: bool = false,
        drop_performed: bool = false,
        finished: bool = false,
        cancelled: bool = false,
        fn xdgSurface(_: *@This(), surface: wl.xdg_surface, event: wl.xdg_surface.Event) void {
            surface.ack_configure(event.configure.serial);
        }
        fn pointer(self: *@This(), _: wl.wl_pointer, event: wl.wl_pointer.Event) void {
            switch (event) {
                .enter => self.pointer_entered = true,
                .button => |args| if (args.state == 1) {
                    self.press_serial = args.serial;
                },
                else => {},
            }
        }
        fn device(self: *@This(), _: wl.wl_data_device, event: wl.wl_data_device.Event) void {
            switch (event) {
                .data_offer => |args| {
                    self.offer = args.id;
                    args.id.listen(@This(), self, offerEvent);
                },
                .enter => |args| {
                    self.enters += 1;
                    self.enter_serial = args.serial;
                },
                .drop => self.dropped = true,
                else => {},
            }
        }
        fn offerEvent(self: *@This(), _: wl.wl_data_offer, event: wl.wl_data_offer.Event) void {
            switch (event) {
                .offer => |args| if (std.mem.eql(u8, args.mime_type, "text/plain")) {
                    self.offered_text = true;
                },
                .source_actions => |args| self.source_actions = args.source_actions,
                .action => |args| self.offer_action = args.dnd_action,
            }
        }
        fn source(self: *@This(), _: wl.wl_data_source, event: wl.wl_data_source.Event) void {
            switch (event) {
                .target => |args| self.target_text = if (args.mime_type) |mime| std.mem.eql(u8, mime, "text/plain") else false,
                .action => |args| self.source_action = args.dnd_action,
                .dnd_drop_performed => self.drop_performed = true,
                .dnd_finished => self.finished = true,
                .cancelled => self.cancelled = true,
                .send => |args| _ = std.c.close(args.fd),
            }
        }
    };
    var dnd: Dnd = .{};
    const pointer = client.seat.?.get_pointer();
    pointer.listen(Dnd, &dnd, Dnd.pointer);
    const device = client.data.?.get_data_device(client.seat.?);
    device.listen(Dnd, &dnd, Dnd.device);
    const surface = client.compositor.?.create_surface();
    const xdg_surface = client.wm_base.?.get_xdg_surface(surface);
    xdg_surface.listen(Dnd, &dnd, Dnd.xdgSurface);
    const toplevel = xdg_surface.get_toplevel();
    surface.commit();
    try client.conn.roundtrip();
    const buffer = try client.shmBuffer(400, 300, null);
    surface.attach(buffer, 0, 0);
    // "Everything", as GL clients damage it, must not overflow the compositor.
    surface.damage(0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
    surface.commit();
    try client.conn.roundtrip();

    const wait = struct {
        fn until(conn: *client_wire.Connection, flag: *const bool) !void {
            const deadline = util.monotonicTime() + 3_000_000;
            while (!flag.* and util.monotonicTime() < deadline) _ = try conn.dispatchTimeout(50);
            try std.testing.expect(flag.*);
        }
    };
    // Press inside the window, then start dragging text from it.
    const virtual = client.pointers.?.create_virtual_pointer(client.seat.?);
    virtual.motion_absolute(0, 100, 100, 1280, 720);
    virtual.frame();
    try wait.until(client.conn, &dnd.pointer_entered);
    virtual.button(0, 0x110, 1);
    virtual.frame();
    try client.conn.roundtrip();
    const deadline = util.monotonicTime() + 3_000_000;
    while (dnd.press_serial == 0 and util.monotonicTime() < deadline) _ = try client.conn.dispatchTimeout(50);
    try std.testing.expect(dnd.press_serial != 0);
    const source = client.data.?.create_data_source();
    source.listen(Dnd, &dnd, Dnd.source);
    source.offer("text/plain");
    source.set_actions(wl.wl_data_device_manager.DndAction.copy | wl.wl_data_device_manager.DndAction.move);
    device.start_drag(source, surface, null, dnd.press_serial);
    try client.conn.roundtrip();
    try client.conn.roundtrip();
    try std.testing.expectEqual(@as(u32, 1), dnd.enters);
    try std.testing.expect(dnd.offered_text);
    try std.testing.expectEqual(@as(u32, 3), dnd.source_actions);

    // The target accepts text and prefers moving it.
    dnd.offer.?.accept(dnd.enter_serial, "text/plain");
    dnd.offer.?.set_actions(wl.wl_data_device_manager.DndAction.copy | wl.wl_data_device_manager.DndAction.move, wl.wl_data_device_manager.DndAction.move);
    try client.conn.roundtrip();
    try client.conn.roundtrip();
    try std.testing.expect(dnd.target_text);
    try std.testing.expectEqual(@as(u32, 2), dnd.offer_action);
    try std.testing.expectEqual(@as(u32, 2), dnd.source_action);

    virtual.motion_absolute(0, 150, 120, 1280, 720);
    virtual.button(0, 0x110, 0);
    virtual.frame();
    try wait.until(client.conn, &dnd.dropped);
    try wait.until(client.conn, &dnd.drop_performed);
    dnd.offer.?.finish();
    try wait.until(client.conn, &dnd.finished);
    try std.testing.expect(!dnd.cancelled);

    dnd.offer.?.destroy();
    source.destroy();
    buffer.destroy();
    toplevel.destroy();
    xdg_surface.destroy();
    surface.destroy();
    try client.conn.roundtrip();
}

test "outputs redraw the damage of the frames a reused buffer missed" {
    var output: Output = .{ .comp = undefined, .width = 1000, .height = 800, .pixels = &.{} };
    output.scheduled = true; // keep the repaint timer out of it
    // The first frame, and frames after a full repaint, draw everything.
    try std.testing.expectEqual(@as(?Gl.Clip, null), output.takeDamage(1));
    output.addDamage(.{ .x = 10, .y = 10, .width = 20, .height = 20 });
    try std.testing.expectEqual(@as(?Gl.Clip, .{ .x = 10, .y = 10, .width = 20, .height = 20 }), output.takeDamage(1));
    output.addDamage(.{ .x = 500, .y = 500, .width = 10, .height = 10 });
    // A buffer two frames old also lacks the previous frame's change.
    try std.testing.expectEqual(@as(?Gl.Clip, .{ .x = 10, .y = 10, .width = 500, .height = 500 }), output.takeDamage(2));
    // Damage is clipped to the output, and unknown buffer ages redraw everything.
    output.addDamage(.{ .x = 990, .y = -5, .width = 50, .height = 10 });
    try std.testing.expectEqual(@as(?Gl.Clip, null), output.takeDamage(0));
    output.addDamage(.{ .x = 990, .y = -5, .width = 50, .height = 10 });
    try std.testing.expectEqual(@as(?Gl.Clip, .{ .x = 990, .y = 0, .width = 10, .height = 5 }), output.takeDamage(1));
    output.scheduleRepaint();
    try std.testing.expectEqual(@as(?Gl.Clip, null), output.takeDamage(1));
}

test "keyboards switch layouts on the keymap's group keys" {
    const keymap = keymapFile(@import("xkb-reference").us_ru) orelse return error.Keymap;
    defer keymap.deinit();
    const map = keymap.map orelse return error.Keymap;
    try std.testing.expectEqual(@as(u32, 2), map.groupCount());
    // With Alt held, Shift is the layout switch of grp:alt_shift_toggle.
    var state: xkb.State = .{ .keymap = map };
    state.update(map.modifierMask(56 + 8), 0, 0, 0);
    try std.testing.expectEqual(keysyms.ISO_Next_Group, state.keysym(42 + 8));
    // The second layout types Cyrillic: Q is й.
    state.update(0, 0, 0, 1);
    try std.testing.expectEqual(@as(u32, 0x6ca), state.keysym(16 + 8));
    state.update(0, 0, 0, 0);
    try std.testing.expectEqual(@as(u32, 'q'), state.keysym(16 + 8));
}

test "shared-memory formats convert to premultiplied ARGB" {
    var bytes: [4]u8 = undefined;
    // ABGR8888 half-transparent red (premultiplied): 0x80 alpha, 0x80 red.
    std.mem.writeInt(u32, &bytes, 0x80000080, .little);
    try std.testing.expectEqual(@as(u32, 0x80800000), shmPixel(0x34324241, &bytes));
    // RGB565 pure green widens to 0xff.
    std.mem.writeInt(u16, bytes[0..2], 0x07e0, .little);
    try std.testing.expectEqual(@as(u32, 0xff00ff00), shmPixel(0x36314752, &bytes));
    // XRGB2101010 full red: top 8 of the 10 bits.
    std.mem.writeInt(u32, &bytes, 0x3ff00000, .little);
    try std.testing.expectEqual(@as(u32, 0xffff0000), shmPixel(0x30335258, &bytes));
    // ABGR2101010 opaque blue: blue in the high bits.
    std.mem.writeInt(u32, &bytes, 0xfff00000, .little);
    try std.testing.expectEqual(@as(u32, 0xff0000ff), shmPixel(0x30334241, &bytes));
    try std.testing.expectEqual(@as(usize, 2), shmLayout(0x36314752).?.bytes);
    try std.testing.expect(shmLayout(0x12345678) == null);
    const F = ws.wl_shm.Format;
    try std.testing.expectEqualSlices(u32, &.{ F.argb8888, F.xrgb8888, F.abgr8888, F.xbgr8888, F.rgb565, F.argb2101010, F.xrgb2101010, F.abgr2101010, F.xbgr2101010 }, &shm_formats);
}

test "native compositor moves a window dragged by its title bar" {
    const wl = @import("wayland-client");
    const a = std.testing.allocator;
    var env: TestEnv = .{};
    try env.start(a, "move");
    defer env.stop();
    var client: TestClient = undefined;
    try client.connect(a);
    defer client.deinit();

    const Window = struct {
        press_serial: u32 = 0,
        size: [2]i32 = .{ 0, 0 },
        fn xdgSurface(_: *@This(), surface: wl.xdg_surface, event: wl.xdg_surface.Event) void {
            surface.ack_configure(event.configure.serial);
        }
        fn toplevel(self: *@This(), _: wl.xdg_toplevel, event: wl.xdg_toplevel.Event) void {
            switch (event) {
                .configure => |args| if (args.width > 0) {
                    self.size = .{ args.width, args.height };
                },
                else => {},
            }
        }
        fn pointer(self: *@This(), _: wl.wl_pointer, event: wl.wl_pointer.Event) void {
            switch (event) {
                .button => |args| if (args.state == 1) {
                    self.press_serial = args.serial;
                },
                else => {},
            }
        }
    };
    var window: Window = .{};
    const pointer = client.seat.?.get_pointer();
    pointer.listen(Window, &window, Window.pointer);
    const surface = client.compositor.?.create_surface();
    const xdg_surface = client.wm_base.?.get_xdg_surface(surface);
    xdg_surface.listen(Window, &window, Window.xdgSurface);
    const toplevel = xdg_surface.get_toplevel();
    toplevel.listen(Window, &window, Window.toplevel);
    surface.commit();
    try client.conn.roundtrip();
    // A red window of the size it was given (the output's usable area).
    const buffer = try client.shmBuffer(@intCast(window.size[0]), @intCast(window.size[1]), 0xffff0000);
    surface.attach(buffer, 0, 0);
    surface.commit();
    try client.conn.roundtrip();
    var deadline = util.monotonicTime() + 3_000_000;
    while (env.handle.pixel(50, 50).value != 0xffff0000 and util.monotonicTime() < deadline) {
        _ = try client.conn.dispatchTimeout(20);
    }
    try std.testing.expectEqual(@as(u32, 0xffff0000), env.handle.pixel(50, 50).value);

    const virtual = client.pointers.?.create_virtual_pointer(client.seat.?);
    virtual.motion_absolute(0, 100, 100, 1280, 720);
    virtual.button(0, 0x110, 1);
    virtual.frame();
    deadline = util.monotonicTime() + 3_000_000;
    while (window.press_serial == 0 and util.monotonicTime() < deadline) _ = try client.conn.dispatchTimeout(50);
    try std.testing.expect(window.press_serial != 0);
    toplevel.move(client.seat.?, window.press_serial);
    try client.conn.roundtrip();
    virtual.motion(0, 200, 150);
    virtual.frame();
    try client.conn.roundtrip();
    // The window keeps its size and follows the pointer; its old corner shows the background.
    deadline = util.monotonicTime() + 3_000_000;
    while ((env.handle.pixel(50, 50).value != 0xff303030 or env.handle.pixel(250, 200).value != 0xffff0000) and util.monotonicTime() < deadline) {
        _ = try client.conn.dispatchTimeout(20);
    }
    try std.testing.expectEqual(@as(u32, 0xff303030), env.handle.pixel(50, 50).value);
    try std.testing.expectEqual(@as(u32, 0xffff0000), env.handle.pixel(250, 200).value);
    virtual.button(0, 0x110, 0);
    virtual.frame();
    try client.conn.roundtrip();

    buffer.destroy();
    toplevel.destroy();
    xdg_surface.destroy();
    surface.destroy();
    try client.conn.roundtrip();
}

test "native compositor hides the panel over a fullscreen window" {
    const wl = @import("wayland-client");
    const a = std.testing.allocator;
    var env: TestEnv = .{};
    try env.start(a, "fullscreen");
    defer env.stop();
    var client: TestClient = undefined;
    try client.connect(a);
    defer client.deinit();

    const State = struct {
        panel_serial: u32 = 0,
        size: [2]i32 = .{ 0, 0 },
        fn layer(self: *@This(), _: wl.zwlr_layer_surface_v1, event: wl.zwlr_layer_surface_v1.Event) void {
            switch (event) {
                .configure => |args| self.panel_serial = args.serial,
                else => {},
            }
        }
        fn xdgSurface(_: *@This(), surface: wl.xdg_surface, event: wl.xdg_surface.Event) void {
            surface.ack_configure(event.configure.serial);
        }
        fn toplevel(self: *@This(), _: wl.xdg_toplevel, event: wl.xdg_toplevel.Event) void {
            switch (event) {
                .configure => |args| if (args.width > 0) {
                    self.size = .{ args.width, args.height };
                },
                else => {},
            }
        }
    };
    var state: State = .{};
    // A blue panel across the top, in the top layer.
    const panel_surface = client.compositor.?.create_surface();
    const panel = client.layers.?.get_layer_surface(panel_surface, null, 2, "desktop-panel");
    panel.listen(State, &state, State.layer);
    panel.set_size(0, 32);
    panel.set_anchor(1 | 4 | 8);
    panel.set_exclusive_zone(32);
    panel_surface.commit();
    try client.conn.roundtrip();
    panel.ack_configure(state.panel_serial);
    const panel_buffer = try client.shmBuffer(1280, 32, 0xff0000ff);
    panel_surface.attach(panel_buffer, 0, 0);
    panel_surface.commit();
    // A red window that goes fullscreen.
    const surface = client.compositor.?.create_surface();
    const xdg_surface = client.wm_base.?.get_xdg_surface(surface);
    xdg_surface.listen(State, &state, State.xdgSurface);
    const toplevel = xdg_surface.get_toplevel();
    toplevel.listen(State, &state, State.toplevel);
    toplevel.set_fullscreen(null);
    surface.commit();
    try client.conn.roundtrip();
    try std.testing.expectEqual([2]i32{ 1280, 720 }, state.size);
    const buffer = try client.shmBuffer(1280, 720, 0xffff0000);
    surface.attach(buffer, 0, 0);
    surface.commit();
    try client.conn.roundtrip();
    var deadline = util.monotonicTime() + 3_000_000;
    while (env.handle.pixel(10, 10).value != 0xffff0000 and util.monotonicTime() < deadline) _ = try client.conn.dispatchTimeout(20);
    try std.testing.expectEqual(@as(u32, 0xffff0000), env.handle.pixel(10, 10).value);
    // Leaving fullscreen brings the panel back over the maximized window.
    toplevel.unset_fullscreen();
    try client.conn.roundtrip();
    deadline = util.monotonicTime() + 3_000_000;
    while (env.handle.pixel(10, 10).value != 0xff0000ff and util.monotonicTime() < deadline) _ = try client.conn.dispatchTimeout(20);
    try std.testing.expectEqual(@as(u32, 0xff0000ff), env.handle.pixel(10, 10).value);

    buffer.destroy();
    panel_buffer.destroy();
    toplevel.destroy();
    xdg_surface.destroy();
    surface.destroy();
    panel.destroy();
    panel_surface.destroy();
    try client.conn.roundtrip();
}

test "native compositor passes scroll sources, stops and wheel steps to clients" {
    const wl = @import("wayland-client");
    const a = std.testing.allocator;
    var env: TestEnv = .{};
    try env.start(a, "scroll");
    defer env.stop();
    var client: TestClient = undefined;
    try client.connect(a);
    defer client.deinit();

    const Events = struct {
        entered: bool = false,
        sources: u32 = 0,
        finger: bool = false,
        stops: u32 = 0,
        axis_values: u32 = 0,
        value120: i32 = 0,
        frames: u32 = 0,
        size: [2]i32 = .{ 0, 0 },
        fn xdgSurface(_: *@This(), surface: wl.xdg_surface, event: wl.xdg_surface.Event) void {
            surface.ack_configure(event.configure.serial);
        }
        fn toplevel(self: *@This(), _: wl.xdg_toplevel, event: wl.xdg_toplevel.Event) void {
            switch (event) {
                .configure => |args| if (args.width > 0) {
                    self.size = .{ args.width, args.height };
                },
                else => {},
            }
        }
        fn pointer(self: *@This(), _: wl.wl_pointer, event: wl.wl_pointer.Event) void {
            switch (event) {
                .enter => self.entered = true,
                .axis_source => |args| {
                    self.sources += 1;
                    self.finger = args.axis_source == 1;
                },
                .axis_stop => self.stops += 1,
                .axis => self.axis_values += 1,
                .axis_value120 => |args| self.value120 += args.value120,
                .frame => self.frames += 1,
                else => {},
            }
        }
    };
    var events: Events = .{};
    const pointer = client.seat.?.get_pointer();
    pointer.listen(Events, &events, Events.pointer);
    const surface = client.compositor.?.create_surface();
    const xdg_surface = client.wm_base.?.get_xdg_surface(surface);
    xdg_surface.listen(Events, &events, Events.xdgSurface);
    const toplevel = xdg_surface.get_toplevel();
    toplevel.listen(Events, &events, Events.toplevel);
    surface.commit();
    try client.conn.roundtrip();
    const buffer = try client.shmBuffer(@intCast(events.size[0]), @intCast(events.size[1]), null);
    surface.attach(buffer, 0, 0);
    surface.commit();
    try client.conn.roundtrip();
    const virtual = client.pointers.?.create_virtual_pointer(client.seat.?);
    virtual.motion_absolute(0, 200, 200, 1280, 720);
    virtual.frame();
    const deadline = util.monotonicTime() + 3_000_000;
    while (!events.entered and util.monotonicTime() < deadline) _ = try client.conn.dispatchTimeout(20);
    try std.testing.expect(events.entered);
    // Two fingers on a touchpad, both axes in one frame, then lifted.
    virtual.axis_source(1);
    virtual.axis(0, 0, 10);
    virtual.axis(0, 1, 4);
    virtual.frame();
    virtual.axis_source(1);
    virtual.axis_stop(1, 0);
    virtual.frame();
    // One wheel click.
    virtual.axis_source(0);
    virtual.axis_discrete(2, 0, 15, 1);
    virtual.frame();
    try client.conn.roundtrip();
    try client.conn.roundtrip();
    try std.testing.expectEqual(@as(u32, 3), events.sources);
    try std.testing.expectEqual(@as(u32, 1), events.stops);
    try std.testing.expectEqual(@as(u32, 3), events.axis_values);
    try std.testing.expectEqual(@as(i32, 120), events.value120);
    try std.testing.expect(!events.finger);
    buffer.destroy();
    toplevel.destroy();
    xdg_surface.destroy();
    surface.destroy();
    try client.conn.roundtrip();
}

test "native compositor shuts down cleanly with connected clients and stale capture objects" {
    const wl = @import("wayland-client");
    const a = std.testing.allocator;
    var env: TestEnv = .{};
    try env.start(a, "teardown");
    // Stop compositor BEFORE closing client connection to exercise shutdown teardown order.
    var client: TestClient = undefined;
    try client.connect(a);
    defer client.deinit();
    defer env.stop();

    const State = struct {
        last_handle: ?wl.ext_foreign_toplevel_handle_v1 = null,
        session_stopped: bool = false,
        frame_failed: bool = false,
        size: [2]i32 = .{ 0, 0 },
        fn listEvent(self: *@This(), _: wl.ext_foreign_toplevel_list_v1, event: wl.ext_foreign_toplevel_list_v1.Event) void {
            switch (event) {
                .toplevel => |args| self.last_handle = args.toplevel,
                else => {},
            }
        }
        fn xdgSurface(_: *@This(), surface: wl.xdg_surface, event: wl.xdg_surface.Event) void {
            surface.ack_configure(event.configure.serial);
        }
        fn toplevel(self: *@This(), _: wl.xdg_toplevel, event: wl.xdg_toplevel.Event) void {
            switch (event) {
                .configure => |args| if (args.width > 0) {
                    self.size = .{ args.width, args.height };
                },
                else => {},
            }
        }
        fn sessionEvent(self: *@This(), _: wl.ext_image_copy_capture_session_v1, event: wl.ext_image_copy_capture_session_v1.Event) void {
            if (event == .stopped) self.session_stopped = true;
        }
        fn frameEvent(self: *@This(), _: wl.ext_image_copy_capture_frame_v1, event: wl.ext_image_copy_capture_frame_v1.Event) void {
            if (event == .failed) self.frame_failed = true;
        }
    };
    var state: State = .{};
    client.list.?.listen(State, &state, State.listEvent);
    try client.conn.roundtrip();

    // Map first window, create a CaptureSource, then destroy the window before create_session.
    const s1 = client.compositor.?.create_surface();
    const x1 = client.wm_base.?.get_xdg_surface(s1);
    x1.listen(State, &state, State.xdgSurface);
    const t1 = x1.get_toplevel();
    t1.listen(State, &state, State.toplevel);
    s1.commit();
    try client.conn.roundtrip();
    const w: usize = @intCast(@max(1, state.size[0]));
    const h: usize = @intCast(@max(1, state.size[1]));
    const buf1 = try client.shmBuffer(w, h, null);
    s1.attach(buf1, 0, 0);
    s1.commit();
    try client.conn.roundtrip();
    try std.testing.expect(state.last_handle != null);
    const stale_source = client.sources.?.create_source(state.last_handle.?);
    t1.destroy();
    x1.destroy();
    s1.destroy();
    try client.conn.roundtrip();
    const stopped_session = client.copy.?.create_session(stale_source, 0);
    stopped_session.listen(State, &state, State.sessionEvent);
    try client.conn.roundtrip();
    try std.testing.expect(state.session_stopped);
    stopped_session.destroy();
    stale_source.destroy();

    // Map second window, create a session & frame, destroy session & buffer before capture().
    state.last_handle = null;
    const s2 = client.compositor.?.create_surface();
    const x2 = client.wm_base.?.get_xdg_surface(s2);
    x2.listen(State, &state, State.xdgSurface);
    const t2 = x2.get_toplevel();
    t2.listen(State, &state, State.toplevel);
    s2.commit();
    try client.conn.roundtrip();
    const buf2 = try client.shmBuffer(w, h, null);
    s2.attach(buf2, 0, 0);
    s2.commit();
    try client.conn.roundtrip();
    const src2 = client.sources.?.create_source(state.last_handle.?);
    const sess2 = client.copy.?.create_session(src2, 0);
    const frame2 = sess2.create_frame();
    frame2.listen(State, &state, State.frameEvent);
    const cap_buf = try client.shmBuffer(w, h, null);
    frame2.attach_buffer(cap_buf);
    cap_buf.destroy();
    sess2.destroy();
    frame2.capture();
    try client.conn.roundtrip();
    try std.testing.expect(state.frame_failed);
    // Intentionally leave s2/x2/t2/buf1/buf2/src2/frame2 live when env.stop() runs.
}

test "native compositor keeps physical wl_output mode size when rotated" {
    const wl = @import("wayland-client");
    const a = std.testing.allocator;
    var env: TestEnv = .{};
    try env.start(a, "rotate");
    defer env.stop();
    var client: TestClient = undefined;
    try client.connect(a);
    defer client.deinit();

    const State = struct {
        head: ?wl.zwlr_output_head_v1 = null,
        serial: u32 = 0,
        mode_w: i32 = 0,
        mode_h: i32 = 0,
        transform: i32 = 0,
        succeeded: bool = false,
        fn outputEvent(self: *@This(), _: wl.wl_output, event: wl.wl_output.Event) void {
            switch (event) {
                .geometry => |args| self.transform = args.transform,
                .mode => |args| {
                    self.mode_w = args.width;
                    self.mode_h = args.height;
                },
                else => {},
            }
        }
        fn managerEvent(self: *@This(), _: wl.zwlr_output_manager_v1, event: wl.zwlr_output_manager_v1.Event) void {
            switch (event) {
                .head => |args| self.head = args.head,
                .done => |args| self.serial = args.serial,
                else => {},
            }
        }
        fn configEvent(self: *@This(), _: wl.zwlr_output_configuration_v1, event: wl.zwlr_output_configuration_v1.Event) void {
            if (event == .succeeded) self.succeeded = true;
        }
    };
    var state: State = .{};
    client.output.?.listen(State, &state, State.outputEvent);
    client.output_manager.?.listen(State, &state, State.managerEvent);
    try client.conn.roundtrip();
    try std.testing.expect(state.head != null);
    for ([_]i32{ 1, 2 }) |turn| {
        state.succeeded = false;
        const config = client.output_manager.?.create_configuration(state.serial);
        config.listen(State, &state, State.configEvent);
        const head_cfg = config.enable_head(state.head.?);
        head_cfg.set_transform(turn);
        config.apply();
        try client.conn.roundtrip();
        try std.testing.expect(state.succeeded);
        try std.testing.expectEqual(turn, state.transform);
        try std.testing.expectEqual(@as(i32, 1280), state.mode_w);
        try std.testing.expectEqual(@as(i32, 720), state.mode_h);
        head_cfg.destroy();
        config.destroy();
    }
}

test "native compositor frees presentation feedback and handles out-of-order surface destruction" {
    const wl = @import("wayland-client");
    const a = std.testing.allocator;
    var env: TestEnv = .{};
    try env.start(a, "lifetime");
    defer env.stop();
    var client: TestClient = undefined;
    try client.connect(a);
    defer client.deinit();

    const State = struct {
        configured: bool = false,
        presented: usize = 0,
        fn xdgEvent(self: *@This(), surface: wl.xdg_surface, event: wl.xdg_surface.Event) void {
            if (event == .configure) {
                surface.ack_configure(event.configure.serial);
                self.configured = true;
            }
        }
        fn feedbackEvent(self: *@This(), _: wl.wp_presentation_feedback, event: wl.wp_presentation_feedback.Event) void {
            if (event == .presented) self.presented += 1;
        }
    };
    var state: State = .{};

    // Destroy wl_surface before its wp_viewport and wp_fractional_scale_v1.
    const doomed = client.compositor.?.create_surface();
    const vp = client.viewporter.?.get_viewport(doomed);
    const fs = client.fractional.?.get_fractional_scale(doomed);
    doomed.destroy();
    try client.conn.roundtrip();
    vp.destroy();
    fs.destroy();
    try client.conn.roundtrip();

    // Map a toplevel and submit presentation feedback across multiple commits.
    const buf = try client.shmBuffer(32, 32, null);
    const surface = client.compositor.?.create_surface();
    const xdg = client.wm_base.?.get_xdg_surface(surface);
    xdg.listen(State, &state, State.xdgEvent);
    const toplevel = xdg.get_toplevel();
    surface.commit();
    try client.conn.roundtrip();
    try std.testing.expect(state.configured);
    for (0..3) |_| {
        const fb = client.presentation.?.feedback(surface);
        fb.listen(State, &state, State.feedbackEvent);
        surface.attach(buf, 0, 0);
        surface.damage_buffer(0, 0, 32, 32);
        surface.commit();
        try client.conn.roundtrip();
    }
    const deadline = util.monotonicTime() + 500_000;
    while (state.presented == 0 and util.monotonicTime() < deadline) {
        std.testing.io.sleep(.fromMilliseconds(5), .awake) catch {};
        try client.conn.roundtrip();
    }
    try std.testing.expect(state.presented >= 1);
    toplevel.destroy();
    xdg.destroy();
    surface.destroy();
    buf.destroy();
    try client.conn.roundtrip();
}
