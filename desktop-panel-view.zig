//! Cached native panel content and Codex/Claude usage controls.
const std = @import("std");
const raster = @import("desktop-raster.zig");
const text = @import("desktop-text.zig");
const decode = @import("desktop-decode.zig");
const imaging = @import("desktop-image.zig");
const mainloop = @import("desktop-loop.zig");
pub const Rect = raster.Rect;
const white: raster.Color = .{ .red = 1, .green = 1, .blue = 1 };
const overview_foreground: raster.Color = .{ .red = 250.0 / 255.0, .green = 250.0 / 255.0, .blue = 251.0 / 255.0 };
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
    pub fn set(self: *Label, a: std.mem.Allocator, value: []const u8) void {
        if (std.mem.eql(u8, self.value, value)) return;
        const copy = a.dupeSentinel(u8, value, 0) catch @panic("out of memory");
        self.deinit(a);
        self.* = .{ .value = copy, .owned = true };
    }
    pub fn deinit(self: *Label, a: std.mem.Allocator) void {
        if (self.mask) |mask| mask.deinit(a);
        if (self.owned) a.free(self.value);
        self.* = .{};
    }
    pub fn prepare(self: *Label, a: std.mem.Allocator, renderer: *text.Renderer, scale: u32, size: f64, bold: bool, limit: ?u32, markup: bool) !void {
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
pub const Tooltip = struct {
    label: Label = .{},
    timer: u32 = 0,
    visible: bool = false,
    x: f64 = 0,
    y: f64 = 0,

    pub fn deinit(self: *Tooltip, a: std.mem.Allocator) void {
        self.hide();
        self.label.deinit(a);
    }
    pub fn hide(self: *Tooltip) void {
        if (self.timer != 0) _ = mainloop.remove(self.timer);
        self.timer = 0;
        self.visible = false;
    }
    pub fn update(self: *Tooltip, a: std.mem.Allocator, x: f64, y: f64, value: ?[:0]const u8, active: bool, context: anytype, comptime callback: anytype) void {
        self.x = x;
        self.y = y;
        self.hide();
        self.label.set(a, value orelse "");
        if (active and value != null) self.timer = mainloop.timeout(500, context, callback);
    }
    pub fn show(self: *Tooltip) void {
        self.timer = 0;
        self.visible = true;
    }
    pub fn paint(self: *Tooltip, a: std.mem.Allocator, target: raster.Buffer, renderer: *text.Renderer, scale: u32) !void {
        if (!self.visible or self.label.value.len == 0) return;
        const logical_width = target.width / scale;
        const logical_height = target.height / scale;
        try self.label.prepare(a, renderer, scale, 12, false, logical_width -| 32, false);
        const w = @min(@as(f64, @floatFromInt(logical_width)), self.label.width() + 16);
        const h = self.label.height() + 12;
        const x = std.math.clamp(self.x + 12, 0, @max(0, @as(f64, @floatFromInt(logical_width)) - w));
        const y = std.math.clamp(self.y + 24, 0, @max(0, @as(f64, @floatFromInt(logical_height)) - h));
        @import("desktop-preferences-view.zig").fill(.{ .target = target, .scale = @floatFromInt(scale) }, .{ .x = x, .y = y, .width = w, .height = h }, 0x161619, 6);
        self.label.paint(target, x + 8, y + 6, white);
    }
};
pub const Item = struct {
    label: Label = .{},
    icon: Label = .{},
    tooltip: Label = .{},
    command: Label = .{},
    image: ?decode.Image = null,
    icon_scale: u32 = 0,
    visible: bool = false,
    rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    pub fn deinit(self: *Item, a: std.mem.Allocator) void {
        self.label.deinit(a);
        self.icon.deinit(a);
        self.tooltip.deinit(a);
        self.command.deinit(a);
        if (self.image) |image| decode.free(a, image);
        self.image = null;
    }
    pub fn setIcon(self: *Item, a: std.mem.Allocator, value: []const u8) void {
        if (std.mem.eql(u8, self.icon.value, value)) return;
        self.icon.set(a, value);
        if (self.image) |image| decode.free(a, image);
        self.image = null;
        self.icon_scale = 0;
    }
    fn prepare(self: *Item, a: std.mem.Allocator, renderer: *text.Renderer, scale: u32, small: bool) !void {
        try self.label.prepare(a, renderer, scale, if (small) 12 else 14.666, true, null, false);
        if (self.icon_scale == scale) return;
        if (self.image) |image| decode.free(a, image);
        self.image = null;
        if (self.icon.value.len != 0) {
            self.image = @import("desktop-icons.zig").load(a, self.icon.value, 16, scale, @import("desktop-icons.zig").white);
        }
        self.icon_scale = scale;
    }
    fn paint(self: *const Item, buffer: raster.Buffer, scale: u32, foreground: raster.Color, show_label: bool) void {
        var x = self.rect.x;
        if (self.image) |image| {
            imaging.blit(.{ .target = buffer, .scale = @floatFromInt(scale) }, image, .{ .x = x, .y = (self.rect.height - 16) / 2, .width = 16, .height = 16 });
        }
        if (!show_label) return;
        if (self.icon.value.len != 0) x += 16 + (if (self.label.value.len != 0) @as(f64, 6) else 0);
        self.label.paint(buffer, x, (self.rect.height - self.label.height()) / 2, foreground);
    }
    /// Usage widgets with an icon replace the percent label with the pace bars.
    fn barsReplaceLabel(self: *const Item) bool {
        return self.icon.value.len != 0;
    }
};
pub const Graph = struct {
    history: [5][100]f64 = std.mem.zeroes([5][100]f64),
    colors: [5]raster.Color = @splat(.{ .red = 0, .green = 0, .blue = 0, .alpha = 0 }),
    count: u32 = 0,
    series: u32 = 0,
    sequence: i64 = -1,
    maximum: f64 = 100,
    autoscale: c_int = 0,
    tooltip: Label = .{},
    name: Label = .{},
    pub fn deinit(self: *Graph, a: std.mem.Allocator) void {
        self.tooltip.deinit(a);
        self.name.deinit(a);
    }
    pub fn paint(self: *const Graph, canvas: raster.Canvas, x: f64, width: f64, height: f64) void {
        if (width <= 0 or height <= 0) return;
        // Match system-monitor-next's #ffffff16 chart background and stepped area polygon.
        canvas.draw(&.{.{ .rounded_rect = .{ .rect = .{ .x = x, .y = 0, .width = width, .height = height }, .radius = 0 } }}, .{ .red = 1, .green = 1, .blue = 1, .alpha = @as(f64, 0x16) / 255.0 });
        if (self.series == 0 or self.count < 2) return;
        var maximum = self.maximum;
        if (self.autoscale != 0) {
            maximum = 1;
            for (self.history[self.series - 1][0..self.count]) |v| maximum = @max(maximum, v);
            maximum = std.math.pow(f64, 2, @ceil(std.math.log2(maximum)));
        }
        if (!std.math.isFinite(maximum) or maximum <= 0) return;
        var points: [204]raster.Point = undefined;
        var series = self.series;
        while (series > 0) {
            series -= 1;
            var has_nonzero = false;
            for (self.history[series][0..self.count]) |v| {
                if (v > 0) {
                    has_nonzero = true;
                    break;
                }
            }
            if (!has_nonzero) continue;
            var len: usize = 0;
            const last = self.count - 1;
            points[len] = .{ .x = x + width, .y = height };
            len += 1;
            var cx = x + width - 0.25;
            points[len] = .{ .x = @max(x, cx), .y = height * (1 - std.math.clamp(self.history[series][last] / maximum, 0, 1)) };
            len += 1;
            cx -= 0.5;
            var j = self.count;
            while (j > 0) {
                j -= 1;
                const y = height * (1 - std.math.clamp(self.history[series][j] / maximum, 0, 1));
                points[len] = .{ .x = @max(x, cx), .y = y };
                len += 1;
                cx -= 0.5;
                points[len] = .{ .x = @max(x, cx), .y = y };
                len += 1;
                cx -= 0.5;
            }
            cx += 0.25;
            points[len] = .{ .x = @max(x, cx), .y = height * (1 - std.math.clamp(self.history[series][0] / maximum, 0, 1)) };
            len += 1;
            points[len] = .{ .x = @max(x, cx), .y = height };
            len += 1;
            canvas.draw(&.{.{ .polygon = points[0..len] }}, self.colors[series]);
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
    usage: bool = false,
    /// Remaining percent and expected pace for the 5-hour (0) and weekly (1) windows.
    window_percent: [2]?f64 = .{ null, null },
    window_pace: [2]?f64 = .{ null, null },
    disk: bool = false,
    hovered: bool = false,
    focus: bool = false,
    overview: bool = false,
    workspace_count: u8 = 2,
    workspace_active: u8 = 0,
    scale: u32 = 1,
    width: u32 = 1,
    pub fn deinit(self: *View, a: std.mem.Allocator) void {
        for (&self.items) |*item| item.deinit(a);
        for (&self.graphs) |*graph| graph.deinit(a);
        self.clock.deinit(a);
        self.renderer.deinit();
    }
    pub fn prepare(self: *View, a: std.mem.Allocator, scale: u32, height: f64) !void {
        self.scale = scale;
        const padding: f64 = if (self.disk) 0 else if (self.usage) 8 else 18;
        var x = padding;
        if (self.activities) {
            const count: usize = @max(1, self.workspace_count);
            x += 26 + @as(f64, @floatFromInt(count - 1)) * 13;
        } else if (self.monitors) {
            for (&self.graphs, [_][:0]const u8{ "cpu", "mem", "net" }) |*graph, name| {
                graph.name.set(a, name);
                try graph.name.prepare(a, &self.renderer, scale, 9.166, true, null, false);
            }
            x += 354;
        } else if (self.clock.value.len != 0) {
            try self.clock.prepare(a, &self.renderer, scale, 14.666, true, null, false);
            x += self.clock.width();
        } else for (&self.items) |*item| {
            if (!item.visible) continue;
            try item.prepare(a, &self.renderer, scale, self.usage);
            const gap: f64 = if (self.status) 8 else 0;
            x += gap / 2;
            const width = if (self.hasBars())
                (if (item.barsReplaceLabel()) @as(f64, 16) else item.label.width()) + usage_bar_spacing + usage_bar_width
            else
                (if (item.icon.value.len != 0) @as(f64, 16) else 0) + (if (item.icon.value.len != 0 and item.label.value.len != 0) @as(f64, 6) else 0) + item.label.width();
            item.rect = .{ .x = x, .y = 0, .width = width, .height = height };
            x += width + gap / 2;
        }
        self.width = @intFromFloat(@ceil(@max(1, x + padding)));
    }
    fn hasBars(self: *const View) bool {
        return self.usage and (self.window_percent[0] != null or self.window_percent[1] != null);
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
        const fg = if (self.overview) overview_foreground else white;
        const pill_color: ?raster.Color = if (self.activities and self.overview)
            .{ .red = fg.red, .green = fg.green, .blue = fg.blue, .alpha = if (self.hovered or self.focus) 0.32 else 0.28 }
        else if ((self.hovered or self.focus) and !self.disk)
            .{ .red = 1, .green = 1, .blue = 1, .alpha = 0.17 }
        else
            null;
        if (pill_color) |color| canvas.draw(&.{.{ .rounded = .{ .x = 3, .y = 3, .width = @max(0, width - 6), .height = @max(0, height - 6) } }}, color);
        const padding: f64 = if (self.disk) 0 else if (self.usage) 8 else 18;
        if (self.activities) {
            const count: usize = @max(1, self.workspace_count);
            const active = @min(self.workspace_active, count - 1);
            const base_radius: f64 = if (count <= 2) 3.625 else if (count <= 5) 3.25 else 2.75;
            const inactive_fg: raster.Color = .{ .red = fg.red, .green = fg.green, .blue = fg.blue, .alpha = 0.50 };
            var dot_x = padding;
            for (0..count) |i| {
                if (i == active) {
                    canvas.draw(&.{.{ .rounded = .{ .x = dot_x, .y = height / 2 - base_radius, .width = 26, .height = base_radius * 2 } }}, fg);
                    dot_x += 26 + 5;
                } else {
                    canvas.draw(&.{.{ .circle = .{ .center = .{ .x = dot_x + 4, .y = height / 2 }, .radius = base_radius * 0.75 } }}, inactive_fg);
                    dot_x += 8 + 5;
                }
            }
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
        } else if (self.clock.value.len != 0) self.clock.paint(buffer, padding, (height - self.clock.height()) / 2, fg) else {
            const has_bars = self.hasBars();
            for (self.items) |item| {
                if (!item.visible) continue;
                item.paint(buffer, self.scale, fg, !has_bars or !item.barsReplaceLabel());
                if (!has_bars) continue;
                // Icon on the left; 5-hour bar on top, weekly bar underneath, centred vertically.
                const bar_x = item.rect.x + item.rect.width - usage_bar_width;
                const top = (height - 2 * usage_bar_height - usage_bar_gap) / 2;
                for (self.window_percent, self.window_pace, 0..) |percent, pace, i| {
                    const y = top + @as(f64, @floatFromInt(i)) * (usage_bar_height + usage_bar_gap);
                    if (percent) |value| paintUsageBar(canvas, .{ .x = bar_x, .y = y, .width = usage_bar_width, .height = usage_bar_height }, value, pace);
                }
                break;
            }
        }
    }
};

const usage_bar_height: f64 = 6;
const usage_bar_gap: f64 = 3;
const usage_bar_width: f64 = 44;
const usage_bar_spacing: f64 = 8;

fn paintUsageBar(canvas: raster.Canvas, bar: raster.Rect, percent: f64, pace: ?f64) void {
    if (bar.width <= 0 or bar.height <= 0) return;
    const value = std.math.clamp(percent, 0, 100);
    canvas.draw(&.{.{ .rounded = bar }}, .{ .red = 1, .green = 1, .blue = 1, .alpha = 0.16 });
    if (pace) |raw_pace| {
        const expected = std.math.clamp(raw_pace, 0, 100);
        const neutral = raster.hex(0x9ca3af);
        if (value > expected) {
            var filled = bar;
            filled.width = bar.width * value / 100;
            if (filled.width > 0) canvas.draw(&.{.{ .rounded = filled }}, raster.hex(0x10b981));
            var base = bar;
            base.width = bar.width * expected / 100;
            if (base.width > 0) canvas.draw(&.{.{ .rounded = base }}, neutral);
        } else {
            var target = bar;
            target.width = bar.width * expected / 100;
            if (value < expected and target.width > 0) {
                const deficit = expected - value;
                const color = if (deficit >= 20 or value <= 10) raster.hex(0xef4444) else raster.hex(0xf97316);
                canvas.draw(&.{.{ .rounded = target }}, color);
            }
            var base = bar;
            base.width = bar.width * value / 100;
            if (base.width > 0) canvas.draw(&.{.{ .rounded = base }}, neutral);
        }
        const x = bar.x + bar.width * expected / 100;
        const tick: raster.Shape = .{ .line = .{ .start = .{ .x = x, .y = bar.y - 1 }, .end = .{ .x = x, .y = bar.y + bar.height + 1 }, .radius = 0.6 } };
        const outline: raster.Shape = .{ .line = .{ .start = tick.line.start, .end = tick.line.end, .radius = 1.2 } };
        canvas.draw(&.{outline}, .{ .red = 0, .green = 0, .blue = 0, .alpha = 0.65 });
        canvas.draw(&.{tick}, .{ .red = 1, .green = 1, .blue = 1, .alpha = 0.95 });
    } else {
        var filled = bar;
        filled.width = bar.width * value / 100;
        if (filled.width > 0) canvas.draw(&.{.{ .rounded = filled }}, usageColor(value));
    }
}

pub const Usage = struct {
    renderer: text.Renderer = .{},
    titles: [2]Label = .{ .{ .value = "5-Hour Remaining" }, .{ .value = "Weekly Remaining" } },
    percent: [2]Label = .{ .{ .value = "—" }, .{ .value = "—" } },
    reset: [2]Label = .{ .{ .value = "Resets: —" }, .{ .value = "Resets: —" } },
    values: [2]f64 = .{ 0, 0 },
    /// Remaining share expected from even usage; fill beyond the marker is surplus, short of it deficit.
    pace: [2]?f64 = .{ null, null },
    checked: Label = .{ .value = "Checked: —" },
    error_label: Label = .{},
    refresh: Label = .{ .value = "Refresh" },
    refresh_icon: ?text.Mask = null,
    refresh_icon_scale: u32 = 0,
    enabled: bool = false,
    hovered: bool = false,
    pressed: bool = false,
    keyboard_focus: bool = true,
    scale: u32 = 1,
    width: u32 = 340,
    height: u32 = 280,
    pub fn deinit(self: *Usage, a: std.mem.Allocator) void {
        for (&self.titles) |*label| label.deinit(a);
        for (&self.percent) |*label| label.deinit(a);
        for (&self.reset) |*label| label.deinit(a);
        self.checked.deinit(a);
        self.error_label.deinit(a);
        self.refresh.deinit(a);
        if (self.refresh_icon) |mask| mask.deinit(a);
        self.renderer.deinit();
    }
    pub fn prepare(self: *Usage, a: std.mem.Allocator, scale: u32) !void {
        self.scale = scale;
        for (&self.titles) |*label| try label.prepare(a, &self.renderer, scale, 13, true, null, false);
        for (&self.percent) |*label| try label.prepare(a, &self.renderer, scale, 13, true, null, false);
        for (&self.reset) |*label| try label.prepare(a, &self.renderer, scale, 11, false, 300, false);
        try self.refresh.prepare(a, &self.renderer, scale, 12, true, null, false);
        try self.prepareRefreshIcon(a, scale);
        try self.checked.prepare(a, &self.renderer, scale, 10, false, 174, false);
        try self.error_label.prepare(a, &self.renderer, scale, 11, false, 300, false);
        self.height = @intFromFloat(280 + (if (self.error_label.value.len == 0) @as(f64, 0) else self.error_label.height() + 12));
    }
    fn prepareRefreshIcon(self: *Usage, a: std.mem.Allocator, scale: u32) !void {
        if (self.refresh_icon_scale == scale) return;
        const image = @import("desktop-icons.zig").load(a, "view-refresh-symbolic", 14, scale, @import("desktop-icons.zig").white) orelse return;
        defer decode.free(a, image);
        var width: u32 = 0;
        var height: u32 = 0;
        const coverage = try imaging.alphaMask(a, image, &width, &height);
        if (self.refresh_icon) |old| old.deinit(a);
        self.refresh_icon = .{ .pixels = coverage, .width = width, .height = height, .left = 0, .top = 0 };
        self.refresh_icon_scale = scale;
    }
    pub fn refreshRect(_: *const Usage) Rect {
        return .{ .x = 20, .y = 226, .width = 100, .height = 32 };
    }
    pub fn paint(self: *const Usage, buffer: raster.Buffer) void {
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
            if (self.pace[i]) |expected| {
                // Even-usage marker: the fill reaching past it is surplus, stopping short is deficit.
                const x = bar.x + bar.width * std.math.clamp(expected, 0, 100) / 100;
                const marker: raster.Shape = .{ .line = .{ .start = .{ .x = x, .y = bar.y - 4 }, .end = .{ .x = x, .y = bar.y + bar.height + 4 }, .radius = 1 } };
                const outline: raster.Shape = .{ .line = .{ .start = marker.line.start, .end = marker.line.end, .radius = 2 } };
                canvas.draw(&.{outline}, .{ .red = 0, .green = 0, .blue = 0, .alpha = 0.45 });
                canvas.draw(&.{marker}, .{ .red = 1, .green = 1, .blue = 1, .alpha = 0.95 });
            }
            self.reset[i].paint(buffer, 20, y + 46, secondary);
            canvas.draw(&.{.{ .line = .{ .start = .{ .x = 20, .y = y + 82 }, .end = .{ .x = 320, .y = y + 82 }, .radius = 0.5 } }}, .{ .red = 1, .green = 1, .blue = 1, .alpha = 0.1 });
        }
        const button = self.refreshRect();
        canvas.draw(&.{.{ .rounded = .{ .x = button.x, .y = button.y, .width = button.width, .height = button.height } }}, .{ .red = 1, .green = 1, .blue = 1, .alpha = if (self.pressed) 0.18 else if (self.hovered) 0.12 else 0.06 });
        if (self.keyboard_focus and self.enabled) canvas.draw(&.{.{ .rounded_stroke = .{ .rect = .{ .x = button.x, .y = button.y, .width = button.width, .height = button.height }, .radius = 16 } }}, .{ .red = 0.47, .green = 0.68, .blue = 0.93 });
        const foreground: raster.Color = .{ .red = 1, .green = 1, .blue = 1, .alpha = if (self.enabled) 1 else 0.5 };
        const content_x = button.x + (button.width - 14 - 6 - self.refresh.width()) / 2;
        if (self.refresh_icon) |mask| raster.mask(buffer, .{ .x = @intFromFloat(@round(content_x * canvas.scale)), .y = @intFromFloat(@round((button.y + (button.height - 14) / 2) * canvas.scale)), .width = mask.width, .height = mask.height }, mask.pixels, foreground);
        self.refresh.paint(buffer, content_x + 20, button.y + (button.height - self.refresh.height()) / 2, foreground);
        self.checked.paint(buffer, 320 - self.checked.width(), 237, secondary);
        if (self.error_label.value.len != 0) self.error_label.paint(buffer, 20, 274, secondary);
    }
};
pub fn usageColor(value: f64) raster.Color {
    const rgb: [3]f64 = if (value <= 10) .{ 239, 68, 68 } else if (value <= 30) .{ 249, 115, 22 } else if (value <= 60) .{ 234, 179, 8 } else .{ 16, 163, 127 };
    return .{ .red = rgb[0] / 255.0, .green = rgb[1] / 255.0, .blue = rgb[2] / 255.0 };
}

test "panel labels retain masks across hover, refresh at output scale, and drop hidden hit targets" {
    const a = std.testing.allocator;
    var view: View = .{};
    defer view.deinit(a);
    view.items[0].visible = true;
    view.items[0].label.set(a, "54%");
    view.items[1].visible = true;
    view.items[1].label.set(a, "Disk");
    try view.prepare(a, 1, 32);
    const mask = view.items[0].label.mask.?.pixels.ptr;
    const width = view.width;
    view.hovered = true;
    try view.prepare(a, 1, 32);
    try std.testing.expectEqual(mask, view.items[0].label.mask.?.pixels.ptr);
    const rect = view.items[1].rect;
    try std.testing.expectEqual(@as(?usize, 1), view.hit(rect.x + 1, 16));
    view.items[1].visible = false;
    try view.prepare(a, 2, 32);
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

test "integration: Usage wraps errors, scales pixels, and retains remaining-budget colors" {
    const a = std.testing.allocator;
    if (!@import("options").integration_tests) return error.SkipZigTest;
    var view: Usage = .{};
    defer view.deinit(a);
    try view.prepare(a, 1);
    const height = view.height;
    view.error_label.set(a, "Cannot refresh usage. Sign in with codex login and try again.");
    view.values = .{ 54, 0 };
    view.enabled = true;
    try view.prepare(a, 2);
    try std.testing.expect(view.height > height);
    try std.testing.expect(usageColor(10).red > usageColor(100).red);
    const pixels = try a.alloc(u32, view.width * view.height * 4);
    defer a.free(pixels);
    view.paint(.{ .pixels = pixels, .width = view.width * 2, .height = view.height * 2 });
    try std.testing.expectEqual(@as(u32, 0), pixels[0]);
    try std.testing.expect(pixels[100 * view.width * 2 + 100] != 0);
}

test "native tooltips preserve explicit line breaks without forcing a fixed width" {
    const a = std.testing.allocator;
    var renderer: text.Renderer = .{};
    defer renderer.deinit();
    var label: Label = .{};
    defer label.deinit(a);
    label.set(a, "5h: 54% remaining");
    try label.prepare(a, &renderer, 1, 13.333, false, null, false);
    const height = label.height();
    label.set(a, "5h: 54% remaining\n7d: 93% remaining");
    try label.prepare(a, &renderer, 1, 13.333, false, null, false);
    try std.testing.expect(label.height() > height * 1.5);
    try std.testing.expect(label.width() < 300);
}

test "usage panel view paints icon then 5-hour and weekly pace bars instead of the percent label" {
    const a = std.testing.allocator;
    var view: View = .{ .usage = true };
    defer view.deinit(a);
    view.items[0].visible = true;
    view.items[0].setIcon(a, "test-usage-symbolic");
    view.items[0].label.set(a, "54%");

    // Without usage data, the label layout is kept.
    try view.prepare(a, 1, 32);
    const label_width = view.width;

    view.window_percent = .{ 20, 85 };
    view.window_pace = .{ 65, 40 };
    try view.prepare(a, 1, 32);
    const width = view.width;
    try std.testing.expect(width != label_width);
    try std.testing.expectEqual(@as(u32, 8 + 16 + 8 + 44 + 8), width);
    const pixels = try a.alloc(u32, width * 32);
    defer a.free(pixels);

    // Bars are centred: 5-hour spans rows 8.5..14.5, weekly rows 17.5..23.5.
    const five_row = 11 * width;
    const weekly_row = 20 * width;
    const bar_x: f64 = @as(f64, @floatFromInt(width)) - 8 - 44;
    const surplus_x: usize = @intFromFloat(bar_x + 44 * 0.65);
    const deficit_x: usize = @intFromFloat(bar_x + 44 * 0.42);

    // Weekly surplus (85% vs 40% pace) is green; 5-hour deficit (20% vs 65% pace) is red/orange.
    view.paint(.{ .pixels = pixels, .width = width, .height = 32 });
    const surplus_px = pixels[weekly_row + surplus_x];
    try std.testing.expect(((surplus_px >> 8) & 255) > ((surplus_px >> 16) & 255) + 50);
    const deficit_px = pixels[five_row + deficit_x];
    try std.testing.expect(((deficit_px >> 16) & 255) > ((deficit_px >> 8) & 255) + 50);

    // And the other way round.
    view.window_percent = .{ 85, 20 };
    view.window_pace = .{ 40, 65 };
    view.paint(.{ .pixels = pixels, .width = width, .height = 32 });
    const five_surplus = pixels[five_row + surplus_x];
    try std.testing.expect(((five_surplus >> 8) & 255) > ((five_surplus >> 16) & 255) + 50);
    const weekly_deficit = pixels[weekly_row + deficit_x];
    try std.testing.expect(((weekly_deficit >> 16) & 255) > ((weekly_deficit >> 8) & 255) + 50);
}
