//! GTK popup host for the native calendar and notification history canvas.
const std = @import("std");
const c = @import("desktop-gtk.zig");
pub const native = @import("desktop-date-menu-view.zig");
const a = if (@import("builtin").is_test) std.testing.allocator else std.heap.page_allocator;
const cast = c.__zig.cast;
pub const Callbacks = struct {
    context: ?*anyopaque,
    clear: *const fn (?*anyopaque) void,
    dismiss: *const fn (?*anyopaque, u32) void,
    activate: *const fn (?*anyopaque, u32, [:0]const u8) void,
};
pub const Controls = struct {
    popover: *c.GtkWidget,
    canvas: *c.GtkWidget,
    view: native.View,
    callbacks: Callbacks,
    scroll_grab: ?f64 = null,

    pub fn create(popover: *c.GtkWidget, callbacks: Callbacks) !*Controls {
        const self = try a.create(Controls);
        errdefer a.destroy(self);
        var view = try native.View.init(a);
        errdefer view.deinit();
        try view.prepare(1);
        const canvas = c.gtk_drawing_area_new().?;
        self.* = .{ .popover = popover, .canvas = canvas, .view = view, .callbacks = callbacks };
        c.gtk_widget_set_size_request(canvas, @intCast(view.width), @intCast(view.height));
        c.gtk_widget_set_can_focus(canvas, 1);
        c.gtk_widget_add_events(canvas, c.GDK_BUTTON_PRESS_MASK | c.GDK_BUTTON_RELEASE_MASK | c.GDK_POINTER_MOTION_MASK | c.GDK_LEAVE_NOTIFY_MASK | c.GDK_KEY_PRESS_MASK | c.GDK_SCROLL_MASK | c.GDK_SMOOTH_SCROLL_MASK);
        c.gtk_container_add(cast(c.GtkContainer, popover), canvas);
        connect(canvas, "draw", &draw, self);
        connect(canvas, "button-press-event", &press, self);
        connect(canvas, "button-release-event", &release, self);
        connect(canvas, "motion-notify-event", &motion, self);
        connect(canvas, "leave-notify-event", &leave, self);
        connect(canvas, "key-press-event", &key, self);
        connect(canvas, "scroll-event", &scroll, self);
        connect(popover, "map", &mapped, self);
        connect(popover, "closed", &closed, self);
        c.gtk_widget_show_all(canvas);
        return self;
    }
    pub fn destroy(self: *Controls) void {
        _ = c.g_signal_handlers_disconnect_matched(self.popover, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
        _ = c.g_signal_handlers_disconnect_matched(self.canvas, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
        self.view.deinit();
        a.destroy(self);
    }
    pub fn reset(self: *Controls) void {
        self.view.navigate(0);
        self.view.prepare(self.scale()) catch |err| {
            self.failed(err);
            return;
        };
        self.view.focus = .{ .day = self.view.selectedIndex() };
        self.view.keyboard_focus = true;
        self.redraw();
    }
    pub fn load(self: *Controls, raw: []const u8) void {
        self.view.load(raw) catch |err| {
            self.failed(err);
            return;
        };
        self.redraw();
    }
    pub fn tick(self: *Controls) void {
        if (c.gtk_widget_get_visible(self.popover) != 0 and self.view.minute != @divTrunc(c.g_get_real_time(), 60_000_000)) self.redraw();
    }
    fn redraw(self: *Controls) void {
        c.gtk_widget_queue_draw(self.canvas);
    }
    fn scale(self: *const Controls) u32 {
        return @intCast(@max(1, c.gtk_widget_get_scale_factor(self.canvas)));
    }
    fn failed(self: *Controls, err: anyerror) void {
        std.log.err("date menu: {s}", .{@errorName(err)});
        c.gtk_popover_popdown(cast(c.GtkPopover, self.popover));
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
        const effect = self.view.activate(target) catch |err| {
            self.failed(err);
            return;
        };
        self.redraw();
        self.deliver(effect);
    }
    pub fn handleKey(self: *Controls, symbol: u32, modifiers: c.GdkModifierType) bool {
        if (symbol == 0xff1b) {
            c.gtk_popover_popdown(cast(c.GtkPopover, self.popover));
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
    fn draw(_: *c.GtkWidget, cr: *c.cairo_t, ptr: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Controls, ptr);
        self.paint(cr) catch |err| self.failed(err);
        return 1;
    }
    fn paint(self: *Controls, cr: *c.cairo_t) !void {
        const factor = self.scale();
        try self.view.prepare(factor);
        const width: u32 = @intCast(@max(@as(c_int, @intCast(self.view.width)), c.gtk_widget_get_allocated_width(self.canvas)));
        const height: u32 = @intCast(@max(@as(c_int, @intCast(self.view.height)), c.gtk_widget_get_allocated_height(self.canvas)));
        try c.__zig.paintCairo(cr, width, height, factor, &self.view, native.View.paint);
    }
    fn press(_: *c.GtkWidget, event: *c.GdkEventButton, ptr: c.gpointer) callconv(.c) c.gboolean {
        if (event.button != 1) return 0;
        const self = cast(Controls, ptr);
        c.gtk_widget_grab_focus(self.canvas);
        self.view.keyboard_focus = false;
        self.view.hover = self.view.hit(event.x, event.y);
        self.view.pressed = self.view.hover;
        if (self.view.pressed != .none) self.view.focus = self.view.pressed;
        if (self.view.pressed == .scrollbar) {
            const thumb = self.view.scrollbarRect();
            self.scroll_grab = if (event.y >= thumb.y and event.y < thumb.y + thumb.height) event.y - thumb.y else thumb.height / 2;
            self.view.dragScroll(event.y, self.scroll_grab.?);
        }
        self.redraw();
        return 1;
    }
    fn release(_: *c.GtkWidget, event: *c.GdkEventButton, ptr: c.gpointer) callconv(.c) c.gboolean {
        if (event.button != 1) return 0;
        const self = cast(Controls, ptr);
        if (self.scroll_grab != null) {
            self.scroll_grab = null;
            self.view.pressed = .none;
            self.redraw();
            return 1;
        }
        const target = self.view.pressed;
        self.view.pressed = .none;
        self.redraw();
        if (target != .none and std.meta.eql(target, self.view.hit(event.x, event.y))) self.activate(target);
        return 1;
    }
    fn motion(_: *c.GtkWidget, event: *c.GdkEventMotion, ptr: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Controls, ptr);
        const previous = self.view.hover;
        const previous_scroll = self.view.scroll;
        if (self.scroll_grab) |grab| self.view.dragScroll(event.y, grab);
        self.view.hover = self.view.hit(event.x, event.y);
        if (!std.meta.eql(previous, self.view.hover) or self.view.scroll != previous_scroll) self.redraw();
        return 1;
    }
    fn leave(_: *c.GtkWidget, _: *c.GdkEventCrossing, ptr: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Controls, ptr);
        self.view.hover = .none;
        self.redraw();
        return 0;
    }
    fn key(_: *c.GtkWidget, event: *c.GdkEvent, ptr: c.gpointer) callconv(.c) c.gboolean {
        var symbol: c.guint = 0;
        var modifiers: c.GdkModifierType = 0;
        _ = c.gdk_event_get_keyval(event, &symbol);
        _ = c.gdk_event_get_state(event, &modifiers);
        return @intFromBool(cast(Controls, ptr).handleKey(symbol, modifiers));
    }
    fn scroll(_: *c.GtkWidget, event: *c.GdkEvent, ptr: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Controls, ptr);
        var x: f64 = 0;
        var y: f64 = 0;
        var dx: f64 = 0;
        var dy: f64 = 0;
        _ = c.gdk_event_get_coords(event, &x, &y);
        if (!self.view.historyRect().contains(x, y)) return 0;
        if (c.gdk_event_get_scroll_deltas(event, &dx, &dy) == 0) {
            var direction: c.GdkScrollDirection = 0;
            _ = c.gdk_event_get_scroll_direction(event, &direction);
            if (direction != c.GDK_SCROLL_UP and direction != 1) return 0;
            dy = if (direction == c.GDK_SCROLL_UP) -1 else 1;
        }
        self.view.scrollBy(dy * 40);
        self.redraw();
        return 1;
    }
    fn mapped(_: *c.GtkWidget, ptr: c.gpointer) callconv(.c) void {
        const self = cast(Controls, ptr);
        c.gtk_widget_grab_focus(self.canvas);
    }
    fn closed(_: *c.GtkPopover, ptr: c.gpointer) callconv(.c) void {
        const self = cast(Controls, ptr);
        self.scroll_grab = null;
        self.view.pressed = .none;
        self.view.hover = .none;
    }
};
fn connect(widget: anytype, signal: [*:0]const u8, callback: anytype, ptr: anytype) void {
    _ = c.g_signal_connect_data(widget, signal, @ptrCast(callback), ptr, null, 0);
}
