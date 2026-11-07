//! Sound settings geometry, keyboard navigation and raster controls.
const std = @import("std");
const raster = @import("desktop-raster.zig");
const text = @import("desktop-text.zig");
const audio = @import("desktop-audio.zig");
pub const Rect = @import("desktop-askpass-view.zig").Rect;
pub const Control = enum { volume, mute, default };
pub const Target = struct {
    row: usize = 0,
    control: Control = .volume,
    pub fn eql(self: Target, other: Target) bool {
        return self.row == other.row and self.control == other.control;
    }
};
pub const Row = struct {
    target: audio.Target,
    title: [:0]const u8,
    heading: ?[:0]const u8 = null,
    device: bool = false,
    state: ?audio.State = null,
    is_default: bool = false,
    pending: ?f64 = null,
    pending_target: ?audio.Target = null,
    title_mask: ?text.Mask = null,
    heading_mask: ?text.Mask = null,
    value_mask: ?text.Mask = null,
    value: [24:0]u8 = @splat(0),
    pub fn invalidate(self: *Row, allocator: std.mem.Allocator) void {
        for ([_]?text.Mask{ self.title_mask, self.heading_mask, self.value_mask }) |mask| if (mask) |m| m.deinit(allocator);
        self.title_mask = null;
        self.heading_mask = null;
        self.value_mask = null;
        self.value = @splat(0);
    }
};
pub const View = struct {
    rows: std.ArrayList(Row) = .empty,
    width: u32 = 560,
    scale: u32 = 0,
    focus: ?Target = null,
    hover: ?Target = null,
    pressed: ?Target = null,
    keyboard_focus: bool = false,
    enabled: bool = true,
    renderer: text.Renderer = .{},
    labels: [5]?text.Mask = @splat(null),
    message: [:0]const u8 = "",
    message_mask: ?text.Mask = null,
    pub fn invalidate(self: *View, allocator: std.mem.Allocator) void {
        for (self.rows.items) |*row| row.invalidate(allocator);
        for (&self.labels) |*mask| {
            if (mask.*) |m| m.deinit(allocator);
            mask.* = null;
        }
        if (self.message_mask) |mask| mask.deinit(allocator);
        self.message_mask = null;
        self.scale = 0;
    }
    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.invalidate(allocator);
        for (self.rows.items) |row| allocator.free(row.title);
        self.rows.deinit(allocator);
        self.renderer.deinit();
    }
    pub fn rowY(self: *const View, index: usize) f64 {
        var y: f64 = 76;
        for (self.rows.items[0..index]) |row| y += 102 + (if (row.heading != null) @as(f64, 36) else 0);
        return y + (if (self.rows.items[index].heading != null) @as(f64, 36) else 0);
    }
    pub fn height(self: *const View) u32 {
        if (self.rows.items.len == 0) return 200;
        return @intFromFloat(self.rowY(self.rows.items.len - 1) + 160);
    }
    pub fn rect(self: *const View, target: Target) Rect {
        const y = self.rowY(target.row) + 36;
        const w: f64 = @floatFromInt(self.width);
        return switch (target.control) {
            .volume => .{ .x = 32, .y = y, .width = w - 296, .height = 36 },
            .mute => .{ .x = w - 202, .y = y, .width = 64, .height = 36 },
            .default => .{ .x = w - 128, .y = y, .width = 96, .height = 36 },
        };
    }
    pub fn active(self: *const View, target: Target) bool {
        if (!self.enabled or target.row >= self.rows.items.len) return false;
        const row = self.rows.items[target.row];
        return row.state != null and (target.control != .default or (row.device and !row.is_default));
    }
    pub fn hit(self: *const View, x: f64, y: f64) ?Target {
        for (self.rows.items, 0..) |_, i| for ([_]Control{ .volume, .mute, .default }) |control| {
            const target: Target = .{ .row = i, .control = control };
            if (self.active(target) and self.rect(target).contains(x, y)) return target;
        };
        return null;
    }
    pub fn percent(self: *const View, target: Target, x: f64) f64 {
        const r = self.rect(target);
        return @round(std.math.clamp((x - r.x - 8) / (r.width - 16), 0, 1) * 100);
    }
    pub fn moveFocus(self: *View, backwards: bool) void {
        const count = self.rows.items.len * 3;
        if (count == 0) return;
        const start = if (self.focus) |f| f.row * 3 + @backingInt(f.control) else if (backwards) @as(usize, 0) else count - 1;
        for (1..count + 1) |step| {
            const index = if (backwards) (start + count - step) % count else (start + step) % count;
            const target: Target = .{ .row = index / 3, .control = @fromBackingInt(@intCast(index % 3)) };
            if (self.active(target)) {
                self.focus = target;
                self.keyboard_focus = true;
                return;
            }
        }
        self.focus = null;
    }
    pub fn prepare(self: *View, allocator: std.mem.Allocator, scale: u32) !void {
        if (self.scale != scale) {
            self.invalidate(allocator);
            self.scale = scale;
        }
        const factor: f64 = @floatFromInt(scale);
        for ([_][:0]const u8{ "Sound", "Mute", "Muted", "Set default", "Default" }, &self.labels) |label, *mask| {
            if (mask.* == null) mask.* = try self.renderer.renderLayout(allocator, label, .{ .size = (if (mask == &self.labels[0]) @as(f64, 22) else 13) * factor, .dpi = 96 * factor, .origin = .top });
        }
        if (self.message.len != 0 and self.message_mask == null) self.message_mask = try self.renderer.renderLayout(allocator, self.message, .{ .size = 13 * factor, .dpi = 96 * factor, .width = (self.width - 64) * scale, .lines = 3, .ellipsize = true, .origin = .top });
        for (self.rows.items) |*row| {
            if (row.title_mask == null) row.title_mask = try self.renderer.renderLayout(allocator, row.title, .{ .size = 15 * factor, .dpi = 96 * factor, .width = (self.width - 64) * scale, .ellipsize = true, .origin = .top });
            if (row.heading) |heading| if (row.heading_mask == null) {
                row.heading_mask = try self.renderer.renderLayout(allocator, heading, .{ .font = "Adwaita Sans Bold", .size = 14 * factor, .dpi = 96 * factor, .origin = .top });
            };
            var buffer: [24]u8 = undefined;
            const value = try std.fmt.bufPrintSentinel(&buffer, "{d:.0}%", .{row.pending orelse if (row.state) |state| state.percent else 0}, 0);
            if (row.value_mask == null or !std.mem.eql(u8, value, std.mem.sliceTo(&row.value, 0))) {
                const mask = try self.renderer.renderLayout(allocator, value, .{ .size = 13 * factor, .dpi = 96 * factor, .origin = .top });
                if (row.value_mask) |old| old.deinit(allocator);
                row.value_mask = mask;
                @memset(&row.value, 0);
                @memcpy(row.value[0..value.len], value);
            }
        }
    }
    pub fn paint(self: *const View, target: raster.Buffer) void {
        @memset(target.pixels, 0xff242428);
        const canvas: raster.Canvas = .{ .target = target, .scale = @floatFromInt(self.scale) };
        drawText(canvas, self.labels[0].?, 24, 24, 0xffffff);
        for (self.rows.items, 0..) |row, i| {
            const y = self.rowY(i);
            if (row.heading_mask) |mask| drawText(canvas, mask, 24, y - 30, 0xd6d6da);
            canvas.draw(&.{.{ .rounded_rect = .{ .rect = .{ .x = 20, .y = y - 6, .width = @floatFromInt(self.width - 40), .height = 90 }, .radius = 12 } }}, color(0x303034));
            const tint: u32 = if (row.state != null) 0xffffff else 0x929296;
            drawText(canvas, row.title_mask.?, 32, y + 6, tint);
            const volume: Target = .{ .row = i };
            const r = self.rect(volume);
            const value = std.math.clamp(row.pending orelse if (row.state) |state| state.percent else 0, 0, 100);
            const knob_x = r.x + 8 + (r.width - 16) * value / 100;
            canvas.draw(&.{.{ .rounded_rect = .{ .rect = .{ .x = r.x + 8, .y = r.y + 15, .width = r.width - 16, .height = 6 }, .radius = 3 } }}, color(0x626268));
            canvas.draw(&.{.{ .rounded_rect = .{ .rect = .{ .x = r.x + 8, .y = r.y + 15, .width = @max(0.01, knob_x - r.x - 8), .height = 6 }, .radius = 3 } }}, color(if (self.active(volume)) 0x3584e4 else 0x626268));
            canvas.draw(&.{.{ .circle = .{ .center = .{ .x = knob_x, .y = r.y + 18 }, .radius = 8 } }}, color(tint));
            drawText(canvas, row.value_mask.?, r.x + r.width + 6, r.y + 10, tint);
            for ([_]Control{ .mute, .default }) |control| {
                if (control == .default and !row.device) continue;
                const t: Target = .{ .row = i, .control = control };
                const bounds = self.rect(t);
                const selected = if (control == .mute) (if (row.state) |state| state.muted else false) else row.is_default;
                const hover = if (self.hover) |h| h.eql(t) else false;
                canvas.draw(&.{.{ .rounded_rect = .{ .rect = .{ .x = bounds.x, .y = bounds.y, .width = bounds.width, .height = bounds.height }, .radius = 8 } }}, color(if (selected) @as(u32, 0x245b98) else if (hover) @as(u32, 0x55555a) else 0x444449));
                const mask = self.labels[if (control == .mute) (if (selected) @as(usize, 2) else 1) else (if (selected) @as(usize, 4) else 3)].?;
                drawText(canvas, mask, bounds.x + (bounds.width - @as(f64, @floatFromInt(mask.logical_width)) / canvas.scale) / 2, bounds.y + 10, if (self.active(t) or selected) 0xffffff else 0x929296);
            }
            if (self.keyboard_focus) if (self.focus) |f| if (f.row == i and self.active(f)) {
                const bounds = self.rect(f);
                canvas.draw(&.{.{ .rounded_stroke = .{ .rect = .{ .x = bounds.x, .y = bounds.y, .width = bounds.width, .height = bounds.height }, .radius = 8, .width = 2 } }}, color(0x99c1f1));
            };
        }
        if (self.message_mask) |mask| drawText(canvas, mask, 24, @as(f64, @floatFromInt(self.height())) - 64, 0xffb4b9);
    }
};
fn color(rgb: u32) raster.Color {
    return raster.Color.rgb(rgb, 1);
}
fn drawText(canvas: raster.Canvas, mask: text.Mask, x: f64, y: f64, tint: u32) void {
    mask.paint(canvas, x, y, color(tint));
}

test "sound controls clamp pointer volume and skip unavailable and default controls" {
    const allocator = std.testing.allocator;
    var view: View = .{};
    defer view.deinit(allocator);
    try view.rows.append(allocator, .{ .target = .output, .title = try allocator.dupeSentinel(u8, "Speakers", 0), .device = true, .state = .{ .percent = 50 }, .is_default = true });
    try view.rows.append(allocator, .{ .target = .input, .title = try allocator.dupeSentinel(u8, "Missing microphone", 0) });
    try std.testing.expectEqual(@as(f64, 0), view.percent(.{}, -100));
    try std.testing.expectEqual(@as(f64, 100), view.percent(.{}, 10000));
    view.moveFocus(false);
    try std.testing.expect(view.focus.?.eql(.{}));
    view.moveFocus(false);
    try std.testing.expect(view.focus.?.eql(.{ .control = .mute }));
    view.moveFocus(false);
    try std.testing.expect(view.focus.?.eql(.{}));
    view.moveFocus(true);
    try std.testing.expect(view.focus.?.eql(.{ .control = .mute }));
    const bounds = view.rect(.{});
    try std.testing.expect(view.hit(bounds.x + 20, bounds.y + 5).?.eql(.{}));
    try std.testing.expect(view.hit(10, 10) == null);
    view.enabled = false;
    try std.testing.expect(view.hit(bounds.x + 20, bounds.y + 5) == null);
}

test "sound view renders at both scales with long labels and empty sections" {
    const allocator = std.testing.allocator;
    var view: View = .{};
    defer view.deinit(allocator);
    view.message = "Audio service unavailable";
    try view.rows.append(allocator, .{ .target = .output, .title = try allocator.dupeSentinel(u8, "A long device title that should fit within the sound settings window without touching controls", 0), .heading = "Output devices", .device = true, .state = .{ .percent = 135, .muted = true } });
    try view.rows.append(allocator, .{ .target = .input, .title = try allocator.dupeSentinel(u8, "None available", 0), .heading = "Input devices" });
    for ([_]u32{ 1, 2 }) |scale| {
        try view.prepare(allocator, scale);
        const pixels = try allocator.alloc(u32, view.width * view.height() * scale * scale);
        defer allocator.free(pixels);
        view.paint(.{ .pixels = pixels, .width = view.width * scale, .height = view.height() * scale });
        try std.testing.expect(std.mem.count(u32, pixels, &.{0xff242428}) < pixels.len);
    }
}
