//! Cached native panel content and Codex usage controls. GTK only hosts the pixels.
const std = @import("std");
const raster = @import("desktop-raster.zig");
const text = @import("desktop-text.zig");
const c = @import("desktop-gtk.zig");
const a = if (@import("builtin").is_test) std.testing.allocator else std.heap.page_allocator;
pub const Rect = @import("desktop-askpass-view.zig").Rect;
const white: raster.Color = .{ .red = 1, .green = 1, .blue = 1 };
const secondary: raster.Color = .{ .red = 0.63, .green = 0.63, .blue = 0.63 };

pub const Label = struct {
    value: [:0]const u8 = "",
    owned: bool = false,
    mask: ?text.Mask = null,
    scale: u32 = 0,
    size: f64 = 0,
    limit: ?u32 = null,
    bold: bool = false,
    markup: bool = false,
    pub fn set(self: *Label, value: [:0]const u8) void {
        if (std.mem.eql(u8, self.value, value)) return;
        const copy = a.dupeSentinel(u8, value, 0) catch @panic("out of memory");
        self.deinit();
        self.* = .{ .value = copy, .owned = true };
    }
    pub fn deinit(self: *Label) void {
        if (self.mask) |mask| mask.deinit(a);
        if (self.owned) a.free(self.value);
        self.* = .{};
    }
    pub fn prepare(self: *Label, renderer: *text.Renderer, scale: u32, size: f64, bold: bool, limit: ?u32, markup: bool) !void {
        if (self.scale == scale and self.size == size and self.limit == limit and self.bold == bold and self.markup == markup) return;
        if (self.mask) |mask| mask.deinit(a);
        self.mask = null;
        self.scale = 0;
        self.mask = try renderer.renderLayout(a, self.value, .{ .font = if (bold) "Adwaita Sans Bold" else "Adwaita Sans", .size = size * @as(f64, @floatFromInt(scale)), .dpi = 96 * @as(f64, @floatFromInt(scale)), .origin = .top, .width = if (limit) |w| w * scale else null, .lines = if (limit != null or std.mem.indexOfScalar(u8, self.value, '\n') != null) 8 else null, .markup = markup });
        self.scale = scale;
        self.size = size;
        self.limit = limit;
        self.bold = bold;
        self.markup = markup;
    }
    pub fn width(self: *const Label) f64 {
        return if (self.mask) |m| @as(f64, @floatFromInt(m.logical_width)) / @as(f64, @floatFromInt(self.scale)) else 0;
    }
    pub fn height(self: *const Label) f64 {
        return if (self.mask) |m| @as(f64, @floatFromInt(m.logical_height)) / @as(f64, @floatFromInt(self.scale)) else 0;
    }
    pub fn paint(self: *const Label, buffer: raster.Buffer, x: f64, y: f64, color: raster.Color) void {
        if (self.mask) |m| raster.mask(buffer, .{ .x = @as(i32, @intFromFloat(@round(x * @as(f64, @floatFromInt(self.scale))))) + m.left, .y = @as(i32, @intFromFloat(@round(y * @as(f64, @floatFromInt(self.scale))))) + m.top, .width = m.width, .height = m.height }, m.pixels, color);
    }
};
pub const Item = struct {
    label: Label = .{},
    icon: Label = .{},
    tooltip: Label = .{},
    command: Label = .{},
    pixbuf: ?*c.GdkPixbuf = null,
    icon_scale: u32 = 0,
    visible: bool = false,
    rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    pub fn deinit(self: *Item) void {
        self.label.deinit();
        self.icon.deinit();
        self.tooltip.deinit();
        self.command.deinit();
        if (self.pixbuf) |image| c.g_object_unref(image);
        self.pixbuf = null;
    }
    pub fn setIcon(self: *Item, value: [:0]const u8) void {
        if (std.mem.eql(u8, self.icon.value, value)) return;
        self.icon.set(value);
        if (self.pixbuf) |image| c.g_object_unref(image);
        self.pixbuf = null;
        self.icon_scale = 0;
    }
    fn prepare(self: *Item, renderer: *text.Renderer, scale: u32, small: bool) !void {
        try self.label.prepare(renderer, scale, if (small) 12 else 14.666, true, null, false);
        if (self.icon_scale == scale) return;
        if (self.pixbuf) |image| c.g_object_unref(image);
        self.pixbuf = null;
        const size: c_int = @intCast(16 * scale);
        if (self.icon.value.len != 0) {
            if (std.fs.path.isAbsolute(self.icon.value)) {
                self.pixbuf = c.gdk_pixbuf_new_from_file_at_scale(self.icon.value, size, size, 1, null);
            } else if (c.gtk_icon_theme_lookup_icon(c.gtk_icon_theme_get_default(), self.icon.value, size, c.GTK_ICON_LOOKUP_FORCE_SIZE)) |info| {
                defer c.g_object_unref(info);
                const foreground = c.GdkRGBA{ .red = 1, .green = 1, .blue = 1, .alpha = 1 };
                self.pixbuf = c.gtk_icon_info_load_symbolic(info, &foreground, null, null, null, null, null);
            }
        }
        self.icon_scale = scale;
    }
    fn paint(self: *const Item, buffer: raster.Buffer, scale: u32) void {
        var x = self.rect.x;
        if (self.pixbuf) |image| {
            const data = c.gdk_pixbuf_get_pixels(image);
            const stride: usize = @intCast(c.gdk_pixbuf_get_rowstride(image));
            const height: u32 = @intCast(c.gdk_pixbuf_get_height(image));
            const factor: f64 = @floatFromInt(scale);
            raster.blit(buffer, .{ .pixels = data[0 .. stride * (height - 1) + @as(usize, @intCast(c.gdk_pixbuf_get_width(image) * c.gdk_pixbuf_get_n_channels(image)))], .width = @intCast(c.gdk_pixbuf_get_width(image)), .height = height, .stride = stride, .format = if (c.gdk_pixbuf_get_has_alpha(image) != 0) .rgba else .rgb }, .{ .x = x * factor, .y = (self.rect.height - 16) / 2 * factor, .width = 16 * factor, .height = 16 * factor }, null) catch {};
        }
        if (self.icon.value.len != 0) x += 16 + (if (self.label.value.len != 0) @as(f64, 6) else 0);
        self.label.paint(buffer, x, (self.rect.height - self.label.height()) / 2, white);
    }
};
pub const Graph = struct {
    history: [5][100]f64 = std.mem.zeroes([5][100]f64),
    colors: [5]c.GdkRGBA = std.mem.zeroes([5]c.GdkRGBA),
    count: u32 = 0,
    series: u32 = 0,
    sequence: i64 = -1,
    maximum: f64 = 100,
    autoscale: c.gboolean = 0,
    tooltip: Label = .{},
    name: Label = .{},
    pub fn deinit(self: *Graph) void {
        self.tooltip.deinit();
        self.name.deinit();
    }
    pub fn paint(self: *const Graph, canvas: raster.Canvas, x: f64, width: f64, height: f64) void {
        if (self.series == 0 or self.count < 2) return;
        var maximum = self.maximum;
        if (self.autoscale != 0) {
            maximum = 1;
            for (self.history[self.series - 1][0..self.count]) |v| maximum = @max(maximum, v);
            maximum = std.math.pow(f64, 2, @ceil(std.math.log2(maximum)));
        }
        if (!std.math.isFinite(maximum) or maximum <= 0) return;
        // Draw stacked samples as clipped columns; newest samples stay at the right.
        var series = self.series;
        while (series > 0) {
            series -= 1;
            const color = self.colors[series];
            for (0..self.count) |i| {
                const right = x + width - @as(f64, @floatFromInt(self.count - 1 - i));
                const top = height * (1 - std.math.clamp(self.history[series][i] / maximum, 0, 1));
                canvas.draw(&.{.{ .rounded_rect = .{ .rect = .{ .x = right - 1, .y = top, .width = 1, .height = height - top }, .radius = 0 } }}, .{ .red = color.red, .green = color.green, .blue = color.blue, .alpha = color.alpha });
            }
        }
    }
};

pub const View = struct {
    renderer: text.Renderer = .{},
    items: [8]Item = @splat(.{}),
    graphs: [3]Graph = @splat(.{}),
    clock: Label = .{},
    activities: bool = false,
    monitors: bool = false,
    status: bool = false,
    codex: bool = false,
    disk: bool = false,
    hovered: bool = false,
    focus: bool = false,
    scale: u32 = 1,
    width: u32 = 1,
    pub fn deinit(self: *View) void {
        for (&self.items) |*item| item.deinit();
        for (&self.graphs) |*graph| graph.deinit();
        self.clock.deinit();
        self.renderer.deinit();
    }
    pub fn prepare(self: *View, scale: u32, height: f64) !void {
        self.scale = scale;
        const padding: f64 = if (self.disk) 0 else if (self.codex) 15 else 18;
        var x = padding;
        if (self.activities) x += 42 else if (self.monitors) {
            for (&self.graphs, [_][:0]const u8{ "cpu", "mem", "net" }) |*graph, name| {
                graph.name.set(name);
                try graph.name.prepare(&self.renderer, scale, 9.166, true, null, false);
            }
            x += 354;
        } else if (self.clock.value.len != 0) {
            try self.clock.prepare(&self.renderer, scale, 14.666, true, null, false);
            x += self.clock.width();
        } else for (&self.items) |*item| {
            if (!item.visible) continue;
            try item.prepare(&self.renderer, scale, self.codex);
            const gap: f64 = if (self.status) 8 else 0;
            x += gap / 2;
            const width = (if (item.icon.value.len != 0) @as(f64, 16) else 0) + (if (item.icon.value.len != 0 and item.label.value.len != 0) @as(f64, 6) else 0) + item.label.width();
            item.rect = .{ .x = x, .y = 0, .width = width, .height = height };
            x += width + gap / 2;
        }
        self.width = @intFromFloat(@ceil(@max(1, x + padding)));
    }
    pub fn hit(self: *const View, x: f64, y: f64) ?usize {
        for (self.items, 0..) |item, i| if (item.visible and item.rect.contains(x, y)) return i;
        return null;
    }
    pub fn paint(self: *const View, buffer: raster.Buffer) void {
        @memset(buffer.pixels, 0);
        const scale: f64 = @floatFromInt(self.scale);
        const width = @as(f64, @floatFromInt(buffer.width)) / scale;
        const height = @as(f64, @floatFromInt(buffer.height)) / scale;
        const canvas: raster.Canvas = .{ .target = buffer, .scale = scale };
        if ((self.hovered or self.focus) and !self.disk) canvas.draw(&.{.{ .rounded = .{ .x = 3, .y = 3, .width = @max(0, width - 6), .height = @max(0, height - 6) } }}, .{ .red = 1, .green = 1, .blue = 1, .alpha = 0.17 });
        const padding: f64 = if (self.disk) 0 else if (self.codex) 15 else 18;
        if (self.activities) {
            canvas.draw(&.{ .{ .rounded = .{ .x = padding + 2, .y = height / 2 - 4, .width = 26, .height = 8 } }, .{ .circle = .{ .center = .{ .x = padding + 37, .y = height / 2 }, .radius = 4 } } }, white);
        } else if (self.monitors) {
            for (self.graphs, 0..) |graph, i| {
                const x = padding + @as(f64, @floatFromInt(i)) * 118;
                // Rotate the cached name mask counterclockwise without Cairo.
                if (graph.name.mask) |m| {
                    for (0..m.height) |y| for (0..m.width) |column| {
                        const alpha = m.pixels[y * m.width + column];
                        const px: i32 = @intFromFloat(x * scale + @as(f64, @floatFromInt(y)));
                        const py: i32 = @intFromFloat((height * scale + @as(f64, @floatFromInt(m.width))) / 2 - @as(f64, @floatFromInt(column)));
                        raster.mask(buffer, .{ .x = px, .y = py, .width = 1, .height = 1 }, &.{alpha}, .{ .red = 1, .green = 1, .blue = 1, .alpha = 0.75 });
                    };
                }
                graph.paint(canvas, x + 14, 100, height);
            }
        } else if (self.clock.value.len != 0) self.clock.paint(buffer, padding, (height - self.clock.height()) / 2, white) else for (self.items) |item| {
            if (item.visible) item.paint(buffer, self.scale);
        }
    }
};

pub const Codex = struct {
    renderer: text.Renderer = .{},
    titles: [2]Label = .{ .{ .value = "5-Hour Remaining" }, .{ .value = "Weekly Remaining" } },
    percent: [2]Label = .{ .{ .value = "—" }, .{ .value = "—" } },
    reset: [2]Label = .{ .{ .value = "Resets: —" }, .{ .value = "Resets: —" } },
    values: [2]f64 = .{ 0, 0 },
    checked: Label = .{ .value = "Checked: —" },
    error_label: Label = .{},
    refresh: Label = .{ .value = "Refresh" },
    enabled: bool = false,
    hovered: bool = false,
    pressed: bool = false,
    keyboard_focus: bool = true,
    scale: u32 = 1,
    width: u32 = 340,
    height: u32 = 280,
    pub fn deinit(self: *Codex) void {
        for (&self.titles) |*label| label.deinit();
        for (&self.percent) |*label| label.deinit();
        for (&self.reset) |*label| label.deinit();
        self.checked.deinit();
        self.error_label.deinit();
        self.refresh.deinit();
        self.renderer.deinit();
    }
    pub fn prepare(self: *Codex, scale: u32) !void {
        self.scale = scale;
        for (&self.titles) |*label| try label.prepare(&self.renderer, scale, 13, true, null, false);
        for (&self.percent) |*label| try label.prepare(&self.renderer, scale, 13, true, null, false);
        for (&self.reset) |*label| try label.prepare(&self.renderer, scale, 11, false, 300, false);
        try self.refresh.prepare(&self.renderer, scale, 12, true, null, false);
        try self.checked.prepare(&self.renderer, scale, 10, false, 174, false);
        try self.error_label.prepare(&self.renderer, scale, 11, false, 300, false);
        self.height = @intFromFloat(280 + (if (self.error_label.value.len == 0) @as(f64, 0) else self.error_label.height() + 12));
    }
    pub fn refreshRect(_: *const Codex) Rect {
        return .{ .x = 20, .y = 226, .width = 100, .height = 32 };
    }
    pub fn paint(self: *const Codex, buffer: raster.Buffer) void {
        @memset(buffer.pixels, 0);
        const canvas: raster.Canvas = .{ .target = buffer, .scale = @floatFromInt(self.scale) };
        const card: raster.Rect = .{ .x = 1, .y = 1, .width = @floatFromInt(self.width - 2), .height = @floatFromInt(self.height - 2) };
        canvas.draw(&.{.{ .rounded_rect = .{ .rect = card, .radius = 20 } }}, .{ .red = 54.0 / 255.0, .green = 54.0 / 255.0, .blue = 58.0 / 255.0 });
        canvas.draw(&.{.{ .rounded_stroke = .{ .rect = card, .radius = 20 } }}, .{ .red = 66.0 / 255.0, .green = 66.0 / 255.0, .blue = 71.0 / 255.0 });
        for (0..2) |i| {
            const y: f64 = 22 + @as(f64, @floatFromInt(i * 101));
            self.titles[i].paint(buffer, 20, y, white);
            self.percent[i].paint(buffer, 320 - self.percent[i].width(), y, white);
            const bar: raster.Rect = .{ .x = 20, .y = y + 28, .width = 300, .height = 8 };
            canvas.draw(&.{.{ .rounded = bar }}, .{ .red = 1, .green = 1, .blue = 1, .alpha = 0.1 });
            var filled = bar;
            filled.width *= self.values[i] / 100;
            if (filled.width > 0) canvas.draw(&.{.{ .rounded = filled }}, usageColor(self.values[i]));
            self.reset[i].paint(buffer, 20, y + 46, secondary);
            canvas.draw(&.{.{ .line = .{ .start = .{ .x = 20, .y = y + 82 }, .end = .{ .x = 320, .y = y + 82 }, .radius = 0.5 } }}, .{ .red = 1, .green = 1, .blue = 1, .alpha = 0.1 });
        }
        const button = self.refreshRect();
        canvas.draw(&.{.{ .rounded = .{ .x = button.x, .y = button.y, .width = button.width, .height = button.height } }}, .{ .red = 1, .green = 1, .blue = 1, .alpha = if (self.pressed) 0.18 else if (self.hovered) 0.12 else 0.06 });
        if (self.keyboard_focus and self.enabled) canvas.draw(&.{.{ .rounded_stroke = .{ .rect = .{ .x = button.x, .y = button.y, .width = button.width, .height = button.height }, .radius = 16 } }}, .{ .red = 0.47, .green = 0.68, .blue = 0.93 });
        canvas.draw(&.{ .{ .arc = .{ .center = .{ .x = 34, .y = 242 }, .radius = 5, .start = 0.4, .end = 3.3, .stroke = 0.8 } }, .{ .line = .{ .start = .{ .x = 29, .y = 241 }, .end = .{ .x = 29, .y = 245 }, .radius = 0.8 } }, .{ .line = .{ .start = .{ .x = 29, .y = 245 }, .end = .{ .x = 33, .y = 245 }, .radius = 0.8 } } }, .{ .red = 1, .green = 1, .blue = 1, .alpha = if (self.enabled) 1 else 0.5 });
        self.refresh.paint(buffer, 46, 234, .{ .red = 1, .green = 1, .blue = 1, .alpha = if (self.enabled) 1 else 0.5 });
        self.checked.paint(buffer, 320 - self.checked.width(), 237, secondary);
        if (self.error_label.value.len != 0) self.error_label.paint(buffer, 20, 274, secondary);
    }
};
pub fn usageColor(value: f64) raster.Color {
    const rgb: [3]f64 = if (value <= 10) .{ 239, 68, 68 } else if (value <= 30) .{ 249, 115, 22 } else if (value <= 60) .{ 234, 179, 8 } else .{ 16, 163, 127 };
    return .{ .red = rgb[0] / 255.0, .green = rgb[1] / 255.0, .blue = rgb[2] / 255.0 };
}

test "panel labels retain masks across hover, refresh at output scale, and drop hidden hit targets" {
    var view: View = .{};
    defer view.deinit();
    view.items[0].visible = true;
    view.items[0].label.set("54%");
    view.items[1].visible = true;
    view.items[1].label.set("Disk");
    try view.prepare(1, 32);
    const mask = view.items[0].label.mask.?.pixels.ptr;
    const width = view.width;
    view.hovered = true;
    try view.prepare(1, 32);
    try std.testing.expectEqual(mask, view.items[0].label.mask.?.pixels.ptr);
    const rect = view.items[1].rect;
    try std.testing.expectEqual(@as(?usize, 1), view.hit(rect.x + 1, 16));
    view.items[1].visible = false;
    try view.prepare(2, 32);
    try std.testing.expect(view.width < width);
    try std.testing.expectEqual(@as(u32, 2), view.items[0].label.scale);
    try std.testing.expectEqual(@as(?usize, null), view.hit(rect.x + 1, 16));
    const pixels = try a.alloc(u32, view.width * 128 + 2);
    defer a.free(pixels);
    @memset(pixels, 0x12345678);
    view.paint(.{ .pixels = pixels[1 .. pixels.len - 1], .width = view.width * 2, .height = 64 });
    try std.testing.expectEqual(@as(u32, 0x12345678), pixels[0]);
    try std.testing.expectEqual(@as(u32, 0x12345678), pixels[pixels.len - 1]);
}

test "Codex wraps errors, scales pixels, and retains remaining-budget colors" {
    var view: Codex = .{};
    defer view.deinit();
    try view.prepare(1);
    const height = view.height;
    view.error_label.set("Cannot refresh usage. Sign in with codex login and try again.");
    view.values = .{ 54, 0 };
    view.enabled = true;
    try view.prepare(2);
    try std.testing.expect(view.height > height);
    try std.testing.expect(usageColor(10).red > usageColor(100).red);
    const pixels = try a.alloc(u32, view.width * view.height * 4);
    defer a.free(pixels);
    view.paint(.{ .pixels = pixels, .width = view.width * 2, .height = view.height * 2 });
    try std.testing.expectEqual(@as(u32, 0), pixels[0]);
    try std.testing.expect(pixels[100 * view.width * 2 + 100] != 0);
}

test "native tooltips preserve explicit line breaks without forcing a fixed width" {
    var renderer: text.Renderer = .{};
    defer renderer.deinit();
    var label: Label = .{};
    defer label.deinit();
    label.set("5h: 54% remaining");
    try label.prepare(&renderer, 1, 13.333, false, null, false);
    const height = label.height();
    label.set("5h: 54% remaining\n7d: 93% remaining");
    try label.prepare(&renderer, 1, 13.333, false, null, false);
    try std.testing.expect(label.height() > height * 1.5);
    try std.testing.expect(label.width() < 300);
}
