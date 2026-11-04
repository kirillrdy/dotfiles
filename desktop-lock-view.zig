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

    pub fn paint(self: *const View, target: raster.Buffer, status: Status) void {
        raster.fill(target, .{ .x = 0, .y = 0, .width = target.width, .height = target.height }, 0xff1e1e2e, .source);
        // Preserve the existing logical-pixel positions and baselines. The
        // session-lock surface uses a buffer scale of one, including on HiDPI.
        const x = @as(i32, @intCast(target.width / 2)) - 105;
        const y: i32 = @intCast(target.height / 2);
        paintMask(target, self.masks[0], x, y - 35);
        paintMask(target, self.masks[1 + @backingInt(status)], x, y + 5);
    }
};

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
            view.paint(target, status);
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
