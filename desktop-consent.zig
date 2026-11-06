//! Native Wayland consent window. Responses leave the Wayland dispatch callback
//! before reaching owners, which may destroy the dialog synchronously.
const std = @import("std");
const c = @import("desktop-gtk.zig");
const wire = @import("desktop-surface.zig");
const view = @import("desktop-askpass-view.zig");
const cast = c.__zig.cast;
pub const Dialog = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    client: *wire.Client,
    surface: ?*wire.Surface = null,
    view: view.View,
    prompt: [:0]const u8,
    context: ?*anyopaque,
    completed: *const fn (?*anyopaque, bool) void,
    response: ?bool = null,
    idle: c.guint = 0,
    offset: f64 = 0,
    image: []u32 = &.{},
    pub fn create(allocator: std.mem.Allocator, title: [:0]const u8, prompt: [:0]const u8, accept: [:0]const u8, parent: [:0]const u8, context: ?*anyopaque, completed: *const fn (?*anyopaque, bool) void) !*Dialog {
        const self = try allocator.create(Dialog);
        errdefer allocator.destroy(self);
        var arena: std.heap.ArenaAllocator = .init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        var painter = view.View.init(.confirm);
        errdefer painter.deinit(allocator);
        painter.title = try a.dupeSentinel(u8, title, 0);
        painter.accept_label = try a.dupeSentinel(u8, accept, 0);
        painter.cancel_label = "Cancel";
        const owned_prompt = try a.dupeSentinel(u8, prompt, 0);
        const owned_parent = try a.dupeSentinel(u8, parent, 0);
        try painter.prepare(allocator, owned_prompt, 1);
        const client = try wire.Client.createInteractive(.{ .added = &outputAdded, .removed = &outputRemoved }, self);
        errdefer client.destroy();
        if (client.outputs.items.len == 0) return error.DisplayUnavailable;
        self.* = .{ .allocator = allocator, .arena = arena, .client = client, .view = painter, .prompt = owned_prompt, .context = context, .completed = completed };
        const output = client.outputs.items[0];
        self.surface = try wire.Surface.createPixels(output, .{ .namespace = "desktop-consent", .title = painter.title, .parent = owned_parent, .role = .toplevel, .width = painter.width, .height = @min(painter.height, @as(u32, @intCast(@max(120, output.height() - 60)))), .interactive = true, .cursor = .arrow }, &paint, self);
        self.surface.?.close = &close;
        self.surface.?.input = .{ .symbol = &key, .button = &button, .motion = &motion, .leave = &leave, .scroll = &scroll };
        try client.start();
        try self.surface.?.show();
        return self;
    }
    pub fn destroy(self: *Dialog) void {
        if (self.idle != 0) _ = c.g_source_remove(self.idle);
        self.client.destroy();
        self.view.deinit(self.allocator);
        self.allocator.free(self.image);
        self.arena.deinit();
        self.allocator.destroy(self);
    }
    fn outputAdded(_: ?*anyopaque, _: *wire.Output) void {}
    fn outputRemoved(ptr: ?*anyopaque, output: *wire.Output) void {
        const self = cast(Dialog, ptr);
        if (self.surface) |surface| if (surface.output == output) {
            self.surface = null;
            self.respond(false);
        };
    }
    fn close(ptr: ?*anyopaque) void {
        cast(Dialog, ptr).respond(false);
    }
    fn respond(self: *Dialog, accepted: bool) void {
        if (self.response != null) return;
        self.response = accepted;
        self.idle = c.g_idle_add(&deliver, self);
    }
    fn deliver(ptr: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast(Dialog, ptr);
        self.idle = 0;
        if (self.surface) |surface| surface.hide();
        self.completed(self.context, self.response.?);
        return 0;
    }
    fn redraw(self: *Dialog) void {
        if (self.surface) |surface| surface.redraw();
    }
    fn clamp(self: *Dialog) void {
        const surface = self.surface orelse return;
        self.offset = std.math.clamp(self.offset, 0, @as(f64, @floatFromInt(self.view.height -| surface.height)));
    }
    fn paint(ptr: ?*anyopaque, target: wire.Pixels) void {
        const self = cast(Dialog, ptr);
        self.paintPixels(target) catch {
            self.respond(false);
        };
    }
    fn paintPixels(self: *Dialog, target: wire.Pixels) !void {
        const surface = self.surface orelse return;
        const scale = surface.output.scale;
        const width = target.width / scale;
        if (self.view.width != width) {
            self.view.width = width;
            self.view.invalidate(self.allocator);
        }
        try self.view.prepare(self.allocator, self.prompt, scale);
        self.clamp();
        const height = @max(self.view.height * scale, target.height);
        const size = try wire.bufferSize(target.width, height);
        if (self.image.len != size / 4) {
            const image = try self.allocator.alloc(u32, size / 4);
            self.allocator.free(self.image);
            self.image = image;
        }
        self.view.paint(.{ .pixels = self.image, .width = target.width, .height = height });
        const start: usize = @intFromFloat(self.offset * @as(f64, @floatFromInt(scale)));
        for (0..target.height) |row| {
            @memcpy(target.pixels[row * target.width ..][0..target.width], self.image[(start + row) * target.width ..][0..target.width]);
        }
    }
    fn key(ptr: ?*anyopaque, _: *wire.Surface, symbol: u32, modifiers: u32, pressed: bool) bool {
        const self = cast(Dialog, ptr);
        if (!pressed or self.response != null) return true;
        if (symbol == 0xff1b) {
            self.respond(false);
            return true;
        }
        if ((symbol == 's' or symbol == 'S') and modifiers & 8 != 0) {
            self.respond(true);
            return true;
        }
        if (symbol == 0xff0d or symbol == 0xff8d or symbol == 0x20) {
            self.respond(self.view.focus == .accept);
            return true;
        }
        if (symbol == 0xff09 or symbol == 0xfe20 or symbol == 0xff51 or symbol == 0xff53) {
            self.view.stepFocus(symbol == 0xfe20 or symbol == 0xff51 or modifiers & 1 != 0);
            if (self.surface) |surface| {
                const rect = self.view.targetRect(self.view.focus);
                if (rect.y < self.offset) self.offset = rect.y;
                if (rect.y + rect.height > self.offset + @as(f64, @floatFromInt(surface.height))) self.offset = rect.y + rect.height - @as(f64, @floatFromInt(surface.height));
            }
            self.clamp();
            self.redraw();
            return true;
        }
        return false;
    }
    fn motion(ptr: ?*anyopaque, _: *wire.Surface, x: f64, y: f64) void {
        const self = cast(Dialog, ptr);
        self.view.hover = self.view.hit(x, y + self.offset);
        self.redraw();
    }
    fn leave(ptr: ?*anyopaque, _: *wire.Surface) void {
        const self = cast(Dialog, ptr);
        self.view.hover = .none;
        self.redraw();
    }
    fn button(ptr: ?*anyopaque, _: *wire.Surface, code: u32, pressed: bool, x: f64, y: f64) void {
        const self = cast(Dialog, ptr);
        if (code != 0x110 or self.response != null) return;
        const target = self.view.hit(x, y + self.offset);
        if (pressed) {
            self.view.pressed = target;
            if (target != .none) self.view.focus = target;
        } else {
            const previous = self.view.pressed;
            self.view.pressed = .none;
            if (previous == target and (target == .cancel or target == .accept)) self.respond(target == .accept);
        }
        self.redraw();
    }
    fn scroll(ptr: ?*anyopaque, _: *wire.Surface, axis: u32, delta: f64) void {
        const self = cast(Dialog, ptr);
        if (axis != 0) return;
        self.offset += delta * 3;
        self.clamp();
        self.redraw();
    }
};
