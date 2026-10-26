//! Screenshot parsing, PNG stream encoding and overlay tests.
const std = @import("std");
const screenshot = @import("screenshot");
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
    const args1 = [_][]const u8{ "desktop-screenshot", "-o", "eDP-1", "-g", "10,20 300x400", "test.png" };
    const opt1 = screenshot.Options.parse(&args1);
    try std.testing.expectEqualStrings("eDP-1", opt1.output_name.?);
    try std.testing.expectEqual(@as(i32, 10), opt1.geometry.?.x);
    try std.testing.expectEqual(@as(i32, 20), opt1.geometry.?.y);
    try std.testing.expectEqual(@as(i32, 300), opt1.geometry.?.w);
    try std.testing.expectEqual(@as(i32, 400), opt1.geometry.?.h);
    try std.testing.expectEqualStrings("test.png", opt1.file_path.?);
    try std.testing.expect(!opt1.interactive);

    const args2 = [_][]const u8{ "desktop-screenshot", "-c" };
    const opt2 = screenshot.Options.parse(&args2);
    try std.testing.expect(opt2.clipboard);
    try std.testing.expect(opt2.interactive);
    try std.testing.expect(!opt2.save_default);

    const defaults = screenshot.Options.parse(&.{"desktop-screenshot"});
    try std.testing.expect(defaults.interactive);
    try std.testing.expect(defaults.clipboard);
    try std.testing.expect(defaults.save_default);
    const region = screenshot.Options.parse(&.{ "desktop-screenshot", "-g", "0,0 32x32" });
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
}

fn testPngEncoding(allocator: std.mem.Allocator) !void {
    const width: c_int = 64;
    const height: c_int = 64;
    const surface = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, width, height);
    defer c.cairo_surface_destroy(surface);

    const cr = c.cairo_create(surface);
    defer c.cairo_destroy(cr);

    c.cairo_set_source_rgb(cr, 0.2, 0.5, 0.9);
    c.cairo_paint(cr);

    var png = screenshot.PngBuffer.init(allocator);
    defer png.deinit();

    const status = c.cairo_surface_write_to_png_stream(surface, &screenshot.PngBuffer.writeCallback, &png);
    try std.testing.expect(status == c.CAIRO_STATUS_SUCCESS);
    try std.testing.expect(png.bytes.items.len > 8);

    // Verify PNG header signature: 0x89 'P' 'N' 'G' 0x0D 0x0A 0x1A 0x0A
    const png_magic = "\x89PNG\r\n\x1a\n";
    try std.testing.expectEqualStrings(png_magic, png.bytes.items[0..8]);
}

pub fn main(init: std.process.Init) !void {
    _ = init;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    try testGeometryParsing();
    try testOptionsParsing();
    try testPngEncoding(arena.allocator());

    std.debug.print("desktop-screenshot: geometry parsing, CLI options, Cairo surface creation and PNG stream encoding passed\n", .{});
}
