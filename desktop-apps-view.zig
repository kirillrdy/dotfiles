//! GNOME 50 app-grid geometry and native pixels. Theme references:
//! gnome-shell-sass/widgets/{_app-grid,_search-entry}.scss and js/ui/iconGrid.js.
const std = @import("std");
const c = @import("desktop-gtk.zig");
const raster = @import("desktop-raster.zig");
const text = @import("desktop-text.zig");
const a = if (@import("builtin").is_test) std.testing.allocator else std.heap.c_allocator;
pub const Rect = raster.Rect;
pub fn color(rgb: u32) raster.Color {
    return raster.Color.rgb(rgb, 1);
}
fn rounded(canvas: raster.Canvas, rect: Rect, radius: f64, rgb: u32) void {
    canvas.draw(&.{rect.shape(radius)}, color(rgb));
}
pub const Grid = struct {
    width: f64,
    height: f64,
    columns: usize,
    rows: usize,
    icon_size: u32,
    tile_size: f64,
    x: f64,
    y: f64,
    dx: f64,
    dy: f64,
    pub fn init(width: u32, height: u32) Grid {
        const w: f64 = @floatFromInt(width);
        const h: f64 = @floatFromInt(height);
        // GNOME chooses the closest aspect ratio, always keeping 24 slots.
        const available_w = @max(1, w * 0.8 - 36);
        const available_h = @max(1, h - 40 - 48);
        const modes = [_][2]usize{ .{ 3, 8 }, .{ 4, 6 }, .{ 6, 4 }, .{ 8, 3 } };
        var columns: usize = 3;
        var rows: usize = 8;
        var distance = std.math.inf(f64);
        for (modes) |mode| {
            const ratio = @as(f64, @floatFromInt(mode[0])) / @as(f64, @floatFromInt(mode[1]));
            const delta = @abs(available_w / available_h - ratio);
            if (delta < distance) {
                distance = delta;
                columns = mode[0];
                rows = mode[1];
            }
        }
        const cols: f64 = @floatFromInt(columns);
        const rs: f64 = @floatFromInt(rows);
        var icon_size: u32 = 16;
        for ([_]u32{ 96, 64, 48, 32, 24, 16 }) |size| {
            // Square tiles: 12px padding, 6px icon-label gap, 19px text.
            const tile_extent: f64 = @floatFromInt(size + 49);
            if (cols * tile_extent + (cols - 1) * 12 <= available_w and rs * tile_extent + (rs - 1) * 12 <= available_h) {
                icon_size = size;
                break;
            }
        }
        const tile_extent: f64 = @floatFromInt(icon_size + 49);
        const gap_x = std.math.clamp((available_w - cols * tile_extent) / @max(1, cols - 1), 12, 36);
        const gap_y = std.math.clamp((available_h - rs * tile_extent) / @max(1, rs - 1), 12, 36);
        return .{ .width = w, .height = h, .columns = columns, .rows = rows, .icon_size = icon_size, .tile_size = tile_extent, .dx = tile_extent + gap_x, .dy = tile_extent + gap_y, .x = @floor((w - cols * tile_extent - (cols - 1) * gap_x) / 2), .y = @floor((h - 40 - rs * tile_extent - (rs - 1) * gap_y) / 2) };
    }
    pub fn capacity(self: Grid) usize {
        return self.columns * self.rows;
    }
    pub fn tile(self: Grid, slot: usize) Rect {
        return .{ .x = @floor(self.x + @as(f64, @floatFromInt(slot % self.columns)) * self.dx), .y = @floor(self.y + @as(f64, @floatFromInt(slot / self.columns)) * self.dy), .width = self.tile_size, .height = self.tile_size };
    }
    pub fn hit(self: Grid, x: f64, y: f64) ?usize {
        for (0..self.capacity()) |i| if (self.tile(i).contains(x, y)) return i;
        return null;
    }
};
fn drawMask(canvas: raster.Canvas, mask: text.Mask, x: f64, y: f64, rgb: u32) void {
    raster.mask(canvas.target, .{ .x = @as(i32, @intFromFloat(@round(x * canvas.scale))) + mask.left, .y = @as(i32, @intFromFloat(@round(y * canvas.scale))) + mask.top, .width = mask.width, .height = mask.height }, mask.pixels, color(rgb));
}
pub const Tile = struct {
    mask: ?text.Mask = null,
    pixbuf: ?*c.GdkPixbuf = null,
    scale: u32 = 0,
    size: u32 = 0,
    pub fn deinit(self: *Tile) void {
        if (self.mask) |mask| mask.deinit(a);
        if (self.pixbuf) |image| c.g_object_unref(image);
        self.* = .{};
    }
    pub fn paint(self: *Tile, canvas: raster.Canvas, scale: u32, renderer: *text.Renderer, name: [*c]const u8, icon: ?*c.GIcon, rect: Rect, size: u32, hover: bool, focused: bool, selected: bool, pressed: bool) !void {
        if (self.scale != scale or self.size != size) {
            self.deinit();
            self.mask = try renderer.renderLayout(a, std.mem.span(name), .{ .size = 14.6666666667 * canvas.scale, .dpi = 96 * canvas.scale, .width = @intFromFloat((rect.width - 24) * canvas.scale), .alignment = .center, .ellipsize = true, .origin = .top });
            const theme = c.gtk_icon_theme_get_default();
            if (icon) |gicon| if (c.gtk_icon_theme_lookup_by_gicon(theme, gicon, @intCast(size * scale), c.GTK_ICON_LOOKUP_FORCE_SIZE)) |info| {
                defer c.g_object_unref(info);
                self.pixbuf = c.gtk_icon_info_load_icon(info, null);
            };
            if (self.pixbuf == null) self.pixbuf = c.gtk_icon_theme_load_icon(theme, "application-x-executable", @intCast(size * scale), c.GTK_ICON_LOOKUP_FORCE_SIZE, null);
            self.scale = scale;
            self.size = size;
        }
        // GNOME system base #222226; hover and press lighten by 7% / 9%.
        if (hover or focused or pressed) rounded(canvas, rect, 24, if (pressed) (if (hover) @as(u32, 0x484851) else @as(u32, 0x38383f)) else if (hover) 0x333339 else 0x292b34);
        // GNOME :selected lightens the base by 8%, plus hover/active lightening.
        if (selected) rounded(canvas, rect, 24, if (pressed) @as(u32, 0x4b4b54) else if (hover) 0x46464e else 0x35353c);
        if (focused) canvas.draw(&.{.{ .rounded_stroke = .{ .rect = .{ .x = rect.x + 1, .y = rect.y + 1, .width = rect.width - 2, .height = rect.height - 2 }, .radius = 23, .width = 2 } }}, color(0x719ed2));
        const icon_size: f64 = @floatFromInt(size);
        if (self.pixbuf) |image| {
            const source = c.__zig.pixbufImage(image);
            const aspect = @as(f64, @floatFromInt(source.width)) / @as(f64, @floatFromInt(source.height));
            const iw = if (aspect > 1) icon_size else icon_size * aspect;
            const ih = if (aspect > 1) icon_size / aspect else icon_size;
            try raster.blit(canvas.target, source, .{ .x = (rect.x + (rect.width - iw) / 2) * canvas.scale, .y = (rect.y + 12 + (icon_size - ih) / 2) * canvas.scale, .width = iw * canvas.scale, .height = ih * canvas.scale }, null);
        }
        drawMask(canvas, self.mask.?, rect.x + 12, rect.y + 12 + icon_size + 6, 0xfafafb);
    }
};
pub const Search = struct {
    find: ?*c.GdkPixbuf = null,
    clear: ?*c.GdkPixbuf = null,
    scale: u32 = 0,
    pub fn deinit(self: *Search) void {
        if (self.find) |image| c.g_object_unref(image);
        if (self.clear) |image| c.g_object_unref(image);
        self.* = .{};
    }
    fn prepare(self: *Search, scale: u32) void {
        if (self.scale == scale) return;
        self.deinit();
        self.find = symbol("edit-find-symbolic", scale);
        self.clear = symbol("edit-clear-symbolic", scale);
        self.scale = scale;
    }
    fn symbol(name: [:0]const u8, scale: u32) ?*c.GdkPixbuf {
        const info = c.gtk_icon_theme_lookup_icon(c.gtk_icon_theme_get_default(), name, @intCast(16 * scale), c.GTK_ICON_LOOKUP_FORCE_SIZE) orelse return null;
        defer c.g_object_unref(info);
        const tint: c.GdkRGBA = .{ .red = 0.98, .green = 0.98, .blue = 0.984, .alpha = 0.7 };
        return c.gtk_icon_info_load_symbolic(info, &tint, null, null, null, null, null);
    }
    fn paintIcon(image: ?*c.GdkPixbuf, canvas: raster.Canvas, x: f64, y: f64) !void {
        const pixbuf = image orelse return;
        try raster.blit(canvas.target, c.__zig.pixbufImage(pixbuf), .{ .x = x * canvas.scale, .y = y * canvas.scale, .width = 16 * canvas.scale, .height = 16 * canvas.scale }, null);
    }
};
pub fn paintPages(canvas: raster.Canvas, grid: Grid, page: usize, count: usize) void {
    if (count <= 1) return;
    const start = (grid.width - @as(f64, @floatFromInt(count * 34))) / 2;
    for (0..count) |i| canvas.draw(&.{.{ .circle = .{ .center = .{ .x = start + @as(f64, @floatFromInt(i * 34)) + 17, .y = grid.height - 20 }, .radius = if (i == page) 5 else 3 } }}, color(if (i == page) 0xfafafb else 0x78787b));
    for ([_]bool{ false, true }) |next| {
        if ((next and page + 1 >= count) or (!next and page == 0)) continue;
        const x = if (next) grid.width * 0.95 else grid.width * 0.05;
        const y = (grid.height - 40) / 2;
        const sign: f64 = if (next) 1 else -1;
        canvas.draw(&.{ .{ .line = .{ .start = .{ .x = x - 4 * sign, .y = y - 7 }, .end = .{ .x = x + 3 * sign, .y = y }, .radius = 1.5 } }, .{ .line = .{ .start = .{ .x = x + 3 * sign, .y = y }, .end = .{ .x = x - 4 * sign, .y = y + 7 }, .radius = 1.5 } } }, color(0xfafafb));
    }
}
pub fn measure(renderer: *text.Renderer, value: []const u8, scale: u32) !f64 {
    const z = try a.dupeSentinel(u8, value, 0);
    defer a.free(z);
    const factor: f64 = @floatFromInt(scale);
    const mask = try renderer.renderLayout(a, z, .{ .size = 14.6666666667 * factor, .dpi = 96 * factor });
    defer mask.deinit(a);
    return @as(f64, @floatFromInt(mask.logical_width)) / factor;
}
pub fn centerText(target: raster.Buffer, scale: u32, renderer: *text.Renderer, value: [:0]const u8, rgb: u32) !void {
    const factor: f64 = @floatFromInt(scale);
    const mask = try renderer.renderLayout(a, value, .{ .size = 14.6666666667 * factor, .dpi = 96 * factor, .width = @max(1, target.width - @min(target.width - 1, 48 * scale)), .alignment = .center, .lines = 2, .ellipsize = true, .origin = .top });
    defer mask.deinit(a);
    drawMask(.{ .target = target, .scale = factor }, mask, 24, (@as(f64, @floatFromInt(target.height)) - @as(f64, @floatFromInt(mask.logical_height))) / (2 * factor), rgb);
}
pub fn paintSearch(target: raster.Buffer, scale: u32, renderer: *text.Renderer, icons: *Search, entry: anytype, hover: bool, offset: *f64) !void {
    const factor: f64 = @floatFromInt(scale);
    const canvas: raster.Canvas = .{ .target = target, .scale = factor };
    const w = @as(f64, @floatFromInt(target.width)) / factor;
    const h = @as(f64, @floatFromInt(target.height)) / factor;
    rounded(canvas, .{ .x = 0, .y = 0, .width = w, .height = h }, h / 2, if (entry.focused) 0x43464c else if (hover) 0x4a4a50 else 0x404045);
    if (entry.focused) canvas.draw(&.{.{ .rounded_stroke = .{ .rect = .{ .x = 1, .y = 1, .width = w - 2, .height = h - 2 }, .radius = h / 2 - 1, .width = 2 } }}, color(0x719ed2));
    icons.prepare(scale);
    try Search.paintIcon(icons.find, canvas, 13, @floor((h - 16) / 2) + 1);
    const value = entry.buffer.valueZ();
    const cursor = try measure(renderer, value[0..entry.buffer.cursor], scale);
    const anchor = try measure(renderer, value[0..entry.buffer.anchor], scale);
    const available = @max(1, w - 82);
    if (cursor - offset.* > available) offset.* = cursor - available;
    if (cursor < offset.*) offset.* = cursor;
    if (value.len == 0) offset.* = 0;
    // Paint text into a clipped scratch strip, keeping long queries off icons.
    const strip_width: u32 = @intFromFloat(available * factor);
    const pixels = try a.alloc(u32, strip_width * target.height);
    defer a.free(pixels);
    @memset(pixels, 0);
    const strip: raster.Buffer = .{ .pixels = pixels, .width = strip_width, .height = target.height };
    const sc: raster.Canvas = .{ .target = strip, .scale = factor };
    const mask = try renderer.renderLayout(a, if (value.len == 0) "Type to search" else value, .{ .size = 14.6666666667 * factor, .dpi = 96 * factor, .origin = .top });
    defer mask.deinit(a);
    const y = (h - @as(f64, @floatFromInt(mask.logical_height)) / factor) / 2;
    if (entry.buffer.selected() and entry.focused) rounded(sc, .{ .x = @min(cursor, anchor) - offset.*, .y = y, .width = @abs(cursor - anchor), .height = @as(f64, @floatFromInt(mask.logical_height)) / factor }, 0, 0x36577d);
    drawMask(sc, mask, -offset.*, y, if (value.len == 0) 0xb6b6b9 else 0xfafafb);
    if (entry.focused and entry.caret) rounded(sc, .{ .x = cursor - offset.*, .y = 9, .width = 1, .height = h - 18 }, 0, 0xfafafb);
    const x0: usize = @intFromFloat(41 * factor);
    for (0..target.height) |row| for (0..strip_width) |col| {
        const destination = &target.pixels[row * target.width + x0 + col];
        destination.* = raster.over(destination.*, pixels[row * strip_width + col]);
    };
    if (value.len != 0) {
        try Search.paintIcon(icons.clear, canvas, w - 29, @floor((h - 16) / 2) + 1);
    }
}

test "app-grid modes keep 24 slots and hit tests respect tile gaps" {
    for ([_][2]u32{ .{ 1280, 660 }, .{ 1920, 900 }, .{ 800, 1000 }, .{ 600, 1300 } }) |size| {
        const grid = Grid.init(size[0], size[1]);
        try std.testing.expectEqual(@as(usize, 24), grid.capacity());
        for (0..grid.capacity()) |i| {
            const rect = grid.tile(i);
            try std.testing.expect(rect.x >= 48 and rect.y >= 0);
            try std.testing.expect(rect.x + rect.width <= grid.width - 48);
            try std.testing.expect(rect.y + rect.height <= grid.height - 40);
            try std.testing.expectEqual(@as(?usize, i), grid.hit(rect.x + rect.width / 2, rect.y + rect.height / 2));
            try std.testing.expectEqual(@as(?usize, null), grid.hit(rect.x + rect.width + 1, rect.y + 1));
        }
    }
}

test "grid matches measured GNOME 50.4 allocation at 1280 by 720" {
    // Headless GNOME: grid 1280x392, plus our 40px pagination footer.
    // First tile at (146,24), 97px square, with 48px icons, 8 columns.
    const grid = Grid.init(1280, 432);
    try std.testing.expectEqual(@as(usize, 8), grid.columns);
    try std.testing.expectEqual(@as(u32, 48), grid.icon_size);
    try std.testing.expectEqual(@as(f64, 97), grid.tile_size);
    try std.testing.expectEqual(@as(f64, 146), grid.tile(0).x);
    try std.testing.expectEqual(@as(f64, 24), grid.tile(0).y);
    try std.testing.expectEqual(@as(f64, 273), grid.tile(1).x);
    try std.testing.expectEqual(@as(f64, 147), grid.tile(8).y);
}
