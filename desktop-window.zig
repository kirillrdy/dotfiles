//! Shared native toplevel connection and explicit window lifetimes.
//! Owner callbacks run outside Wayland dispatch so they may destroy windows.
const std = @import("std");
const c = @import("desktop-glib.zig");
pub const wire = @import("desktop-surface.zig");
const cast = c.__zig.cast;
var connection: ?*wire.Client = null;
var windows: std.ArrayList(*Window) = .empty;

/// Releases the connection retained for clipboard ownership after the last window closes.
pub fn deinit() void {
    std.debug.assert(windows.items.len == 0);
    if (connection) |client| client.destroy();
    connection = null;
}

pub const Window = struct {
    allocator: std.mem.Allocator,
    surface: ?*wire.Surface,
    context: ?*anyopaque,
    closed: ?*const fn (?*anyopaque) void = null,
    parent: ?*Window = null,
    closing: bool = false,
    idle: c.guint = 0,

    pub fn create(a: std.mem.Allocator, title: [:0]const u8, namespace: [:0]const u8, width: u32, height: u32, paint: wire.PixelPaint, context: ?*anyopaque) !*Window {
        const self = try a.create(Window);
        errdefer a.destroy(self);
        const fresh = connection == null;
        if (fresh) connection = try wire.Client.createInteractive(a, .{ .added = &added, .removed = &removed }, null);
        const client = connection.?;
        errdefer if (fresh) {
            client.destroy();
            connection = null;
        };
        if (client.outputs.items.len == 0) return error.DisplayUnavailable;
        const output = client.outputs.items[0];
        const surface = try wire.Surface.createPixels(output, .{ .namespace = namespace, .title = title, .role = .toplevel, .width = width, .height = @min(height, @as(u32, @intCast(@max(120, output.height() - 60)))), .interactive = true, .cursor = .arrow }, paint, context);
        errdefer surface.destroy();
        self.* = .{ .allocator = a, .surface = surface, .context = context };
        try windows.append(client.allocator, self);
        errdefer {
            _ = windows.pop();
            if (fresh) {
                windows.deinit(client.allocator);
                windows = .empty;
            }
        }
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
        if (self.parent) |parent| if (parent.surface) |other| if (other.toplevel != null and surface.toplevel != null) {
            surface.toplevel.?.set_parent(other.toplevel);
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
        if (surface.toplevel) |toplevel| {
            toplevel.set_title(title);
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
        if (self.closed) |callback| callback(self.context);
        return 0;
    }
    pub fn destroy(self: *Window) void {
        if (self.idle != 0) _ = c.g_source_remove(self.idle);
        for (windows.items) |child| if (child.parent == self) {
            child.parent = null;
            child.close();
        };
        if (self.surface) |surface| surface.destroy();
        for (windows.items, 0..) |window, index| if (window == self) {
            _ = windows.orderedRemove(index);
            break;
        };
        self.allocator.destroy(self);
        if (windows.items.len == 0) {
            // Clipboard ownership survives closing the last form, just as it
            // does for a toolkit display. Reuse that connection for later UI.
            var serving_clipboard = false;
            for (connection.?.seats.items) |seat| if (seat.clipboard) |device| {
                serving_clipboard = serving_clipboard or device.source != null;
            };
            windows.deinit(connection.?.allocator);
            windows = .empty;
            if (!serving_clipboard) {
                connection.?.destroy();
                connection = null;
            }
        }
    }
};
