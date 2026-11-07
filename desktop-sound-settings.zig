//! Native sound controls; GTK provides only the toplevel, canvas and scrolling.
const std = @import("std");
const c = @import("desktop-gtk.zig");
const audio = @import("desktop-audio.zig");
pub const native = @import("desktop-sound-view.zig");
const a = if (@import("builtin").is_test) std.testing.allocator else std.heap.page_allocator;
const cast = c.__zig.cast;
fn connect(widget: anytype, signal: [*:0]const u8, callback: anytype, data: anytype) void {
    _ = c.g_signal_connect_data(widget, signal, @ptrCast(callback), data, null, 0);
}
pub const Sound = struct {
    window: *c.GtkWidget,
    canvas: *c.GtkWidget,
    scroll: *c.GtkWidget,
    view: native.View = .{},
    service: ?*audio.Service = null,
    cancel: *c.GCancellable,
    closed: bool = false,
    operations: usize = 0,
    timer: c.guint = 0,
    layout: ?u64 = null,
    message: ?[:0]u8 = null,
    failed: bool = false,
    refreshing: bool = false,
    flushing: bool = false,
    pub fn create() !*Sound {
        const self = try a.create(Sound);
        errdefer a.destroy(self);
        const window = c.gtk_window_new(c.GTK_WINDOW_TOPLEVEL).?;
        errdefer c.gtk_widget_destroy(window);
        c.gtk_window_set_title(cast(c.GtkWindow, window), "Sound");
        c.gtk_window_set_role(cast(c.GtkWindow, window), "desktop-sound-settings");
        c.gtk_window_set_icon_name(cast(c.GtkWindow, window), "preferences-desktop-sound");
        c.gtk_window_set_default_size(cast(c.GtkWindow, window), 560, 600);
        const scroll = c.gtk_scrolled_window_new(null, null).?;
        c.gtk_scrolled_window_set_policy(cast(c.GtkScrolledWindow, scroll), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
        c.gtk_container_add(cast(c.GtkContainer, window), scroll);
        const canvas = c.gtk_drawing_area_new().?;
        c.gtk_widget_set_can_focus(canvas, 1);
        c.gtk_widget_add_events(canvas, c.GDK_BUTTON_PRESS_MASK | c.GDK_BUTTON_RELEASE_MASK | c.GDK_POINTER_MOTION_MASK | c.GDK_LEAVE_NOTIFY_MASK | c.GDK_KEY_PRESS_MASK | c.GDK_FOCUS_CHANGE_MASK);
        c.gtk_container_add(cast(c.GtkContainer, scroll), canvas);
        self.* = .{ .window = window, .canvas = canvas, .scroll = scroll, .cancel = c.g_cancellable_new().? };
        errdefer {
            c.g_object_unref(self.cancel);
            self.view.deinit(a);
            if (self.message) |message| a.free(message);
        }
        connect(canvas, "draw", &draw, self);
        connect(canvas, "button-press-event", &press, self);
        connect(canvas, "button-release-event", &release, self);
        connect(canvas, "motion-notify-event", &motion, self);
        connect(canvas, "leave-notify-event", &leave, self);
        connect(canvas, "key-press-event", &key, self);
        connect(canvas, "focus-out-event", &focusOut, self);
        self.service = audio.Service.create(&changed, self) catch null;
        errdefer if (self.service) |service| service.destroy();
        try self.refresh();
        connect(window, "destroy", &destroyed, self);
        c.gtk_widget_show_all(window);
        c.gtk_widget_grab_focus(canvas);
        return self;
    }
    pub fn destroy(self: *Sound) void {
        std.debug.assert(self.closed and self.operations == 0);
        c.g_object_unref(self.cancel);
        self.view.deinit(a);
        if (self.message) |message| a.free(message);
        a.destroy(self);
    }
    fn destroyed(_: *c.GtkWidget, ptr: c.gpointer) callconv(.c) void {
        const self = cast(Sound, ptr);
        self.closed = true;
        c.g_cancellable_cancel(self.cancel);
        if (self.timer != 0) _ = c.g_source_remove(self.timer);
        self.timer = 0;
        if (self.service) |service| service.destroy();
        self.service = null;
    }
    fn setMessage(self: *Sound, message: [:0]const u8) !void {
        if (std.mem.eql(u8, self.view.message, message)) return;
        const copy = try a.dupeSentinel(u8, message, 0);
        if (self.message) |old| a.free(old);
        self.message = copy;
        self.view.message = copy;
        if (self.view.message_mask) |mask| mask.deinit(a);
        self.view.message_mask = null;
    }
    fn changed(ptr: ?*anyopaque, _: *audio.Service) void {
        const self = cast(Sound, ptr);
        if (!self.closed) self.refresh() catch self.renderFailure();
    }
    fn renderFailure(self: *Sound) void {
        self.failed = true;
        self.setMessage("Unable to render sound settings") catch {};
        c.gtk_widget_queue_draw(self.canvas);
    }
    fn append(self: *Sound, target: audio.Target, title: [:0]const u8, heading: ?[:0]const u8, device: bool) !void {
        const copy = try a.dupeSentinel(u8, if (std.unicode.utf8ValidateSlice(title)) title else "Unnamed audio device", 0);
        errdefer a.free(copy);
        try self.view.rows.append(a, .{ .target = target, .title = copy, .heading = heading, .device = device });
    }
    pub fn refresh(self: *Sound) !void {
        if (self.closed or self.refreshing or self.flushing) return;
        self.refreshing = true;
        defer self.refreshing = false;
        const service = self.service orelse {
            try self.setMessage("Audio service unavailable");
            c.gtk_widget_set_size_request(self.canvas, 480, 200);
            c.gtk_widget_queue_draw(self.canvas);
            return;
        };
        var hash = std.hash.Wyhash.init(0);
        for (service.nodes.items) |entry| {
            hash.update(std.mem.asBytes(&entry.id));
            hash.update(std.mem.asBytes(&entry.class));
            hash.update(std.mem.sliceTo(&entry.title, 0));
            hash.update(std.mem.sliceTo(&entry.name, 0));
        }
        const layout = hash.final();
        if (self.layout == null or self.layout.? != layout) {
            // Keep debounced writes attached to their old IDs before rebuilding.
            self.flushVolumes();
            self.view.invalidate(a);
            for (self.view.rows.items) |row| a.free(row.title);
            self.view.rows.clearRetainingCapacity();
            self.layout = null;
            self.view.focus = null;
            self.view.hover = null;
            self.view.pressed = null;
            try self.append(.output, "Output volume", null, false);
            try self.append(.input, "Microphone volume", null, false);
            for ([_]audio.Class{ .output, .input, .playback, .recording }, [_][:0]const u8{ "Output devices", "Input devices", "Playback applications", "Recording applications" }) |class, heading| {
                var count: usize = 0;
                for (service.nodes.items) |*entry| {
                    if (entry.class != class) continue;
                    try self.append(.{ .id = entry.id }, std.mem.sliceTo(&entry.title, 0), if (count == 0) heading else null, class == .output or class == .input);
                    count += 1;
                }
                if (count == 0) try self.append(.{ .id = std.math.maxInt(u32) }, "None available", heading, false);
            }
            self.layout = layout;
        }
        for (self.view.rows.items) |*row| {
            row.state = service.state(row.target);
            row.is_default = if (service.node(row.target)) |node| node.is_default else false;
        }
        if (!service.ready) try self.setMessage("Audio service unavailable") else if (!self.failed) try self.setMessage("");
        c.gtk_widget_set_size_request(self.canvas, 480, @intCast(self.view.height()));
        c.gtk_widget_queue_draw(self.canvas);
    }
    pub fn setVolume(self: *Sound, index: usize, value: f64) void {
        const target: native.Target = .{ .row = index };
        if (self.closed or !self.view.active(target) or !std.math.isFinite(value)) return;
        const service = self.service orelse return;
        const node = service.node(self.view.rows.items[index].target) orelse return;
        self.view.rows.items[index].pending_target = .{ .id = node.id };
        self.view.rows.items[index].pending = @round(std.math.clamp(value, 0, 100));
        if (self.timer != 0) _ = c.g_source_remove(self.timer);
        self.timer = c.g_timeout_add(150, &volumeTimeout, self);
        c.gtk_widget_queue_draw(self.canvas);
    }
    fn volumeTimeout(ptr: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Sound, ptr);
        self.timer = 0;
        self.flushVolumes();
        return 0;
    }
    fn flushVolumes(self: *Sound) void {
        if (self.timer != 0) _ = c.g_source_remove(self.timer);
        self.timer = 0;
        // Rejected writes may complete synchronously; keep row storage stable.
        self.flushing = true;
        defer self.flushing = false;
        for (self.view.rows.items) |*row| if (row.pending) |value| {
            const target = row.pending_target orelse row.target;
            row.pending = null;
            row.pending_target = null;
            self.apply(target, .{ .volume = value });
        };
    }
    pub fn activate(self: *Sound, target: native.Target) void {
        if (self.closed or !self.view.active(target)) return;
        const row = self.view.rows.items[target.row];
        switch (target.control) {
            .volume => {},
            .mute => self.apply(row.target, .{ .mute = !row.state.?.muted }),
            .default => self.apply(row.target, .default),
        }
    }
    fn apply(self: *Sound, target: audio.Target, change: audio.Change) void {
        if (self.closed) return;
        const service = self.service orelse return;
        self.failed = false;
        self.operations += 1;
        service.apply(target, change, self.cancel, &done, self);
    }
    fn done(ptr: ?*anyopaque, result: audio.Result) void {
        const self = cast(Sound, ptr);
        self.operations -= 1;
        if (self.closed) return;
        switch (result) {
            .failure => |err| {
                self.failed = true;
                self.setMessage(@errorName(err)) catch {};
            },
            .value => {
                if (c.g_application_get_default()) |app| if (c.g_application_get_dbus_connection(app)) |bus| {
                    _ = c.g_dbus_connection_emit_signal(bus, null, "/org/dotfiles/DesktopSettings", "org.dotfiles.DesktopSettings", "DeviceChanged", null, null);
                };
            },
        }
        self.refresh() catch self.renderFailure();
        c.gtk_widget_queue_draw(self.canvas);
    }
    fn draw(_: *c.GtkWidget, cr: *c.cairo_t, ptr: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Sound, ptr);
        self.paint(cr) catch {
            self.failed = true;
            // Avoid repeatedly scheduling a draw when allocating a frame fails.
        };
        return 1;
    }
    fn paint(self: *Sound, cr: *c.cairo_t) !void {
        const scale: u32 = @intCast(@max(1, c.gtk_widget_get_scale_factor(self.canvas)));
        const width: u32 = @intCast(@max(480, c.gtk_widget_get_allocated_width(self.canvas)));
        if (self.view.width != width) {
            self.view.invalidate(a);
            self.view.width = width;
        }
        try self.view.prepare(a, scale);
        const height: u32 = @intCast(@max(@as(c_int, @intCast(self.view.height())), c.gtk_widget_get_allocated_height(self.canvas)));
        try c.__zig.paintCairo(cr, width, height, scale, &self.view, native.View.paint);
    }
    fn focus(self: *Sound) void {
        if (self.view.focus) |target| {
            const rect = self.view.rect(target);
            c.gtk_adjustment_clamp_page(c.gtk_scrolled_window_get_vadjustment(cast(c.GtkScrolledWindow, self.scroll)), rect.y - 36, rect.y + rect.height + 8);
        }
        c.gtk_widget_queue_draw(self.canvas);
    }
    fn press(_: *c.GtkWidget, event: *c.GdkEventButton, ptr: c.gpointer) callconv(.c) c.gboolean {
        if (event.button != 1) return 0;
        const self = cast(Sound, ptr);
        const target = self.view.hit(event.x, event.y);
        self.view.pressed = target;
        self.view.focus = target;
        self.view.hover = target;
        self.view.keyboard_focus = false;
        c.gtk_widget_grab_focus(self.canvas);
        if (target) |t| if (t.control == .volume) self.setVolume(t.row, self.view.percent(t, event.x));
        c.gtk_widget_queue_draw(self.canvas);
        return 1;
    }
    fn release(_: *c.GtkWidget, event: *c.GdkEventButton, ptr: c.gpointer) callconv(.c) c.gboolean {
        if (event.button != 1) return 0;
        const self = cast(Sound, ptr);
        const pressed = self.view.pressed;
        self.view.pressed = null;
        if (pressed) |target| {
            if (target.control == .volume) {
                self.setVolume(target.row, self.view.percent(target, event.x));
                self.flushVolumes();
            } else if (self.view.hit(event.x, event.y)) |hit| if (hit.eql(target)) self.activate(target);
        }
        c.gtk_widget_queue_draw(self.canvas);
        return 1;
    }
    fn motion(_: *c.GtkWidget, event: *c.GdkEventMotion, ptr: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Sound, ptr);
        self.view.hover = self.view.hit(event.x, event.y);
        if (self.view.pressed) |target| if (target.control == .volume) self.setVolume(target.row, self.view.percent(target, event.x));
        c.gtk_widget_queue_draw(self.canvas);
        return 1;
    }
    fn leave(_: *c.GtkWidget, _: *c.GdkEventCrossing, ptr: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Sound, ptr);
        self.view.hover = null;
        c.gtk_widget_queue_draw(self.canvas);
        return 0;
    }
    fn focusOut(_: *c.GtkWidget, _: *c.GdkEvent, ptr: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Sound, ptr);
        self.view.pressed = null;
        self.view.keyboard_focus = false;
        c.gtk_widget_queue_draw(self.canvas);
        return 0;
    }
    fn key(_: *c.GtkWidget, event: *c.GdkEvent, ptr: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Sound, ptr);
        var symbol: c.guint = 0;
        var modifiers: c.GdkModifierType = 0;
        _ = c.gdk_event_get_keyval(event, &symbol);
        _ = c.gdk_event_get_state(event, &modifiers);
        return @intFromBool(self.handleKey(symbol, modifiers));
    }
    pub fn handleKey(self: *Sound, symbol: u32, modifiers: c.GdkModifierType) bool {
        if (self.closed) return false;
        switch (symbol) {
            0xff1b => c.gtk_widget_destroy(self.window), // Escape
            0xff09, 0xfe20 => { // Tab / Shift-Tab
                self.view.moveFocus(modifiers & c.GDK_SHIFT_MASK != 0 or symbol == 0xfe20);
                self.focus();
            },
            0x20, 0xff0d, 0xff8d => if (self.view.focus) |target| self.activate(target),
            0xff51, 0xff53, 0xff52, 0xff54, 0xff50, 0xff57 => {
                const target = self.view.focus orelse return false;
                if (target.control != .volume or !self.view.active(target)) return false;
                const row = self.view.rows.items[target.row];
                const current = row.pending orelse row.state.?.percent;
                const value = switch (symbol) {
                    0xff50 => @as(f64, 0),
                    0xff57 => @as(f64, 100),
                    0xff51, 0xff54 => current - 5,
                    else => current + 5,
                };
                self.view.keyboard_focus = true;
                self.setVolume(target.row, value);
            },
            else => return false,
        }
        return true;
    }
};
