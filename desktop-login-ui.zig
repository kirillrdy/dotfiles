//! Shared UI primitives and locked secret buffer for the display manager greeter
//! and the session lock screen. No credentials ever enter the drawing helpers.
const std = @import("std");
const libc = @import("desktop-libc.zig");
const raster = @import("desktop-raster.zig");
const text = @import("desktop-text.zig");
const decode = @import("desktop-decode.zig");
const u = @import("desktop-util.zig");

pub const Status = enum { ready, authenticating, failed };

pub const warning: u32 = 0xf8e45c;
pub const accent: u32 = 0x3584e4;

pub const entry_width: f64 = 280;
pub const entry_height: f64 = 36;
pub const button_size: f64 = 36;
pub const row_spacing: f64 = 12;
pub const dot_radius: f64 = 3.5;
pub const dot_spacing: usize = 11;
pub const max_dots: usize = (@as(usize, @intFromFloat(entry_width)) - 24) / dot_spacing;

/// Fixed-size UTF-8 secret buffer with secure erasure and optional mlock-backed allocation.
pub const SecretBuffer = struct {
    bytes: [1024:0]u8 = @splat(0),
    len: usize = 0,

    /// Allocates on dedicated pages and locks them into RAM so munlock never
    /// unlocks unrelated allocations.
    pub fn createLocked() !*SecretBuffer {
        const self = try std.heap.page_allocator.create(SecretBuffer);
        errdefer std.heap.page_allocator.destroy(self);
        self.* = .{};
        if (libc.mlock(self, @sizeOf(SecretBuffer)) != 0) return error.SecretMemoryLockFailed;
        return self;
    }

    pub fn destroyLocked(self: *SecretBuffer) void {
        self.clear();
        _ = libc.munlock(self, @sizeOf(SecretBuffer));
        std.heap.page_allocator.destroy(self);
    }

    pub fn clear(self: *SecretBuffer) void {
        std.crypto.secureZero(u8, &self.bytes);
        self.len = 0;
    }

    pub fn backspace(self: *SecretBuffer) void {
        if (self.len == 0) return;
        self.len -= 1;
        while (self.len > 0 and self.bytes[self.len] & 0xc0 == 0x80) self.len -= 1;
        std.crypto.secureZero(u8, self.bytes[self.len..]);
    }

    pub fn append(self: *SecretBuffer, value: []const u8) void {
        if (value.len > self.bytes.len - self.len - 1) return;
        @memcpy(self.bytes[self.len..][0..value.len], value);
        self.len += value.len;
        self.bytes[self.len] = 0;
    }

    pub fn slice(self: *const SecretBuffer) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn charCount(self: *const SecretBuffer) usize {
        var count: usize = 0;
        for (self.slice()) |byte| count += @intFromBool(byte & 0xc0 != 0x80);
        return count;
    }
};

/// Monotonic spinner rotation in radians (800 ms period).
pub fn spinPhase() f64 {
    const period = 800 * std.time.us_per_ms;
    const phase: f64 = @floatFromInt(@mod(u.monotonicTime(), period));
    return phase / period * 2 * std.math.pi;
}

/// Logical width and height of a rendered text mask at `scale`.
pub fn maskExtent(mask: ?text.Mask, scale: u32) [2]f64 {
    const value = mask orelse return .{ 0, 0 };
    const factor: f64 = @floatFromInt(scale);
    const w = if (value.logical_width != 0) value.logical_width else value.width;
    const h = if (value.logical_height != 0) value.logical_height else value.height;
    return .{ @as(f64, @floatFromInt(w)) / factor, @as(f64, @floatFromInt(h)) / factor };
}

/// Paints a text mask horizontally centred within `width`, returning its logical height.
pub fn paintCenteredMask(canvas: raster.Canvas, mask: ?text.Mask, scale: u32, width: f64, y: f64, color: raster.Color) f64 {
    const size = maskExtent(mask, scale);
    if (mask) |m| m.paint(canvas, @round((width - size[0]) / 2), @round(y), color);
    return size[1];
}

/// Paints a circular user avatar or GNOME's default silhouette fallback.
pub fn paintAvatar(canvas: raster.Canvas, avatar: ?decode.Image, cx: f64, cy: f64, size: f64) void {
    const radius = size / 2;
    if (avatar) |image| {
        const s = canvas.scale;
        const rect: raster.Rect = .{ .x = (cx - radius) * s, .y = (cy - radius) * s, .width = size * s, .height = size * s };
        const clip: raster.Shape = .{ .circle = .{ .center = .{ .x = cx * s, .y = cy * s }, .radius = radius * s } };
        if (raster.blitWithOptions(canvas.target, image.view(), rect, .{ .shape = clip })) return else |_| {}
    }
    const k = size / 128.0;
    canvas.draw(&.{.{ .circle = .{ .center = .{ .x = cx, .y = cy }, .radius = radius } }}, raster.Color.rgb(0xffffff, 0.12));
    var body: [25]raster.Point = undefined;
    for (&body, 0..) |*point, i| {
        const angle = std.math.pi * @as(f64, @floatFromInt(i)) / 24;
        point.* = .{ .x = cx - 34 * k * @cos(angle), .y = cy + 38 * k - 30 * k * @sin(angle) };
    }
    canvas.draw(&.{.{ .polygon = &body }}, raster.Color.rgb(0xffffff, 0.8));
    canvas.draw(&.{.{ .circle = .{ .center = .{ .x = cx, .y = cy - 12 * k }, .radius = 17 * k } }}, raster.Color.rgb(0xffffff, 0.8));
}

/// Paints the circular back/cancel button with a left chevron.
pub fn paintBackButton(canvas: raster.Canvas, rect: raster.Rect, busy: bool, hovered: bool) void {
    const cx = rect.x + rect.width / 2;
    const cy = rect.y + rect.height / 2;
    const alpha: f64 = if (busy) 0.05 else if (hovered) 0.18 else 0.10;
    canvas.draw(&.{rect.shape(rect.height / 2)}, raster.Color.rgb(0xffffff, alpha));
    const chevron = [_]raster.Shape{
        .{ .line = .{ .start = .{ .x = cx + 2.5, .y = cy - 5 }, .end = .{ .x = cx - 2.5, .y = cy }, .radius = 1 } },
        .{ .line = .{ .start = .{ .x = cx - 2.5, .y = cy }, .end = .{ .x = cx + 2.5, .y = cy + 5 }, .radius = 1 } },
    };
    canvas.draw(&chevron, raster.Color.rgb(0xffffff, if (busy) 0.4 else 0.9));
}

/// Paints the pill-shaped input entry background and GNOME's focus ring.
pub fn paintEntryFrame(canvas: raster.Canvas, rect: raster.Rect, busy: bool) void {
    canvas.draw(&.{rect.shape(rect.height / 2)}, raster.Color.rgb(0xffffff, if (busy) 0.05 else 0.10));
    if (!busy) {
        const ring: raster.Rect = .{ .x = rect.x + 1, .y = rect.y + 1, .width = rect.width - 2, .height = rect.height - 2 };
        canvas.draw(&.{ring.stroke(rect.height / 2 - 1, 2)}, raster.Color.rgb(accent, 0.65));
    }
}

/// Paints masked password dots, placeholder text, and caret inside `rect`.
pub fn paintPasswordDots(canvas: raster.Canvas, rect: raster.Rect, typed: usize, busy: bool, placeholder: ?text.Mask, scale: u32) void {
    const center_y = rect.y + rect.height / 2;
    const content = raster.Color.rgb(0xffffff, if (busy) 0.5 else 1.0);
    const dots: usize = @min(typed, max_dots);
    if (dots == 0 and !busy) {
        if (placeholder) |m| m.paint(canvas, rect.x + 16, @round(center_y - maskExtent(placeholder, scale)[1] / 2), raster.Color.rgb(0xffffff, 0.5));
    }
    var shapes: [max_dots + 1]raster.Shape = undefined;
    for (0..dots) |i| shapes[i] = .{ .circle = .{ .center = .{ .x = rect.x + 18 + @as(f64, @floatFromInt(i * dot_spacing)), .y = center_y }, .radius = dot_radius } };
    var count = dots;
    if (!busy) {
        const caret_x = rect.x + 13 + @as(f64, @floatFromInt(dots * dot_spacing));
        shapes[count] = .{ .line = .{ .start = .{ .x = caret_x, .y = center_y - 9 }, .end = .{ .x = caret_x, .y = center_y + 9 }, .radius = 0.5 } };
        count += 1;
    }
    canvas.draw(shapes[0..count], content);
}

/// Paints the circular authentication spinner centred at `(cx, cy)`.
pub fn paintSpinner(canvas: raster.Canvas, cx: f64, cy: f64, spin: f64) void {
    const track: raster.Rect = .{ .x = cx - 8, .y = cy - 8, .width = 16, .height = 16 };
    canvas.draw(&.{track.stroke(8, 2)}, raster.Color.rgb(0xffffff, 0.15));
    canvas.draw(&.{.{ .arc = .{ .center = .{ .x = cx, .y = cy }, .radius = 8, .start = spin, .end = spin + std.math.pi * 0.75, .stroke = 2 } }}, raster.Color.rgb(0xffffff, 0.9));
}

test "secret buffer handles Unicode backspace, char count, capacity, and complete erasure" {
    var password: SecretBuffer = .{};
    password.append("a日本");
    try std.testing.expectEqual(@as(usize, 3), password.charCount());
    password.backspace();
    try std.testing.expectEqualStrings("a日", password.slice());
    try std.testing.expectEqual(@as(usize, 2), password.charCount());
    password.backspace();
    password.backspace();
    password.backspace();
    try std.testing.expectEqual(@as(usize, 0), password.len);
    var too_long: [1024]u8 = @splat('a');
    password.append(&too_long);
    try std.testing.expectEqual(@as(usize, 0), password.len);
    password.append("secret");
    password.clear();
    for (password.bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}
