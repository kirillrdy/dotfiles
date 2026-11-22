//! Actual native dash rendering, icon caching, interaction states and HiDPI.
const std = @import("std");
const desktop = @import("desktop");
const native = desktop.dash_view;
const c = desktop.glib;

pub fn main(init: std.process.Init) !void {
    var view: native.View = .{ .allocator = init.gpa };
    defer view.deinit();
    for ([_]struct { title: [:0]const u8, icon: [:0]const u8 }{
        .{ .title = "Terminal", .icon = "utilities-terminal" },
        .{ .title = "Files", .icon = "system-file-manager" },
        .{ .title = "Browser", .icon = "web-browser" },
    }, 0..) |fixture, i| {
        const source = try std.fmt.allocPrint(std.heap.page_allocator, "[Desktop Entry]\nType=Application\nName={s}\nExec=true\nIcon={s}\n", .{ fixture.title, fixture.icon });
        defer std.heap.page_allocator.free(source);
        const app = (try @import("desktop").appinfo.App.parse(std.heap.page_allocator, source, "", null)).?;
        defer app.unref();
        try view.add(fixture.title, app, if (i == 0) "terminal-id" else null, null);
    }
    try view.add("Show Applications", null, null, null);
    view.items.items[3].show_apps = true;
    view.relayout(1280, 720);
    view.focus = 3;
    view.navigate(1);
    try std.testing.expectEqual(@as(usize, 0), view.focus);
    view.navigate(-1);
    try std.testing.expectEqual(@as(usize, 3), view.focus);
    view.keyboard_focus = false;
    for ([_]u32{ 1, 2 }) |scale| {
        const width = view.layout.width * scale;
        const height = view.layout.height * scale;
        const pixels = try std.heap.page_allocator.alloc(u32, width * height);
        defer std.heap.page_allocator.free(pixels);
        @memset(pixels, 0);
        const target: native.Buffer = .{ .pixels = pixels, .width = width, .height = height };
        try view.paint(target, scale);
        const normal = try std.heap.page_allocator.dupe(u32, pixels);
        defer std.heap.page_allocator.free(normal);
        const icon = view.items.items[0].pixels;
        try std.testing.expect(icon != null);
        try view.paint(target, scale);
        try std.testing.expectEqual(icon, view.items.items[0].pixels);
        try std.testing.expectEqualSlices(u32, normal, pixels);
        try snapshot(pixels, width, height, scale, "normal");
        view.hover = 0;
        try view.paint(target, scale);
        try std.testing.expect(!std.mem.eql(u32, normal, pixels));
        const hovered = try std.heap.page_allocator.dupe(u32, pixels);
        defer std.heap.page_allocator.free(hovered);
        try snapshot(pixels, width, height, scale, "hover");
        view.pressed = 0;
        try view.paint(target, scale);
        try std.testing.expect(!std.mem.eql(u32, hovered, pixels));
        try snapshot(pixels, width, height, scale, "press");
        view.pressed = null;
        view.hover = null;
        view.keyboard_focus = true;
        view.focus = 0;
        try view.paint(target, scale);
        try std.testing.expect(!std.mem.eql(u32, normal, pixels));
        try snapshot(pixels, width, height, scale, "focus");
        view.keyboard_focus = false;
        view.apps_mode = true;
        try view.paint(target, scale);
        try std.testing.expect(!std.mem.eql(u32, normal, pixels));
        try snapshot(pixels, width, height, scale, "checked");
        view.apps_mode = false;
        try view.prepareTooltip(0, scale);
        try std.testing.expect(view.tooltip_mask.?.logical_width < 360 * scale);
        try std.testing.expectEqual(@as(?usize, 0), view.tooltip_index);
        try tooltipSnapshot(&view, scale);
        try view.prepareTooltip(2, scale);
        try std.testing.expectEqual(@as(?usize, 2), view.tooltip_index);
    }
    view.separator = 2;
    view.relayout(1280, 720);
    try std.testing.expectEqual(@as(u32, 285), view.layout.width);
    std.debug.print("desktop-dash: GNOME geometry, icon caching, hover/press/focus, checked state, navigation, tooltips and HiDPI passed\n", .{});
}
fn tooltipSnapshot(view: *native.View, scale: u32) !void {
    const width = view.tooltip_mask.?.logical_width + 26 * scale;
    const height = view.tooltip_mask.?.logical_height + 14 * scale;
    const data = try std.heap.page_allocator.alloc(u32, width * height);
    defer std.heap.page_allocator.free(data);
    @memset(data, 0);
    view.paintTooltip(.{ .pixels = data, .width = width, .height = height }, scale);
    try std.testing.expectEqual(@as(u32, 0), data[0]);
    const alpha = data[(height / 2) * width + 3 * scale] >> 24;
    try std.testing.expect(alpha >= 229 and alpha <= 231);
    try snapshot(data, width, height, scale, "tooltip");
}
fn snapshot(pixels: []const u32, width: u32, height: u32, scale: u32, state: []const u8) !void {
    const root = c.__zig.getenv("DESKTOP_DASH_SCREENSHOTS") orelse return;
    const path = try std.fmt.allocPrintSentinel(std.heap.page_allocator, "{s}/dash-{s}-{d}x.png", .{ root, state, scale }, 0);
    defer std.heap.page_allocator.free(path);
    try writePng(pixels, width, height, path);
}

fn writePng(pixels: []const u32, width: u32, height: u32, path: [*:0]const u8) !void {
    const encoded = try desktop.png.encode(std.heap.page_allocator, .{ .pixels = std.mem.sliceAsBytes(pixels), .width = width, .height = height, .stride = width * 4, .alpha = true });
    defer std.heap.page_allocator.free(encoded);
    const file = std.c.fopen(path, "wb") orelse return error.WriteFailed;
    defer _ = std.c.fclose(file);
    if (std.c.fwrite(encoded.ptr, 1, encoded.len, file) != encoded.len) return error.WriteFailed;
}
