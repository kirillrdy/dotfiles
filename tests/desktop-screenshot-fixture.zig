//! Screenshot parsing, PNG stream encoding and overlay tests.
const std = @import("std");
const screenshot = @import("desktop").screenshot;
const c = screenshot.c;
const assert = std.debug.assert;

fn testGeometryParsing() !void {
    const r1 = screenshot.Rect.parse("350,280 1028x720").?;
    try std.testing.expectEqual(@as(i32, 350), r1.x);
    try std.testing.expectEqual(@as(i32, 280), r1.y);
    try std.testing.expectEqual(@as(i32, 1028), r1.w);
    try std.testing.expectEqual(@as(i32, 720), r1.h);

    const r2 = screenshot.Rect.parse("0,0 1920x1080").?;
    try std.testing.expectEqual(@as(i32, 0), r2.x);
    try std.testing.expectEqual(@as(i32, 0), r2.y);
    try std.testing.expectEqual(@as(i32, 1920), r2.w);
    try std.testing.expectEqual(@as(i32, 1080), r2.h);

    const r3 = screenshot.Rect.parse("  \"100,200 400x300\"  ").?;
    try std.testing.expectEqual(@as(i32, 100), r3.x);
    try std.testing.expectEqual(@as(i32, 200), r3.y);
    try std.testing.expectEqual(@as(i32, 400), r3.w);
    try std.testing.expectEqual(@as(i32, 300), r3.h);

    try std.testing.expect(screenshot.Rect.parse("invalid") == null);
    try std.testing.expect(screenshot.Rect.parse("100,200 -5x10") == null);
}

fn testOptionsParsing() !void {
    const args1 = [_][]const u8{ "screenshot", "-o", "eDP-1", "-g", "10,20 300x400", "test.png" };
    const opt1 = screenshot.Options.parse(&args1);
    try std.testing.expectEqualStrings("eDP-1", opt1.output_name.?);
    try std.testing.expectEqual(@as(i32, 10), opt1.geometry.?.x);
    try std.testing.expectEqual(@as(i32, 20), opt1.geometry.?.y);
    try std.testing.expectEqual(@as(i32, 300), opt1.geometry.?.w);
    try std.testing.expectEqual(@as(i32, 400), opt1.geometry.?.h);
    try std.testing.expectEqualStrings("test.png", opt1.file_path.?);
    try std.testing.expect(!opt1.interactive);

    const args2 = [_][]const u8{ "screenshot", "-c" };
    const opt2 = screenshot.Options.parse(&args2);
    try std.testing.expect(opt2.clipboard);
    try std.testing.expect(opt2.interactive);
    try std.testing.expect(!opt2.save_default);

    const defaults = screenshot.Options.parse(&.{"screenshot"});
    try std.testing.expect(defaults.interactive);
    try std.testing.expect(defaults.clipboard);
    try std.testing.expect(defaults.save_default);
    const region = screenshot.Options.parse(&.{ "screenshot", "-g", "0,0 32x32" });
    try std.testing.expect(region.save_default);
    try std.testing.expect(!region.interactive);
    const stdout = screenshot.Options.parse(&.{ "screenshot", "-g", "0,0 32x32", "-" });
    try std.testing.expectEqualStrings("-", stdout.file_path.?);
    try std.testing.expect(!stdout.save_default);

    const args3 = [_][]const u8{ "slurp", "-f", "%o", "-or" };
    const opt3 = screenshot.Options.parse(&args3);
    try std.testing.expect(opt3.slurp_mode);
    try std.testing.expect(!opt3.save_default);

    const args4 = [_][]const u8{ "grim", "-s", "1", "-g", "0,0 1920x1080", "-t", "ppm", "--", "shot.png" };
    const opt4 = screenshot.Options.parse(&args4);
    try std.testing.expectEqualStrings("shot.png", opt4.file_path.?);
    try std.testing.expect(!opt4.save_default);
    try std.testing.expectEqual(@as(i32, 1920), opt4.geometry.?.w);
}

fn testPngEncoding(allocator: std.mem.Allocator, io: std.Io) !void {
    // Decode with GdkPixbuf/libpng, independently of the Zig encoder.
    var template = "/tmp/desktop-png-XXXXXX".*;
    const fd = c.g_mkstemp(&template);
    try std.testing.expect(fd >= 0);
    _ = @import("desktop").libc.close(fd);
    defer _ = @import("desktop").libc.unlink(&template);
    for ([_]bool{ false, true }) |alpha| {
        for ([_]bool{ false, true }) |invert| {
            const pixels = [_]u32{ 0x00804020, 0x80004000, 0xdeadbeef, 0xff123456, 0x000000ff, 0xdeadbeef };
            const bytes = try screenshot.png.encode(allocator, .{
                .pixels = std.mem.sliceAsBytes(&pixels),
                .width = 2,
                .height = 2,
                .stride = 12,
                .alpha = alpha,
                .y_invert = invert,
            });
            defer allocator.free(bytes);
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = std.mem.span(@as([*:0]const u8, &template)), .data = bytes });
            const decoded = c.gdk_pixbuf_new_from_file(&template, null) orelse return error.PngDecodeFailed;
            defer c.g_object_unref(decoded);
            try std.testing.expectEqual(@as(c_int, 2), c.gdk_pixbuf_get_width(decoded));
            try std.testing.expectEqual(@as(c_int, 2), c.gdk_pixbuf_get_height(decoded));
            const channels: usize = if (alpha) 4 else 3;
            try std.testing.expectEqual(@as(c_int, @intCast(channels)), c.gdk_pixbuf_get_n_channels(decoded));
            const data = c.gdk_pixbuf_get_pixels(decoded);
            const stride: usize = @intCast(c.gdk_pixbuf_get_rowstride(decoded));
            const rgba = [_][4]u8{ .{ 0, 0, 0, 0 }, .{ 0, 128, 0, 128 }, .{ 18, 52, 86, 255 }, .{ 0, 0, 0, 0 } };
            const rgb = [_][3]u8{ .{ 128, 64, 32 }, .{ 0, 64, 0 }, .{ 18, 52, 86 }, .{ 0, 0, 255 } };
            for (0..2) |y| for (0..2) |x| {
                const source_y = if (invert) 1 - y else y;
                const expected: []const u8 = if (alpha) &rgba[source_y * 2 + x] else &rgb[source_y * 2 + x];
                try std.testing.expectEqualSlices(u8, expected, data[y * stride + x * channels ..][0..channels]);
            };
        }
    }
    // Noisy pixels exercise multiple IDAT chunks and compressor window turns.
    const pixels = try allocator.alloc(u32, 256 * 256);
    defer allocator.free(pixels);
    var random = std.Random.DefaultPrng.init(42);
    random.random().bytes(std.mem.sliceAsBytes(pixels));
    const bytes = try screenshot.png.encode(allocator, .{ .pixels = std.mem.sliceAsBytes(pixels), .width = 256, .height = 256, .stride = 1024 });
    defer allocator.free(bytes);
    try std.testing.expect(bytes.len > 65536);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = std.mem.span(@as([*:0]const u8, &template)), .data = bytes });
    const decoded = c.gdk_pixbuf_new_from_file(&template, null) orelse return error.PngDecodeFailed;
    defer c.g_object_unref(decoded);
    const data = c.gdk_pixbuf_get_pixels(decoded);
    const stride: usize = @intCast(c.gdk_pixbuf_get_rowstride(decoded));
    for (pixels, 0..) |pixel, i| {
        const expected = [_]u8{ @truncate(pixel >> 16), @truncate(pixel >> 8), @truncate(pixel) };
        try std.testing.expectEqualSlices(u8, &expected, data[(i / 256) * stride + (i % 256) * 3 ..][0..3]);
    }
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    try testGeometryParsing();
    try testOptionsParsing();
    try testPngEncoding(arena.allocator(), init.io);

    std.debug.print("desktop-screenshot: geometry, CLI, native PNG, RGB/ARGB, alpha, row padding, inversion and multiple chunks passed\n", .{});
}
