//! Shared native popup surface, output selection, and deferred dismissal.
const std = @import("std");
const c = @import("desktop-gtk.zig");
const wire = @import("desktop-surface.zig");
const raster = @import("desktop-raster.zig");
const input = @import("desktop-input.zig");
const cast = c.__zig.cast;

pub const Host = struct {
    context: ?*anyopaque,
    namespace: [:0]const u8,
    paint: wire.PixelPaint,
    input: input.Events,
    resized: *const fn (?*anyopaque) void,
    dismiss: *const fn (?*anyopaque) void,
    client: ?*wire.Client = null,
    surface: ?*wire.Surface = null,
    visible: bool = false,
    close_idle: c.guint = 0,
    anchor_x: i32 = 0,
    anchor_y: i32 = 0,

    pub fn deinit(self: *Host) void {
        self.visible = false;
        self.cancelHide();
        if (self.client) |client| client.destroy();
        self.client = null;
        self.surface = null;
    }
    pub fn prepare(self: *Host, global_x: i32, global_y: i32) !void {
        if (self.client == null) {
            self.client = try wire.Client.createInteractive(.{ .added = &added, .removed = &removed, .changed = &changed }, self);
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
            }, self.paint, self.context);
            self.surface.?.input = self.input;
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
        if (self.surface) |surface| surface.hide();
    }
    pub fn redraw(self: *Host) void {
        if (self.visible and self.close_idle == 0) if (self.surface) |surface| surface.redraw();
    }
    pub fn bounds(self: *const Host, width: u32, height: u32) raster.Rect {
        const output = (self.surface orelse return .{}).output;
        return placement(output.width(), output.height(), self.anchor_x - output.x, self.anchor_y - output.y, width, height);
    }
    fn cancelHide(self: *Host) void {
        if (self.close_idle != 0) _ = c.g_source_remove(self.close_idle);
        self.close_idle = 0;
    }
    pub fn requestHide(self: *Host) void {
        // Dismissal may destroy the owner and client; leave Wayland dispatch first.
        if (self.close_idle == 0) self.close_idle = c.g_idle_add(&hideIdle, self);
    }
    fn hideIdle(ptr: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast(Host, ptr);
        self.close_idle = 0;
        self.dismiss(self.context);
        return 0;
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
    var host: Host = .{ .context = &owner, .namespace = "test-popup", .paint = &Owner.paint, .input = .{}, .resized = &Owner.resized, .dismiss = &Owner.dismiss };
    defer host.deinit();
    host.visible = true;
    host.requestHide();
    const pending = host.close_idle;
    host.requestHide();
    try std.testing.expect(pending != 0);
    try std.testing.expectEqual(pending, host.close_idle);
    try std.testing.expectEqual(@as(usize, 0), owner.calls);
    while (host.close_idle != 0) _ = c.g_main_context_iteration(null, 0);
    try std.testing.expectEqual(@as(usize, 1), owner.calls);

    host.requestHide();
    host.hide();
    try std.testing.expect(!host.visible and host.close_idle == 0);
    while (c.g_main_context_iteration(null, 0) != 0) {}
    try std.testing.expectEqual(@as(usize, 1), owner.calls);

    host.requestHide();
    host.deinit();
    while (c.g_main_context_iteration(null, 0) != 0) {}
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
    owner.* = .{ .host = .{ .context = owner, .namespace = "test-popup", .paint = &Owner.paint, .input = .{}, .resized = &Owner.resized, .dismiss = &Owner.dismiss } };
    owner.host.requestHide();
    // The callback frees owner; dispatch must never read its host afterward.
    _ = c.g_main_context_iteration(null, 0);
}
