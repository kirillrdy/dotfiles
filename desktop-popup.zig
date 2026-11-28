//! Shared native popup surface, output selection, and deferred dismissal.
const std = @import("std");
const mainloop = @import("desktop-loop.zig");
const util = @import("desktop-util.zig");
const wire = @import("desktop-surface.zig");
const raster = @import("desktop-raster.zig");
const input = @import("desktop-input.zig");
fn cast(comptime T: type, ptr: anytype) *T { return @ptrCast(@alignCast(ptr)); }

pub const Host = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    context: ?*anyopaque,
    namespace: [:0]const u8,
    paint: wire.PixelPaint,
    input: input.Events,
    resized: *const fn (?*anyopaque) void,
    dismiss: *const fn (?*anyopaque) void,
    client: ?*wire.Client = null,
    surface: ?*wire.Surface = null,
    pixels: std.ArrayList(u32) = .empty,
    rect: raster.Rect = .{},
    view_width: u32 = 1,
    view_height: u32 = 1,
    visible: bool = false,
    close_idle: u32 = 0,
    anchor_x: i32 = 0,
    anchor_y: i32 = 0,
    /// Opt in when the owner draws only through blit: the host then clears and
    /// damages just the popup bounds instead of the whole output-sized surface.
    partial: bool = false,
    /// Logical popup bounds and buffer scale of the last commit, for damage.
    committed: ?raster.Rect = null,
    committed_scale: u32 = 0,

    pub fn deinit(self: *Host) void {
        self.visible = false;
        self.cancelHide();
        if (self.client) |client| client.destroy();
        self.client = null;
        self.surface = null;
        self.pixels.deinit(self.allocator);
        self.pixels = .empty;
    }
    pub fn prepare(self: *Host, global_x: i32, global_y: i32) !void {
        if (self.client == null) {
            self.client = try wire.Client.createInteractive(self.allocator, self.io, .{ .added = &added, .removed = &removed, .changed = &changed }, self);
            errdefer {
                self.client.?.destroy();
                self.client = null;
            }
            try self.client.?.start();
        }
        const client = self.client.?;
        if (client.failed or client.outputs.items.len == 0) return error.DisplayUnavailable;
        var output = client.outputs.items[0];
        for (client.outputs.items) |candidate| {
            if (global_x >= candidate.x and global_y >= candidate.y and global_x < candidate.x + candidate.width() and global_y < candidate.y + candidate.height()) {
                output = candidate;
                break;
            }
        }
        if (self.surface) |surface| if (surface.output != output) {
            self.surface = null;
            surface.destroy();
        };
        if (self.surface == null) {
            self.surface = try wire.Surface.createPixels(output, .{
                .namespace = self.namespace,
                .layer = 3,
                .anchors = wire.top | wire.bottom | wire.left | wire.right,
                .interactive = true,
                .keyboard = .exclusive,
                .cursor = .arrow,
                .clear_buffer = !self.partial,
            }, self.paint, self.context);
            self.committed = null;
            self.surface.?.input = self.input;
            // Coalesce input-driven redraws (scroll bursts, motion) to one per compositor frame.
            self.surface.?.next_frame = &paced;
        }
        self.cancelHide();
        self.anchor_x = global_x;
        self.anchor_y = global_y;
    }
    pub fn show(self: *Host) !void {
        self.visible = true;
        errdefer self.visible = false;
        try self.surface.?.show();
    }
    pub fn hide(self: *Host) void {
        self.cancelHide();
        self.visible = false;
        self.committed = null; // A remapped surface starts with no previous frame.
        if (self.surface) |surface| surface.hide();
    }
    pub fn redraw(self: *Host) void {
        if (self.visible and self.close_idle == 0) if (self.surface) |surface| surface.redraw();
    }
    pub fn bounds(self: *const Host, width: u32, height: u32) raster.Rect {
        const output = (self.surface orelse return .{}).output;
        return placement(output.width(), output.height(), self.anchor_x - output.x, self.anchor_y - output.y, width, height);
    }
    pub fn place(self: *Host, width: u32, height: u32) void {
        self.view_width = @max(1, width);
        self.view_height = @max(1, height);
        self.rect = self.bounds(width, height);
    }
    pub fn contains(self: *const Host, x: f64, y: f64) bool {
        return self.rect.contains(x, y);
    }
    pub fn point(self: *const Host, x: f64, y: f64) raster.Point {
        const zoom = self.rect.width / @as(f64, @floatFromInt(@max(1, self.view_width)));
        return .{ .x = (x - self.rect.x) / zoom, .y = (y - self.rect.y) / zoom };
    }
    pub fn canvas(self: *Host, width: u32, height: u32) !wire.Pixels {
        const factor = self.surface.?.buffer_scale;
        self.place(width, height);
        const physical_width = width * factor;
        const physical_height = height * factor;
        try self.pixels.resize(self.allocator, @as(usize, physical_width) * physical_height);
        return .{ .pixels = self.pixels.items, .width = physical_width, .height = physical_height };
    }
    pub fn blit(self: *Host, target: wire.Pixels) !void {
        const surface = self.surface.?;
        const factor = surface.buffer_scale;
        const scale: f64 = @floatFromInt(factor);
        const width = self.view_width * factor;
        const height = self.view_height * factor;
        const destination: raster.Rect = .{ .x = self.rect.x * scale, .y = self.rect.y * scale, .width = self.rect.width * scale, .height = self.rect.height * scale };
        if (self.partial) {
            // The rest of the output-sized buffer stays transparent: clear only
            // where this buffer last drew and where the popup lands now.
            const now = outward(destination, target.width, target.height);
            raster.fill(target, enclose(surface.swapDrawn(now), now), 0, .source);
        }
        if (self.partial and copyAligned(target, self.pixels.items, width, height, destination)) {
            // Fast path done: an unscaled popup over cleared pixels is a plain copy.
        } else try raster.blit(target, .{ .pixels = std.mem.sliceAsBytes(self.pixels.items), .width = width, .height = height, .stride = width * 4, .format = .argb }, destination, null);
        if (self.partial) {
            // Damage what changed since the previous commit: old and new popup bounds.
            if (self.committed) |previous| if (self.committed_scale == factor) {
                const logical = enclose(outward(previous, std.math.maxInt(u32), std.math.maxInt(u32)), outward(self.rect, std.math.maxInt(u32), std.math.maxInt(u32)));
                surface.damage_hint = .{ .x = logical.x, .y = logical.y, .width = @intCast(logical.width), .height = @intCast(logical.height) };
            };
            self.committed = self.rect;
            self.committed_scale = factor;
        }
    }
    fn cancelHide(self: *Host) void {
        if (self.close_idle != 0) _ = mainloop.remove(self.io, self.close_idle);
        self.close_idle = 0;
    }
    pub fn requestHide(self: *Host) void {
        // Dismissal may destroy the owner and client; leave Wayland dispatch first.
        if (self.close_idle == 0) self.close_idle = mainloop.idle(self.io, self, hideIdle);
    }
    fn hideIdle(self: *Host) bool {
        self.close_idle = 0;
        self.dismiss(self.context);
        return false;
    }
    fn paced(_: ?*anyopaque, _: *wire.Surface, _: u32) bool {
        return false; // Pace only; popups never animate on their own.
    }
    fn added(_: ?*anyopaque, _: *wire.Output) void {}
    fn removed(ptr: ?*anyopaque, output: *wire.Output) void {
        const self = cast(Host, ptr);
        if (self.surface) |surface| if (surface.output == output) {
            self.surface = null; // Client revokes the removed output's surfaces.
            if (self.visible) self.requestHide();
        };
    }
    fn changed(ptr: ?*anyopaque, output: *wire.Output) void {
        const self = cast(Host, ptr);
        if (self.surface) |surface| if (surface.output == output) self.resized(self.context);
    }
};

/// Pixel bounds covering `rect`, rounded outward and clamped to a width x height buffer.
fn outward(rect: raster.Rect, width: u32, height: u32) raster.Region {
    const w: f64 = @floatFromInt(width);
    const h: f64 = @floatFromInt(height);
    const x0 = std.math.clamp(@floor(rect.x), 0, w);
    const y0 = std.math.clamp(@floor(rect.y), 0, h);
    const x1 = std.math.clamp(@ceil(rect.x + rect.width), x0, w);
    const y1 = std.math.clamp(@ceil(rect.y + rect.height), y0, h);
    return .{ .x = @intFromFloat(x0), .y = @intFromFloat(y0), .width = @intFromFloat(x1 - x0), .height = @intFromFloat(y1 - y0) };
}
/// Copy rows when `destination` is pixel-aligned, unscaled and inside the target.
/// Source-over onto cleared (transparent) pixels equals the source, so this
/// matches raster.blit there. Returns false when the general blit is needed.
fn copyAligned(target: wire.Pixels, source: []const u32, width: u32, height: u32, destination: raster.Rect) bool {
    const w: f64 = @floatFromInt(width);
    const h: f64 = @floatFromInt(height);
    if (destination.width != w or destination.height != h) return false;
    if (destination.x != @floor(destination.x) or destination.y != @floor(destination.y)) return false;
    if (destination.x < 0 or destination.y < 0) return false;
    if (destination.x + w > @as(f64, @floatFromInt(target.width)) or destination.y + h > @as(f64, @floatFromInt(target.height))) return false;
    if (source.len < @as(usize, width) * height) return false;
    const x: usize = @intFromFloat(destination.x);
    const y: usize = @intFromFloat(destination.y);
    for (0..height) |row| @memcpy(target.pixels[(y + row) * target.width + x ..][0..width], source[row * width ..][0..width]);
    return true;
}
fn enclose(a: raster.Region, b: raster.Region) raster.Region {
    if (a.width == 0 or a.height == 0) return b;
    if (b.width == 0 or b.height == 0) return a;
    const x0 = @min(a.x, b.x);
    const y0 = @min(a.y, b.y);
    const x1 = @max(a.x + @as(i32, @intCast(a.width)), b.x + @as(i32, @intCast(b.width)));
    const y1 = @max(a.y + @as(i32, @intCast(a.height)), b.y + @as(i32, @intCast(b.height)));
    return .{ .x = x0, .y = y0, .width = @intCast(x1 - x0), .height = @intCast(y1 - y0) };
}

// Coordinates are output-local logical pixels, independent of buffer scale.
pub fn placement(output_width: i32, output_height: i32, x: i32, y: i32, view_width: u32, view_height: u32) raster.Rect {
    const available_width: f64 = @floatFromInt(@max(1, output_width - 16));
    const available_height: f64 = @floatFromInt(@max(1, output_height - 16));
    const vw: f64 = @floatFromInt(@max(1, view_width));
    const vh: f64 = @floatFromInt(@max(1, view_height));
    const zoom = @min(1, @min(available_width / vw, available_height / vh));
    const w = vw * zoom;
    const h = vh * zoom;
    return .{
        .x = @floor(std.math.clamp(@as(f64, @floatFromInt(x)) - w / 2, 8, @max(8, @as(f64, @floatFromInt(output_width)) - w - 8))),
        .y = @floor(std.math.clamp(@as(f64, @floatFromInt(y)), 8, @max(8, @as(f64, @floatFromInt(output_height)) - h - 8))),
        .width = w,
        .height = h,
    };
}

test "popup dismissal coalesces and hide or destruction cancels queued callbacks" {
    const Owner = struct {
        calls: usize = 0,
        fn paint(_: ?*anyopaque, _: wire.Pixels) void {}
        fn resized(_: ?*anyopaque) void {}
        fn dismiss(ptr: ?*anyopaque) void {
            cast(@This(), ptr).calls += 1;
        }
    };
    var owner: Owner = .{};
    var host: Host = .{ .allocator = std.testing.allocator, .io = std.testing.io, .context = &owner, .namespace = "test-popup", .paint = &Owner.paint, .input = .{}, .resized = &Owner.resized, .dismiss = &Owner.dismiss };
    defer host.deinit();
    host.visible = true;
    host.requestHide();
    const pending = host.close_idle;
    host.requestHide();
    try std.testing.expect(pending != 0);
    try std.testing.expectEqual(pending, host.close_idle);
    try std.testing.expectEqual(@as(usize, 0), owner.calls);
    while (host.close_idle != 0) _ = mainloop.iteration(std.testing.io, false);
    try std.testing.expectEqual(@as(usize, 1), owner.calls);

    host.requestHide();
    host.hide();
    try std.testing.expect(!host.visible and host.close_idle == 0);
    while (mainloop.iteration(std.testing.io, false)) {}
    try std.testing.expectEqual(@as(usize, 1), owner.calls);

    host.requestHide();
    host.deinit();
    while (mainloop.iteration(std.testing.io, false)) {}
    try std.testing.expectEqual(@as(usize, 1), owner.calls);
}

test "popup dismissal callback can destroy its owner" {
    const Owner = struct {
        host: Host,
        fn paint(_: ?*anyopaque, _: wire.Pixels) void {}
        fn resized(_: ?*anyopaque) void {}
        fn dismiss(ptr: ?*anyopaque) void {
            const self = cast(@This(), ptr);
            self.host.deinit();
            std.testing.allocator.destroy(self);
        }
    };
    const owner = try std.testing.allocator.create(Owner);
    owner.* = .{ .host = .{ .allocator = std.testing.allocator, .io = std.testing.io, .context = owner, .namespace = "test-popup", .paint = &Owner.paint, .input = .{}, .resized = &Owner.resized, .dismiss = &Owner.dismiss } };
    owner.host.requestHide();
    // The callback frees owner; dispatch must never read its host afterward.
    _ = mainloop.iteration(std.testing.io, false);
}

test "popup placement fits output edges and small screens in logical coordinates" {
    const center = placement(1728, 1080, 864, 32, 752, 420);
    try std.testing.expectEqual(raster.Rect{ .x = 488, .y = 32, .width = 752, .height = 420 }, center);
    const corner = placement(1728, 1080, 1728, 1079, 752, 420);
    try std.testing.expectEqual(@as(f64, 968), corner.x);
    try std.testing.expectEqual(@as(f64, 652), corner.y);
    const right = placement(1728, 1080, 1700, 32, 376, 480);
    try std.testing.expectEqual(raster.Rect{ .x = 1344, .y = 32, .width = 376, .height = 480 }, right);
    for ([_][2]u32{ .{ 752, 420 }, .{ 376, 480 } }) |size| {
        const small = placement(640, 360, 320, 32, size[0], size[1]);
        try std.testing.expect(small.x >= 8 and small.y >= 8);
        try std.testing.expect(small.x + small.width <= 632 and small.y + small.height <= 352);
        try std.testing.expectApproxEqAbs(@as(f64, @floatFromInt(size[0])) / @as(f64, @floatFromInt(size[1])), small.width / small.height, 0.000001);
    }
}

test "partial popup clearing rounds bounds outward, clamps to the buffer, and unions regions" {
    try std.testing.expectEqual(raster.Region{ .x = 1, .y = 2, .width = 4, .height = 3 }, outward(.{ .x = 1.5, .y = 2.2, .width = 3, .height = 2.5 }, 100, 100));
    try std.testing.expectEqual(raster.Region{ .x = 90, .y = 0, .width = 10, .height = 5 }, outward(.{ .x = 90, .y = -3, .width = 40, .height = 8 }, 100, 100));
    const empty: raster.Region = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    const a: raster.Region = .{ .x = 10, .y = 10, .width = 5, .height = 5 };
    try std.testing.expectEqual(a, enclose(empty, a));
    try std.testing.expectEqual(a, enclose(a, empty));
    try std.testing.expectEqual(raster.Region{ .x = 2, .y = 10, .width = 13, .height = 20 }, enclose(a, .{ .x = 2, .y = 20, .width = 3, .height = 10 }));
}

test "aligned popup copy matches source-over blit onto cleared pixels and declines unaligned cases" {
    const source = [_]u32{ 0x00000000, 0x80402010, 0xff112233, 0x40000000, 0xffffffff, 0x10101010 };
    var fast: [8 * 6]u32 = @splat(0);
    var slow: [8 * 6]u32 = @splat(0);
    const destination: raster.Rect = .{ .x = 2, .y = 1, .width = 3, .height = 2 };
    try std.testing.expect(copyAligned(.{ .pixels = &fast, .width = 8, .height = 6 }, &source, 3, 2, destination));
    try raster.blit(.{ .pixels = &slow, .width = 8, .height = 6 }, .{ .pixels = std.mem.sliceAsBytes(&source), .width = 3, .height = 2, .stride = 12, .format = .argb }, destination, null);
    try std.testing.expectEqualSlices(u32, &slow, &fast);
    const target: wire.Pixels = .{ .pixels = &fast, .width = 8, .height = 6 };
    try std.testing.expect(!copyAligned(target, &source, 3, 2, .{ .x = 2.5, .y = 1, .width = 3, .height = 2 }));
    try std.testing.expect(!copyAligned(target, &source, 3, 2, .{ .x = 2, .y = 1, .width = 2.5, .height = 2 }));
    try std.testing.expect(!copyAligned(target, &source, 3, 2, .{ .x = 6, .y = 1, .width = 3, .height = 2 }));
}
