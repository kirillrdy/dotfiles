//! Screenshot parsing, PNG stream encoding and overlay tests.
const std = @import("std");
const screenshot = @import("desktop").screenshot;
const wl_formats = screenshot.wl.wl_shm.Format;
const assert = std.debug.assert;
const libc = @import("desktop").libc;

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

    const args3 = [_][]const u8{ "slurp", "-f", "%o", "-or" };
    const opt3 = screenshot.Options.parse(&args3);
    try std.testing.expect(opt3.slurp_mode);
    try std.testing.expect(!opt3.save_default);

    const args4 = [_][]const u8{ "grim", "-s", "1", "-g", "0,0 1920x1080", "-t", "ppm", "--", "shot.png" };
    const opt4 = screenshot.Options.parse(&args4);
    try std.testing.expectEqualStrings("shot.png", opt4.file_path.?);
    try std.testing.expect(!opt4.save_default);
    try std.testing.expectEqual(@as(i32, 1920), opt4.geometry.?.w);
    const stdout = screenshot.Options.parse(&.{ "grim", "-" });
    try std.testing.expectEqualStrings("-", stdout.file_path.?);
    try std.testing.expect(!stdout.interactive);
    try std.testing.expect(!stdout.save_default);
}

fn roundTrip(allocator: std.mem.Allocator, image: screenshot.png.Image) !void {
    const encoded = try screenshot.png.encode(allocator, image);
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings("\x89PNG\r\n\x1a\n", encoded[0..8]);
    const created = try @import("desktop").paths.createTemporary(allocator, "/tmp/desktop-png-");
    const path = created.path;
    defer allocator.free(path);
    defer _ = libc.unlink(path);
    {
        defer _ = libc.close(created.fd);
        try screenshot.writeAll(created.fd, encoded);
    }
    // Decode with the existing C library as an independent reference.
    const decode = @import("desktop").decode;
    const decoded = decode.file(allocator, path, null) orelse return error.PngDecodeFailed;
    defer decode.free(allocator, decoded);
    try std.testing.expectEqual(image.width, decoded.width);
    try std.testing.expectEqual(image.height, decoded.height);
    const pixels = std.mem.bytesAsSlice(u32, decoded.pixels);
    for (0..image.height) |y| {
        const source_y = if (image.y_invert) image.height - 1 - y else y;
        for (0..image.width) |x| {
            const original = std.mem.readInt(u32, image.pixels[source_y * image.stride + x * 4 ..][0..4], @import("builtin").cpu.arch.endian());
            try std.testing.expectEqual(original | 0xff000000, pixels[y * decoded.stride / 4 + x]);
        }
    }
}
fn testPngEncoding(allocator: std.mem.Allocator) !void {
    var random: std.Random.DefaultPrng = .init(1234);
    // Include incompressible data crossing the compressor window and IDAT chunks.
    for ([_][2]u32{ .{ 1, 1 }, .{ 64, 64 }, .{ 257, 129 } }) |size| {
        const stride = @as(usize, size[0]) * 4 + 12;
        const pixels = try allocator.alloc(u8, stride * size[1]);
        defer allocator.free(pixels);
        random.random().bytes(pixels);
        for ([_]bool{ false, true }) |inverted| {
            try roundTrip(allocator, .{ .pixels = pixels, .width = size[0], .height = size[1], .stride = stride, .y_invert = inverted });
        }
        if (size[0] > 1) {
            // A portal crop ends before the source stride, including on its last row.
            const offset = stride + 4;
            const length = (size[1] - 2) * stride + (size[0] - 1) * 4;
            try roundTrip(allocator, .{ .pixels = pixels[offset..][0..length], .width = size[0] - 1, .height = size[1] - 1, .stride = stride });
        }
    }
}

fn testCaptureFormats(allocator: std.mem.Allocator) !void {
    const endian = @import("builtin").cpu.arch.endian();
    // NVIDIA readback can advertise packed BGR888 rather than a 32-bit format.
    // Cover tight rows, source padding, and strides wider than the output row.
    for ([_]u32{ 6, 8, 12 }) |stride| {
        var pixels: [24]u8 = @splat(0xa5);
        const colors = [_]u32{ 0xff112233, 0xff445566, 0xff778899, 0xffaabbcc };
        for (colors, 0..) |color, i| {
            const offset = (i / 2) * stride + (i % 2) * 3;
            pixels[offset..][0..3].* = .{ @truncate(color >> 16), @truncate(color >> 8), @truncate(color) };
        }
        var frame: screenshot.FrameCapture = .{
            .shm = undefined,
            .frame = undefined,
            .format = wl_formats.bgr888,
            .width = 2,
            .height = 2,
            .stride = stride,
            .memory = &pixels,
            .length = pixels.len,
            .y_invert = true,
        };
        frame.onReady();
        try std.testing.expect(frame.done and !frame.failed and frame.y_invert);
        try std.testing.expectEqual(@as(u32, wl_formats.xrgb8888), frame.format);
        try std.testing.expectEqual(@max(stride, 8), frame.stride);
        for (colors, 0..) |color, i| {
            const offset = (i / 2) * frame.stride + (i % 2) * 4;
            try std.testing.expectEqual(color, std.mem.readInt(u32, pixels[offset..][0..4], endian));
        }
        try roundTrip(allocator, .{ .pixels = &pixels, .width = 2, .height = 2, .stride = frame.stride, .y_invert = true });
    }
    for ([_]u32{ wl_formats.xrgb8888, wl_formats.argb8888, wl_formats.xbgr8888, wl_formats.abgr8888 }) |format| {
        var pixels: [24]u8 = @splat(0xa5); // Two rows, including stride padding.
        const swapped = format == wl_formats.xbgr8888 or format == wl_formats.abgr8888;
        for (0..2) |y| for (0..2) |x| {
            std.mem.writeInt(u32, pixels[y * 12 + x * 4 ..][0..4], if (swapped) 0x7f332211 else 0x7f112233, endian);
        };
        var frame: screenshot.FrameCapture = .{
            .shm = undefined,
            .frame = undefined,
            .format = format,
            .width = 2,
            .height = 2,
            .stride = 12,
            .memory = &pixels,
            .length = pixels.len,
            .y_invert = true,
        };
        frame.onReady();
        try std.testing.expect(frame.done and !frame.failed and frame.y_invert);
        try std.testing.expectEqual(@as(u32, if (format == wl_formats.xrgb8888 or format == wl_formats.xbgr8888) wl_formats.xrgb8888 else wl_formats.argb8888), frame.format);
        for (0..2) |y| {
            for (0..2) |x| try std.testing.expectEqual(@as(u32, 0x7f112233), std.mem.readInt(u32, pixels[y * 12 + x * 4 ..][0..4], endian));
            try std.testing.expectEqualSlices(u8, &.{ 0xa5, 0xa5, 0xa5, 0xa5 }, pixels[y * 12 + 8 ..][0..4]);
        }
        try roundTrip(allocator, .{ .pixels = &pixels, .width = 2, .height = 2, .stride = 12, .y_invert = true });
    }
}

pub fn main(init: std.process.Init) !void {
    _ = init;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    try testGeometryParsing();
    try testOptionsParsing();
    try testPngEncoding(arena.allocator());
    try testCaptureFormats(arena.allocator());

    std.debug.print("desktop-screenshot: geometry parsing, CLI options, Zig PNG encoding, independent RGB decoding, inverted rows, padding and crops passed\n", .{});
}
