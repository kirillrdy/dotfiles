//! Lock-screen pixels and cached public labels. No credentials enter this view.
const std = @import("std");
const raster = @import("desktop-raster.zig");
const text = @import("desktop-text.zig");

pub const Status = enum { ready, authenticating, failed };

pub const View = struct {
    masks: [4]text.Mask,

    pub fn init(allocator: std.mem.Allocator) !View {
        var renderer: text.Renderer = .{};
        defer renderer.deinit();
        var self: View = undefined;
        var count: usize = 0;
        errdefer for (self.masks[0..count]) |mask| mask.deinit(allocator);
        for ([_][:0]const u8{ "Session locked", "Password, then Enter", "Authenticating…", "Try again" }, 0..) |label, i| {
            self.masks[i] = try renderer.renderLayout(allocator, label, .{ .size = if (i == 0) 26 else 17 });
            count += 1;
        }
        return self;
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        for (self.masks) |mask| mask.deinit(allocator);
        self.* = undefined;
    }

    /// `typed` is only a character count; the password itself never reaches the view.
    pub fn paint(self: *const View, target: raster.Buffer, status: Status, typed: usize) void {
        raster.fill(target, .{ .x = 0, .y = 0, .width = target.width, .height = target.height }, 0xff1e1e2e, .source);
        // Preserve the existing logical-pixel positions and baselines. The
        // session-lock surface uses a buffer scale of one, including on HiDPI.
        const x = @as(i32, @intCast(target.width / 2)) - 105;
        const y: i32 = @intCast(target.height / 2);
        paintMask(target, self.masks[0], x, y - 35);
        paintMask(target, self.masks[1 + @backingInt(status)], x, y + 5);
        paintField(target, x, y + 22, status, typed);
    }
};

const field_width = 240;
const field_height = 36;
const dot_spacing = 14;
const max_dots = (field_width - 32) / dot_spacing + 1;

/// A rounded field with one dot per typed character, so typing is visible.
fn paintField(target: raster.Buffer, x: i32, top: i32, status: Status, typed: usize) void {
    const canvas: raster.Canvas = .{ .target = target, .scale = 1 };
    const rect: raster.Rect = .{ .x = @floatFromInt(x), .y = @floatFromInt(top), .width = field_width, .height = field_height };
    canvas.draw(&.{rect.shape(8)}, raster.hex(0xff313244));
    const border: u32 = switch (status) {
        .ready => if (typed > 0) 0xff89b4fa else 0xff585b70,
        .authenticating => 0xff6c7086,
        .failed => 0xfff38ba8,
    };
    canvas.draw(&.{rect.stroke(8, 1.5)}, raster.hex(border));
    const dots: usize = @min(typed, max_dots);
    const center_y = rect.y + field_height / 2;
    var shapes: [max_dots + 1]raster.Shape = undefined;
    for (0..dots) |i| shapes[i] = .{ .circle = .{ .center = .{ .x = rect.x + 16 + @as(f64, @floatFromInt(i * dot_spacing)), .y = center_y }, .radius = 4 } };
    var count = dots;
    if (status != .authenticating and dots < max_dots) {
        const caret_x = rect.x + 16 + @as(f64, @floatFromInt(dots * dot_spacing)) - (if (dots > 0) @as(f64, 6) else 4);
        shapes[count] = .{ .line = .{ .start = .{ .x = caret_x, .y = center_y - 9 }, .end = .{ .x = caret_x, .y = center_y + 9 } } };
        count += 1;
    }
    canvas.draw(shapes[0..count], raster.hex(if (status == .authenticating) 0xff9399b2 else 0xffcdd6f4));
}

fn paintMask(target: raster.Buffer, mask: text.Mask, x: i32, baseline: i32) void {
    raster.mask(target, .{ .x = x + mask.left, .y = baseline + mask.top, .width = mask.width, .height = mask.height }, mask.pixels, .{ .red = 1, .green = 1, .blue = 1 });
}

test "lock rendering is opaque in every state and clips on small outputs" {
    const allocator = std.testing.allocator;
    var view = try View.init(allocator);
    defer view.deinit(allocator);
    for ([_][2]u32{ .{ 640, 480 }, .{ 17, 13 } }) |size| {
        const count = size[0] * size[1];
        const storage = try allocator.alloc(u32, count + 2);
        defer allocator.free(storage);
        const target: raster.Buffer = .{ .pixels = storage[1 .. count + 1], .width = size[0], .height = size[1] };
        for ([_]Status{ .ready, .authenticating, .failed }) |status| {
            @memset(storage, 0x12345678);
            view.paint(target, status, 5);
            for (target.pixels) |pixel| try std.testing.expectEqual(@as(u32, 255), pixel >> 24);
            try std.testing.expectEqual(@as(u32, 0x12345678), storage[0]);
            try std.testing.expectEqual(@as(u32, 0x12345678), storage[count + 1]);
            if (size[0] == 640) {
                var foreground: usize = 0;
                for (target.pixels) |pixel| {
                    if (pixel != 0xff1e1e2e) foreground += 1;
                }
                try std.testing.expect(foreground > 100);
                try std.testing.expectEqual(@as(u32, 0xff1e1e2e), target.pixels[0]);
            }
        }
    }
}
