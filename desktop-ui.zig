//! UI helpers kept separate from the C ABI declarations.
const c = @import("desktop-glib.zig");
const std = @import("std");
const raster = @import("desktop-raster.zig");
const Image = @import("desktop-image.zig").Image;
pub fn cast(comptime T: type, ptr: anytype) *T {
    return @ptrCast(@alignCast(ptr));
}
pub const eq = @import("desktop-util.zig").eq;
pub fn dupeZ(allocator: std.mem.Allocator, value: []const u8) [:0]u8 {
    return allocator.dupeSentinel(u8, value, 0) catch @panic("out of memory");
}
pub fn connect(widget: anytype, signal: [*:0]const u8, callback: anytype, data: anytype) void {
    _ = c.g_signal_connect_data(widget, signal, @ptrCast(callback), data, null, 0);
}
/// Opens an installed GSettings schema, optionally requiring `key` to exist.
pub fn settings(schema: [*:0]const u8, key: ?[*:0]const u8) ?*c.GSettings {
    const source = c.g_settings_schema_source_get_default() orelse return null;
    const found = c.g_settings_schema_source_lookup(source, schema, 1) orelse return null;
    defer c.g_settings_schema_unref(found);
    if (key) |name| if (c.g_settings_schema_has_key(found, name) == 0) return null;
    return c.g_settings_new_full(found, null, null);
}
pub const variant = struct {
    pub fn builder(signature: [*:0]const u8) *c.GVariantBuilder {
        return c.g_variant_builder_new(@ptrCast(signature)).?;
    }
    pub fn emptyDict() ?*c.GVariant {
        return c.g_variant_new_array(@ptrCast(@as([*:0]const u8, "{sv}")), null, 0);
    }
    pub fn child(value: ?*c.GVariant, index: usize) *c.GVariant {
        return c.g_variant_get_child_value(value, index).?;
    }
    pub fn text(value: ?*c.GVariant) [:0]const u8 {
        return std.mem.span(c.g_variant_get_string(value, null));
    }
    pub fn slice(value: ?*c.GVariant) []const u8 {
        return if (value) |v| std.mem.span(c.g_variant_get_string(v, null)) else "";
    }
    pub fn bytes(value: ?*c.GVariant) []const u8 {
        const v = value orelse return "";
        var len: usize = 0;
        const data = c.g_variant_get_fixed_array(v, &len, 1) orelse return "";
        return @as([*]const u8, @ptrCast(data))[0..len];
    }
    pub fn byteArray(value: []const u8) *c.GVariant {
        return c.g_variant_new_fixed_array(@ptrCast(@as([*:0]const u8, "y")), value.ptr, value.len, 1).?;
    }
    pub fn lookup(dict: ?*c.GVariant, key: [*:0]const u8, signature: ?[*:0]const u8) ?*c.GVariant {
        return c.g_variant_lookup_value(dict, key, if (signature) |s| @ptrCast(s) else null);
    }
    pub fn nested(base: *c.GVariant, group: [*:0]const u8, key: [*:0]const u8) ?*c.GVariant {
        const section = c.g_variant_lookup_value(base, group, null) orelse return null;
        defer c.g_variant_unref(section);
        return c.g_variant_lookup_value(section, key, null);
    }
};
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
pub const ShmBuffer = struct {
    proxy: *c.wl_buffer,
    memory: *anyopaque,
};
pub fn createShmBuffer(shm: ?*c.wl_shm, name: [*:0]const u8, length: usize, width: u32, height: u32, stride: u32, format: u32) !ShmBuffer {
    const libc = @import("desktop-libc.zig");
    const fd = libc.memfd_create(name, libc.MFD_CLOEXEC);
    if (fd < 0) return error.SharedMemory;
    defer _ = libc.close(fd);
    if (libc.ftruncate(fd, @intCast(length)) != 0) return error.SharedMemory;
    const memory = libc.mmap(null, length, libc.PROT_READ | libc.PROT_WRITE, libc.MAP_SHARED, fd, 0);
    if (memory == libc.MAP_FAILED or memory == null) return error.SharedMemory;
    errdefer _ = libc.munmap(memory, length);
    const pool = c.wl_shm_create_pool(shm, fd, @intCast(length)) orelse return error.SharedMemory;
    defer c.wl_shm_pool_destroy(pool);
    const proxy = c.wl_shm_pool_create_buffer(pool, 0, @intCast(width), @intCast(height), @intCast(stride), format) orelse return error.SharedMemory;
    return .{ .proxy = proxy, .memory = memory.? };
}
pub fn dispatchWayland(display: ?*c.wl_display) bool {
    const libc = @import("desktop-libc.zig");
    while (c.wl_display_prepare_read(display) != 0) {
        if (c.wl_display_dispatch_pending(display) < 0) return false;
    }
    if (c.wl_display_read_events(display) < 0 and libc.__errno_location().* != @backingInt(std.c.E.AGAIN)) return false;
    return c.wl_display_dispatch_pending(display) >= 0;
}
