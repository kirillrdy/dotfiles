//! GNOME 51 overview geometry and unaligned window layout (workspace.js).
const std = @import("std");
pub const Rect = @import("desktop-capture.zig").Rect;

pub const Geometry = struct {
    strip_y: f64,
    strip_height: f64,
    thumbnail_width: f64,
    thumbnail_height: f64,
    stage_y: f64,
    stage_height: f64,
    pub fn init(width: f64, height: f64, footer: f64, count: usize) Geometry {
        const spacing = @round(height * 0.02);
        const strip_height = @min(height * 0.05, @max(0, width - 12 - @as(f64, @floatFromInt(count -| 1)) * 6) / @as(f64, @floatFromInt(@max(1, count))) * height / @max(1, width) + 12);
        const thumbnail_height = @max(1, @round(strip_height - 12));
        const strip_y = 55 + @round(spacing * 0.6);
        const stage_y = strip_y + strip_height + @round(spacing * 0.4);
        return .{ .strip_y = strip_y, .strip_height = strip_height, .thumbnail_width = @round(thumbnail_height * width / @max(1, height)), .thumbnail_height = thumbnail_height, .stage_y = stage_y, .stage_height = @max(1, @round(height - footer - spacing - stage_y)) };
    }
};

pub const Item = struct {
    geometry: Rect,
    index: usize,
    slot: Rect = .{},
    scale: f64 = 1,
    fn vertical(_: void, l: Item, r: Item) bool {
        return l.geometry.y + l.geometry.h / 2 < r.geometry.y + r.geometry.h / 2;
    }
    fn horizontal(_: void, l: Item, r: Item) bool {
        return l.geometry.x + l.geometry.w / 2 < r.geometry.x + r.geometry.w / 2;
    }
};
const Row = struct { start: usize, end: usize, width: f64 = 0, height: f64 = 0 };
const Candidate = struct { scale: f64, space: f64, height: f64 };
pub const Layout = struct {
    items: std.ArrayList(Item) = .empty,
    rows: std.ArrayList(Row) = .empty,
    pub fn deinit(self: *Layout, a: std.mem.Allocator) void {
        self.items.deinit(a);
        self.rows.deinit(a);
    }
    fn candidate(self: *Layout, a: std.mem.Allocator, n: usize, area: Rect) !Candidate {
        self.rows.clearRetainingCapacity();
        std.mem.sort(Item, self.items.items, {}, Item.vertical);
        var total: f64 = 0;
        for (self.items.items) |item| total += item.geometry.w * item.scale;
        const ideal = total / @as(f64, @floatFromInt(n));
        var cursor: usize = 0;
        var grid_width: f64 = 0;
        var grid_height: f64 = 0;
        var max_columns: usize = 1;
        for (0..n) |i| {
            var row: Row = .{ .start = cursor, .end = cursor };
            while (cursor < self.items.items.len) : (cursor += 1) {
                const item = self.items.items[cursor];
                const w = item.geometry.w * item.scale;
                row.height = @max(row.height, item.geometry.h * item.scale);
                if (row.width + w <= ideal or @abs(1 - (row.width + w) / ideal) < @abs(1 - row.width / ideal) or i == n - 1) {
                    row.width += w;
                    row.end = cursor + 1;
                } else break;
            }
            std.mem.sort(Item, self.items.items[row.start..row.end], {}, Item.horizontal);
            if (row.width > grid_width) {
                grid_width = row.width;
                max_columns = row.end - row.start;
            }
            grid_height += row.height;
            try self.rows.append(a, row);
        }
        const hs = @as(f64, @floatFromInt(max_columns -| 1)) * 32;
        const vs = @as(f64, @floatFromInt(n - 1)) * 32;
        const scale = @max(0, @min(0.95, @min((area.w - hs) / @max(1, grid_width), (area.h - vs) / @max(1, grid_height))));
        return .{ .scale = scale, .space = (grid_width * scale + hs) * (grid_height * scale + vs) / (area.w * area.h), .height = grid_height * scale };
    }
    pub fn compute(self: *Layout, a: std.mem.Allocator, monitor_height: f64, workarea: Rect, area: Rect) !void {
        if (self.items.items.len == 0) return;
        for (self.items.items) |*item| item.scale = 1.5 - 0.5 * item.geometry.h / monitor_height;
        var best: Candidate = undefined;
        var best_rows: usize = 1;
        var last_columns: usize = 0;
        var n: usize = 1;
        while (n <= self.items.items.len) : (n += 1) {
            const columns = (self.items.items.len + n - 1) / n;
            if (columns == last_columns) break;
            const next = try self.candidate(a, n, workarea);
            if (n > 1) {
                const better = if (next.scale > best.scale and next.space > best.space) true else if (next.scale > best.scale) next.scale - best.scale > (next.space - best.space) * 0.1 else if (next.space > best.space) (next.space - best.space) * 0.1 > next.scale - best.scale else false;
                if (!better) break;
            }
            best = next;
            best_rows = n;
            last_columns = columns;
        }
        best = try self.candidate(a, best_rows, workarea);
        const vs = @as(f64, @floatFromInt(best_rows - 1)) * 32;
        const vertical_scale = @min(1, @max(0, area.h - vs) / @max(1, best.height));
        var compensation: f64 = 0;
        for (self.rows.items) |row| {
            const hs = @as(f64, @floatFromInt((row.end - row.start) -| 1)) * 32;
            const horizontal_scale = @min(1, @max(0, area.w - hs) / @max(1, row.width * best.scale));
            compensation += @max(0, vertical_scale - horizontal_scale) * row.height * best.scale;
        }
        var y: f64 = 0;
        for (self.rows.items) |row| {
            const hs = @as(f64, @floatFromInt((row.end - row.start) -| 1)) * 32;
            const extra = @min(vertical_scale, @min(1, @max(0, area.w - hs) / @max(1, row.width * best.scale)));
            var x = area.x + @max(0, area.w - (row.width * best.scale * extra + hs)) / 2;
            const row_y = area.y + @max(0, area.h - (best.height + vs)) / 2 + y + compensation / 2;
            const row_height = row.height * best.scale * extra;
            for (self.items.items[row.start..row.end]) |*item| {
                const s = best.scale * item.scale * extra;
                const cw = item.geometry.w * s;
                const ch = item.geometry.h * s;
                const w = item.geometry.w * @min(s, 0.95);
                const h = item.geometry.h * @min(s, 0.95);
                item.slot = .{ .x = @floor(x + (cw - w) / 2), .y = @floor(row_y + (if (best_rows == 1) (row_height - h) / 2 else row_height - ch)), .w = w, .h = h };
                x += cw + 32;
            }
            y += row_height + 32;
        }
    }
};

// Frozen measurements from GNOME Shell 50.4's headless test tool, at scale 1.
test "overview allocations match GNOME at 720p and 1080p" {
    const small = Geometry.init(1280, 688, 96, 4);
    try std.testing.expectApproxEqAbs(@as(f64, 63), small.strip_y, 0.01);
    try std.testing.expectEqual(@as(f64, 41), small.thumbnail_width);
    try std.testing.expectEqual(@as(f64, 22), small.thumbnail_height);
    try std.testing.expectApproxEqAbs(@as(f64, 103.4), small.stage_y, 0.01);
    try std.testing.expectEqual(@as(f64, 475), small.stage_height);
    const large = Geometry.init(1728, 1048, 112, 4);
    try std.testing.expectEqual(@as(f64, 66), large.thumbnail_width);
    try std.testing.expectEqual(@as(f64, 40), large.thumbnail_height);
    try std.testing.expectApproxEqAbs(@as(f64, 128.4), large.stage_y, 0.01);
    try std.testing.expectEqual(@as(f64, 787), large.stage_height);
}

test "window slots reproduce measured GNOME unaligned layout" {
    const a = std.testing.allocator;
    var layout: Layout = .{};
    defer layout.deinit(a);
    for (0..4) |i| try layout.items.append(a, .{ .geometry = .{ .x = 544 + @as(f64, @floatFromInt(i)) * 50, .y = 328 + @as(f64, @floatFromInt(i)) * 50, .w = 640, .h = 457 }, .index = i });
    try layout.compute(a, 1080, .{ .w = 1728, .h = 1048 }, .{ .w = 1298, .h = 787 });
    const expected = [_]Rect{
        .{ .x = 104, .y = 0, .w = 528.66520787746, .h = 377.5 },
        .{ .x = 665, .y = 0, .w = 528.66520787746, .h = 377.5 },
        .{ .x = 104, .y = 409, .w = 528.66520787746, .h = 377.5 },
        .{ .x = 665, .y = 409, .w = 528.66520787746, .h = 377.5 },
    };
    for (layout.items.items) |item| {
        const want = expected[item.index];
        try std.testing.expectEqual(want.x, item.slot.x);
        try std.testing.expectEqual(want.y, item.slot.y);
        try std.testing.expectApproxEqAbs(want.w, item.slot.w, 0.01);
        try std.testing.expectApproxEqAbs(want.h, item.slot.h, 0.01);
    }
}

test "small windows never enlarge past GNOME's preview cap" {
    const a = std.testing.allocator;
    var layout: Layout = .{};
    defer layout.deinit(a);
    try layout.items.append(a, .{ .geometry = .{ .w = 200, .h = 160 }, .index = 0 });
    try layout.compute(a, 1080, .{ .w = 1728, .h = 1048 }, .{ .w = 1298, .h = 787 });
    try std.testing.expectApproxEqAbs(@as(f64, 190), layout.items.items[0].slot.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 152), layout.items.items[0].slot.h, 0.01);
}

// GNOME Shell 51.0, 1728x1080, 32px panel and 112px dash; four maximized clients.
test "GNOME 51 picker slots use the container rather than the wallpaper inset" {
    const a = std.testing.allocator;
    const geometry = Geometry.init(1728, 1048, 112, 4);
    try std.testing.expectEqual(@as(f64, 40), geometry.thumbnail_height);
    try std.testing.expectApproxEqAbs(@as(f64, 160.4), 32 + geometry.stage_y, 0.01);
    var picker: Layout = .{};
    defer picker.deinit(a);
    for (0..4) |i| try picker.items.append(a, .{ .geometry = .{ .x = 0, .y = 32, .w = 1728, .h = 1048 }, .index = i });
    const container_width = @ceil(geometry.stage_height * 1728 / 1048);
    try picker.compute(a, 1080, .{ .w = 1728, .h = 1048 }, .{ .w = container_width, .h = geometry.stage_height });
    const expected_x = [_]f64{ 225, 879, 225, 879 };
    const expected_y = [_]f64{ 160.4, 160.4, 569.4, 569.4 };
    for (picker.items.items) |item| {
        try std.testing.expectApproxEqAbs(expected_x[item.index], (1728 - container_width) / 2 + item.slot.x, 0.01);
        try std.testing.expectApproxEqAbs(expected_y[item.index], 32 + geometry.stage_y + item.slot.y, 0.01);
        try std.testing.expectApproxEqAbs(@as(f64, 622.4427480916031), item.slot.w, 0.01);
        try std.testing.expectApproxEqAbs(@as(f64, 377.5), item.slot.h, 0.01);
    }
}

test "overview geometry remains finite for an unconfigured or tiny output" {
    for ([_][2]f64{ .{ 0, 0 }, .{ 1, 1 }, .{ 12, 20 } }) |size| {
        const geometry = Geometry.init(size[0], size[1], 112, 4);
        for ([_]f64{ geometry.strip_y, geometry.strip_height, geometry.thumbnail_width, geometry.thumbnail_height, geometry.stage_y, geometry.stage_height }) |value| try std.testing.expect(std.math.isFinite(value));
        try std.testing.expect(geometry.strip_height >= 0);
        try std.testing.expect(geometry.stage_height >= 1);
    }
}
