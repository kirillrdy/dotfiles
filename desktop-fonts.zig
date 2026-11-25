//! Font discovery and fallback ordering without fontconfig. The font
//! directories and family aliases come from the system fonts.conf
//! ($FONTCONFIG_FILE, else /etc/fonts/fonts.conf) and its includes; face
//! metadata is read with FreeType once per process.
const std = @import("std");
const t = @import("text-c");
const paths = @import("desktop-paths.zig");
const util = @import("desktop-util.zig");

pub const Font = struct {
    path: [:0]const u8,
    index: c_long,
    /// The typographic family (name ID 16) and the legacy family (name ID 1).
    families: [2][]const u8,
    weight: f64,
    /// OpenType wght axis range; equal to `weight` for static faces.
    weight_min: f64,
    weight_max: f64,
    italic: bool,
    /// OS/2 usWidthClass: 5 is normal.
    width: u16,
};

/// A fallback candidate for one requested family, weight and slant.
pub const Match = struct {
    font: *const Font,
    /// Synthesize bold: the request is bold but the face is at most medium.
    embolden: bool,
};

pub const Catalog = struct {
    fonts: []const Font,
    /// Family names in lower case, each mapped to its alias expansion.
    aliases: std.StringHashMapUnmanaged(Alias),
};

const Alias = struct { prefer: []const []const u8 = &.{}, accept: []const []const u8 = &.{}, default: []const []const u8 = &.{} };

const generic = [_][]const u8{ "sans-serif", "serif", "monospace", "emoji", "math", "system-ui", "cursive", "fantasy" };

/// The process-wide catalog, scanned on first use.
pub fn catalog() *const Catalog {
    return Loaded.get();
}

const Loaded = util.Lazy(Catalog, struct {
    fn load() Catalog {
        // The catalog lives for the whole process.
        const a = std.heap.c_allocator;
        const file = util.env("FONTCONFIG_FILE") orelse "/etc/fonts/fonts.conf";
        var config: Config = .{ .a = a };
        config.read(file, 0);
        var fonts: std.ArrayList(Font) = .empty;
        var library: t.FT_Library = null;
        if (t.FT_Init_FreeType(&library) == 0) {
            defer _ = t.FT_Done_FreeType(library);
            var seen: std.StringHashMapUnmanaged(void) = .empty;
            for (config.dirs.items) |dir| scanDirectory(a, library, dir, &seen, &fonts, 0);
        }
        return .{ .fonts = fonts.toOwnedSlice(a) catch &.{}, .aliases = config.aliases };
    }
}.load);

// ---------------------------------------------------------------- fonts.conf

const Config = struct {
    a: std.mem.Allocator,
    dirs: std.ArrayList([]const u8) = .empty,
    aliases: std.StringHashMapUnmanaged(Alias) = .empty,

    /// Reads a configuration file or, for a directory, its *.conf files in name order.
    fn read(self: *Config, path: []const u8, depth: u32) void {
        if (depth > 8) return;
        if (paths.isDirectory(path)) {
            const entries = paths.list(self.a, path) catch return;
            std.mem.sort(paths.Listed, entries, {}, struct {
                fn less(_: void, x: paths.Listed, y: paths.Listed) bool {
                    return std.mem.lessThan(u8, x.name, y.name);
                }
            }.less);
            for (entries) |entry| {
                if (!std.mem.endsWith(u8, entry.name, ".conf")) continue;
                const child = std.fs.path.join(self.a, &.{ path, entry.name }) catch continue;
                if (!paths.isDirectory(child)) self.read(child, depth + 1);
            }
            return;
        }
        const xml = paths.readFile(self.a, path, 1 << 20) catch return;
        self.parse(xml, std.fs.path.dirname(path) orelse "/", depth) catch {};
    }

    fn parse(self: *Config, xml: []const u8, base: []const u8, depth: u32) !void {
        var tags: Tags = .{ .xml = xml };
        // Only <dir>, <include> and <alias> at the top level carry anything we use.
        while (tags.next()) |tag| {
            if (tag.closing or tag.self_closing) continue;
            if (std.mem.eql(u8, tag.name, "dir")) {
                const value = try decode(self.a, tags.text("dir"));
                if (try self.resolve(value, attribute(tag.attributes, "prefix"), base, .data)) |dir| try self.dirs.append(self.a, dir);
            } else if (std.mem.eql(u8, tag.name, "include")) {
                const value = try decode(self.a, tags.text("include"));
                if (try self.resolve(value, attribute(tag.attributes, "prefix"), base, .config)) |included| self.read(included, depth + 1);
            } else if (std.mem.eql(u8, tag.name, "alias")) {
                try self.alias(&tags);
            }
        }
    }

    fn alias(self: *Config, tags: *Tags) !void {
        var name: ?[]const u8 = null;
        var lists: [3]std.ArrayList([]const u8) = .{ .empty, .empty, .empty };
        var section: ?usize = null;
        while (tags.next()) |tag| {
            if (std.mem.eql(u8, tag.name, "alias") and tag.closing) break;
            const index: ?usize = if (std.mem.eql(u8, tag.name, "prefer")) 0 else if (std.mem.eql(u8, tag.name, "accept")) 1 else if (std.mem.eql(u8, tag.name, "default")) 2 else null;
            if (index) |i| {
                section = if (tag.closing or tag.self_closing) null else i;
            } else if (std.mem.eql(u8, tag.name, "family") and !tag.closing and !tag.self_closing) {
                const family = try lower(self.a, try decode(self.a, tags.text("family")));
                if (section) |i| try lists[i].append(self.a, family) else if (name == null) name = family;
            }
        }
        const key = name orelse return;
        const entry = try self.aliases.getOrPut(self.a, key);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        const value = entry.value_ptr;
        // Later rules apply after earlier ones: their prefers land closer to the family.
        value.prefer = try std.mem.concat(self.a, []const u8, &.{ value.prefer, lists[0].items });
        value.accept = try std.mem.concat(self.a, []const u8, &.{ lists[1].items, value.accept });
        value.default = try std.mem.concat(self.a, []const u8, &.{ value.default, lists[2].items });
    }

    fn resolve(self: *Config, value: []const u8, prefix: ?[]const u8, base: []const u8, xdg: enum { data, config }) !?[]const u8 {
        if (value.len == 0) return null;
        if (prefix) |p| if (std.mem.eql(u8, p, "xdg")) {
            return try std.fs.path.join(self.a, &.{ if (xdg == .data) paths.dataHome() else paths.configHome(), value });
        };
        if (std.mem.startsWith(u8, value, "~/")) return try std.fs.path.join(self.a, &.{ paths.home(), value[2..] });
        if (std.fs.path.isAbsolute(value)) return value;
        return try std.fs.path.join(self.a, &.{ base, value });
    }
};

const Tag = struct { name: []const u8, attributes: []const u8, closing: bool, self_closing: bool, end: usize };

/// A minimal XML tag scanner for fontconfig's configuration format.
const Tags = struct {
    xml: []const u8,
    position: usize = 0,

    fn next(self: *Tags) ?Tag {
        while (std.mem.indexOfScalarPos(u8, self.xml, self.position, '<')) |start| {
            const rest = self.xml[start..];
            if (std.mem.startsWith(u8, rest, "<!--")) {
                self.position = (std.mem.indexOfPos(u8, self.xml, start, "-->") orelse return null) + 3;
                continue;
            }
            const end = std.mem.indexOfScalarPos(u8, self.xml, start, '>') orelse return null;
            self.position = end + 1;
            if (rest.len < 2 or rest[1] == '?' or rest[1] == '!') continue;
            const closing = rest[1] == '/';
            var body = self.xml[start + 1 + @intFromBool(closing) .. end];
            const self_closing = body.len > 0 and body[body.len - 1] == '/';
            if (self_closing) body = body[0 .. body.len - 1];
            const split = std.mem.indexOfAny(u8, body, " \t\r\n") orelse body.len;
            return .{ .name = body[0..split], .attributes = body[split..], .closing = closing, .self_closing = self_closing, .end = end + 1 };
        }
        return null;
    }

    /// The text up to the matching close tag, which is consumed.
    fn text(self: *Tags, name: []const u8) []const u8 {
        const start = self.position;
        while (self.next()) |tag| {
            if (tag.closing and std.mem.eql(u8, tag.name, name)) {
                const close = std.mem.lastIndexOfScalar(u8, self.xml[0..tag.end], '<').?;
                return std.mem.trim(u8, self.xml[start..close], " \t\r\n");
            }
        }
        return "";
    }
};

fn attribute(attributes: []const u8, key: []const u8) ?[]const u8 {
    var rest = attributes;
    while (std.mem.indexOfScalar(u8, rest, '=')) |eq| {
        const name = std.mem.trim(u8, rest[0..eq], " \t\r\n");
        const after = std.mem.trimStart(u8, rest[eq + 1 ..], " \t\r\n");
        if (after.len == 0 or (after[0] != '"' and after[0] != '\'')) return null;
        const close = std.mem.indexOfScalarPos(u8, after, 1, after[0]) orelse return null;
        if (std.mem.eql(u8, name, key)) return after[1..close];
        rest = after[close + 1 ..];
    }
    return null;
}

fn decode(a: std.mem.Allocator, value: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, value, '&') == null) return value;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    outer: while (i < value.len) {
        if (value[i] == '&') {
            for ([_][2][]const u8{ .{ "&amp;", "&" }, .{ "&lt;", "<" }, .{ "&gt;", ">" }, .{ "&quot;", "\"" }, .{ "&apos;", "'" } }) |entity| {
                if (std.mem.startsWith(u8, value[i..], entity[0])) {
                    try out.appendSlice(a, entity[1]);
                    i += entity[0].len;
                    continue :outer;
                }
            }
        }
        try out.append(a, value[i]);
        i += 1;
    }
    return out.toOwnedSlice(a);
}

fn lower(a: std.mem.Allocator, value: []const u8) ![]const u8 {
    return std.ascii.allocLowerString(a, value);
}

// ---------------------------------------------------------------- Scanning

fn scanDirectory(a: std.mem.Allocator, library: t.FT_Library, dir: []const u8, seen: *std.StringHashMapUnmanaged(void), fonts: *std.ArrayList(Font), depth: u32) void {
    if (depth > 8) return;
    const entries = paths.list(a, dir) catch return;
    std.mem.sort(paths.Listed, entries, {}, struct {
        fn less(_: void, x: paths.Listed, y: paths.Listed) bool {
            return std.mem.lessThan(u8, x.name, y.name);
        }
    }.less);
    for (entries) |entry| {
        if (entry.name[0] == '.') continue;
        const path = std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ dir, entry.name }, 0) catch continue;
        const kind = if (entry.resolved) entry.kind else paths.kind(path);
        if (kind == .directory) {
            scanDirectory(a, library, path, seen, fonts, depth + 1);
            continue;
        }
        if (kind != .file) continue;
        const extension = std.fs.path.extension(entry.name);
        const known = for ([_][]const u8{ ".ttf", ".otf", ".ttc", ".otc" }) |suffix| {
            if (std.ascii.eqlIgnoreCase(extension, suffix)) break true;
        } else false;
        // Directories are often listed twice through different store paths.
        if (!known or (seen.getOrPut(a, entry.name) catch continue).found_existing) continue;
        scanFile(a, library, path, fonts);
    }
}

fn scanFile(a: std.mem.Allocator, library: t.FT_Library, path: [:0]const u8, fonts: *std.ArrayList(Font)) void {
    var index: c_long = 0;
    var count: c_long = 1;
    while (index < count) : (index += 1) {
        var face: t.FT_Face = null;
        if (t.FT_New_Face(library, path, index, &face) != 0) return;
        defer _ = t.FT_Done_Face(face);
        count = face.*.num_faces;
        // Bitmap-only faces cannot be scaled, except color emoji, as in fontconfig.
        if ((face.*.face_flags & (t.FT_FACE_FLAG_SCALABLE | t.FT_FACE_FLAG_COLOR)) == 0) continue;
        const font = describe(a, library, face, path, index) catch continue;
        fonts.append(a, font) catch return;
    }
}

fn describe(a: std.mem.Allocator, library: t.FT_Library, face: t.FT_Face, path: [:0]const u8, index: c_long) !Font {
    var typographic: ?[]const u8 = null;
    var legacy: ?[]const u8 = null;
    for (0..t.FT_Get_Sfnt_Name_Count(face)) |i| {
        var name: t.FT_SfntName = undefined;
        if (t.FT_Get_Sfnt_Name(face, @intCast(i), &name) != 0) continue;
        const slot = switch (name.name_id) {
            16 => &typographic,
            1 => &legacy,
            else => continue,
        };
        // Prefer English names: Windows US English, then Macintosh Roman English.
        const windows = name.platform_id == 3 and name.language_id == 0x409;
        const mac = name.platform_id == 1 and name.language_id == 0;
        if (!windows and !(mac and slot.* == null)) continue;
        const raw = name.string[0..name.string_len];
        slot.* = if (windows) try utf16be(a, raw) else try lower(a, raw);
    }
    const family_fallback = if (face.*.family_name != null) try lower(a, std.mem.span(face.*.family_name)) else return error.Unnamed;
    const first = typographic orelse legacy orelse family_fallback;
    var weight: f64 = if ((face.*.style_flags & t.FT_STYLE_FLAG_BOLD) != 0) 700 else 400;
    var width: u16 = 5;
    var italic = (face.*.style_flags & t.FT_STYLE_FLAG_ITALIC) != 0;
    if (@as(?*t.TT_OS2, @ptrCast(@alignCast(t.FT_Get_Sfnt_Table(face, t.FT_SFNT_OS2))))) |os2| {
        if (os2.version != 0xffff) {
            if (os2.usWeightClass >= 1 and os2.usWeightClass <= 1000) weight = @floatFromInt(os2.usWeightClass);
            if (os2.usWidthClass >= 1 and os2.usWidthClass <= 9) width = os2.usWidthClass;
            italic = italic or (os2.fsSelection & 1) != 0;
        }
    }
    var font: Font = .{ .path = path, .index = index, .families = .{ first, legacy orelse first }, .weight = weight, .weight_min = weight, .weight_max = weight, .italic = italic, .width = width };
    if ((face.*.face_flags & t.FT_FACE_FLAG_MULTIPLE_MASTERS) != 0) {
        var mm: [*c]t.FT_MM_Var = null;
        if (t.FT_Get_MM_Var(face, &mm) == 0) {
            defer _ = t.FT_Done_MM_Var(library, mm);
            for (0..mm.*.num_axis) |i| {
                const axis = mm.*.axis[i];
                if (axis.tag != (('w' << 24) | ('g' << 16) | ('h' << 8) | 't')) continue;
                font.weight_min = @as(f64, @floatFromInt(axis.minimum)) / 65536;
                font.weight_max = @as(f64, @floatFromInt(axis.maximum)) / 65536;
                font.weight = @as(f64, @floatFromInt(axis.def)) / 65536;
            }
        }
    }
    return font;
}

fn utf16be(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const units = try a.alloc(u16, raw.len / 2);
    defer a.free(units);
    for (units, 0..) |*unit, i| unit.* = std.mem.readInt(u16, raw[i * 2 ..][0..2], .big);
    const text = try std.unicode.utf16LeToUtf8Alloc(a, units);
    defer a.free(text);
    return lower(a, text);
}

// ---------------------------------------------------------------- Matching

/// The fallback order for a comma-separated family list: the requested
/// families and their aliases, then the generic sans-serif family, then
/// every other installed family. Each family contributes its closest face.
pub fn sort(a: std.mem.Allocator, from: *const Catalog, families: []const u8, weight: f64, italic: bool) ![]Match {
    var order: std.ArrayList([]const u8) = .empty;
    var requested_generic = false;
    var names = std.mem.splitScalar(u8, families, ',');
    while (names.next()) |raw| {
        const name = std.mem.trim(u8, raw, " ");
        if (name.len == 0) continue;
        const key = try lower(a, name);
        for (generic) |g| requested_generic = requested_generic or std.mem.eql(u8, key, g);
        try expand(a, from, key, &order, 0);
    }
    // fontconfig appends sans-serif to requests that name no generic family.
    if (!requested_generic) try expand(a, from, "sans-serif", &order, 0);

    const used = try a.alloc(bool, from.fonts.len);
    defer a.free(used);
    @memset(used, false);
    var families_taken: std.StringHashMapUnmanaged(void) = .empty;
    defer families_taken.deinit(a);
    var result: std.ArrayList(Match) = .empty;
    for (order.items) |family| {
        if (try best(a, from, family, weight, italic, used, &families_taken)) |match| try result.append(a, match);
    }
    // Every remaining family, in catalog order, for coverage fallback.
    for (from.fonts) |font| {
        if (families_taken.contains(font.families[0])) continue;
        if (try best(a, from, font.families[0], weight, italic, used, &families_taken)) |match| try result.append(a, match);
    }
    return result.toOwnedSlice(a);
}

fn expand(a: std.mem.Allocator, from: *const Catalog, family: []const u8, order: *std.ArrayList([]const u8), depth: u32) !void {
    if (depth > 8) return;
    for (order.items) |existing| if (std.mem.eql(u8, existing, family)) return;
    const alias = from.aliases.get(family) orelse {
        try order.append(a, family);
        return;
    };
    for (alias.prefer) |name| try expand(a, from, name, order, depth + 1);
    for (order.items) |existing| if (std.mem.eql(u8, existing, family)) return;
    try order.append(a, family);
    for (alias.accept) |name| try expand(a, from, name, order, depth + 1);
    for (alias.default) |name| try expand(a, from, name, order, depth + 1);
}

/// The face of `family` closest in slant, then weight, then width.
fn best(a: std.mem.Allocator, from: *const Catalog, family: []const u8, weight: f64, italic: bool, used: []bool, taken: *std.StringHashMapUnmanaged(void)) !?Match {
    var chosen: ?usize = null;
    var chosen_score: f64 = std.math.inf(f64);
    for (from.fonts, 0..) |font, i| {
        if (used[i]) continue;
        const legacy_match = std.mem.eql(u8, font.families[1], family);
        if (!legacy_match and !std.mem.eql(u8, font.families[0], family)) continue;
        const distance = if (weight < font.weight_min) font.weight_min - weight else if (weight > font.weight_max) weight - font.weight_max else 0;
        var score = distance + @as(f64, @floatFromInt(@abs(@as(i32, font.width) - 5))) * 0.1;
        if (font.italic != italic) score += 10000;
        // A face whose legacy family is the request is the canonical one (not Condensed).
        if (!legacy_match) score += 0.05;
        if (score < chosen_score) {
            chosen = i;
            chosen_score = score;
        }
    }
    const index = chosen orelse return null;
    used[index] = true;
    const font = &from.fonts[index];
    try taken.put(a, font.families[0], {});
    return .{ .font = font, .embolden = weight >= 600 and font.weight_max <= 500 };
}

test "fonts.conf directories, includes and aliases" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var config: Config = .{ .a = arena.allocator() };
    try config.parse(
        \\<?xml version="1.0"?>
        \\<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
        \\<fontconfig>
        \\  <!-- <dir>/ignored</dir> -->
        \\  <dir>/fonts/a</dir>
        \\  <dir>relative</dir>
        \\  <include ignore_missing="yes">/nonexistent/conf.d</include>
        \\  <match target="font"><edit name="hinting"><bool>true</bool></edit></match>
        \\  <alias binding="same"><family>sans-serif</family><prefer><family>DejaVu Sans</family></prefer></alias>
        \\  <alias><family>Sans-Serif</family><prefer><family>Noto &amp; Co</family></prefer><default><family>Unifont</family></default></alias>
        \\</fontconfig>
    , "/etc/fonts", 0);
    try std.testing.expectEqual(@as(usize, 2), config.dirs.items.len);
    try std.testing.expectEqualStrings("/fonts/a", config.dirs.items[0]);
    try std.testing.expectEqualStrings("/etc/fonts/relative", config.dirs.items[1]);
    const alias = config.aliases.get("sans-serif").?;
    try std.testing.expectEqual(@as(usize, 2), alias.prefer.len);
    try std.testing.expectEqualStrings("dejavu sans", alias.prefer[0]);
    try std.testing.expectEqualStrings("noto & co", alias.prefer[1]);
    try std.testing.expectEqualStrings("unifont", alias.default[0]);
}

test "fallback order follows the request, aliases, then everything else" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fonts = [_]Font{
        .{ .path = "emoji", .index = 0, .families = .{ "noto color emoji", "noto color emoji" }, .weight = 400, .weight_min = 400, .weight_max = 400, .italic = false, .width = 5 },
        .{ .path = "dejavu", .index = 0, .families = .{ "dejavu sans", "dejavu sans" }, .weight = 400, .weight_min = 400, .weight_max = 400, .italic = false, .width = 5 },
        .{ .path = "dejavu-condensed", .index = 0, .families = .{ "dejavu sans", "dejavu sans condensed" }, .weight = 400, .weight_min = 400, .weight_max = 400, .italic = false, .width = 4 },
        .{ .path = "dejavu-bold", .index = 0, .families = .{ "dejavu sans", "dejavu sans" }, .weight = 700, .weight_min = 700, .weight_max = 700, .italic = false, .width = 5 },
        .{ .path = "adwaita-italic", .index = 0, .families = .{ "adwaita sans", "adwaita sans" }, .weight = 400, .weight_min = 100, .weight_max = 900, .italic = true, .width = 5 },
        .{ .path = "adwaita", .index = 0, .families = .{ "adwaita sans", "adwaita sans" }, .weight = 400, .weight_min = 100, .weight_max = 900, .italic = false, .width = 5 },
    };
    var catalog_value: Catalog = .{ .fonts = &fonts, .aliases = .empty };
    try catalog_value.aliases.put(a, "sans-serif", .{ .prefer = &.{"dejavu sans"} });
    const bold = try sort(a, &catalog_value, "Adwaita Sans", 700, false);
    try std.testing.expectEqualStrings("adwaita", bold[0].font.path);
    try std.testing.expect(!bold[0].embolden);
    try std.testing.expectEqualStrings("dejavu-bold", bold[1].font.path);
    try std.testing.expectEqualStrings("emoji", bold[2].font.path);
    try std.testing.expectEqual(@as(usize, 3), bold.len);
    const regular = try sort(a, &catalog_value, "Missing, sans-serif", 400, false);
    try std.testing.expectEqualStrings("dejavu", regular[0].font.path);
    const emoji = try sort(a, &catalog_value, "Noto Color Emoji", 700, false);
    try std.testing.expect(emoji[0].embolden);
}
