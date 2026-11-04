//! OpenSSH askpass protocol with native pixels and a locked, masked text entry.
const std = @import("std");
pub const c = @import("desktop-gtk.zig");
const libc = @import("desktop-libc.zig");
pub const native = @import("desktop-askpass-view.zig");
pub const password = @import("desktop-password-entry.zig");
pub const Mode = native.Mode;
const a = if (@import("builtin").is_test) std.testing.allocator else std.heap.page_allocator;
const cast = c.__zig.cast;
fn connect(widget: anytype, signal: [*:0]const u8, callback: anytype, data: anytype) void {
    _ = c.g_signal_connect_data(widget, signal, @ptrCast(callback), data, null, 0);
}

pub const Dialog = struct {
    window: *c.GtkWidget,
    canvas: *c.GtkWidget,
    scroll: *c.GtkWidget,
    prompt: [:0]u8,
    entry: ?*password.Entry = null,
    mode: Mode,
    view: native.View,
    accepted: bool = false,
    failed: bool = false,

    pub fn create(mode: Mode, prompt_text: [:0]const u8) !*Dialog {
        const self = try a.create(Dialog);
        errdefer a.destroy(self);
        const prompt = try a.dupeSentinel(u8, prompt_text, 0);
        errdefer a.free(prompt);
        var view = native.View.init(mode);
        errdefer view.deinit(a);
        try view.prepare(a, prompt, 1);
        const window = c.gtk_dialog_new().?;
        errdefer c.gtk_widget_destroy(window);
        c.gtk_window_set_title(cast(c.GtkWindow, window), "SSH Authentication");
        c.gtk_window_set_role(cast(c.GtkWindow, window), "desktop-askpass");
        c.gtk_window_set_type_hint(cast(c.GtkWindow, window), c.GDK_WINDOW_TYPE_HINT_DIALOG);
        c.gtk_window_set_icon_name(cast(c.GtkWindow, window), "dialog-password");
        c.gtk_window_set_modal(cast(c.GtkWindow, window), 1);
        c.gtk_window_set_keep_above(cast(c.GtkWindow, window), 1);
        c.gtk_window_set_resizable(cast(c.GtkWindow, window), 0);
        c.gtk_window_set_position(cast(c.GtkWindow, window), c.GTK_WIN_POS_CENTER);
        c.gtk_window_set_default_size(cast(c.GtkWindow, window), 460, -1);
        c.gtk_dialog_set_default_response(cast(c.GtkDialog, window), if (mode == .confirm) c.GTK_RESPONSE_CANCEL else c.GTK_RESPONSE_OK);
        const actions = c.gtk_dialog_get_action_area(cast(c.GtkDialog, window));
        c.gtk_widget_set_no_show_all(actions, 1);
        c.gtk_widget_hide(actions);
        const content = c.gtk_dialog_get_content_area(cast(c.GtkDialog, window));
        c.gtk_container_set_border_width(cast(c.GtkContainer, content), 0);
        c.gtk_box_set_spacing(cast(c.GtkBox, content), 0);
        const scroll = c.gtk_scrolled_window_new(null, null).?;
        c.gtk_scrolled_window_set_policy(cast(c.GtkScrolledWindow, scroll), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
        c.gtk_scrolled_window_set_propagate_natural_height(cast(c.GtkScrolledWindow, scroll), 1);
        c.gtk_scrolled_window_set_max_content_height(cast(c.GtkScrolledWindow, scroll), 640);
        c.gtk_box_pack_start(cast(c.GtkBox, content), scroll, 1, 1, 0);
        const canvas = c.gtk_drawing_area_new().?;
        c.gtk_widget_set_can_focus(canvas, 1);
        c.gtk_widget_add_events(canvas, c.GDK_BUTTON_PRESS_MASK | c.GDK_BUTTON_RELEASE_MASK | c.GDK_POINTER_MOTION_MASK | c.GDK_LEAVE_NOTIFY_MASK | c.GDK_KEY_PRESS_MASK | c.GDK_KEY_RELEASE_MASK | c.GDK_FOCUS_CHANGE_MASK);
        c.gtk_container_add(cast(c.GtkContainer, scroll), canvas);
        self.* = .{ .window = window, .canvas = canvas, .scroll = scroll, .prompt = prompt, .mode = mode, .view = view };
        if (mode == .password) self.entry = try password.Entry.create(canvas, &changed, self);
        connect(canvas, "draw", &draw, self);
        connect(canvas, "button-press-event", &press, self);
        connect(canvas, "button-release-event", &released, self);
        connect(canvas, "motion-notify-event", &motion, self);
        connect(canvas, "leave-notify-event", &leave, self);
        connect(canvas, "key-press-event", &key, self);
        connect(canvas, "key-release-event", &keyRelease, self);
        connect(canvas, "focus-in-event", &focusIn, self);
        connect(canvas, "focus-out-event", &focusOut, self);
        connect(canvas, "map", &mapped, self);
        self.size();
        c.gtk_widget_show_all(window);
        c.gtk_widget_grab_focus(canvas);
        return self;
    }
    pub fn destroy(self: *Dialog) void {
        if (self.entry) |entry| entry.destroy();
        _ = c.g_signal_handlers_disconnect_matched(self.canvas, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
        c.gtk_widget_destroy(self.window);
        self.view.deinit(a);
        a.free(self.prompt);
        a.destroy(self);
    }
    fn size(self: *Dialog) void {
        c.gtk_widget_set_size_request(self.canvas, @intCast(self.view.width), @intCast(self.view.height));
        if (self.entry) |entry| {
            const rect = self.view.entryRect();
            entry.rect = .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height };
        }
    }
    fn changed(data: ?*anyopaque) void {
        c.gtk_widget_queue_draw(cast(Dialog, data).canvas);
    }
    fn mapped(_: *c.GtkWidget, data: c.gpointer) callconv(.c) void {
        const self = cast(Dialog, data);
        const monitor = c.gdk_display_get_monitor_at_window(c.gtk_widget_get_display(self.window), c.gtk_widget_get_window(self.window));
        if (monitor != null) {
            var geometry: c.GdkRectangle = undefined;
            c.gdk_monitor_get_geometry(monitor, &geometry);
            c.gtk_scrolled_window_set_max_content_height(cast(c.GtkScrolledWindow, self.scroll), @max(120, geometry.height - 80));
        }
        self.focus(self.view.focus);
    }
    fn focus(self: *Dialog, target: native.Target) void {
        self.view.focus = target;
        if (self.entry) |entry| entry.focus(target == .entry);
        const rect = if (target == .entry) self.view.entryRect() else self.view.buttonRect(target);
        c.gtk_adjustment_clamp_page(c.gtk_scrolled_window_get_vadjustment(cast(c.GtkScrolledWindow, self.scroll)), rect.y, rect.y + rect.height);
        changed(self);
    }
    fn focusIn(_: *c.GtkWidget, _: *c.GdkEvent, data: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Dialog, data);
        if (self.entry) |entry| entry.focus(self.view.focus == .entry);
        return 0;
    }
    fn focusOut(_: *c.GtkWidget, _: *c.GdkEvent, data: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Dialog, data);
        if (self.entry) |entry| entry.focus(false);
        return 0;
    }
    fn draw(_: *c.GtkWidget, cr: *c.cairo_t, data: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Dialog, data);
        self.paint(cr) catch {
            self.failed = true;
            self.respond(false);
        };
        return 1;
    }
    fn paint(self: *Dialog, cr: *c.cairo_t) !void {
        const scale: u32 = @intCast(@max(1, c.gtk_widget_get_scale_factor(self.canvas)));
        const old_height = self.view.height;
        try self.view.prepare(a, self.prompt, scale);
        if (old_height != self.view.height) self.size();
        const width = self.view.width * scale;
        const height = self.view.height * scale;
        const image = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, @intCast(width), @intCast(height));
        defer c.cairo_surface_destroy(image);
        if (c.cairo_surface_status(image) != 0) return error.ImageAllocation;
        const pixels: [*]u32 = @ptrCast(@alignCast(c.cairo_image_surface_get_data(image)));
        const target: @import("desktop-raster.zig").Buffer = .{ .pixels = pixels[0 .. width * height], .width = width, .height = height };
        self.view.paint(target);
        if (self.entry) |entry| try entry.paint(target, scale);
        c.cairo_surface_mark_dirty(image);
        c.cairo_surface_set_device_scale(image, @floatFromInt(scale), @floatFromInt(scale));
        c.cairo_set_source_surface(cr, image, 0, 0);
        c.cairo_paint(cr);
    }
    fn press(_: *c.GtkWidget, event: *c.GdkEventButton, data: c.gpointer) callconv(.c) c.gboolean {
        if (event.button != 1) return 0;
        const self = cast(Dialog, data);
        const target = self.view.hit(event.x, event.y);
        self.view.keyboard_focus = false;
        self.view.pressed = target;
        self.view.hover = target;
        if (target != .none) self.focus(target);
        c.gtk_widget_grab_focus(self.canvas);
        if (target == .entry) {
            const entry = self.entry.?;
            entry.dragging = true;
            entry.point(event.x, event.state & c.GDK_SHIFT_MASK != 0);
        }
        changed(self);
        return 1;
    }
    fn released(_: *c.GtkWidget, event: *c.GdkEventButton, data: c.gpointer) callconv(.c) c.gboolean {
        if (event.button != 1) return 0;
        const self = cast(Dialog, data);
        const target = self.view.pressed;
        self.view.pressed = .none;
        if (self.entry) |entry| entry.dragging = false;
        if ((target == .accept or target == .cancel) and self.view.hit(event.x, event.y) == target) self.respond(target == .accept);
        changed(self);
        return 1;
    }
    fn motion(_: *c.GtkWidget, event: *c.GdkEventMotion, data: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Dialog, data);
        self.view.hover = self.view.hit(event.x, event.y);
        if (self.entry) |entry| if (entry.dragging) entry.point(event.x, true);
        changed(self);
        return 1;
    }
    fn leave(_: *c.GtkWidget, _: *c.GdkEventCrossing, data: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Dialog, data);
        self.view.hover = .none;
        changed(self);
        return 0;
    }
    fn key(_: *c.GtkWidget, event: *c.GdkEvent, data: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Dialog, data);
        if (self.view.focus == .entry and self.entry.?.filter(event)) return 1;
        var symbol: c.guint = 0;
        var modifiers: c.GdkModifierType = 0;
        _ = c.gdk_event_get_keyval(event, &symbol);
        _ = c.gdk_event_get_state(event, &modifiers);
        return @intFromBool(self.handleKey(symbol, modifiers));
    }
    fn keyRelease(_: *c.GtkWidget, event: *c.GdkEvent, data: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Dialog, data);
        return @intFromBool(self.view.focus == .entry and self.entry.?.filter(event));
    }
    pub fn handleKey(self: *Dialog, symbol: u32, modifiers: c.GdkModifierType) bool {
        self.view.keyboard_focus = true;
        switch (symbol) {
            0xff1b => self.respond(false),
            0xff09, 0xfe20 => {
                self.view.stepFocus(symbol == 0xfe20 or modifiers & c.GDK_SHIFT_MASK != 0);
                self.focus(self.view.focus);
            },
            0xff0d, 0xff8d => self.respond(self.view.focus != .cancel),
            else => {
                if (self.view.focus == .entry) {
                    const entry = self.entry.?;
                    if (!entry.key(symbol, modifiers)) {
                        const codepoint = c.gdk_keyval_to_unicode(symbol);
                        if (modifiers & (c.GDK_CONTROL_MASK | c.GDK_MOD1_MASK) != 0 or codepoint < 32 or codepoint == 127) return false;
                        var bytes: [4]u8 = @splat(0);
                        defer std.crypto.secureZero(u8, &bytes);
                        const len = std.unicode.utf8Encode(@intCast(codepoint), &bytes) catch return false;
                        entry.insert(bytes[0..len]) catch {};
                    }
                } else if (symbol == 0x20) self.respond(self.view.focus == .accept) else if (symbol == 0xff51 or symbol == 0xff53) {
                    self.view.stepFocus(symbol == 0xff51);
                    self.focus(self.view.focus);
                } else return false;
            },
        }
        changed(self);
        return true;
    }
    pub fn respond(self: *Dialog, accepted: bool) void {
        if (!accepted) self.clear();
        c.gtk_dialog_response(cast(c.GtkDialog, self.window), if (accepted) c.GTK_RESPONSE_OK else c.GTK_RESPONSE_CANCEL);
    }
    pub fn clear(self: *Dialog) void {
        if (self.entry) |entry| entry.clear();
    }
    fn cancel(data: c.gpointer) callconv(.c) c.gboolean {
        cast(Dialog, data).respond(false);
        return 1;
    }
    pub fn run(self: *Dialog) void {
        if (self.failed) return;
        const term = c.g_unix_signal_add(c.SIGTERM, &cancel, self);
        defer _ = c.g_source_remove(term);
        const interrupt = c.g_unix_signal_add(c.SIGINT, &cancel, self);
        defer _ = c.g_source_remove(interrupt);
        c.gtk_window_present(cast(c.GtkWindow, self.window));
        self.accepted = c.gtk_dialog_run(cast(c.GtkDialog, self.window)) == c.GTK_RESPONSE_OK and !self.failed;
    }
    pub fn writeAnswer(self: *Dialog, io: std.Io, output: std.Io.File) !u8 {
        defer self.clear();
        if (!self.accepted) return 1;
        switch (self.mode) {
            .password => {
                try output.writeStreamingAll(io, self.entry.?.buffer.value());
                try output.writeStreamingAll(io, "\n");
            },
            .confirm => try output.writeStreamingAll(io, "yes\n"),
            .information => {},
        }
        return 0;
    }
};

pub fn main(init: std.process.Init) void {
    const status = run(init) catch 1;
    if (status != 0) std.process.exit(status);
}
fn run(init: std.process.Init) !u8 {
    var arguments = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arguments.deinit();
    return runArgs(init, try init.minimal.args.toSlice(arguments.allocator()));
}
pub fn runArgs(init: std.process.Init, args: []const []const u8) !u8 {
    // Passwords should not appear in a core dump or another process's ptrace
    // view. No password is copied into argv, an environment variable or a file.
    if (libc.prctl(libc.PR_SET_DUMPABLE, @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0)) != 0) return 1;
    if (c.gtk_init_check(null, null) == 0) return 1;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const text = try arena.allocator().dupeSentinel(u8, if (args.len > 1) args[1] else "Enter your SSH passphrase:", 0);
    const hint = c.g_getenv("SSH_ASKPASS_PROMPT");
    const dialog = try Dialog.create(Mode.fromHint(if (hint) |h| std.mem.span(h) else null), text);
    defer dialog.destroy();
    dialog.run();
    return dialog.writeAnswer(init.io, std.Io.File.stdout());
}
