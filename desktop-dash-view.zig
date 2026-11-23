//! Native Activities dash, following GNOME 50's dash and overview-tile styles.
const std = @import("std");
const c = @import("desktop-glib.zig");
const App = @import("desktop-appinfo.zig").App;
const raster = @import("desktop-raster.zig");
const text = @import("desktop-text.zig");
pub const Rect = raster.Rect;
pub const Buffer = raster.Buffer;
const color = raster.hex;
const rounded = raster.rounded;

pub const Layout = struct {
    icon_size: u32,
    width: u32,
    height: u32,
    count: usize,
    separator: ?usize,
    pub fn init(max_width: u32, monitor_height: u32, count: usize, separator: ?usize) Layout {
        const n: u32 = @intCast(@max(1, count));
        const extra: u32 = if (separator != null) 9 else 0;
        const available_width = max_width -| (32 + extra);
        const available_height = @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(monitor_height -| 32)) * 0.16))) -| 48;
        var size: u32 = 16;
        for ([_]u32{ 16, 22, 24, 32, 48, 64 }) |candidate| {
            if (n * (candidate + 16) <= available_width and candidate <= available_height) size = candidate;
        }
        return .{ .icon_size = size, .width = 20 + n * (size + 16) + extra, .height = size + 48, .count = count, .separator = separator };
    }
    pub fn item(self: Layout, index: usize) Rect {
        const gap: u32 = if (self.separator != null and index >= self.separator.?) 9 else 0;
        return .{ .x = @floatFromInt(12 + index * (self.icon_size + 16) + gap), .y = 12, .width = @floatFromInt(self.icon_size + 12), .height = @floatFromInt(self.icon_size + 12) };
    }
    pub fn hit(self: Layout, x: f64, y: f64) ?usize {
        if (y < 0 or y >= self.height) return null;
        for (0..self.count) |i| {
            const rect = self.item(i);
            if (x >= rect.x and x < rect.x + rect.width) return i;
        }
        return null;
    }
};

pub const Item = struct {
    title: [:0]u8,
    app: ?*App = null,
    window_id: ?[:0]u8 = null,
    /// The application's icon; the item's reference keeps it alive.
    icon: ?[:0]const u8 = null,
    fallback: ?c.__icons.Image = null,
    pixels: ?c.__icons.Image = null,
    scale: u32 = 0,
    size: u32 = 0,
    show_apps: bool = false,
    pub fn deinit(self: *Item, a: std.mem.Allocator) void {
        a.free(self.title);
        if (self.window_id) |id| a.free(id);
        if (self.app) |app| app.unref();
        if (self.fallback) |image| c.__icons.free(a, image);
        if (self.pixels) |image| c.__icons.free(a, image);
    }
    fn prepare(self: *Item, a: std.mem.Allocator, scale: u32, size: u32) void {
        if (self.scale == scale and self.size == size) return;
        if (self.pixels) |image| c.__icons.free(a, image);
        self.pixels = null;
        if (self.show_apps) {
            self.pixels = @import("desktop-icons.zig").load(a, "view-app-grid-symbolic", size, scale, @import("desktop-icons.zig").foreground);
        } else {
            self.pixels = c.__icons.loadApp(a, self.icon, size * scale, self.fallback, "application-x-executable");
        }
        self.scale = scale;
        self.size = size;
    }
};

pub const View = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Item) = .empty,
    layout: Layout = Layout.init(1728, 1080, 1, null),
    separator: ?usize = null,
    hover: ?usize = null,
    pressed: ?usize = null,
    focus: usize = 0,
    keyboard_focus: bool = false,
    apps_mode: bool = false,
    renderer: text.Renderer = .{},
    tooltip_mask: ?text.Mask = null,
    tooltip_index: ?usize = null,
    tooltip_scale: u32 = 0,
    pub fn deinit(self: *View) void {
        self.clear();
        self.items.deinit(self.allocator);
        self.renderer.deinit();
    }
    pub fn clear(self: *View) void {
        for (self.items.items) |*item| item.deinit(self.allocator);
        self.items.clearRetainingCapacity();
        self.separator = null;
        self.hover = null;
        self.pressed = null;
        self.invalidateTooltip();
    }
    pub fn add(self: *View, title: [:0]const u8, app: ?*App, window_id: ?[*:0]const u8, fallback: ?c.__icons.Image) !void {
        const owned = try self.allocator.dupeSentinel(u8, title, 0);
        errdefer self.allocator.free(owned);
        const id = if (window_id) |value| try self.allocator.dupeSentinel(u8, std.mem.span(value), 0) else null;
        errdefer if (id) |value| self.allocator.free(value);
        try self.items.ensureUnusedCapacity(self.allocator, 1);
        self.items.appendAssumeCapacity(.{ .title = owned, .window_id = id, .app = if (app) |info| info.ref() else null, .fallback = if (fallback) |image| @import("desktop-decode.zig").clone(self.allocator, image) else null, .icon = if (app) |info| info.icon else null });
    }
    pub fn relayout(self: *View, width: u32, height: u32) void {
        self.layout = Layout.init(width, height, self.items.items.len, self.separator);
        self.focus = @min(self.focus, self.items.items.len -| 1);
    }
    pub fn navigate(self: *View, direction: i32) void {
        if (self.items.items.len == 0) return;
        const n = self.items.items.len;
        self.focus = if (direction < 0) (self.focus + n - 1) % n else (self.focus + 1) % n;
        self.keyboard_focus = true;
        self.hover = null;
        self.pressed = null;
    }
    pub fn invalidateTooltip(self: *View) void {
        if (self.tooltip_mask) |mask| mask.deinit(self.allocator);
        self.tooltip_mask = null;
        self.tooltip_index = null;
        self.tooltip_scale = 0;
    }
    pub fn prepareTooltip(self: *View, index: usize, scale: u32) !void {
        if (self.tooltip_index == index and self.tooltip_scale == scale) return;
        self.invalidateTooltip();
        const factor: f64 = @floatFromInt(scale);
        self.tooltip_mask = try self.renderer.renderLayout(self.allocator, self.items.items[index].title, .{ .size = 14.6666666667 * factor, .dpi = 96 * factor, .line_height = 19 * scale, .origin = .top });
        if (self.tooltip_mask.?.logical_width > 360 * scale) {
            self.tooltip_mask.?.deinit(self.allocator);
            self.tooltip_mask = null;
            self.tooltip_mask = try self.renderer.renderLayout(self.allocator, self.items.items[index].title, .{ .size = 14.6666666667 * factor, .dpi = 96 * factor, .line_height = 19 * scale, .width = 360 * scale, .lines = 1, .ellipsize = true, .origin = .top });
        }
        self.tooltip_index = index;
        self.tooltip_scale = scale;
    }
    pub fn paintTooltip(self: *View, target: raster.Buffer, scale: u32) void {
        @memset(target.pixels, 0);
        const mask = self.tooltip_mask orelse return;
        const factor: f64 = @floatFromInt(scale);
        const canvas: raster.Canvas = .{ .target = target, .scale = factor };
        const width = @as(f64, @floatFromInt(target.width)) / factor;
        const height = @as(f64, @floatFromInt(target.height)) / factor;
        @import("desktop-overview-view.zig").paintPillMask(canvas, .{ .x = 0, .y = 0, .width = width, .height = height }, mask, color(0xffffff));
    }
    pub fn paint(self: *View, target: raster.Buffer, scale: u32) !void {
        @memset(target.pixels, 0);
        const factor: f64 = @floatFromInt(scale);
        const canvas: raster.Canvas = .{ .target = target, .scale = factor };
        rounded(canvas, .{ .x = 0, .y = 0, .width = @floatFromInt(self.layout.width), .height = @floatFromInt(self.layout.height - 12) }, 28, 0x38383b);
        if (self.separator) |index| {
            const x = self.layout.item(index).x - 7;
            canvas.draw(&.{.{ .rounded_rect = .{ .rect = .{ .x = x, .y = 18, .width = 1, .height = @floatFromInt(self.layout.icon_size) }, .radius = 0 } }}, .{ .red = 250.0 / 255.0, .green = 250.0 / 255.0, .blue = 251.0 / 255.0, .alpha = 0.1 });
        }
        for (self.items.items, 0..) |*item, i| {
            item.prepare(self.allocator, scale, self.layout.icon_size);
            const rect = self.layout.item(i);
            const hover = self.hover == i;
            const pressed = self.pressed == i;
            const focused = self.keyboard_focus and self.focus == i;
            const checked = item.show_apps and self.apps_mode;
            if (hover or pressed or focused or checked) rounded(canvas, rect, 16, if (pressed) (if (focused) @as(u32, 0x505359) else @as(u32, 0x4e4e52)) else if (hover) (if (checked) @as(u32, 0x5c5c61) else if (focused) @as(u32, 0x4c4f55) else @as(u32, 0x49494d)) else if (checked) 0x4b4b4f else 0x3b3e43);
            if (focused) canvas.draw(&.{.{ .rounded_stroke = .{ .rect = .{ .x = rect.x + 1, .y = rect.y + 1, .width = rect.width - 2, .height = rect.height - 2 }, .radius = 15, .width = 2 } }}, color(0x769dcc));
            if (item.pixels) |image| {
                const source = image.view();
                const size: f64 = @floatFromInt(self.layout.icon_size);
                const ratio = @as(f64, @floatFromInt(source.width)) / @as(f64, @floatFromInt(source.height));
                const w = if (ratio > 1) size else size * ratio;
                const h = if (ratio > 1) size / ratio else size;
                try raster.blit(target, source, .{ .x = (rect.x + (rect.width - w) / 2) * factor, .y = (rect.y + (rect.height - h) / 2) * factor, .width = w * factor, .height = h * factor }, null);
            }
            if (item.window_id != null) canvas.draw(&.{.{ .circle = .{ .center = .{ .x = rect.x + rect.width / 2, .y = rect.y + rect.height - 2.5 }, .radius = 2.5 } }}, color(0xfafafb));
        }
    }
};

test "dash matches measured GNOME 50 allocation and adapts to crowded monitors" {
    const layout = Layout.init(1280, 720, 4, null);
    try std.testing.expectEqual(@as(u32, 48), layout.icon_size);
    try std.testing.expectEqual(@as(u32, 276), layout.width);
    try std.testing.expectEqual(@as(u32, 96), layout.height);
    try std.testing.expectEqual(@as(f64, 12), layout.item(0).x);
    try std.testing.expectEqual(@as(f64, 204), layout.item(3).x);
    try std.testing.expectEqual(@as(?usize, 0), layout.hit(13, 13));
    try std.testing.expectEqual(@as(?usize, null), layout.hit(73, 13));
    try std.testing.expectEqual(@as(u32, 64), Layout.init(1728, 1080, 4, null).icon_size);
    const crowded = Layout.init(800, 1080, 18, 3);
    try std.testing.expect(crowded.width <= 800);
    try std.testing.expectEqual(@as(u32, 24), crowded.icon_size);
    try std.testing.expectEqual(@as(?usize, null), crowded.hit(crowded.item(3).x - 5, 20));
}
