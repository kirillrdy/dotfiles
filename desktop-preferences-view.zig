//! Native Adwaita-style drawing primitives shared by settings pages.
const std = @import("std");
const c = @import("desktop-gtk.zig");
const form = @import("desktop-form.zig");
const raster = @import("desktop-raster.zig");
const a = if (@import("builtin").is_test) std.testing.allocator else std.heap.page_allocator;
pub const Rect = form.Rect;
pub const Canvas = raster.Canvas;
pub const background = 0x222226;
pub const card = 0x323236;
pub const secondary = 0x9a9a9e;
pub const Frame = struct {
    width: f64,
    height: f64,
    sidebar: f64,
    x: f64,
    content_width: f64,
    pub fn init(ui: *form.Form, sidebar: f64) Frame {
        const w: f64 = @floatFromInt(ui.width);
        const h: f64 = @floatFromInt(@max(400, ui.viewport_height));
        const content = @min(576, w - sidebar - 48);
        ui.height = @intFromFloat(h);
        return .{ .width = w, .height = h, .sidebar = sidebar, .x = sidebar + (w - sidebar - content) / 2, .content_width = content };
    }
};
pub fn reset(ui: *form.Form) void {
    for (ui.items.items) |item| {
        item.visible = false;
        item.pinned = false;
        item.clip = null;
    }
}
pub fn place(ui: *form.Form, id: usize, rect: Rect) void {
    const item = ui.get(id);
    item.visible = true;
    item.bounds = rect;
    if (item.entry) |entry| entry.rect = .{ .x = rect.x + 12, .y = rect.y + 24, .width = rect.width - 24, .height = @max(30, rect.height - 28) };
}
pub fn fill(canvas: Canvas, rect: Rect, rgb: u32, radius: f64) void {
    canvas.draw(&.{.{ .rounded_rect = .{ .rect = .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height }, .radius = radius } }}, raster.Color.rgb(rgb, 1));
}
pub fn line(canvas: Canvas, x: f64, y: f64, width: f64) void {
    fill(canvas, .{ .x = x, .y = y, .width = width, .height = 1 }, background, 0);
}
pub fn focus(canvas: Canvas, rect: Rect) void {
    canvas.draw(&.{.{ .rounded_stroke = .{ .rect = .{ .x = rect.x + 1, .y = rect.y + 1, .width = rect.width - 2, .height = rect.height - 2 }, .radius = 7, .width = 2 } }}, raster.Color.rgb(0x868688, 1));
}
pub fn text(ui: *form.Form, canvas: Canvas, value: [:0]const u8, rect: Rect, size: f64, bold: bool, centered: bool, tint: u32) !void {
    if (value.len == 0) return;
    const mask = try ui.renderer.renderLayout(a, value, .{ .font = if (bold) "Adwaita Sans Bold" else "Adwaita Sans", .size = size * canvas.scale, .dpi = 96 * canvas.scale, .width = @intFromFloat(@max(1, rect.width) * canvas.scale), .ellipsize = true, .lines = 1, .alignment = if (centered) .center else .left, .origin = .top });
    defer mask.deinit(a);
    mask.paint(canvas, rect.x, rect.y + (rect.height - @as(f64, @floatFromInt(mask.logical_height)) / canvas.scale) / 2, raster.Color.rgb(tint, 1));
}
pub fn title(ui: *form.Form, canvas: Canvas, id: usize, rect: Rect, bold: bool, tint: u32) !void {
    const item = ui.get(id);
    if (item.title_mask == null) item.title_mask = try ui.renderer.renderLayout(a, item.title, .{ .font = if (bold) "Adwaita Sans Bold" else "Adwaita Sans", .size = 14.666 * canvas.scale, .dpi = 96 * canvas.scale, .width = @intFromFloat(@max(1, rect.width) * canvas.scale), .ellipsize = true, .lines = 1, .origin = .top });
    const mask = item.title_mask.?;
    mask.paint(canvas, rect.x, rect.y + (rect.height - @as(f64, @floatFromInt(mask.logical_height)) / canvas.scale) / 2, raster.Color.rgb(tint, 1));
}
pub fn button(ui: *form.Form, canvas: Canvas, id: usize, suggested: bool, destructive: bool) !void {
    const item = ui.get(id);
    if (!item.visible) return;
    const enabled = ui.active(id);
    fill(canvas, item.bounds, if (suggested) (if (enabled) @as(u32, 0x3584e4) else 0x295082) else if (ui.hover == id) @as(u32, 0x47474b) else 0x3d3d41, 7);
    try text(ui, canvas, item.title, item.bounds, 14.666, suggested, true, if (!enabled) secondary else if (destructive) @as(u32, 0xff7b86) else 0xffffff);
    if (ui.focus == id) focus(canvas, item.bounds);
}
pub fn toggle(ui: *form.Form, canvas: Canvas, id: usize) !void {
    const item = ui.get(id);
    const r = item.bounds;
    const enabled = ui.active(id);
    try title(ui, canvas, id, .{ .x = r.x + 14, .y = r.y, .width = r.width - 90, .height = r.height }, false, if (enabled) @as(u32, 0xffffff) else secondary);
    const track = Rect{ .x = r.x + r.width - 60, .y = r.y + (r.height - 26) / 2, .width = 46, .height = 26 };
    fill(canvas, track, if (item.checked) 0x3584e4 else 0x68686c, 13);
    canvas.draw(&.{.{ .circle = .{ .center = .{ .x = track.x + (if (item.checked) @as(f64, 33) else 13), .y = track.y + 13 }, .radius = 10 } }}, raster.Color.rgb(if (enabled) @as(u32, 0xffffff) else 0xc0c0c4, 1));
    if (ui.focus == id) focus(canvas, item.bounds);
}
pub fn field(ui: *form.Form, canvas: Canvas, id: usize) !void {
    const item = ui.get(id);
    if (!item.visible) return;
    if (item.kind == .toggle) return toggle(ui, canvas, id);
    const r = item.bounds;
    if (item.kind == .choice) {
        try title(ui, canvas, id, .{ .x = r.x + 14, .y = r.y, .width = r.width * 0.48, .height = r.height }, false, 0xffffff);
        const selected = if (item.selected) |i| item.options.items[i].label else "Select…";
        try text(ui, canvas, selected, .{ .x = r.x + r.width * 0.5, .y = r.y, .width = r.width * 0.5 - 35, .height = r.height }, 14.666, false, false, secondary);
        canvas.draw(&.{ .{ .line = .{ .start = .{ .x = r.x + r.width - 24, .y = r.y + r.height / 2 - 2 }, .end = .{ .x = r.x + r.width - 20, .y = r.y + r.height / 2 + 2 }, .radius = 1 } }, .{ .line = .{ .start = .{ .x = r.x + r.width - 20, .y = r.y + r.height / 2 + 2 }, .end = .{ .x = r.x + r.width - 16, .y = r.y + r.height / 2 - 2 }, .radius = 1 } } }, raster.Color.rgb(secondary, 1));
        if (ui.focus == id) focus(canvas, r);
        return;
    }
    try text(ui, canvas, item.title, .{ .x = r.x + 14, .y = r.y + 5, .width = r.width - 28, .height = 22 }, 12.666, false, false, secondary);
    if (item.entry) |entry| {
        if (ui.focus == id) {
            try entry.paint(canvas.target, @intFromFloat(canvas.scale));
        } else {
            try text(ui, canvas, if (!entry.echo and entry.buffer.len > 0) "••••••••" else entry.buffer.valueZ(), .{ .x = r.x + 14, .y = r.y + 25, .width = r.width - 28, .height = r.height - 30 }, 14.666, false, false, if (item.enabled) @as(u32, 0xffffff) else secondary);
        }
    }
}
pub fn expanded(ui: *form.Form, canvas: Canvas) !void {
    const id = ui.expanded orelse return;
    const item = ui.get(id);
    const top = ui.optionTop(item);
    fill(canvas, .{ .x = item.bounds.x, .y = top - 6, .width = item.bounds.width, .height = @as(f64, @floatFromInt(item.options.items.len * 36)) + 12 }, 0x38383c, 10);
    for (item.options.items, 0..) |option, i| {
        const r = Rect{ .x = item.bounds.x + 6, .y = top + @as(f64, @floatFromInt(i * 36)), .width = item.bounds.width - 12, .height = 36 };
        if (ui.option_cursor == i) fill(canvas, r, 0x4b4b50, 6);
        try text(ui, canvas, option.label, .{ .x = r.x + 8, .y = r.y, .width = r.width - 16, .height = 36 }, 14.666, false, false, 0xffffff);
    }
}
pub fn toast(ui: *form.Form, canvas: Canvas, id: usize, frame: Frame) !void {
    const message = ui.get(id).title;
    if (message.len == 0) return;
    const r = Rect{ .x = frame.x, .y = frame.height - 62, .width = frame.content_width, .height = 40 };
    fill(canvas, r, 0x414145, 12);
    try text(ui, canvas, message, .{ .x = r.x + 12, .y = r.y, .width = r.width - 24, .height = 40 }, 14.666, false, true, 0xffffff);
}
pub const Icons = struct {
    const Icon = struct { name: [:0]const u8, size: u32, image: *c.GdkPixbuf };
    entries: std.ArrayList(Icon) = .empty,
    pub fn deinit(self: *Icons) void {
        for (self.entries.items) |entry| c.g_object_unref(entry.image);
        self.entries.deinit(a);
    }
    pub fn paint(self: *Icons, canvas: Canvas, name: [:0]const u8, x: f64, y: f64, size: u32) !void {
        const physical: u32 = @intFromFloat(@as(f64, @floatFromInt(size)) * canvas.scale);
        var image: ?*c.GdkPixbuf = null;
        for (self.entries.items) |entry| if (entry.size == physical and std.mem.eql(u8, name, entry.name)) {
            image = entry.image;
            break;
        };
        if (image == null) {
            const info = c.gtk_icon_theme_lookup_icon(c.gtk_icon_theme_get_default(), name, @intCast(physical), c.GTK_ICON_LOOKUP_FORCE_SIZE) orelse return;
            defer c.g_object_unref(info);
            const fg: c.GdkRGBA = .{ .red = 1, .green = 1, .blue = 1, .alpha = 1 };
            image = c.gtk_icon_info_load_symbolic(info, &fg, null, null, null, null, null);
            if (image) |pixbuf| self.entries.append(a, .{ .name = name, .size = physical, .image = pixbuf }) catch |err| {
                c.g_object_unref(pixbuf);
                return err;
            };
        }
        if (image) |pixbuf| c.__zig.blitPixbuf(canvas, pixbuf, .{ .x = x, .y = y, .width = @floatFromInt(size), .height = @floatFromInt(size) });
    }
};
