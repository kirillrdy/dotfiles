//! Shared native toplevel connection and explicit window lifetimes.
//! Owner callbacks run outside Wayland dispatch so they may destroy windows.
const std = @import("std");
const c = @import("desktop-gtk.zig");
pub const wire = @import("desktop-surface.zig");
const a = std.heap.page_allocator;
const cast = c.__zig.cast;
var connection: ?*wire.Client = null;
var windows: std.ArrayList(*Window) = .empty;
pub const Window = struct {
    surface: ?*wire.Surface,
    context: ?*anyopaque,
    closed: ?*const fn (?*anyopaque) void = null,
    parent: ?*Window = null,
    closing: bool = false,
    idle: c.guint = 0,
    application: ?*c.GApplication = null,

    pub fn create(title: [:0]const u8, namespace: [:0]const u8, width: u32, height: u32, paint: wire.PixelPaint, context: ?*anyopaque) !*Window {
        const self = try a.create(Window);
        errdefer a.destroy(self);
        const fresh = connection == null;
        if (fresh) connection = try wire.Client.createInteractive(.{ .added = &added, .removed = &removed }, null);
        const client = connection.?;
        errdefer if (fresh) {
            client.destroy();
            connection = null;
        };
        if (client.outputs.items.len == 0) return error.DisplayUnavailable;
        const output = client.outputs.items[0];
        const surface = try wire.Surface.createPixels(output, .{ .namespace = namespace, .title = title, .role = .toplevel, .width = width, .height = @min(height, @as(u32, @intCast(@max(120, output.height() - 60)))), .interactive = true, .cursor = .arrow }, paint, context);
        errdefer surface.destroy();
        self.* = .{ .surface = surface, .context = context };
        try windows.append(a, self);
        errdefer _ = windows.pop();
        if (fresh) try client.start();
        return self;
    }
    fn added(_: ?*anyopaque, _: *wire.Output) void {}
    fn removed(_: ?*anyopaque, output: *wire.Output) void {
        for (windows.items) |window| if (window.surface) |surface| if (surface.output == output) {
            window.surface = null; // Client owns destruction after this callback.
            window.close();
        };
    }
    pub fn show(self: *Window) !void {
        if (self.closing) return;
        const surface = self.surface orelse return error.DisplayUnavailable;
        const mapped = surface.role != null;
        try surface.show();
        if (mapped) surface.present();
        if (self.parent) |parent| if (parent.surface) |other| if (other.role) |role| {
            _ = c.wl_proxy_marshal_flags(surface.role.?, 1, null, c.wl_proxy_get_version(surface.role.?), 0, role);
            surface.client.flush();
        };
    }
    pub fn hide(self: *Window) void {
        if (self.surface) |surface| surface.hide();
    }
    pub fn blocked(self: *Window) bool {
        for (windows.items) |child| if (child.parent == self and !child.closing) {
            if (child.surface) |surface| if (surface.role != null) return true;
        };
        return false;
    }
    pub fn redraw(self: *Window) void {
        if (!self.closing) if (self.surface) |surface| surface.redraw();
    }
    pub fn setTitle(self: *Window, title: [:0]const u8) void {
        const surface = self.surface orelse return;
        surface.options.title = title;
        if (surface.role) |role| {
            _ = c.wl_proxy_marshal_flags(role, 2, null, c.wl_proxy_get_version(role), 0, title.ptr);
            surface.client.flush();
        }
    }
    pub fn setSize(self: *Window, width: u32, height: u32) void {
        if (self.surface) |surface| {
            surface.options.width = width;
            surface.options.height = height;
            surface.pending_width = width;
            surface.pending_height = height;
            if (surface.configured) {
                surface.width = width;
                surface.height = height;
                surface.redraw();
            }
        }
    }
    pub fn close(self: *Window) void {
        if (self.closing) return;
        self.closing = true;
        for (windows.items) |child| if (child.parent == self) child.close();
        if (self.surface) |surface| if (!surface.rendering) surface.hide();
        self.idle = c.g_idle_add(&deliverClose, self);
    }
    fn deliverClose(ptr: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast(Window, ptr);
        self.idle = 0;
        self.hide();
        if (self.application) |app| {
            self.application = null;
            g_application_release(app);
        }
        if (self.closed) |callback| callback(self.context);
        return 0;
    }
    pub fn hold(self: *Window, app: *c.GApplication) void {
        if (self.application != null) return;
        self.application = app;
        c.g_application_hold(app);
    }
    pub fn destroy(self: *Window) void {
        if (self.idle != 0) _ = c.g_source_remove(self.idle);
        for (windows.items) |child| if (child.parent == self) {
            child.parent = null;
            child.close();
        };
        if (self.surface) |surface| surface.destroy();
        if (self.application) |app| g_application_release(app);
        for (windows.items, 0..) |window, index| if (window == self) {
            _ = windows.orderedRemove(index);
            break;
        };
        a.destroy(self);
        if (windows.items.len == 0) {
            // Clipboard ownership survives closing the last form, just as it
            // does for a toolkit display. Reuse that connection for later UI.
            var serving_clipboard = false;
            for (connection.?.seats.items) |seat| if (seat.clipboard) |device| {
                serving_clipboard = serving_clipboard or device.source != null;
            };
            if (!serving_clipboard) {
                connection.?.destroy();
                connection = null;
            }
            windows.deinit(a);
            windows = .empty;
        }
    }
};
extern fn g_application_release(*c.GApplication) void;
