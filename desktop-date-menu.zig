//! Native Wayland calendar and notification-history popup.
const std = @import("std");
const c = @import("desktop-glib.zig");
const wire = @import("desktop-surface.zig");
const popup = @import("desktop-popup.zig");
pub const native = @import("desktop-date-menu-view.zig");
const cast = c.__zig.cast;
pub const Callbacks = struct {
    context: ?*anyopaque,
    clear: *const fn (?*anyopaque) void,
    dismiss: *const fn (?*anyopaque, u32) void,
    activate: *const fn (?*anyopaque, u32, [:0]const u8) void,
    closed: ?*const fn (?*anyopaque) void = null,
};

pub const Controls = struct {
    allocator: std.mem.Allocator,
    popup: popup.Host = undefined,
    view: native.View,
    callbacks: Callbacks,
    pointer_x: f64 = 0,
    pointer_y: f64 = 0,
    scroll_grab: ?f64 = null,

    pub fn create(a: std.mem.Allocator, callbacks: Callbacks) !*Controls {
        const self = try a.create(Controls);
        errdefer a.destroy(self);
        var view = try native.View.init(a);
        errdefer view.deinit();
        try view.prepare(1);
        self.* = .{ .allocator = a, .view = view, .callbacks = callbacks };
        self.popup = .{
            .allocator = a,
            .context = self,
            .namespace = "desktop-date-menu",
            .paint = &draw,
            .input = .{ .motion = &motion, .button = &button, .leave = &leave, .symbol = &key, .scroll = &scroll },
            .resized = &resized,
            .dismiss = &dismiss,
        };
        return self;
    }
    pub fn destroy(self: *Controls) void {
        self.popup.deinit();
        self.view.deinit();
        self.allocator.destroy(self);
    }
    pub fn show(self: *Controls, global_x: i32, global_y: i32) !void {
        try self.popup.prepare(global_x, global_y);
        self.popup.place(self.view.width, self.view.height);
        try self.popup.show();
    }
    pub fn hide(self: *Controls) void {
        const was_visible = self.popup.visible;
        self.scroll_grab = null;
        self.view.pressed = .none;
        self.view.hover = .none;
        self.popup.hide();
        if (was_visible) if (self.callbacks.closed) |callback| callback(self.callbacks.context);
    }
    fn requestHide(self: *Controls) void {
        self.popup.requestHide();
    }
    fn dismiss(ptr: ?*anyopaque) void {
        cast(Controls, ptr).hide();
    }
    fn resized(ptr: ?*anyopaque) void {
        const self = cast(Controls, ptr);
        self.popup.place(self.view.width, self.view.height);
        self.redraw();
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
        if (!self.popup.visible) return;
        if (self.popup.client.?.failed or self.popup.surface == null or self.popup.surface.?.role == null) {
            self.requestHide();
            return;
        }
        if (self.view.minute != @divTrunc(c.__zig.realTime(), 60_000_000)) self.redraw();
    }
    fn redraw(self: *Controls) void {
        self.popup.redraw();
    }
    fn scale(self: *const Controls) u32 {
        return if (self.popup.surface) |surface| surface.output.scale else 1;
    }
    fn failed(self: *Controls, err: anyerror) void {
        std.log.err("date menu: {s}", .{@errorName(err)});
        if (self.popup.visible) self.requestHide();
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
        if (self.popup.close_idle != 0) return true;
        if (symbol == 0xff1b) {
            self.requestHide();
            return true;
        }
        switch (symbol) {
            0xff09, 0xfe20, 0xff0d, 0xff8d, 0x20, 0xff55, 0xff56, 0xff50, 0xff51, 0xff52, 0xff53, 0xff54 => {},
            else => return false,
        }
        const effect = self.view.key(symbol, modifiers & c.__zig.shift_mask != 0) catch |err| {
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
        try self.view.prepare(self.popup.surface.?.buffer_scale);
        try self.view.paint(try self.popup.canvas(self.view.width, self.view.height));
        try self.popup.blit(target);
    }
    fn point(self: *Controls, x: f64, y: f64) void {
        const local = self.popup.point(x, y);
        self.pointer_x = local.x;
        self.pointer_y = local.y;
    }
    fn button(ptr: ?*anyopaque, _: *wire.Surface, code: u32, pressed: bool, x: f64, y: f64) void {
        if (code != 272) return;
        const self = cast(Controls, ptr);
        if (!self.popup.visible or self.popup.close_idle != 0) return;
        if (pressed and !self.popup.contains(x, y)) {
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
        if (!self.popup.visible or self.popup.close_idle != 0) return;
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
        if (!self.popup.visible or self.popup.close_idle != 0 or axis != 0 or !self.view.historyRect().contains(self.pointer_x, self.pointer_y)) return;
        self.view.scrollBy(amount * 4);
        self.redraw();
    }
};
