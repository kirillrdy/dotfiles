//! Xcursor themes without libXcursor: finds a cursor by name in a theme
//! (following Inherits=) on the XCURSOR_PATH, and decodes the image whose
//! nominal size is closest to the one asked for.
const std = @import("std");

pub const Image = struct {
    width: u32,
    height: u32,
    hotspot: [2]i32,
    /// Premultiplied ARGB, row-major.
    pixels: []u32,

    pub fn deinit(self: Image, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
};

const magic = "Xcur";
const image_type: u32 = 0xfffd0002;
const max_file = 4 * 1024 * 1024;

/// Decodes the image closest to `size` from an Xcursor file's bytes.
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8, size: u32) !Image {
    if (bytes.len < 16 or !std.mem.eql(u8, bytes[0..4], magic)) return error.InvalidCursor;
    const header = read(bytes, 4) orelse return error.InvalidCursor;
    const count = read(bytes, 12) orelse return error.InvalidCursor;
    if (header < 16 or count > 0x10000) return error.InvalidCursor;
    // The nominal size nearest to the one wanted, as libXcursor chooses.
    var best: ?u32 = null;
    var best_position: u32 = 0;
    for (0..count) |index| {
        const entry = header + index * 12;
        const kind = read(bytes, entry) orelse return error.InvalidCursor;
        const nominal = read(bytes, entry + 4) orelse return error.InvalidCursor;
        const position = read(bytes, entry + 8) orelse return error.InvalidCursor;
        if (kind != image_type) continue;
        const distance = if (nominal > size) nominal - size else size - nominal;
        if (best == null or distance < (if (best.? > size) best.? - size else size - best.?)) {
            best = nominal;
            best_position = position;
        }
    }
    if (best == null) return error.NoCursorImage;
    const chunk = best_position;
    // Chunk header: size, type, subtype, version, then width, height, hotspot, delay.
    if ((read(bytes, chunk + 4) orelse return error.InvalidCursor) != image_type) return error.InvalidCursor;
    const width = read(bytes, chunk + 16) orelse return error.InvalidCursor;
    const height = read(bytes, chunk + 20) orelse return error.InvalidCursor;
    const xhot = read(bytes, chunk + 24) orelse return error.InvalidCursor;
    const yhot = read(bytes, chunk + 28) orelse return error.InvalidCursor;
    if (width == 0 or height == 0 or width > 0x7fff or height > 0x7fff or xhot > width or yhot > height) return error.InvalidCursor;
    const start = @as(usize, chunk) + 36;
    const length = @as(usize, width) * height;
    if (start + length * 4 > bytes.len) return error.InvalidCursor;
    const pixels = try allocator.alloc(u32, length);
    for (pixels, 0..) |*pixel, index| pixel.* = std.mem.readInt(u32, bytes[start + index * 4 ..][0..4], .little);
    return .{ .width = width, .height = height, .hotspot = .{ @intCast(xhot), @intCast(yhot) }, .pixels = pixels };
}

fn read(bytes: []const u8, offset: usize) ?u32 {
    if (offset + 4 > bytes.len) return null;
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

/// Where themes live: XCURSOR_PATH, else the XDG data directories' icons,
/// ~/.icons, `extra` (the desktop's own data directories) and the system's.
pub fn searchPath(buffer: []u8, extra: ?[]const u8) []const u8 {
    if (std.c.getenv("XCURSOR_PATH")) |value| {
        const text = std.mem.span(value);
        if (text.len <= buffer.len) {
            @memcpy(buffer[0..text.len], text);
            return buffer[0..text.len];
        }
    }
    var writer: std.Io.Writer = .fixed(buffer);
    if (std.c.getenv("HOME")) |home| writer.print("{s}/.local/share/icons:{s}/.icons:", .{ std.mem.span(home), std.mem.span(home) }) catch {};
    if (std.c.getenv("XDG_DATA_DIRS")) |dirs| {
        var parts = std.mem.tokenizeScalar(u8, std.mem.span(dirs), ':');
        while (parts.next()) |part| writer.print("{s}/icons:", .{part}) catch {};
    }
    if (extra) |dirs| {
        var parts = std.mem.tokenizeScalar(u8, dirs, ':');
        while (parts.next()) |part| writer.print("{s}/icons:", .{part}) catch {};
    }
    writer.writeAll("/run/current-system/sw/share/icons:/usr/share/icons") catch {};
    return writer.buffered();
}

/// Loads cursor `name` from `theme` (or a theme it inherits), closest to `size`.
pub fn load(allocator: std.mem.Allocator, path: []const u8, theme: []const u8, name: []const u8, size: u32) ?Image {
    return loadDepth(allocator, path, theme, name, size, 0);
}

fn loadDepth(allocator: std.mem.Allocator, path: []const u8, theme: []const u8, name: []const u8, size: u32, depth: u8) ?Image {
    if (depth > 4 or theme.len == 0) return null;
    var dirs = std.mem.tokenizeScalar(u8, path, ':');
    while (dirs.next()) |dir| {
        var file_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const file = std.fmt.bufPrintSentinel(&file_buffer, "{s}/{s}/cursors/{s}", .{ dir, theme, name }, 0) catch continue;
        const bytes = readFile(allocator, file) orelse continue;
        defer allocator.free(bytes);
        if (decode(allocator, bytes, size)) |image| return image else |_| {}
    }
    // Then the themes it inherits, from the first index.theme found.
    dirs = std.mem.tokenizeScalar(u8, path, ':');
    while (dirs.next()) |dir| {
        var file_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const file = std.fmt.bufPrintSentinel(&file_buffer, "{s}/{s}/index.theme", .{ dir, theme }, 0) catch continue;
        const bytes = readFile(allocator, file) orelse continue;
        defer allocator.free(bytes);
        var lines = std.mem.tokenizeAny(u8, bytes, "\r\n");
        while (lines.next()) |line| {
            const rest = std.mem.trim(u8, line, " \t");
            if (!std.mem.startsWith(u8, rest, "Inherits")) continue;
            const equals = std.mem.indexOfScalar(u8, rest, '=') orelse continue;
            var parents = std.mem.tokenizeAny(u8, rest[equals + 1 ..], ",; \t");
            while (parents.next()) |parent| {
                if (std.mem.eql(u8, parent, theme)) continue;
                if (loadDepth(allocator, path, parent, name, size, depth + 1)) |image| return image;
            }
        }
        break;
    }
    return null;
}

fn readFile(allocator: std.mem.Allocator, path: [*:0]const u8) ?[]u8 {
    const fd = std.c.open(path, .{ .CLOEXEC = true });
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    var list: std.ArrayList(u8) = .empty;
    var chunk: [16384]u8 = undefined;
    while (true) {
        const count = std.c.read(fd, &chunk, chunk.len);
        if (count < 0) {
            list.deinit(allocator);
            return null;
        }
        if (count == 0) break;
        list.appendSlice(allocator, chunk[0..@intCast(count)]) catch {
            list.deinit(allocator);
            return null;
        };
        if (list.items.len > max_file) {
            list.deinit(allocator);
            return null;
        }
    }
    return list.toOwnedSlice(allocator) catch null;
}

fn testFile(allocator: std.mem.Allocator, sizes: []const u32) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    const put = struct {
        fn word(list: *std.ArrayList(u8), a: std.mem.Allocator, value: u32) !void {
            var buffer: [4]u8 = undefined;
            std.mem.writeInt(u32, &buffer, value, .little);
            try list.appendSlice(a, &buffer);
        }
    };
    try bytes.appendSlice(allocator, magic);
    try put.word(&bytes, allocator, 16);
    try put.word(&bytes, allocator, 0x10000);
    try put.word(&bytes, allocator, @intCast(sizes.len));
    var position: u32 = @intCast(16 + sizes.len * 12);
    for (sizes) |size| {
        try put.word(&bytes, allocator, image_type);
        try put.word(&bytes, allocator, size);
        try put.word(&bytes, allocator, position);
        position += 36 + size * size * 4;
    }
    for (sizes) |size| {
        for ([_]u32{ 36, image_type, size, 1, size, size, size / 4, size / 2, 0 }) |value| try put.word(&bytes, allocator, value);
        for (0..size * size) |_| try put.word(&bytes, allocator, 0xff000000 | size);
    }
    return bytes.toOwnedSlice(allocator);
}

test "the image nearest the asked size is decoded with its hotspot" {
    const a = std.testing.allocator;
    const bytes = try testFile(a, &.{ 24, 32, 48 });
    defer a.free(bytes);
    const image = try decode(a, bytes, 39);
    defer image.deinit(a);
    try std.testing.expectEqual(@as(u32, 32), image.width);
    try std.testing.expectEqual([2]i32{ 8, 16 }, image.hotspot);
    try std.testing.expectEqual(@as(u32, 0xff000000 | 32), image.pixels[0]);
    const large = try decode(a, bytes, 60);
    defer large.deinit(a);
    try std.testing.expectEqual(@as(u32, 48), large.width);
}

test "truncated and foreign files are rejected" {
    const a = std.testing.allocator;
    const bytes = try testFile(a, &.{24});
    defer a.free(bytes);
    try std.testing.expectError(error.InvalidCursor, decode(a, bytes[0 .. bytes.len - 4], 24));
    try std.testing.expectError(error.InvalidCursor, decode(a, "PNG\x00 not a cursor", 24));
}
