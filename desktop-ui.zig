//! UI helpers kept separate from the C ABI declarations.
const c = @import("desktop-glib.zig");
const std = @import("std");
const raster = @import("desktop-raster.zig");
const Image = @import("desktop-image.zig").Image;
pub fn cast(comptime T: type, ptr: anytype) *T {
    return @ptrCast(@alignCast(ptr));
}
const util = @import("desktop-util.zig");
pub const eq = util.eq;
pub const monotonicTime = util.monotonicTime;
pub const realTime = util.realTime;
pub const getenv = std.c.getenv;
pub fn dupeZ(allocator: std.mem.Allocator, value: []const u8) [:0]u8 {
    return allocator.dupeSentinel(u8, value, 0) catch @panic("out of memory");
}
pub fn connect(widget: anytype, signal: [*:0]const u8, callback: anytype, data: anytype) void {
    _ = c.g_signal_connect_data(widget, signal, @ptrCast(callback), data, null, 0);
}
/// Opens an installed GSettings schema, optionally requiring `key` to exist.
pub fn settings(schema: []const u8, key: ?[]const u8) ?*@import("desktop-gsettings.zig").Settings {
    return @import("desktop-gsettings.zig").Settings.open(schema, key);
}
/// X keysyms and modifier bits used by the native key handlers.
pub const keys = struct {
    pub const BackSpace: c_int = 0xff08;
    pub const Return: c_int = 0xff0d;
    pub const Escape: c_int = 0xff1b;
    pub const Left: c_int = 0xff51;
    pub const Up: c_int = 0xff52;
    pub const Right: c_int = 0xff53;
    pub const Down: c_int = 0xff54;
    pub const Page_Up: c_int = 0xff55;
    pub const Page_Down: c_int = 0xff56;
    pub const KP_Enter: c_int = 0xff8d;
    pub const Super_L: c_int = 0xffeb;
    pub const Super_R: c_int = 0xffec;
};
pub const Modifiers = c_uint;
pub const shift_mask: c_int = 1;
pub const control_mask: c_int = 4;
pub const alt_mask: c_int = 8;
pub fn blitImage(canvas: raster.Canvas, image: Image, rect: raster.Rect) void {
    raster.blit(canvas.target, image.view(), .{
        .x = (rect.x + canvas.origin.x) * canvas.scale,
        .y = (rect.y + canvas.origin.y) * canvas.scale,
        .width = rect.width * canvas.scale,
        .height = rect.height * canvas.scale,
    }, null) catch {};
}
/// Extracts an image's alpha channel as a glyph-style coverage mask.
pub fn alphaMask(allocator: std.mem.Allocator, image: Image, out_width: *u32, out_height: *u32) ![]u8 {
    const mask = try allocator.alloc(u8, @as(usize, image.width) * image.height);
    for (0..image.height) |y| for (0..image.width) |x| {
        mask[y * image.width + x] = @intCast(std.mem.readInt(u32, image.pixels[y * image.stride + x * 4 ..][0..4], @import("builtin").cpu.arch.endian()) >> 24);
    };
    out_width.* = image.width;
    out_height.* = image.height;
    return mask;
}
