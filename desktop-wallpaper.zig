//! One input-transparent background layer per monitor, sharing a decoded image.
const native = @import("desktop-surface.zig");
const raster = @import("desktop-raster.zig");
const std = @import("std");
const util = @import("desktop-util.zig");
const decode = @import("desktop-decode.zig");
const Image = decode.Image;

const cast = util.cast;

fn paint(target: native.Pixels, image: Image) void {
    raster.cover(target, image.view()) catch |err| std.log.err("wallpaper render: {s}", .{@errorName(err)});
}

const Background = struct {
    surface: *native.Surface,
    image: Image, // Owned by App; shared across outputs.

    fn create(output: *native.Output, image: Image) !*Background {
        const allocator = output.client.allocator;
        const self = try allocator.create(Background);
        errdefer allocator.destroy(self);
        self.* = .{ .surface = try native.Surface.createPixels(output, .{
            .namespace = "desktop-wallpaper",
            .layer = 0,
            .anchors = native.top | native.bottom | native.left | native.right,
        }, &draw, self), .image = image };
        errdefer self.surface.destroy();
        try self.surface.show();
        return self;
    }
    fn draw(data: ?*anyopaque, target: native.Pixels) void {
        paint(target, cast(Background, data).image);
    }
    fn destroy(self: *Background) void {
        const allocator = self.surface.client.allocator;
        self.surface.destroy();
        allocator.destroy(self);
    }
};

const App = struct {
    allocator: std.mem.Allocator,
    image: Image,
    backgrounds: std.ArrayList(*Background) = .empty,

    fn add(data: ?*anyopaque, output: *native.Output) void {
        const self = cast(App, data);
        const background = Background.create(output, self.image) catch |err| {
            std.log.err("wallpaper: {s}", .{@errorName(err)});
            return;
        };
        self.backgrounds.append(self.allocator, background) catch @panic("out of memory");
    }
    fn remove(data: ?*anyopaque, output: *native.Output) void {
        const self = cast(App, data);
        for (self.backgrounds.items, 0..) |background, i| if (background.surface.output == output) {
            _ = self.backgrounds.orderedRemove(i);
            background.destroy();
            return;
        };
    }
};

test "fill crops the center of wide and tall images at both buffer scales" {
    for ([_]bool{ false, true }) |vertical| {
        const image = try decode.create(std.testing.allocator, if (vertical) 4 else 12, if (vertical) 12 else 4);
        defer decode.free(std.testing.allocator, image);
        const pixels = std.mem.bytesAsSlice(u32, image.pixels);
        const iw: usize = image.width;
        const ih: usize = image.height;
        for (0..ih) |y| for (0..iw) |x| {
            const band = (if (vertical) y else x) / 4;
            pixels[y * iw + x] = @as(u32, 0xff000000) | (@as(u32, 0xff0000) >> @intCast(band * 8));
        };
        for ([_]c_int{ 1, 2 }) |scale| {
            var data: [64]u32 = undefined;
            const row: usize = @intCast(4 * scale);
            paint(.{ .pixels = data[0 .. row * row], .width = @intCast(row), .height = @intCast(row) }, image);
            const mid: usize = @intCast(2 * scale);
            try std.testing.expectEqual(@as(u32, 0xff00ff00), data[mid * row + mid]);
            // Opaque green at opposite corners also catches letterboxing and
            // sampling past the source edge at doubled buffer scale.
            try std.testing.expectEqual(@as(u32, 0xff00ff00), data[row + 1]);
        }
    }
}

test "integration: background layer paints wallpaper pixels on the desktop" {
    if (!@import("options").integration_tests) return error.SkipZigTest;
    const capture = @import("tests/desktop-surface-capture.zig");
    const image = try decode.create(std.testing.allocator, 2, 2);
    defer decode.free(std.testing.allocator, image);
    @memset(std.mem.bytesAsSlice(u32, image.pixels), 0xff142850);
    var app: App = .{ .allocator = std.testing.allocator, .image = image };
    const native_client = try native.Client.create(std.testing.allocator, std.testing.io, .{ .added = &App.add, .removed = &App.remove }, &app);
    defer native_client.destroy();
    defer {
        for (app.backgrounds.items) |background| background.destroy();
        app.backgrounds.deinit(app.allocator);
    }
    try native_client.start();
    const Probe = struct {
        var paints: usize = 0;
        fn draw(data: ?*anyopaque, target: native.Pixels) void {
            paints += 1;
            Background.draw(data, target);
        }
    };
    Probe.paints = 0;
    for (app.backgrounds.items) |background| background.surface.paint = &Probe.draw;
    capture.pump();
    try std.testing.expectEqual(@as(usize, 1), app.backgrounds.items.len);
    try std.testing.expect(app.backgrounds.items[0].surface.configured);
    try std.testing.expect(app.backgrounds.items[0].surface.buffers[0] != null);
    try std.testing.expectEqual(@as(usize, 1), Probe.paints);
    const frame = try capture.capture();
    defer frame.deinit();
    for ([_][2]u32{ .{ 1, 1 }, .{ frame.width / 2, frame.height / 2 }, .{ frame.width - 2, frame.height - 2 } }) |point| {
        try std.testing.expectEqual(@as(u32, 0x142850), frame.pixel(point[0], point[1]));
    }
}

pub const Service = struct {
    app: App,
    client: *native.Client,

    pub fn create(allocator: std.mem.Allocator, io: std.Io, path: [:0]const u8) !*Service {
        const image = decode.file(allocator, path, null) orelse return error.InvalidImage;
        errdefer decode.free(allocator, image);
        const self = try allocator.create(Service);
        self.* = .{ .app = .{ .allocator = allocator, .image = image }, .client = undefined };
        errdefer allocator.destroy(self);
        self.client = try native.Client.create(allocator, io, .{ .added = &App.add, .removed = &App.remove }, &self.app);
        errdefer self.client.destroy();
        if (self.client.shell == null) return error.LayerShellUnavailable;
        try self.client.start();
        return self;
    }

    pub fn destroy(self: *Service) void {
        for (self.app.backgrounds.items) |background| background.destroy();
        self.app.backgrounds.deinit(self.app.allocator);
        self.client.destroy();
        decode.free(self.app.allocator, self.app.image);
        self.app.allocator.destroy(self);
    }
};
