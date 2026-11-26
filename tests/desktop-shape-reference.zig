//! Compares desktop-shape.zig with HarfBuzz, the reference implementation it
//! follows, on the installed fonts the desktop uses: glyphs, clusters and
//! 26.6 positions must agree exactly.
const std = @import("std");
const hb = @import("harfbuzz-reference");
const fonts = @import("../desktop-fonts.zig");
const opentype = @import("../desktop-opentype.zig");
const shape = @import("../desktop-shape.zig");

const Case = struct {
    family: []const u8,
    text: []const u8,
    direction: shape.Direction = .ltr,
    weight: f32 = 400,
    size: f64 = 14.666,
};

const cases = [_]Case{
    .{ .family = "Adwaita Sans", .text = "Build complete" },
    .{ .family = "Adwaita Sans", .text = "AVAWAY To, Tr. ffi fl -> != 1/2 #1 0x1F", .weight = 700 },
    .{ .family = "Adwaita Sans", .text = "Wi-Fi “Office” — 300 × 180 ½ $5", .weight = 300, .size = 22 },
    .{ .family = "Adwaita Sans", .text = "Ελληνικά Кириллица Ǆ é é ệ ŉ", .weight = 550 },
    .{ .family = "Adwaita Sans", .text = "a\u{200D}b\u{200C}c\u{00AD}d\u{FE0F} e\u{2009}f\u{2003}g\u{00A0}h" },
    .{ .family = "Adwaita Sans", .text = "(a) [b] {c}", .direction = .rtl },
    .{ .family = "Adwaita Mono", .text = "fn main() { return 0; } // => <= >= ===" },
    .{ .family = "Adwaita Mono", .text = "Kerning AV Te", .weight = 700, .size = 30 },
    .{ .family = "DejaVu Sans", .text = "نافذة جديدة", .direction = .rtl },
    .{ .family = "DejaVu Sans", .text = "لا إله (مثال) ١٢٣", .direction = .rtl },
    .{ .family = "DejaVu Sans", .text = "שלום עולם", .direction = .rtl },
    .{ .family = "DejaVu Sans", .text = "Vật lý, Tiếng Việt, ǅ, ﬁ office AVA" },
    .{ .family = "DejaVu Sans", .text = "a\u{0301}\u{0323} o\u{0308}\u{0304} q\u{0307}" },
};

fn reference(a: std.mem.Allocator, data: []const u8, index: u32, design: []const f32, axes: []const opentype.Axis, size: f64, case: Case) ![]shape.Glyph {
    const blob = hb.hb_blob_create(@ptrCast(data.ptr), @intCast(data.len), hb.HB_MEMORY_MODE_READONLY, null, null);
    defer hb.hb_blob_destroy(blob);
    const face = hb.hb_face_create(blob, index);
    defer hb.hb_face_destroy(face);
    const font = hb.hb_font_create(face) orelse return error.Reference;
    defer hb.hb_font_destroy(font);
    const scale: c_int = @intFromFloat(@round(size * 64));
    hb.hb_font_set_scale(font, scale, scale);
    const ppem: c_uint = @intFromFloat(@round(size));
    hb.hb_font_set_ppem(font, ppem, ppem);
    if (axes.len > 0) hb.hb_font_set_var_coords_design(font, design.ptr, @intCast(axes.len));
    const buffer = hb.hb_buffer_create() orelse return error.Reference;
    defer hb.hb_buffer_destroy(buffer);
    hb.hb_buffer_add_utf8(buffer, case.text.ptr, @intCast(case.text.len), 0, @intCast(case.text.len));
    hb.hb_buffer_guess_segment_properties(buffer);
    hb.hb_buffer_set_direction(buffer, if (case.direction == .rtl) hb.HB_DIRECTION_RTL else hb.HB_DIRECTION_LTR);
    // The desktop leaves language unset in effect: its locale has no language-specific forms.
    hb.hb_buffer_set_language(buffer, hb.hb_language_from_string("und", -1));
    hb.hb_shape(font, buffer, null, 0);
    var count: c_uint = 0;
    const infos = hb.hb_buffer_get_glyph_infos(buffer, &count);
    const positions = hb.hb_buffer_get_glyph_positions(buffer, &count);
    const out = try a.alloc(shape.Glyph, count);
    for (out, infos[0..count], positions[0..count]) |*glyph, info, position| glyph.* = .{
        .id = info.codepoint,
        .cluster = info.cluster,
        .x_advance = position.x_advance,
        .y_advance = position.y_advance,
        .x_offset = position.x_offset,
        .y_offset = position.y_offset,
    };
    return out;
}

test "native shaping matches HarfBuzz on the desktop fonts" {
    const a = std.testing.allocator;
    var compared: usize = 0;
    for (cases) |case| {
        const matches = try fonts.sort(a, fonts.catalog(), case.family, case.weight, false);
        defer a.free(matches);
        if (matches.len == 0) continue;
        const match = matches[0];
        // Only compare against the requested family, not a fallback.
        if (!std.ascii.eqlIgnoreCase(match.font.families[0], case.family) and !std.ascii.eqlIgnoreCase(match.font.families[1], case.family)) continue;
        const file = opentype.Mapped.open(match.font.path) orelse continue;
        defer file.close();
        const font = try opentype.Font.init(file.bytes, @intCast(match.font.index));
        var design: [opentype.max_axes]f32 = undefined;
        var coords: [opentype.max_axes]f32 = undefined;
        const axes = font.axes[0..font.axis_count];
        for (axes, design[0..axes.len]) |axis, *value| value.* = if (axis.tag == opentype.tagOf("wght")) case.weight else axis.default;
        font.normalize(design[0..axes.len], &coords);

        var face = shape.Face.init(a, &font);
        defer face.deinit();
        const native = try shape.shape(a, &face, coords[0..axes.len], case.size, case.text, 0, case.text.len, case.direction);
        defer a.free(native);
        const expected = try reference(a, file.bytes, @intCast(match.font.index), design[0..axes.len], axes, case.size, case);
        defer a.free(expected);
        std.testing.expectEqualSlices(shape.Glyph, expected, native) catch |err| {
            std.debug.print("{s} \"{s}\" ({s}, weight {d}, {d} px)\n", .{ case.family, case.text, @tagName(case.direction), case.weight, case.size });
            for (0..@max(expected.len, native.len)) |k| {
                const e: ?shape.Glyph = if (k < expected.len) expected[k] else null;
                const n: ?shape.Glyph = if (k < native.len) native[k] else null;
                std.debug.print("  {d}: harfbuzz {any}\n     native   {any}\n", .{ k, e, n });
            }
            return err;
        };
        // Ascender and descender as Pango measured them through HarfBuzz.
        const blob = hb.hb_blob_create(@ptrCast(file.bytes.ptr), @intCast(file.bytes.len), hb.HB_MEMORY_MODE_READONLY, null, null);
        defer hb.hb_blob_destroy(blob);
        const hb_face = hb.hb_face_create(blob, @intCast(match.font.index));
        defer hb.hb_face_destroy(hb_face);
        const hb_font = hb.hb_font_create(hb_face);
        defer hb.hb_font_destroy(hb_font);
        const scale: c_int = @intFromFloat(@round(case.size * 1024));
        hb.hb_font_set_scale(hb_font, scale, scale);
        if (axes.len > 0) hb.hb_font_set_var_coords_design(hb_font, &design, @intCast(axes.len));
        var extents: hb.hb_font_extents_t = .{};
        _ = hb.hb_font_get_h_extents(hb_font, &extents);
        const native_extents = face.extents(coords[0..axes.len], @floatFromInt(scale));
        try std.testing.expectEqual(extents.ascender, native_extents[0]);
        try std.testing.expectEqual(extents.descender, native_extents[1]);
        compared += 1;
    }
    // The build's font configuration provides Adwaita and DejaVu, so every case runs.
    try std.testing.expectEqual(cases.len, compared);
}

test "shaping survives corrupted layout, metrics and cmap tables" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "Adwaita Sans", "DejaVu Sans" }) |family| {
        const matches = try fonts.sort(a, fonts.catalog(), family, 400, false);
        defer a.free(matches);
        if (matches.len == 0) continue;
        const file = opentype.Mapped.open(matches[0].font.path) orelse continue;
        defer file.close();
        const original = try opentype.Font.init(file.bytes, @intCast(matches[0].font.index));
        const copy = try a.dupe(u8, file.bytes);
        defer a.free(copy);
        var prng: std.Random.DefaultPrng = .init(0x5eed);
        const random = prng.random();
        for (0..200) |_| {
            @memcpy(copy, file.bytes);
            // Damage the tables shaping reads, at their offsets within the file.
            for ([_]*const [4]u8{ "GSUB", "GPOS", "GDEF", "HVAR", "MVAR", "hmtx", "cmap" }) |name| {
                const table = original.findTable(opentype.tagOf(name)) orelse continue;
                if (table.data.len == 0) continue;
                const start = @intFromPtr(table.data.ptr) - @intFromPtr(file.bytes.ptr);
                for (0..16) |_| copy[start + random.uintLessThan(usize, table.data.len)] = random.int(u8);
            }
            const font = opentype.Font.init(copy, @intCast(matches[0].font.index)) catch continue;
            var coords: [opentype.max_axes]f32 = @splat(0);
            for (coords[0..font.axis_count]) |*c| c.* = random.float(f32) * 2 - 1;
            var face = shape.Face.init(a, &font);
            defer face.deinit();
            for ([_]struct { []const u8, shape.Direction }{
                .{ "office AVA ffi -> é é", .ltr },
                .{ "نافذة لا (مثال)", .rtl },
                .{ "a\u{200D}b\u{FE0F} \u{2009}x", .ltr },
            }) |sample| {
                const glyphs = try shape.shape(a, &face, coords[0..font.axis_count], 15, sample[0], 0, sample[0].len, sample[1]);
                a.free(glyphs);
                _ = face.extents(coords[0..font.axis_count], 15 * 1024);
            }
        }
    }
}
