//! Text layout into grayscale glyph masks. fontconfig selects fonts and
//! fallbacks, HarfBuzz shapes and FreeType rasterizes; markup, bidi ordering,
//! line breaking, ellipsis and alignment are handled here, without Pango.
const std = @import("std");
const t = @import("text-c");

pub const Mask = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    left: i32,
    top: i32, // Relative to the requested baseline, in physical pixels.
    logical_height: u32 = 0,
    logical_width: u32 = 0,
    ellipsized: bool = false,

    pub fn deinit(self: Mask, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
    pub fn paint(self: Mask, canvas: @import("desktop-raster.zig").Canvas, x: f64, y: f64, color: @import("desktop-raster.zig").Color) void {
        @import("desktop-raster.zig").mask(canvas.target, .{
            .x = @as(i32, @intFromFloat((x + canvas.origin.x) * canvas.scale)) + self.left,
            .y = @as(i32, @intFromFloat((y + canvas.origin.y) * canvas.scale)) + self.top,
            .width = self.width,
            .height = self.height,
        }, self.pixels, color);
    }
};

pub fn paintMask(canvas: @import("desktop-raster.zig").Canvas, value: ?Mask, x: f64, y: f64, color: @import("desktop-raster.zig").Color) void {
    if (value) |mask| mask.paint(canvas, x, y, color);
}

const load_target_light: i32 = 1 << 16;
const load_no_hinting: i32 = 1 << 1;
const load_force_autohint: i32 = 1 << 5;
const load_no_bitmap: i32 = 1 << 3;

fn tag(comptime s: *const [4]u8) c_ulong {
    return (@as(c_ulong, s[0]) << 24) | (@as(c_ulong, s[1]) << 16) | (@as(c_ulong, s[2]) << 8) | s[3];
}

/// A loaded face from a fontconfig match.
const Face = struct {
    face: t.FT_Face,
    hb: *t.hb_font_t,
    charset: ?*t.FcCharSet,
    load_flags: i32,
    embolden: bool,
    /// Axis indexes for automatic variations, when the face is variable.
    axes: [8]c_ulong = @splat(0),
    defaults: [8]t.FT_Fixed = @splat(0),
    axis_count: u32 = 0,
    named: bool,
    size: f64 = 0,
    points: f64 = 0,
    weight: f64 = 0,

    fn has(self: *const Face, codepoint: u21) bool {
        if (self.charset) |set| return t.FcCharSetHasChar(set, codepoint) != 0;
        return t.FT_Get_Char_Index(self.face, codepoint) != 0;
    }

    /// Sets the pixel size, optical size and weight used for shaping and rendering.
    fn configure(self: *Face, size: f64, points: f64, weight: f64) void {
        if (self.size == size and self.points == points and self.weight == weight) return;
        self.size = size;
        self.points = points;
        self.weight = weight;
        _ = t.FT_Set_Char_Size(self.face, 0, @intFromFloat(@round(size * 64)), 72, 72);
        if (self.axis_count > 0) {
            var coords: [8]t.FT_Fixed = undefined;
            for (0..self.axis_count) |i| {
                coords[i] = self.defaults[i];
                if (self.axes[i] == tag("opsz")) coords[i] = @intFromFloat(points * 65536);
                if (self.axes[i] == tag("wght") and !self.named) coords[i] = @intFromFloat(weight * 65536);
            }
            _ = t.FT_Set_Var_Design_Coordinates(self.face, self.axis_count, &coords);
        }
        t.hb_ft_font_changed(self.hb);
    }

    /// Ascent and descent at 1/1024 pixel precision, matching Pango's units.
    fn extents(self: *Face) [2]f64 {
        const font = t.hb_font_create(t.hb_font_get_face(self.hb)) orelse return .{ 0, 0 };
        defer t.hb_font_destroy(font);
        const scale: c_int = @intFromFloat(@round(self.size * 1024));
        t.hb_font_set_scale(font, scale, scale);
        var coords: [8]t.FT_Fixed = undefined;
        if (self.axis_count > 0 and t.FT_Get_Var_Design_Coordinates(self.face, self.axis_count, &coords) == 0) {
            var design: [8]f32 = undefined;
            for (0..self.axis_count) |i| design[i] = @as(f32, @floatFromInt(coords[i])) / 65536;
            t.hb_font_set_var_coords_design(font, &design, self.axis_count);
        }
        var value: t.hb_font_extents_t = .{};
        _ = t.hb_font_get_h_extents(font, &value);
        return .{ @as(f64, @floatFromInt(value.ascender)) / 1024, @as(f64, @floatFromInt(-value.descender)) / 1024 };
    }
};

/// The fontconfig fallback list for one family, weight and slant.
const Family = struct {
    set: [*c]t.FcFontSet,
    faces: []?*Face,
    weight: f64,
};

const Bitmap = struct { left: i32, top: i32, width: u32, height: u32, pixels: []u8 };
const GlyphKey = struct { face: *Face, glyph: u32, size: u32, points: u32, weight: u32 };

pub const Renderer = struct {
    library: t.FT_Library = null,
    config: ?*t.FcConfig = null,
    families: std.StringHashMapUnmanaged(*Family) = .empty,
    glyphs: std.AutoHashMapUnmanaged(GlyphKey, Bitmap) = .empty,
    arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator),

    pub fn deinit(self: *Renderer) void {
        var families = self.families.valueIterator();
        while (families.next()) |owner| {
            for (owner.*.faces) |entry| if (entry) |loaded| {
                t.hb_font_destroy(loaded.hb);
                _ = t.FT_Done_Face(loaded.face);
            };
            t.FcFontSetDestroy(owner.*.set);
        }
        if (self.library) |library| _ = t.FT_Done_FreeType(library);
        if (self.config) |config| t.FcConfigDestroy(config);
        self.arena.deinit();
        self.* = .{};
    }

    pub fn render(self: *Renderer, allocator: std.mem.Allocator, font: [:0]const u8, size: u32, value: [:0]const u8) !Mask {
        return self.renderLayout(allocator, value, .{ .font = font, .size = @floatFromInt(size) });
    }

    pub const Options = struct {
        font: [:0]const u8 = "Adwaita Sans",
        size: f64,
        dpi: f64 = 96,
        line_height: ?u32 = null,
        width: ?u32 = null,
        alignment: enum(c_uint) { left, center, right } = .left,
        ellipsize: bool = false,
        origin: enum { baseline, top } = .baseline,
        lines: ?u32 = null,
        markup: bool = false,
    };

    fn init(self: *Renderer) !void {
        if (self.library != null) return;
        var library: t.FT_Library = null;
        if (t.FT_Init_FreeType(&library) != 0) return error.FontMap;
        self.library = library;
        // Share the process-wide configuration instead of rescanning fonts per renderer.
        if (t.FcInit() == 0) return error.FontMap;
        self.config = t.FcConfigReference(null) orelse return error.FontMap;
    }

    fn family(self: *Renderer, description: Description) !*Family {
        const a = self.arena.allocator();
        const key = try std.fmt.allocPrint(a, "{s}|{d}|{}", .{ description.family, description.weight, description.italic });
        if (self.families.get(key)) |existing| return existing;
        const pattern = t.FcPatternCreate() orelse return error.FontMap;
        defer t.FcPatternDestroy(pattern);
        var names = std.mem.splitScalar(u8, description.family, ',');
        while (names.next()) |raw| {
            const name = std.mem.trim(u8, raw, " ");
            if (name.len == 0) continue;
            const z = try a.dupeSentinel(u8, name, 0);
            _ = t.FcPatternAddString(pattern, "family", z.ptr);
        }
        _ = t.FcPatternAddDouble(pattern, "weight", t.FcWeightFromOpenTypeDouble(description.weight));
        _ = t.FcPatternAddInteger(pattern, "slant", if (description.italic) 100 else 0);
        _ = t.FcConfigSubstitute(self.config, pattern, t.FcMatchPattern);
        t.FcDefaultSubstitute(pattern);
        var result: t.FcResult = undefined;
        const sorted = t.FcFontSort(self.config, pattern, 1, null, &result);
        if (sorted == null or sorted.*.nfont == 0) return error.FontMap;
        // Render-prepared patterns carry hinting and embolden settings.
        const set = t.FcFontSetCreate() orelse return error.FontMap;
        for (0..@intCast(sorted.*.nfont)) |i| {
            if (t.FcFontRenderPrepare(self.config, pattern, sorted.*.fonts[i])) |prepared| _ = t.FcFontSetAdd(set, prepared);
        }
        t.FcFontSetDestroy(sorted);
        const value = try a.create(Family);
        value.* = .{ .set = set, .faces = try a.alloc(?*Face, @intCast(set.*.nfont)), .weight = description.weight };
        @memset(value.faces, null);
        try self.families.put(a, key, value);
        return value;
    }

    fn face(self: *Renderer, owner: *Family, index: usize) ?*Face {
        if (owner.faces[index]) |existing| return existing;
        const pattern = owner.set.*.fonts[index];
        var file: [*c]u8 = null;
        if (t.FcPatternGetString(pattern, "file", 0, &file) != t.FcResultMatch) return null;
        var face_index: c_int = 0;
        _ = t.FcPatternGetInteger(pattern, "index", 0, &face_index);
        var scalable: t.FcBool = 1;
        _ = t.FcPatternGetBool(pattern, "scalable", 0, &scalable);
        if (scalable == 0) return null;
        var ft_face: t.FT_Face = null;
        if (t.FT_New_Face(self.library, file, face_index, &ft_face) != 0) return null;
        const hb = t.hb_ft_font_create_referenced(ft_face) orelse {
            _ = t.FT_Done_Face(ft_face);
            return null;
        };
        var charset: ?*t.FcCharSet = null;
        _ = t.FcPatternGetCharSet(pattern, "charset", 0, &charset);
        var antialias: t.FcBool = 1;
        var hinting: t.FcBool = 1;
        var autohint: t.FcBool = 0;
        var embolden: t.FcBool = 0;
        var hintstyle: c_int = 1;
        _ = t.FcPatternGetBool(pattern, "antialias", 0, &antialias);
        _ = t.FcPatternGetBool(pattern, "hinting", 0, &hinting);
        _ = t.FcPatternGetBool(pattern, "autohint", 0, &autohint);
        _ = t.FcPatternGetBool(pattern, "embolden", 0, &embolden);
        _ = t.FcPatternGetInteger(pattern, "hintstyle", 0, &hintstyle);
        // Match Pango's FreeType loading: slight hinting targets the light hinter.
        var flags: i32 = load_no_bitmap;
        if (hinting == 0 or hintstyle == 0) {
            flags |= load_no_hinting;
        } else if (hintstyle == 1) {
            flags |= load_target_light;
        }
        if (autohint != 0) flags |= load_force_autohint;
        const value = self.arena.allocator().create(Face) catch return null;
        value.* = .{ .face = ft_face, .hb = hb, .charset = charset, .load_flags = flags, .embolden = embolden != 0, .named = (face_index >> 16) != 0 };
        if ((ft_face.*.face_flags & (@as(c_long, 1) << 8)) != 0) {
            var mm: [*c]t.FT_MM_Var = null;
            if (t.FT_Get_MM_Var(ft_face, &mm) == 0) {
                defer _ = t.FT_Done_MM_Var(self.library, mm);
                var current: [8]t.FT_Fixed = undefined;
                const count = @min(mm.*.num_axis, 8);
                _ = t.FT_Get_Var_Design_Coordinates(ft_face, count, &current);
                for (0..count) |i| {
                    value.axes[i] = mm.*.axis[i].tag;
                    value.defaults[i] = current[i];
                }
                value.axis_count = count;
            }
        }
        owner.faces[index] = value;
        return value;
    }

    /// The first face in the fallback list covering `codepoint`.
    fn pick(self: *Renderer, owner: *Family, codepoint: u21) ?*Face {
        for (0..owner.faces.len) |i| {
            const candidate = self.face(owner, i) orelse continue;
            if (candidate.has(codepoint)) return candidate;
        }
        return self.face(owner, 0) orelse for (0..owner.faces.len) |i| {
            if (self.face(owner, i)) |candidate| break candidate;
        } else null;
    }

    fn glyph(self: *Renderer, owner: *Face, id: u32) ?Bitmap {
        const key: GlyphKey = .{ .face = owner, .glyph = id, .size = @intFromFloat(owner.size * 64), .points = @intFromFloat(owner.points * 64), .weight = @intFromFloat(owner.weight) };
        if (self.glyphs.get(key)) |cached| return cached;
        if (t.FT_Load_Glyph(owner.face, id, owner.load_flags) != 0) return null;
        const slot = owner.face.*.glyph;
        if (owner.embolden) t.FT_GlyphSlot_Embolden(slot);
        if (t.FT_Render_Glyph(slot, t.FT_RENDER_MODE_NORMAL) != 0) return null;
        const bitmap = slot.*.bitmap;
        const width = bitmap.width;
        const height = bitmap.rows;
        const a = self.arena.allocator();
        const pixels = a.alloc(u8, @as(usize, width) * height) catch return null;
        for (0..height) |row| {
            const pitch: isize = bitmap.pitch;
            const source: [*]const u8 = @ptrCast(bitmap.buffer + @as(usize, @intCast(if (pitch >= 0) @as(isize, @intCast(row)) * pitch else (@as(isize, @intCast(height - 1 - row))) * -pitch)));
            switch (bitmap.pixel_mode) {
                // FT_PIXEL_MODE_MONO: one bit per pixel.
                1 => for (0..width) |column| {
                    pixels[row * width + column] = if ((source[column / 8] >> @intCast(7 - column % 8)) & 1 != 0) 255 else 0;
                },
                // FT_PIXEL_MODE_BGRA: keep the alpha channel.
                7 => for (0..width) |column| {
                    pixels[row * width + column] = source[column * 4 + 3];
                },
                else => @memcpy(pixels[row * width ..][0..width], source[0..width]),
            }
        }
        const value: Bitmap = .{ .left = slot.*.bitmap_left, .top = slot.*.bitmap_top, .width = width, .height = height, .pixels = pixels };
        self.glyphs.put(a, key, value) catch {};
        return value;
    }

    pub fn renderLayout(self: *Renderer, allocator: std.mem.Allocator, value: [:0]const u8, options: Options) !Mask {
        if (!std.math.isFinite(options.size) or options.size <= 0 or options.size > 1024 or !std.math.isFinite(options.dpi) or options.dpi <= 0 or options.dpi > 1536 or value.len > 4096 or !std.unicode.utf8ValidateSlice(value)) return error.InvalidText;
        if (options.width) |limit| if (limit == 0 or limit > 32768) return error.InvalidText;
        if (options.lines) |lines| if (lines == 0 or lines > 64) return error.InvalidText;
        if (options.line_height) |height| if (height == 0 or height > 4096) return error.InvalidText;
        try self.init();
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const a = arena.allocator();
        // Match GTK labels: malformed markup is displayed literally.
        const parsed: Markup = if (options.markup) (parseMarkup(a, value) catch try plain(a, value)) else try plain(a, value);
        var layout: Layout = .{ .renderer = self, .a = a, .text = parsed.text, .spans = parsed.spans, .options = options, .base = parseDescription(options.font) };
        try layout.run();
        return layout.mask(allocator);
    }
};

// ---------------------------------------------------------------- Fonts

const Description = struct { family: []const u8, weight: f64 = 400, italic: bool = false };

/// Parses Pango-style descriptions such as "Adwaita Sans Bold Italic 11".
fn parseDescription(text: []const u8) Description {
    var result: Description = .{ .family = std.mem.trim(u8, text, " ") };
    const styles = [_]struct { word: []const u8, weight: ?f64 = null, italic: bool = false }{
        .{ .word = "Thin", .weight = 100 },        .{ .word = "Ultra-Light", .weight = 200 }, .{ .word = "Extra-Light", .weight = 200 },
        .{ .word = "Light", .weight = 300 },       .{ .word = "Semi-Light", .weight = 350 },  .{ .word = "Book", .weight = 380 },
        .{ .word = "Regular", .weight = 400 },     .{ .word = "Normal", .weight = 400 },      .{ .word = "Medium", .weight = 500 },
        .{ .word = "Semi-Bold", .weight = 600 },   .{ .word = "Semibold", .weight = 600 },    .{ .word = "Demi-Bold", .weight = 600 },
        .{ .word = "Bold", .weight = 700 },        .{ .word = "Ultra-Bold", .weight = 800 },  .{ .word = "Extra-Bold", .weight = 800 },
        .{ .word = "Heavy", .weight = 900 },       .{ .word = "Black", .weight = 900 },       .{ .word = "Italic", .italic = true },
        .{ .word = "Oblique", .italic = true },
    };
    while (true) {
        const space = std.mem.lastIndexOfScalar(u8, result.family, ' ') orelse break;
        const word = result.family[space + 1 ..];
        var matched = false;
        if (std.fmt.parseFloat(f64, word)) |_| {
            matched = true;
        } else |_| for (styles) |style| if (std.ascii.eqlIgnoreCase(word, style.word)) {
            if (style.weight) |weight| result.weight = weight;
            if (style.italic) result.italic = true;
            matched = true;
            break;
        };
        if (!matched) break;
        result.family = std.mem.trimEnd(u8, result.family[0..space], " ,");
    }
    if (result.family.len == 0) result.family = "Sans";
    return result;
}

// ---------------------------------------------------------------- Markup

const Style = struct {
    weight: ?f64 = null,
    italic: ?bool = null,
    scale: f64 = 1,
    underline: bool = false,
    strike: bool = false,
    family: ?[]const u8 = null,
};
const Span = struct { start: usize, end: usize, style: Style };
const Markup = struct { text: []const u8, spans: []const Span };

fn plain(a: std.mem.Allocator, value: []const u8) !Markup {
    _ = a;
    return .{ .text = value, .spans = &.{} };
}

/// Pango markup: b, i, u, s, tt, big, small, sub, sup and span attributes.
fn parseMarkup(a: std.mem.Allocator, value: []const u8) !Markup {
    var text: std.ArrayList(u8) = .empty;
    var spans: std.ArrayList(Span) = .empty;
    const Open = struct { name: []const u8, style: Style, start: usize };
    var stack: std.ArrayList(Open) = .empty;
    var i: usize = 0;
    while (i < value.len) {
        const c = value[i];
        if (c == '&') {
            const end = std.mem.indexOfScalarPos(u8, value, i, ';') orelse return error.InvalidMarkup;
            const name = value[i + 1 .. end];
            if (std.mem.eql(u8, name, "amp")) try text.append(a, '&') else if (std.mem.eql(u8, name, "lt")) try text.append(a, '<') else if (std.mem.eql(u8, name, "gt")) try text.append(a, '>') else if (std.mem.eql(u8, name, "quot")) try text.append(a, '"') else if (std.mem.eql(u8, name, "apos")) try text.append(a, '\'') else if (name.len > 1 and name[0] == '#') {
                const code = (if (name[1] == 'x') std.fmt.parseInt(u21, name[2..], 16) else std.fmt.parseInt(u21, name[1..], 10)) catch return error.InvalidMarkup;
                var buffer: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(code, &buffer) catch return error.InvalidMarkup;
                try text.appendSlice(a, buffer[0..n]);
            } else return error.InvalidMarkup;
            i = end + 1;
            continue;
        }
        if (c != '<') {
            try text.append(a, c);
            i += 1;
            continue;
        }
        const end = std.mem.indexOfScalarPos(u8, value, i, '>') orelse return error.InvalidMarkup;
        const inner = std.mem.trim(u8, value[i + 1 .. end], " \t\n");
        i = end + 1;
        if (inner.len == 0) return error.InvalidMarkup;
        if (inner[0] == '/') {
            const open = stack.pop() orelse return error.InvalidMarkup;
            if (!std.mem.eql(u8, std.mem.trim(u8, inner[1..], " "), open.name)) return error.InvalidMarkup;
            if (text.items.len > open.start) try spans.append(a, .{ .start = open.start, .end = text.items.len, .style = open.style });
            continue;
        }
        const self_closing = inner[inner.len - 1] == '/';
        const body = if (self_closing) inner[0 .. inner.len - 1] else inner;
        const name_end = std.mem.indexOfAny(u8, body, " \t\n") orelse body.len;
        const name = body[0..name_end];
        var style: Style = .{};
        const eql = std.mem.eql;
        if (eql(u8, name, "b")) {
            style.weight = 700;
        } else if (eql(u8, name, "i")) {
            style.italic = true;
        } else if (eql(u8, name, "u")) {
            style.underline = true;
        } else if (eql(u8, name, "s")) {
            style.strike = true;
        } else if (eql(u8, name, "tt")) {
            style.family = "monospace";
        } else if (eql(u8, name, "big")) {
            style.scale = 1.2;
        } else if (eql(u8, name, "small") or eql(u8, name, "sub") or eql(u8, name, "sup")) {
            style.scale = 1.0 / 1.2;
        } else if (eql(u8, name, "span")) {
            try spanAttributes(body[name_end..], &style);
        } else return error.InvalidMarkup;
        if (!self_closing) try stack.append(a, .{ .name = name, .style = style, .start = text.items.len });
    }
    if (stack.items.len != 0) return error.InvalidMarkup;
    return .{ .text = text.items, .spans = spans.items };
}

fn spanAttributes(text: []const u8, style: *Style) !void {
    var rest = std.mem.trim(u8, text, " \t\n");
    while (rest.len > 0) {
        const eq = std.mem.indexOfScalar(u8, rest, '=') orelse return error.InvalidMarkup;
        const name = std.mem.trim(u8, rest[0..eq], " \t\n");
        rest = std.mem.trimStart(u8, rest[eq + 1 ..], " \t\n");
        if (rest.len == 0 or (rest[0] != '"' and rest[0] != '\'')) return error.InvalidMarkup;
        const close = std.mem.indexOfScalarPos(u8, rest, 1, rest[0]) orelse return error.InvalidMarkup;
        const value = rest[1..close];
        rest = std.mem.trimStart(u8, rest[close + 1 ..], " \t\n");
        const eql = std.mem.eql;
        if (eql(u8, name, "weight") or eql(u8, name, "font_weight")) {
            style.weight = if (eql(u8, value, "bold")) 700 else if (eql(u8, value, "normal")) 400 else if (eql(u8, value, "light")) 300 else if (eql(u8, value, "heavy")) 900 else if (eql(u8, value, "semibold")) 600 else std.fmt.parseFloat(f64, value) catch 400;
        } else if (eql(u8, name, "style") or eql(u8, name, "font_style")) {
            style.italic = !eql(u8, value, "normal");
        } else if (eql(u8, name, "underline")) {
            style.underline = !eql(u8, value, "none");
        } else if (eql(u8, name, "strikethrough")) {
            style.strike = eql(u8, value, "true");
        } else if (eql(u8, name, "size") or eql(u8, name, "font_size")) {
            style.scale = if (eql(u8, value, "larger")) 1.2 else if (eql(u8, value, "smaller")) 1.0 / 1.2 else if (eql(u8, value, "large")) 1.2 else if (eql(u8, value, "small")) 1.0 / 1.2 else if (eql(u8, value, "x-large")) 1.44 else if (eql(u8, value, "x-small")) 1.0 / 1.44 else 1;
        } else if (eql(u8, name, "face") or eql(u8, name, "font_family")) {
            style.family = value;
        } else if (eql(u8, name, "foreground") or eql(u8, name, "fgcolor") or eql(u8, name, "color") or eql(u8, name, "background") or eql(u8, name, "bgcolor") or eql(u8, name, "alpha") or eql(u8, name, "fgalpha") or eql(u8, name, "lang") or eql(u8, name, "font") or eql(u8, name, "font_desc") or eql(u8, name, "rise") or eql(u8, name, "letter_spacing") or eql(u8, name, "stretch") or eql(u8, name, "variant")) {
            // Colors do not apply to grayscale masks; other attributes are accepted and ignored.
        } else return error.InvalidMarkup;
    }
}

// ---------------------------------------------------------------- Bidi

const Class = enum { l, r, en, an, neutral, mark };

fn classify(c: u21) Class {
    // Checked in order: numbers and marks before the right-to-left blocks containing them.
    return switch (c) {
        '0'...'9', 0x06F0...0x06F9 => .en,
        0x0660...0x0669, 0x066B, 0x066C => .an,
        0x0300...0x036F, 0x0483...0x0489, 0x0591...0x05BD, 0x05BF, 0x05C1, 0x05C2, 0x05C4, 0x05C5, 0x05C7, 0x0610...0x061A, 0x064B...0x065F, 0x0670, 0x06D6...0x06DC, 0x06DF...0x06E4, 0x06E7, 0x06E8, 0x06EA...0x06ED, 0x200C, 0x200D, 0xFE00...0xFE0F, 0x20D0...0x20FF => .mark,
        0x200E => .l,
        0x200F => .r,
        0...0x2F, 0x3A...0x40, 0x5B...0x60, 0x7B...0xBF, 0xD7, 0xF7, 0x2000...0x200B, 0x2010...0x206F, 0x2070...0x20CF, 0x2100...0x2BFF, 0x3000...0x303F, 0xFE30...0xFE4F, 0xFF00...0xFF20, 0x1F000...0x1FAFF => .neutral,
        else => if ((c >= 0x0590 and c <= 0x08FF) or (c >= 0xFB1D and c <= 0xFDFF) or (c >= 0xFE70 and c <= 0xFEFF) or (c >= 0x10800 and c <= 0x10FFF) or (c >= 0x1E800 and c <= 0x1EFFF)) .r else .l,
    };
}

/// Resolves embedding levels for one paragraph with a simplified UBA:
/// strong types, numbers after right-to-left text, neutrals between equal
/// strong types and marks following their base.
fn resolveLevels(classes: []const Class, levels: []u8, base: u8) void {
    var last_strong: Class = if (base == 1) .r else .l;
    for (classes, levels) |class, *level| {
        level.* = switch (class) {
            .l => if (base == 1) 2 else 0,
            .r => 1,
            .an => 2,
            .en => if (base == 1 or last_strong == .r) 2 else 0,
            .neutral, .mark => 255,
        };
        if (class == .l or class == .r) last_strong = class;
    }
    var i: usize = 0;
    while (i < classes.len) {
        if (levels[i] != 255) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < classes.len and levels[j] == 255) j += 1;
        // Marks attach to the preceding character.
        const before: ?u8 = if (i > 0) levels[i - 1] else null;
        const after: ?u8 = if (j < classes.len) levels[j] else null;
        const rtl = struct {
            fn f(level: ?u8) ?bool {
                return if (level) |l| l % 2 == 1 or l == 2 else null;
            }
        }.f;
        const left = rtl(before);
        const right = rtl(after);
        const resolved: u8 = if (left != null and right != null and left.? == right.?) (if (left.?) @max(1, base) else base) else base;
        for (i..j) |k| levels[k] = if (classes[k] == .mark and k > 0 and levels[k - 1] != 255) levels[k - 1] else resolved;
        i = j;
    }
}

// ---------------------------------------------------------------- Layout

const Item = struct {
    start: usize,
    end: usize,
    face: *Face,
    size: f64,
    weight: f64,
    level: u8,
    style: Style,
};

/// Glyph positions snap to whole pixels, as with Pango's default rounding.
fn snap(value: t.hb_position_t) f64 {
    return @round(@as(f64, @floatFromInt(value)) / 64);
}

const Glyph = struct { face: *Face, id: u32, x: f64, y: f64, size: f64, weight: f64, points: f64 };
const Decoration = struct { x: f64, width: f64, y: f64, thickness: f64 };

/// Pango marks intra-word breaks with U+2010 HYPHEN.
const hyphen_symbol = "\u{2010}";

const Line = struct {
    start: usize,
    end: usize,
    ellipsis: bool = false,
    hyphen: bool = false,
};

const Layout = struct {
    renderer: *Renderer,
    a: std.mem.Allocator,
    text: []const u8,
    spans: []const Span,
    options: Renderer.Options,
    base: Description,
    items: std.ArrayList(Item) = .empty,
    /// Advance per byte offset; glyph advances accumulate on their cluster.
    advances: []f64 = &.{},
    levels: []u8 = &.{},
    paragraph_rtl: []bool = &.{},
    glyphs: std.ArrayList(Glyph) = .empty,
    decorations: std.ArrayList(Decoration) = .empty,
    logical_width: f64 = 0,
    logical_left: f64 = std.math.inf(f64),
    logical_height: f64 = 0,
    baseline: f64 = 0,
    ellipsized: bool = false,

    fn styleAt(self: *const Layout, offset: usize) Style {
        var style: Style = .{};
        for (self.spans) |span| if (offset >= span.start and offset < span.end) {
            if (span.style.weight) |w| style.weight = w;
            if (span.style.italic) |v| style.italic = v;
            style.scale *= span.style.scale;
            style.underline = style.underline or span.style.underline;
            style.strike = style.strike or span.style.strike;
            if (span.style.family) |f| style.family = f;
        };
        return style;
    }

    fn descriptionFor(self: *const Layout, style: Style) Description {
        return .{
            .family = style.family orelse self.base.family,
            .weight = style.weight orelse self.base.weight,
            .italic = style.italic orelse self.base.italic,
        };
    }

    fn points(self: *const Layout, size: f64) f64 {
        // Optical size follows the point size at the output DPI, as the patched
        // pangoft2 applied it, so scaled outputs keep the 1x text proportions.
        return size * 72 / self.options.dpi;
    }

    /// Splits text into runs of one face, style and bidi level.
    fn itemize(self: *Layout) !void {
        const text = self.text;
        var codepoints: std.ArrayList(struct { offset: usize, value: u21 }) = .empty;
        var view = std.unicode.Utf8View.initUnchecked(text).iterator();
        var offset: usize = 0;
        while (view.nextCodepointSlice()) |slice| {
            try codepoints.append(self.a, .{ .offset = offset, .value = std.unicode.utf8Decode(slice) catch 0xFFFD });
            offset += slice.len;
        }
        self.levels = try self.a.alloc(u8, text.len);
        self.paragraph_rtl = try self.a.alloc(bool, text.len);
        // Resolve bidi levels paragraph by paragraph.
        var start: usize = 0;
        while (start < codepoints.items.len) {
            var stop = start;
            while (stop < codepoints.items.len and codepoints.items[stop].value != '\n') stop += 1;
            const classes = try self.a.alloc(Class, stop - start);
            var base: u8 = 0;
            var found = false;
            for (codepoints.items[start..stop], classes) |cp, *class| {
                class.* = classify(cp.value);
                if (!found and (class.* == .l or class.* == .r)) {
                    base = if (class.* == .r) 1 else 0;
                    found = true;
                }
            }
            const levels = try self.a.alloc(u8, stop - start);
            resolveLevels(classes, levels, base);
            for (codepoints.items[start..stop], levels) |cp, level| {
                const next = if (cp.offset < text.len) std.unicode.utf8ByteSequenceLength(text[cp.offset]) catch 1 else 1;
                @memset(self.levels[cp.offset..][0..next], level);
                @memset(self.paragraph_rtl[cp.offset..][0..next], base == 1);
            }
            if (stop < codepoints.items.len) {
                self.levels[codepoints.items[stop].offset] = base;
                self.paragraph_rtl[codepoints.items[stop].offset] = base == 1;
            }
            start = stop + 1;
        }
        var current: ?Item = null;
        var previous_face: ?*Face = null;
        for (codepoints.items, 0..) |cp, index| {
            const style = self.styleAt(cp.offset);
            const owner = try self.renderer.family(self.descriptionFor(style));
            const class = classify(cp.value);
            // Neutral and combining characters stay in the previous face when it covers them.
            var chosen: ?*Face = null;
            if ((class == .neutral or class == .mark) and previous_face != null and previous_face.?.has(cp.value)) chosen = previous_face;
            if (chosen == null) chosen = self.renderer.pick(owner, if (cp.value == '\n') ' ' else cp.value);
            const face = chosen orelse continue;
            previous_face = face;
            const size = self.options.size * style.scale;
            const level = self.levels[cp.offset];
            const end = if (index + 1 < codepoints.items.len) codepoints.items[index + 1].offset else text.len;
            if (current) |*item| {
                if (item.face == face and item.size == size and item.level == level and std.meta.eql(item.style, style) and cp.value != '\n') {
                    item.end = end;
                    continue;
                }
                try self.items.append(self.a, item.*);
            }
            current = .{ .start = cp.offset, .end = end, .face = face, .size = size, .weight = self.descriptionFor(style).weight, .level = level, .style = style };
            if (cp.value == '\n') {
                try self.items.append(self.a, current.?);
                current = null;
            }
        }
        if (current) |item| try self.items.append(self.a, item);
    }

    const Shaped = struct { infos: []const t.hb_glyph_info_t, positions: []const t.hb_glyph_position_t, buffer: *t.hb_buffer_t };

    fn shape(self: *Layout, item: Item, start: usize, end: usize) !Shaped {
        item.face.configure(item.size, self.points(item.size), item.weight);
        const buffer = t.hb_buffer_create() orelse return error.TextLayout;
        t.hb_buffer_add_utf8(buffer, self.text.ptr, @intCast(self.text.len), @intCast(start), @intCast(end - start));
        t.hb_buffer_guess_segment_properties(buffer);
        t.hb_buffer_set_direction(buffer, if (item.level % 2 == 1) t.HB_DIRECTION_RTL else t.HB_DIRECTION_LTR);
        t.hb_shape(item.face.hb, buffer, null, 0);
        var count: c_uint = 0;
        const infos = t.hb_buffer_get_glyph_infos(buffer, &count);
        const positions = t.hb_buffer_get_glyph_positions(buffer, &count);
        return .{ .infos = infos[0..count], .positions = positions[0..count], .buffer = buffer };
    }

    fn measure(self: *Layout) !void {
        self.advances = try self.a.alloc(f64, self.text.len + 1);
        @memset(self.advances, 0);
        for (self.items.items) |item| {
            if (self.text[item.start] == '\n') continue;
            const shaped = try self.shape(item, item.start, item.end);
            defer t.hb_buffer_destroy(shaped.buffer);
            for (shaped.infos, shaped.positions) |info, position| self.advances[info.cluster] += snap(position.x_advance);
        }
    }

    fn width(self: *const Layout, start: usize, end: usize) f64 {
        var sum: f64 = 0;
        for (self.advances[start..end]) |value| sum += value;
        return sum;
    }

    fn isSpace(self: *const Layout, offset: usize) bool {
        const c = self.text[offset];
        return c == ' ' or c == '\t';
    }

    fn isWide(codepoint: u21) bool {
        return switch (codepoint) {
            0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x20000...0x3FFFD => true,
            else => false,
        };
    }

    /// Byte offsets where a line may start: after spaces, after hyphens and
    /// around ideographs.
    fn breakAllowed(self: *const Layout, offset: usize) bool {
        if (offset == 0 or offset >= self.text.len) return false;
        const prev_start = previousStart(self.text, offset);
        const prev = std.unicode.utf8Decode(self.text[prev_start..offset]) catch return false;
        const len = std.unicode.utf8ByteSequenceLength(self.text[offset]) catch return false;
        const next = std.unicode.utf8Decode(self.text[offset..][0..@min(len, self.text.len - offset)]) catch return false;
        if (next == ' ' or next == '\t') return false;
        if (prev == ' ' or prev == '\t' or prev == '-' or prev == 0x2010 or prev == 0x2013 or prev == 0x2014 or prev == '/') return true;
        if (isWide(prev) or isWide(next)) return !(classify(next) == .neutral and !isWide(next)) or isWide(next);
        return false;
    }

    fn breakLines(self: *Layout) ![]Line {
        var lines: std.ArrayList(Line) = .empty;
        const limit: ?f64 = if (self.options.width) |w| @floatFromInt(w) else null;
        const multiline = self.options.lines != null;
        const max_lines: ?usize = if (self.options.ellipsize) (self.options.lines orelse 1) else null;
        const char_wrap = multiline;
        var start: usize = 0;
        const text = self.text;
        while (start <= text.len) {
            if (max_lines) |m| if (lines.items.len == m) break;
            // The paragraph ends at a newline when newlines separate lines.
            var stop = text.len;
            if (multiline) {
                if (std.mem.indexOfScalarPos(u8, text, start, '\n')) |nl| stop = nl;
            }
            var end = stop;
            if (limit) |w| {
                if (self.width(start, stop) > w) {
                    // Last allowed break that fits; else characters when allowed.
                    var best: ?usize = null;
                    var offset = start + 1;
                    while (offset < stop) : (offset += 1) {
                        if ((text[offset] & 0xC0) == 0x80) continue;
                        if (self.breakAllowed(offset)) {
                            var trimmed = offset;
                            while (trimmed > start and self.isSpace(trimmed - 1)) trimmed -= 1;
                            if (self.width(start, trimmed) <= w) best = offset else break;
                        }
                    }
                    var hyphen = false;
                    if (best == null and char_wrap) {
                        // Break inside the word, leaving room for a hyphen between letters.
                        const hyphen_width = try self.symbolWidth(start, hyphen_symbol);
                        offset = start + 1;
                        while (offset < stop) : (offset += 1) {
                            if ((text[offset] & 0xC0) == 0x80) continue;
                            const needs = self.intraWord(offset);
                            if (self.width(start, offset) + (if (needs) hyphen_width else 0) > w) break;
                            best = offset;
                            hyphen = needs;
                        }
                    }
                    if (best) |b| {
                        end = b;
                        if (hyphen) {
                            try lines.append(self.a, .{ .start = start, .end = end, .hyphen = true });
                            start = end;
                            continue;
                        }
                    }
                }
            }
            try lines.append(self.a, .{ .start = start, .end = end });
            if (end == stop) {
                if (stop >= text.len) break;
                start = stop + 1;
            } else {
                start = end;
            }
            if (start >= text.len and end != stop) break;
        }
        // Ellipsize the last line when text remains or it overflows.
        if (max_lines != null and lines.items.len > 0) {
            const last = &lines.items[lines.items.len - 1];
            var remaining = last.end < text.len;
            if (remaining) {
                // Only whitespace after the last line does not count.
                remaining = std.mem.trim(u8, text[last.end..], " \t\n").len > 0;
            }
            const overflow = if (limit) |w| self.width(last.start, last.end) > w else false;
            if (remaining or overflow) {
                last.ellipsis = true;
                last.end = if (multiline) (std.mem.indexOfScalarPos(u8, text, last.start, '\n') orelse text.len) else text.len;
                self.ellipsized = true;
            }
        }
        return lines.items;
    }

    fn previousStart(text: []const u8, offset: usize) usize {
        var i = offset - 1;
        while (i > 0 and (text[i] & 0xC0) == 0x80) i -= 1;
        return i;
    }

    const Run = struct { item: Item, start: usize, end: usize };

    /// Letters on both sides: Pango shows a hyphen when breaking there.
    fn intraWord(self: *const Layout, offset: usize) bool {
        const prev_start = previousStart(self.text, offset);
        const prev = std.unicode.utf8Decode(self.text[prev_start..offset]) catch return false;
        const len = std.unicode.utf8ByteSequenceLength(self.text[offset]) catch return false;
        const next = std.unicode.utf8Decode(self.text[offset..][0..@min(len, self.text.len - offset)]) catch return false;
        const letter = struct {
            fn f(c: u21) bool {
                return if (c < 0x80) std.ascii.isAlphabetic(@intCast(c)) else (classify(c) == .l or classify(c) == .r) and !isWide(c);
            }
        }.f;
        return letter(prev) and letter(next);
    }

    fn symbolWidth(self: *Layout, offset: usize, symbol: []const u8) !f64 {
        const near = self.itemAt(offset) orelse (if (self.items.items.len > 0) self.items.items[0] else return 0);
        const info = try self.symbolItem(near, symbol);
        t.hb_buffer_destroy(info.glyphs.buffer);
        return info.width;
    }

    const SymbolInfo = struct { glyphs: Shaped, item: Item, width: f64 };

    fn ellipsisItem(self: *Layout, near: Item) !SymbolInfo {
        return self.symbolItem(near, "\u{2026}");
    }

    /// Shapes `symbol` (an ellipsis or hyphen) in the face and style of `near`.
    fn symbolItem(self: *Layout, near: Item, symbol: []const u8) !SymbolInfo {
        var item = near;
        const codepoint = std.unicode.utf8Decode(symbol) catch '-';
        if (!item.face.has(codepoint)) {
            const owner = try self.renderer.family(self.descriptionFor(item.style));
            item.face = self.renderer.pick(owner, codepoint) orelse item.face;
        }
        item.face.configure(item.size, self.points(item.size), item.weight);
        const buffer = t.hb_buffer_create() orelse return error.TextLayout;
        t.hb_buffer_add_utf8(buffer, symbol.ptr, @intCast(symbol.len), 0, @intCast(symbol.len));
        t.hb_buffer_guess_segment_properties(buffer);
        t.hb_buffer_set_direction(buffer, if (item.level % 2 == 1) t.HB_DIRECTION_RTL else t.HB_DIRECTION_LTR);
        t.hb_shape(item.face.hb, buffer, null, 0);
        var count: c_uint = 0;
        const infos = t.hb_buffer_get_glyph_infos(buffer, &count);
        const positions = t.hb_buffer_get_glyph_positions(buffer, &count);
        var total: f64 = 0;
        for (positions[0..count]) |p| total += snap(p.x_advance);
        return .{ .glyphs = .{ .infos = infos[0..count], .positions = positions[0..count], .buffer = buffer }, .item = item, .width = total };
    }

    fn run(self: *Layout) !void {
        if (self.text.len == 0) {
            const owner = try self.renderer.family(self.base);
            const face = self.renderer.pick(owner, ' ') orelse return error.FontMap;
            face.configure(self.options.size, self.points(self.options.size), self.base.weight);
            const metrics = face.extents();
            self.logical_height = metrics[0] + metrics[1];
            self.baseline = @trunc(metrics[0]);
            return;
        }
        try self.itemize();
        try self.measure();
        const lines = try self.breakLines();
        const limit: ?f64 = if (self.options.width) |w| @floatFromInt(w) else null;
        var y: f64 = 0;
        // Lay out lines first so alignment can use the widest line.
        const Placed = struct { runs: []Run, width: f64, ascent: f64, descent: f64, ellipsis: ?Item, ellipsis_width: f64, rtl: bool, hyphen: ?Item };
        var placed: std.ArrayList(Placed) = .empty;
        var widest: f64 = 0;
        for (lines) |line| {
            var end = line.end;
            // Trailing spaces do not take part in the visible width.
            while (end > line.start and (self.isSpace(end - 1) or self.text[end - 1] == '\n')) end -= 1;
            var ellipsis_item: ?Item = null;
            var ellipsis_width: f64 = 0;
            if (line.ellipsis) {
                const near = self.itemAt(if (end > line.start) previousStart(self.text, end) else line.start) orelse self.items.items[0];
                const info = try self.ellipsisItem(near);
                t.hb_buffer_destroy(info.glyphs.buffer);
                ellipsis_item = info.item;
                ellipsis_width = info.width;
                if (limit) |w| {
                    while (end > line.start and self.width(line.start, end) + ellipsis_width > w) end = previousStart(self.text, end);
                    // Pango keeps a space before the ellipsis.
                }
            }
            var runs: std.ArrayList(Run) = .empty;
            var ascent: f64 = 0;
            var descent: f64 = 0;
            for (self.items.items) |item| {
                const s = @max(item.start, line.start);
                const e = @min(item.end, end);
                if (s >= e) continue;
                if (self.text[s] == '\n') continue;
                try runs.append(self.a, .{ .item = item, .start = s, .end = e });
            }
            for (runs.items) |r| {
                r.item.face.configure(r.item.size, self.points(r.item.size), r.item.weight);
                const m = r.item.face.extents();
                ascent = @max(ascent, m[0]);
                descent = @max(descent, m[1]);
            }
            if (runs.items.len == 0) {
                const near = self.itemAt(line.start) orelse self.items.items[0];
                near.face.configure(near.size, self.points(near.size), near.weight);
                const m = near.face.extents();
                ascent = m[0];
                descent = m[1];
            }
            // Reorder runs visually: reverse sequences from the highest level down to the lowest odd level.
            var max_level: u8 = 0;
            var min_odd: u8 = 255;
            for (runs.items) |r| {
                max_level = @max(max_level, r.item.level);
                if (r.item.level % 2 == 1) min_odd = @min(min_odd, r.item.level);
            }
            if (ellipsis_item) |*item| {
                if (runs.items.len > 0) item.level = runs.items[runs.items.len - 1].item.level;
            }
            var level = max_level;
            while (level >= min_odd and level > 0) : (level -= 1) {
                var i: usize = 0;
                while (i < runs.items.len) {
                    if (runs.items[i].item.level < level) {
                        i += 1;
                        continue;
                    }
                    var j = i;
                    while (j < runs.items.len and runs.items[j].item.level >= level) j += 1;
                    std.mem.reverse(Run, runs.items[i..j]);
                    i = j;
                }
            }
            const rtl = self.paragraph_rtl[line.start];
            // Pango gives an ellipsized line the full layout width.
            var hyphen_item: ?Item = null;
            var hyphen_width: f64 = 0;
            if (line.hyphen and end > line.start) {
                const near = self.itemAt(previousStart(self.text, end)) orelse self.items.items[0];
                const info = try self.symbolItem(near, hyphen_symbol);
                t.hb_buffer_destroy(info.glyphs.buffer);
                hyphen_item = info.item;
                hyphen_width = info.width;
            }
            // Pango gives an ellipsized line the full layout width.
            const line_width = if (ellipsis_item != null and limit != null) limit.? else self.width(line.start, end) + ellipsis_width + hyphen_width;
            widest = @max(widest, line_width);
            try placed.append(self.a, .{ .runs = runs.items, .width = line_width, .ascent = ascent, .descent = descent, .ellipsis = ellipsis_item, .ellipsis_width = ellipsis_width, .rtl = rtl, .hyphen = hyphen_item });
        }
        const box = limit orelse widest;
        for (placed.items, 0..) |line, index| {
            const natural = line.ascent + line.descent;
            const height = if (self.options.line_height) |h| @as(f64, @floatFromInt(h)) else natural;
            const extra = height - natural;
            const baseline = @round(y + extra / 2 + line.ascent);
            // Masks are positioned against the truncated baseline, as pango_layout_get_baseline() / PANGO_SCALE was.
            if (index == 0) self.baseline = @trunc(y + extra / 2 + line.ascent);
            var alignment = self.options.alignment;
            if (line.rtl) alignment = switch (alignment) {
                .left => .right,
                .right => .left,
                .center => .center,
            };
            var x: f64 = switch (alignment) {
                .left => 0,
                .center => @floor((box - line.width) / 2 + 0.5),
                .right => box - line.width,
            };
            self.logical_left = @min(self.logical_left, x);
            self.logical_width = @max(self.logical_width, x + line.width);
            // An ellipsis in a right-to-left line sits at its visual start.
            const ellipsis_first = line.ellipsis != null and line.ellipsis.?.level % 2 == 1;
            if (ellipsis_first) x = try self.placeEllipsis(line.ellipsis.?, x, baseline);
            for (line.runs) |r| {
                const shaped = try self.shape(r.item, r.start, r.end);
                defer t.hb_buffer_destroy(shaped.buffer);
                const start_x = x;
                for (shaped.infos, shaped.positions) |info, position| {
                    try self.glyphs.append(self.a, .{
                        .face = r.item.face,
                        .id = info.codepoint,
                        .x = x + snap(position.x_offset),
                        .y = baseline - snap(position.y_offset),
                        .size = r.item.size,
                        .weight = r.item.weight,
                        .points = self.points(r.item.size),
                    });
                    x += snap(position.x_advance);
                }
                if (r.item.style.underline or r.item.style.strike) {
                    const thickness = @max(1, @round(r.item.size / 14));
                    if (r.item.style.underline) try self.decorations.append(self.a, .{ .x = start_x, .width = x - start_x, .y = baseline + @max(1, @round(r.item.size / 10)), .thickness = thickness });
                    if (r.item.style.strike) try self.decorations.append(self.a, .{ .x = start_x, .width = x - start_x, .y = baseline - @round(r.item.size * 0.3), .thickness = thickness });
                }
            }
            if (line.ellipsis != null and !ellipsis_first) x = try self.placeEllipsis(line.ellipsis.?, x, baseline);
            if (line.hyphen) |near| x = try self.placeSymbol(near, hyphen_symbol, x, baseline);
            y += height;
        }
        self.logical_height = y;
        if (self.logical_left == std.math.inf(f64)) self.logical_left = 0;
    }

    fn placeEllipsis(self: *Layout, near: Item, start: f64, baseline: f64) !f64 {
        return self.placeSymbol(near, "\u{2026}", start, baseline);
    }

    fn placeSymbol(self: *Layout, near: Item, symbol: []const u8, start: f64, baseline: f64) !f64 {
        const info = try self.symbolItem(near, symbol);
        defer t.hb_buffer_destroy(info.glyphs.buffer);
        var x = start;
        for (info.glyphs.infos, info.glyphs.positions) |g, p| {
            try self.glyphs.append(self.a, .{ .face = info.item.face, .id = g.codepoint, .x = x + snap(p.x_offset), .y = baseline - snap(p.y_offset), .size = info.item.size, .weight = info.item.weight, .points = self.points(info.item.size) });
            x += snap(p.x_advance);
        }
        return x;
    }

    fn itemAt(self: *const Layout, offset: usize) ?Item {
        for (self.items.items) |item| if (offset >= item.start and offset < item.end) return item;
        return null;
    }

    fn mask(self: *Layout, allocator: std.mem.Allocator) !Mask {
        // Glyphs are drawn at whole-pixel pen positions, as FreeType renders them.
        const Placed = struct { bitmap: Bitmap, x: i32, y: i32 };
        var placed: std.ArrayList(Placed) = .empty;
        var left: i32 = std.math.maxInt(i32);
        var top: i32 = std.math.maxInt(i32);
        var right: i32 = std.math.minInt(i32);
        var bottom: i32 = std.math.minInt(i32);
        for (self.glyphs.items) |g| {
            g.face.configure(g.size, g.points, g.weight);
            const bitmap = self.renderer.glyph(g.face, g.id) orelse continue;
            if (bitmap.width == 0 or bitmap.height == 0) continue;
            const x: i32 = @as(i32, @intFromFloat(@round(g.x))) + bitmap.left;
            const y: i32 = @as(i32, @intFromFloat(@round(g.y))) - bitmap.top;
            try placed.append(self.a, .{ .bitmap = bitmap, .x = x, .y = y });
            left = @min(left, x);
            top = @min(top, y);
            right = @max(right, x + @as(i32, @intCast(bitmap.width)));
            bottom = @max(bottom, y + @as(i32, @intCast(bitmap.height)));
        }
        for (self.decorations.items) |d| {
            const x0: i32 = @intFromFloat(@round(d.x));
            const x1: i32 = @intFromFloat(@round(d.x + d.width));
            const y0: i32 = @intFromFloat(@round(d.y));
            left = @min(left, x0);
            right = @max(right, x1);
            top = @min(top, y0);
            bottom = @max(bottom, y0 + @as(i32, @intFromFloat(d.thickness)));
        }
        const origin: i32 = if (self.options.origin == .baseline) @intFromFloat(self.baseline) else 0;
        const result_base: Mask = .{
            .pixels = &.{},
            .width = 0,
            .height = 0,
            .left = 0,
            .top = 0,
            // Like pango_layout_get_pixel_extents, logical extents round outward.
            .logical_height = @intFromFloat(@ceil(self.logical_height - 1e-6)),
            .logical_width = @intFromFloat(@max(0, @ceil(self.logical_width - 1e-6) - @floor(self.logical_left))),
            .ellipsized = self.ellipsized,
        };
        if (right <= left or bottom <= top) {
            var empty = result_base;
            empty.pixels = try allocator.alloc(u8, 0);
            return empty;
        }
        const w: u32 = @intCast(right - left);
        const h: u32 = @intCast(bottom - top);
        if (w > 32768 or h > 4096 or @as(u64, w) * h > 16 * 1024 * 1024) return error.TextTooLarge;
        const pixels = try allocator.alloc(u8, @as(usize, w) * h);
        @memset(pixels, 0);
        for (placed.items) |p| {
            const bx: usize = @intCast(p.x - left);
            const by: usize = @intCast(p.y - top);
            for (0..p.bitmap.height) |row| {
                const out = pixels[(by + row) * w + bx ..][0..p.bitmap.width];
                for (out, p.bitmap.pixels[row * p.bitmap.width ..][0..p.bitmap.width]) |*dst, src| dst.* = @intCast(@min(255, @as(u16, dst.*) + src));
            }
        }
        for (self.decorations.items) |d| {
            const x0: usize = @intCast(@as(i32, @intFromFloat(@round(d.x))) - left);
            const x1: usize = @intCast(@as(i32, @intFromFloat(@round(d.x + d.width))) - left);
            const y0: usize = @intCast(@as(i32, @intFromFloat(@round(d.y))) - top);
            for (0..@as(usize, @intFromFloat(d.thickness))) |row| if (y0 + row < h) @memset(pixels[(y0 + row) * w + x0 .. (y0 + row) * w + x1], 255);
        }
        var result = result_base;
        result.pixels = pixels;
        result.width = w;
        result.height = h;
        result.left = left;
        result.top = top - origin;
        return result;
    }
};

test "variable font weight changes native glyph coverage" {
    var renderer: Renderer = .{};
    defer renderer.deinit();
    const regular = try renderer.renderLayout(std.testing.allocator, "Build complete", .{ .size = 14.666, .origin = .top });
    defer regular.deinit(std.testing.allocator);
    const bold = try renderer.renderLayout(std.testing.allocator, "Build complete", .{ .font = "Adwaita Sans Bold", .size = 14.666, .origin = .top });
    defer bold.deinit(std.testing.allocator);
    var regular_coverage: u64 = 0;
    for (regular.pixels) |value| regular_coverage += value;
    var bold_coverage: u64 = 0;
    for (bold.pixels) |value| bold_coverage += value;
    try std.testing.expect(bold_coverage > regular_coverage * 12 / 10);
}

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

test "bounded text masks center short labels and ellipsize Unicode at both scales" {
    var renderer: Renderer = .{};
    defer renderer.deinit();
    const a = std.testing.allocator;
    for ([_]u32{ 1, 2 }) |scale| {
        const short = try renderer.renderLayout(a, "X", .{ .size = 14.6666666667 * @as(f64, @floatFromInt(scale)), .width = 200 * scale, .alignment = .center, .ellipsize = true, .origin = .top });
        defer short.deinit(a);
        try std.testing.expect(short.left > @as(i32, @intCast(80 * scale)));
        try std.testing.expect(short.width < 40 * scale);
        try std.testing.expect(short.top >= 0);
        const long = try renderer.renderLayout(a, "A long window title — 東京 نافذة 🌍", .{ .size = 14.6666666667 * @as(f64, @floatFromInt(scale)), .width = 80 * scale, .alignment = .center, .ellipsize = true, .origin = .top });
        defer long.deinit(a);
        try std.testing.expect(long.width > 0 and long.width <= 82 * scale);
        try std.testing.expect(long.height > 0);
        try std.testing.expect(long.ellipsized);
    }
}

test "wrapped text masks preserve markup and fall back to literal invalid markup" {
    var renderer: Renderer = .{};
    defer renderer.deinit();
    const allocator = std.testing.allocator;
    const options: Renderer.Options = .{ .size = 15, .width = 100, .lines = 3, .ellipsize = true, .markup = true, .origin = .top };
    const wrapped = try renderer.renderLayout(allocator, "<b>Hello 東京</b> world. More text wraps onto several lines, with an ellipsis after the third line and no visible markup delimiters.", options);
    defer wrapped.deinit(allocator);
    try std.testing.expect(wrapped.ellipsized);
    try std.testing.expect(wrapped.logical_height > 35 and wrapped.logical_height < 80);
    const invalid = try renderer.renderLayout(allocator, "<broken markup", options);
    defer invalid.deinit(allocator);
    var literal_options = options;
    literal_options.markup = false;
    const literal = try renderer.renderLayout(allocator, "<broken markup", literal_options);
    defer literal.deinit(allocator);
    try std.testing.expectEqualSlices(u8, literal.pixels, invalid.pixels);
}

test "font descriptions, markup spans and bidi levels" {
    const bold = parseDescription("Adwaita Sans Bold Italic 11");
    try std.testing.expectEqualStrings("Adwaita Sans", bold.family);
    try std.testing.expectEqual(@as(f64, 700), bold.weight);
    try std.testing.expect(bold.italic);
    try std.testing.expectEqualStrings("monospace", parseDescription("monospace").family);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try parseMarkup(arena.allocator(), "a <b>b&amp;</b><span weight='light' size='larger'>c</span>&#x41;");
    try std.testing.expectEqualStrings("a b&cA", parsed.text);
    try std.testing.expectEqual(@as(usize, 2), parsed.spans.len);
    try std.testing.expectEqual(@as(?f64, 700), parsed.spans[0].style.weight);
    try std.testing.expectError(error.InvalidMarkup, parseMarkup(arena.allocator(), "<b>open"));
    try std.testing.expectError(error.InvalidMarkup, parseMarkup(arena.allocator(), "<blink>x</blink>"));
    const classes = [_]Class{ .l, .neutral, .r, .neutral, .r, .neutral, .en };
    var levels: [classes.len]u8 = undefined;
    resolveLevels(&classes, &levels, 0);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 1, 1, 1, 1, 2 }, &levels);
}
