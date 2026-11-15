//! Native Wayland calendar and notification-history popup.
const std = @import("std");
const c = @import("desktop-gtk.zig");
const wire = @import("desktop-surface.zig");
const raster = @import("desktop-raster.zig");
pub const native = @import("desktop-date-menu-view.zig");
const a = if (@import("builtin").is_test) std.testing.allocator else std.heap.page_allocator;
const cast = c.__zig.cast;
pub const Callbacks = struct {
    context: ?*anyopaque,
    clear: *const fn (?*anyopaque) void,
    dismiss: *const fn (?*anyopaque, u32) void,
    activate: *const fn (?*anyopaque, u32, [:0]const u8) void,
    closed: ?*const fn (?*anyopaque) void = null,
};

// Coordinates are output-local logical pixels, independent of buffer scale.
fn placement(width: i32, height: i32, x: i32, y: i32) raster.Rect {
    const available_width: f64 = @floatFromInt(@max(1, width - 16));
    const available_height: f64 = @floatFromInt(@max(1, height - 16));
    const zoom = @min(1, @min(available_width / 752, available_height / 420));
    const w = 752 * zoom;
    const h = 420 * zoom;
    return .{
        .x = @floor(std.math.clamp(@as(f64, @floatFromInt(x)) - w / 2, 8, @max(8, @as(f64, @floatFromInt(width)) - w - 8))),
        .y = @floor(std.math.clamp(@as(f64, @floatFromInt(y)), 8, @max(8, @as(f64, @floatFromInt(height)) - h - 8))),
        .width = w,
        .height = h,
    };
}

pub const Controls = struct {
    client: ?*wire.Client = null,
    surface: ?*wire.Surface = null,
    view: native.View,
    callbacks: Callbacks,
    pixels: std.ArrayList(u32) = .empty,
    visible: bool = false,
    close_idle: c.guint = 0,
    anchor_x: i32 = 0,
    anchor_y: i32 = 0,
    bounds: raster.Rect = .{},
    pointer_x: f64 = 0,
    pointer_y: f64 = 0,
    scroll_grab: ?f64 = null,

    pub fn create(callbacks: Callbacks) !*Controls {
        const self = try a.create(Controls);
        errdefer a.destroy(self);
        var view = try native.View.init(a);
        errdefer view.deinit();
        try view.prepare(1);
        self.* = .{ .view = view, .callbacks = callbacks };
        return self;
    }
    pub fn destroy(self: *Controls) void {
        self.visible = false;
        if (self.close_idle != 0) _ = c.g_source_remove(self.close_idle);
        if (self.client) |client| client.destroy();
        self.pixels.deinit(a);
        self.view.deinit();
        a.destroy(self);
    }
    pub fn show(self: *Controls, global_x: i32, global_y: i32) !void {
        if (self.client == null) {
            self.client = try wire.Client.createInteractive(.{ .added = &added, .removed = &removed, .changed = &outputChanged }, self);
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
                .namespace = "desktop-date-menu",
                .layer = 3,
                .anchors = wire.top | wire.bottom | wire.left | wire.right,
                .interactive = true,
                .keyboard = .exclusive,
                .cursor = .arrow,
            }, &draw, self);
            self.surface.?.input = .{ .motion = &motion, .button = &button, .leave = &leave, .symbol = &key, .scroll = &scroll };
        }
        if (self.close_idle != 0) _ = c.g_source_remove(self.close_idle);
        self.close_idle = 0;
        self.anchor_x = global_x;
        self.anchor_y = global_y;
        self.updateBounds();
        self.visible = true;
        errdefer self.visible = false;
        try self.surface.?.show();
    }
    pub fn hide(self: *Controls) void {
        if (self.close_idle != 0) _ = c.g_source_remove(self.close_idle);
        self.close_idle = 0;
        const was_visible = self.visible;
        self.visible = false;
        self.scroll_grab = null;
        self.view.pressed = .none;
        self.view.hover = .none;
        if (self.surface) |surface| surface.hide();
        if (was_visible) if (self.callbacks.closed) |callback| callback(self.callbacks.context);
    }
    fn requestHide(self: *Controls) void {
        // Owner callbacks may destroy the controller and its Wayland client.
        if (self.close_idle == 0) self.close_idle = c.g_idle_add(&hideIdle, self);
    }
    fn hideIdle(ptr: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast(Controls, ptr);
        self.close_idle = 0;
        self.hide();
        return 0;
    }
    fn added(_: ?*anyopaque, _: *wire.Output) void {}
    fn removed(ptr: ?*anyopaque, output: *wire.Output) void {
        const self = cast(Controls, ptr);
        if (self.surface) |surface| if (surface.output == output) {
            self.surface = null; // Client revokes the removed output's surfaces.
            if (self.visible) self.requestHide();
        };
    }
    fn outputChanged(ptr: ?*anyopaque, output: *wire.Output) void {
        const self = cast(Controls, ptr);
        if (self.surface) |surface| if (surface.output == output) {
            self.updateBounds();
            self.redraw();
        };
    }
    fn updateBounds(self: *Controls) void {
        const output = (self.surface orelse return).output;
        self.bounds = placement(output.width(), output.height(), self.anchor_x - output.x, self.anchor_y - output.y);
    }
    pub fn reset(self: *Controls) void {
        self.view.navigate(0);
        self.view.prepare(self.scale()) catch |err| return self.failed(err);
        self.view.focus = .{ .day = self.view.selectedIndex() };
        self.view.keyboard_focus = true;
        self.redraw();
    }
    pub fn load(self: *Controls, raw: []const u8) void {
        self.view.load(raw) catch |err| return self.failed(err);
        self.redraw();
    }
    pub fn tick(self: *Controls) void {
        if (!self.visible) return;
        if (self.client.?.failed or self.surface == null or self.surface.?.role == null) {
            self.requestHide();
            return;
        }
        if (self.view.minute != @divTrunc(c.g_get_real_time(), 60_000_000)) self.redraw();
    }
    fn redraw(self: *Controls) void {
        if (self.visible and self.close_idle == 0) if (self.surface) |surface| surface.redraw();
    }
    fn scale(self: *const Controls) u32 {
        return if (self.surface) |surface| surface.output.scale else 1;
    }
    fn failed(self: *Controls, err: anyerror) void {
        std.log.err("date menu: {s}", .{@errorName(err)});
        if (self.visible) self.requestHide();
    }
    fn deliver(self: *Controls, value: native.Effect) void {
        switch (value) {
            .none => {},
            .clear => self.callbacks.clear(self.callbacks.context),
            .dismiss => |id| self.callbacks.dismiss(self.callbacks.context, id),
            .activate => |action| self.callbacks.activate(self.callbacks.context, action.id, action.key),
        }
    }
    pub fn activate(self: *Controls, target: native.Target) void {
        const effect = self.view.activate(target) catch |err| return self.failed(err);
        self.redraw();
        self.deliver(effect);
    }
    pub fn handleKey(self: *Controls, symbol: u32, modifiers: u32) bool {
        if (self.close_idle != 0) return true;
        if (symbol == 0xff1b) {
            self.requestHide();
            return true;
        }
        switch (symbol) {
            0xff09, 0xfe20, 0xff0d, 0xff8d, 0x20, 0xff55, 0xff56, 0xff50, 0xff51, 0xff52, 0xff53, 0xff54 => {},
            else => return false,
        }
        const effect = self.view.key(symbol, modifiers & c.GDK_SHIFT_MASK != 0) catch |err| {
            self.failed(err);
            return true;
        };
        self.redraw();
        self.deliver(effect);
        return true;
    }
    fn draw(ptr: ?*anyopaque, target: wire.Pixels) void {
        const self = cast(Controls, ptr);
        @memset(target.pixels, 0);
        self.paint(target) catch |err| self.failed(err);
    }
    fn paint(self: *Controls, target: wire.Pixels) !void {
        const factor = self.surface.?.buffer_scale;
        self.updateBounds();
        try self.view.prepare(factor);
        const width = self.view.width * factor;
        const height = self.view.height * factor;
        try self.pixels.resize(a, @as(usize, width) * height);
        try self.view.paint(.{ .pixels = self.pixels.items, .width = width, .height = height });
        try raster.blit(target, .{ .pixels = std.mem.sliceAsBytes(self.pixels.items), .width = width, .height = height, .stride = width * 4, .format = .argb }, .{
            .x = self.bounds.x * @as(f64, @floatFromInt(factor)),
            .y = self.bounds.y * @as(f64, @floatFromInt(factor)),
            .width = self.bounds.width * @as(f64, @floatFromInt(factor)),
            .height = self.bounds.height * @as(f64, @floatFromInt(factor)),
        }, null);
    }
    fn point(self: *Controls, x: f64, y: f64) void {
        const zoom = self.bounds.width / @as(f64, @floatFromInt(self.view.width));
        self.pointer_x = (x - self.bounds.x) / zoom;
        self.pointer_y = (y - self.bounds.y) / zoom;
    }
    fn button(ptr: ?*anyopaque, _: *wire.Surface, code: u32, pressed: bool, x: f64, y: f64) void {
        if (code != 272) return;
        const self = cast(Controls, ptr);
        if (!self.visible or self.close_idle != 0) return;
        if (pressed and !self.bounds.contains(x, y)) {
            self.requestHide();
            return;
        }
        self.point(x, y);
        if (pressed) {
            self.view.keyboard_focus = false;
            self.view.hover = self.view.hit(self.pointer_x, self.pointer_y);
            self.view.pressed = self.view.hover;
            if (self.view.pressed != .none) self.view.focus = self.view.pressed;
            if (self.view.pressed == .scrollbar) {
                const thumb = self.view.scrollbarRect();
                self.scroll_grab = if (self.pointer_y >= thumb.y and self.pointer_y < thumb.y + thumb.height) self.pointer_y - thumb.y else thumb.height / 2;
                self.view.dragScroll(self.pointer_y, self.scroll_grab.?);
            }
        } else {
            if (self.scroll_grab != null) {
                self.scroll_grab = null;
                self.view.pressed = .none;
                self.redraw();
                return;
            }
            const target = self.view.pressed;
            self.view.pressed = .none;
            self.redraw();
            if (target != .none and std.meta.eql(target, self.view.hit(self.pointer_x, self.pointer_y))) self.activate(target);
            return;
        }
        self.redraw();
    }
    fn motion(ptr: ?*anyopaque, _: *wire.Surface, x: f64, y: f64) void {
        const self = cast(Controls, ptr);
        if (!self.visible or self.close_idle != 0) return;
        self.point(x, y);
        const previous = self.view.hover;
        const previous_scroll = self.view.scroll;
        if (self.scroll_grab) |grab| self.view.dragScroll(self.pointer_y, grab);
        self.view.hover = self.view.hit(self.pointer_x, self.pointer_y);
        if (!std.meta.eql(previous, self.view.hover) or self.view.scroll != previous_scroll) self.redraw();
    }
    fn leave(ptr: ?*anyopaque, _: *wire.Surface) void {
        const self = cast(Controls, ptr);
        self.view.hover = .none;
        self.redraw();
    }
    fn key(ptr: ?*anyopaque, _: *wire.Surface, symbol: u32, modifiers: u32, pressed: bool) bool {
        return !pressed or cast(Controls, ptr).handleKey(symbol, modifiers);
    }
    fn scroll(ptr: ?*anyopaque, _: *wire.Surface, axis: u32, amount: f64) void {
        const self = cast(Controls, ptr);
        if (!self.visible or self.close_idle != 0 or axis != 0 or !self.view.historyRect().contains(self.pointer_x, self.pointer_y)) return;
        self.view.scrollBy(amount * 4);
        self.redraw();
    }
};

test "date popup placement fits output edges and small screens in logical coordinates" {
    const center = placement(1728, 1080, 864, 32);
    try std.testing.expectEqual(raster.Rect{ .x = 488, .y = 32, .width = 752, .height = 420 }, center);
    const corner = placement(1728, 1080, 1728, 1079);
    try std.testing.expectEqual(@as(f64, 968), corner.x);
    try std.testing.expectEqual(@as(f64, 652), corner.y);
    const small = placement(640, 360, 320, 32);
    try std.testing.expect(small.x >= 8 and small.y >= 8);
    try std.testing.expect(small.x + small.width <= 632 and small.y + small.height <= 352);
    try std.testing.expectApproxEqAbs(@as(f64, 752.0 / 420.0), small.width / small.height, 0.000001);
}
