//! Font shaping and grayscale masks; pixel compositing is handled in Zig.
const std = @import("std");
const c = @import("desktop-gtk.zig");

pub const api = struct {
    pub const PangoFontMap = opaque {};
    pub const PangoContext = opaque {};
    pub const PangoFontDescription = opaque {};
    pub const PangoRectangle = extern struct { x: c_int = 0, y: c_int = 0, width: c_int = 0, height: c_int = 0 };
    pub const FT_Bitmap = extern struct {
        rows: c_uint,
        width: c_uint,
        pitch: c_int,
        buffer: [*c]u8,
        num_grays: c_ushort = 256,
        pixel_mode: u8 = 2, // FT_PIXEL_MODE_GRAY.
        palette_mode: u8 = 0,
        palette: ?*anyopaque = null,
    };
    pub extern fn pango_ft2_font_map_new() ?*PangoFontMap;
    pub extern fn pango_font_map_create_context(*PangoFontMap) ?*PangoContext;
    pub extern fn pango_layout_new(*PangoContext) ?*c.PangoLayout;
    pub extern fn pango_font_description_from_string([*:0]const u8) ?*PangoFontDescription;
    pub extern fn pango_font_description_set_absolute_size(*PangoFontDescription, f64) void;
    pub extern fn pango_font_description_free(*PangoFontDescription) void;
    pub extern fn pango_layout_set_font_description(*c.PangoLayout, *const PangoFontDescription) void;
    pub extern fn pango_layout_set_text(*c.PangoLayout, [*:0]const u8, c_int) void;
    pub extern fn pango_layout_set_single_paragraph_mode(*c.PangoLayout, c.gboolean) void;
    pub extern fn pango_layout_get_pixel_extents(*c.PangoLayout, ?*PangoRectangle, ?*PangoRectangle) void;
    pub extern fn pango_layout_get_baseline(*c.PangoLayout) c_int;
    pub extern fn pango_ft2_render_layout(*FT_Bitmap, *c.PangoLayout, c_int, c_int) void;
};

pub const Mask = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    left: i32,
    top: i32, // Relative to the requested baseline, in physical pixels.

    pub fn deinit(self: Mask, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
};

pub const Renderer = struct {
    context: ?*api.PangoContext = null,

    pub fn deinit(self: *Renderer) void {
        if (self.context) |context| c.g_object_unref(context);
        self.* = .{};
    }
    pub fn render(self: *Renderer, allocator: std.mem.Allocator, font: [:0]const u8, size: u32, value: [:0]const u8) !Mask {
        if (size == 0 or size > 1024 or value.len > 4096 or !std.unicode.utf8ValidateSlice(value)) return error.InvalidText;
        if (self.context == null) {
            const map = api.pango_ft2_font_map_new() orelse return error.FontMap;
            defer c.g_object_unref(map);
            self.context = api.pango_font_map_create_context(map) orelse return error.FontContext;
        }
        const layout = api.pango_layout_new(self.context.?) orelse return error.TextLayout;
        defer c.g_object_unref(layout);
        const description = api.pango_font_description_from_string(font) orelse return error.FontDescription;
        defer api.pango_font_description_free(description);
        api.pango_font_description_set_absolute_size(description, @as(f64, @floatFromInt(size)) * 1024);
        api.pango_layout_set_font_description(layout, description);
        api.pango_layout_set_single_paragraph_mode(layout, 1);
        api.pango_layout_set_text(layout, value, @intCast(value.len));
        var ink: api.PangoRectangle = .{};
        api.pango_layout_get_pixel_extents(layout, &ink, null);
        if (ink.width < 0 or ink.height < 0 or ink.width > 32768 or ink.height > 4096 or @as(i64, ink.width) * ink.height > 16 * 1024 * 1024) return error.TextTooLarge;
        const width: u32 = @intCast(ink.width);
        const height: u32 = @intCast(ink.height);
        const pixels = try allocator.alloc(u8, @as(usize, width) * height);
        @memset(pixels, 0);
        if (pixels.len > 0) {
            var bitmap: api.FT_Bitmap = .{ .rows = height, .width = width, .pitch = @intCast(width), .buffer = pixels.ptr };
            api.pango_ft2_render_layout(&bitmap, layout, -ink.x, -ink.y);
        }
        return .{ .pixels = pixels, .width = width, .height = height, .left = ink.x, .top = ink.y - @divTrunc(api.pango_layout_get_baseline(layout), 1024) };
    }
};

test "text masks preserve Unicode, physical scale, baseline and empty strings" {
    var renderer: Renderer = .{};
    defer renderer.deinit();
    const a = std.testing.allocator;
    const small = try renderer.render(a, "Adwaita Sans Bold", 11, "300 × 180 東京");
    defer small.deinit(a);
    const large = try renderer.render(a, "Adwaita Sans Bold", 22, "300 × 180 東京");
    defer large.deinit(a);
    try std.testing.expect(small.width > 0 and small.height > 0 and small.top < 0);
    try std.testing.expect(std.mem.indexOfNone(u8, small.pixels, &.{0}) != null);
    try std.testing.expect(large.width > small.width and large.height > small.height);
    const empty = try renderer.render(a, "Adwaita Sans Bold", 11, "");
    defer empty.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), empty.pixels.len);
    try std.testing.expectError(error.InvalidText, renderer.render(a, "Adwaita Sans", 0, "text"));
    try std.testing.expectError(error.InvalidText, renderer.render(a, "Adwaita Sans", 11, "\xff"));
}
