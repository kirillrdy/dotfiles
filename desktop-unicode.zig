//! Unicode text operations in Zig with GLib's semantics: case folding
//! (g_utf8_casefold), NFKC normalization (g_utf8_normalize with
//! G_NORMALIZE_ALL_COMPOSE), and collation as GLib performs it in the C locale
//! the desktop runs in (g_utf8_collate, g_utf8_collate_key_for_filename).
//! Tables come from the Unicode Character Database at build time.
const std = @import("std");
const tables = @import("unicode-tables");

fn find(comptime T: type, items: []const T, cp: u21) ?T {
    var low: usize = 0;
    var high: usize = items.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (items[mid].cp == cp) return items[mid];
        if (items[mid].cp < cp) low = mid + 1 else high = mid;
    }
    return null;
}

pub fn toLower(cp: u21) u21 {
    return if (find(tables.Mapping, &tables.lower, cp)) |entry| entry.to else cp;
}

pub fn toUpper(cp: u21) u21 {
    return if (find(tables.Mapping, &tables.upper, cp)) |entry| entry.to else cp;
}

pub fn combiningClass(cp: u21) u8 {
    return if (find(tables.Class, &tables.classes, cp)) |entry| entry.class else 0;
}

fn rangeValue(ranges: []const tables.Range, cp: u21) ?u32 {
    var low: usize = 0;
    var high: usize = ranges.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (cp < ranges[mid].first) high = mid else if (cp > ranges[mid].last) low = mid + 1 else return ranges[mid].value;
    }
    return null;
}

/// The ISO 15924 script code as a big-endian tag, e.g. "Latn"; "Zzzz" when unassigned.
pub fn script(cp: u21) u32 {
    return rangeValue(&tables.scripts, cp) orelse std.mem.readInt(u32, "Zzzz", .big);
}

/// The general categories text shaping distinguishes.
pub const Category = enum(u32) { other, nonspacing_mark, spacing_mark, enclosing_mark, format, space };

pub fn category(cp: u21) Category {
    return @fromBackingInt(@intCast(rangeValue(&tables.categories, cp) orelse 0));
}

pub fn isMark(cp: u21) bool {
    return switch (category(cp)) {
        .nonspacing_mark, .spacing_mark, .enclosing_mark => true,
        else => false,
    };
}

pub fn isDefaultIgnorable(cp: u21) bool {
    return rangeValue(&tables.ignorables, cp) != null;
}

/// Arabic-style joining type, with the Syriac groups shaping treats specially.
pub const Joining = enum(u32) { non_joining, left, right, dual, causing, transparent, alaph, dalath_rish };

pub fn joining(cp: u21) Joining {
    if (rangeValue(&tables.joining, cp)) |value| return @fromBackingInt(@intCast(value));
    // Unlisted marks and format characters are transparent; everything else does not join.
    return switch (category(cp)) {
        .nonspacing_mark, .enclosing_mark, .format => .transparent,
        else => .non_joining,
    };
}

/// The Bidi_Mirroring_Glyph of a character, if it has one.
pub fn mirror(cp: u21) ?u21 {
    return if (find(tables.Mapping, &tables.mirrors, cp)) |entry| entry.to else null;
}

/// The canonical decomposition of a character into two parts (or one), unless it has none.
pub fn decomposeCanonical(cp: u21) ?[]const u21 {
    if (cp >= hangul.s_base and cp < hangul.s_base + hangul.s_count) return null;
    const entry = find(tables.Expansion, &tables.decompositions, cp) orelse return null;
    if (entry.compat) return null;
    return tables.data[entry.start..][0..entry.len];
}

pub const composePair = compose;

/// Decodes UTF-8, replacing invalid sequences with U+FFFD.
fn decode(a: std.mem.Allocator, text: []const u8) ![]u21 {
    var out: std.ArrayList(u21) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[i]) catch 0;
        if (length > 0 and i + length <= text.len) {
            if (std.unicode.utf8Decode(text[i .. i + length])) |cp| {
                try out.append(a, cp);
                i += length;
                continue;
            } else |_| {}
        }
        try out.append(a, 0xFFFD);
        i += 1;
    }
    return out.toOwnedSlice(a);
}

fn encode(a: std.mem.Allocator, chars: []const u21) ![:0]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (chars) |cp| {
        var buffer: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(cp, &buffer) catch {
            try out.appendSlice(a, "\u{FFFD}");
            continue;
        };
        try out.appendSlice(a, buffer[0..length]);
    }
    return out.toOwnedSliceSentinel(a, 0);
}

/// Full case folding for caseless matching, as g_utf8_casefold.
pub fn casefold(a: std.mem.Allocator, text: []const u8) ![:0]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const chars = try decode(arena.allocator(), text);
    var out: std.ArrayList(u21) = .empty;
    for (chars) |cp| {
        if (find(tables.Expansion, &tables.folds, cp)) |fold| {
            try out.appendSlice(arena.allocator(), tables.data[fold.start..][0..fold.len]);
        } else try out.append(arena.allocator(), toLower(cp));
    }
    return encode(a, out.items);
}

const hangul = struct {
    const s_base = 0xAC00;
    const l_base = 0x1100;
    const v_base = 0x1161;
    const t_base = 0x11A7;
    const l_count = 19;
    const v_count = 21;
    const t_count = 28;
    const n_count = v_count * t_count;
    const s_count = l_count * n_count;
};

fn decomposeInto(a: std.mem.Allocator, out: *std.ArrayList(u21), cp: u21, compat: bool) !void {
    if (cp >= hangul.s_base and cp < hangul.s_base + hangul.s_count) {
        const index = cp - hangul.s_base;
        try out.append(a, hangul.l_base + index / hangul.n_count);
        try out.append(a, hangul.v_base + (index % hangul.n_count) / hangul.t_count);
        const t = index % hangul.t_count;
        if (t != 0) try out.append(a, hangul.t_base + t);
        return;
    }
    if (find(tables.Expansion, &tables.decompositions, cp)) |entry| if (compat or !entry.compat) {
        for (tables.data[entry.start..][0..entry.len]) |part| try decomposeInto(a, out, part, compat);
        return;
    };
    try out.append(a, cp);
}

/// Stable reordering of combining marks by class, as the canonical ordering algorithm.
fn canonicalOrder(chars: []u21) void {
    var i: usize = 0;
    while (i < chars.len) {
        if (combiningClass(chars[i]) == 0) {
            i += 1;
            continue;
        }
        var end = i;
        while (end < chars.len and combiningClass(chars[end]) != 0) end += 1;
        std.sort.insertion(u21, chars[i..end], {}, struct {
            fn less(_: void, x: u21, y: u21) bool {
                return combiningClass(x) < combiningClass(y);
            }
        }.less);
        i = end;
    }
}

fn compose(first: u21, second: u21) ?u21 {
    // Hangul LV and LVT syllables compose algorithmically.
    if (first >= hangul.l_base and first < hangul.l_base + hangul.l_count and second >= hangul.v_base and second < hangul.v_base + hangul.v_count)
        return hangul.s_base + ((first - hangul.l_base) * hangul.v_count + (second - hangul.v_base)) * hangul.t_count;
    if (first >= hangul.s_base and first < hangul.s_base + hangul.s_count and (first - hangul.s_base) % hangul.t_count == 0 and second > hangul.t_base and second < hangul.t_base + hangul.t_count)
        return first + (second - hangul.t_base);
    var low: usize = 0;
    var high: usize = tables.compositions.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const entry = tables.compositions[mid];
        if (entry.first == first and entry.second == second) return entry.composed;
        if (entry.first < first or (entry.first == first and entry.second < second)) low = mid + 1 else high = mid;
    }
    return null;
}

/// NFKC, as g_utf8_normalize with G_NORMALIZE_ALL_COMPOSE.
pub fn normalize(a: std.mem.Allocator, text: []const u8) ![:0]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    return encode(a, try nfkc(arena.allocator(), try decode(arena.allocator(), text)));
}

fn nfkc(a: std.mem.Allocator, chars: []const u21) ![]u21 {
    var decomposed: std.ArrayList(u21) = .empty;
    for (chars) |cp| try decomposeInto(a, &decomposed, cp, true);
    const buffer = decomposed.items;
    canonicalOrder(buffer);
    // GLib's composition: a character joins the last starter unless a mark
    // of the same or higher class lies between them.
    var n = buffer.len;
    var last_start: usize = 0;
    var last_class: u8 = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const class = combiningClass(buffer[i]);
        if (i > 0 and (last_class == 0 or last_class < class)) if (compose(buffer[last_start], buffer[i])) |composed| {
            buffer[last_start] = composed;
            std.mem.copyForwards(u21, buffer[i .. n - 1], buffer[i + 1 .. n]);
            n -= 1;
            i -= 1;
            last_class = if (i == last_start) 0 else combiningClass(buffer[i]);
            continue;
        };
        if (class == 0) last_start = i;
        last_class = class;
    }
    return buffer[0..n];
}

/// Whether `needle` occurs in `haystack` ignoring case, comparing their case foldings.
pub fn containsCaseless(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    const a = std.heap.smp_allocator;
    const folded_haystack = casefold(a, haystack) catch return false;
    defer a.free(folded_haystack);
    const folded_needle = casefold(a, needle) catch return false;
    defer a.free(folded_needle);
    return std.mem.indexOf(u8, folded_haystack, folded_needle) != null;
}

/// g_utf8_collate in the C locale: NFKC forms compared by code point.
pub fn collate(a: std.mem.Allocator, left: []const u8, right: []const u8) !std.math.Order {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const x = try nfkc(arena.allocator(), try decode(arena.allocator(), left));
    const y = try nfkc(arena.allocator(), try decode(arena.allocator(), right));
    return std.mem.order(u21, x, y);
}

/// g_utf8_collate_key in the C locale: the NFKC form, whose bytes order as its code points.
pub fn collateKey(a: std.mem.Allocator, text: []const u8) ![:0]u8 {
    return normalize(a, text);
}

/// g_utf8_collate_key_for_filename: dots sort first and digit runs sort by
/// value, so "file10" follows "file9"; leading zeros break ties at the end.
pub fn collateKeyForFilename(a: std.mem.Allocator, text: []const u8) ![:0]u8 {
    const sentinel = "\x01\x01\x01";
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(a);
    var append: std.ArrayList(u8) = .empty;
    defer append.deinit(a);
    var prev: usize = 0;
    var p: usize = 0;
    while (p < text.len) : (p += 1) {
        switch (text[p]) {
            '.' => {
                if (prev != p) try appendKey(a, &result, text[prev..p]);
                try result.appendSlice(a, sentinel ++ "\x01");
                prev = p + 1;
            },
            '0'...'9' => {
                if (prev != p) try appendKey(a, &result, text[prev..p]);
                try result.appendSlice(a, sentinel ++ "\x02");
                prev = p;
                var leading_zeros: usize = undefined;
                var digits: usize = undefined;
                if (text[p] == '0') {
                    leading_zeros = 1;
                    digits = 0;
                } else {
                    leading_zeros = 0;
                    digits = 1;
                }
                while (true) {
                    p += 1;
                    if (p >= text.len) break;
                    if (text[p] == '0' and digits == 0) {
                        leading_zeros += 1;
                    } else if (std.ascii.isDigit(text[p])) {
                        digits += 1;
                    } else {
                        // An all-zero run counts as one digit plus leading zeros.
                        if (digits == 0) {
                            digits += 1;
                            leading_zeros -= 1;
                        }
                        break;
                    }
                }
                while (digits > 1) : (digits -= 1) try result.append(a, ':');
                // The count of leading zeros breaks ties after everything else.
                if (leading_zeros > 0) {
                    try append.append(a, @truncate(leading_zeros));
                    prev += leading_zeros;
                }
                try result.appendSlice(a, text[prev..p]);
                prev = p;
                p -= 1;
            },
            else => {},
        }
    }
    if (prev != p) try appendKey(a, &result, text[prev..p]);
    try result.appendSlice(a, append.items);
    return result.toOwnedSliceSentinel(a, 0);
}

fn appendKey(a: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    const key = try collateKey(a, text);
    defer a.free(key);
    try out.appendSlice(a, key);
}

test "case folding, NFKC normalization, and natural filename collation" {
    const a = std.testing.allocator;
    const folded = try casefold(a, "Straße");
    defer a.free(folded);
    try std.testing.expectEqualStrings("strasse", folded);
    const composed = try normalize(a, "Cafe\u{301}");
    defer a.free(composed);
    try std.testing.expectEqualStrings("Café", composed);
    const compat = try normalize(a, "ﬁle １２３");
    defer a.free(compat);
    try std.testing.expectEqualStrings("file 123", compat);
    const key9 = try collateKeyForFilename(a, "file9.txt");
    defer a.free(key9);
    const key10 = try collateKeyForFilename(a, "file10.txt");
    defer a.free(key10);
    try std.testing.expect(std.mem.order(u8, key9, key10) == .lt);
    try std.testing.expectEqual(std.math.Order.eq, try collate(a, "Café", "Cafe\u{301}"));
}
