//! OpenType text shaping in Zig, following HarfBuzz's OpenType shaper: the
//! default shaper for Latin, Greek, Cyrillic, Hebrew, CJK and other scripts
//! without reordering, and the Arabic shaper for joining scripts (Arabic,
//! Syriac, N'Ko, Mongolian, ...). Characters map through cmap with
//! normalization fallbacks, GSUB substitutes, hmtx/HVAR and GPOS position,
//! with GDEF classes, variable-font feature variations and MVAR metrics.
//! Indic, Khmer, Myanmar and Universal Shaping Engine reordering is not
//! implemented: those scripts shape with the default shaper.
const std = @import("std");
const opentype = @import("desktop-opentype.zig");
const unicode = @import("desktop-unicode.zig");

const Bytes = opentype.Bytes;
const Error = opentype.Error;
const tag = opentype.tagOf;

pub const Direction = enum { ltr, rtl };

/// A shaped glyph. Positions are 26.6 fixed-point pixels; `cluster` is the
/// byte offset in the text of the first character the glyph belongs to.
pub const Glyph = struct {
    id: u32,
    cluster: u32,
    x_advance: i32 = 0,
    y_advance: i32 = 0,
    x_offset: i32 = 0,
    y_offset: i32 = 0,
};

/// Shaping tables of one face, with plans cached per script, direction and
/// variation coordinates.
pub const Face = struct {
    allocator: std.mem.Allocator,
    font: *const opentype.Font,
    hmtx: ?Bytes = null,
    metrics_count: u16 = 0,
    hhea: ?Bytes = null,
    os2: ?Bytes = null,
    hvar: ?Bytes = null,
    mvar: ?Bytes = null,
    gdef: Gdef = .{},
    gsub: ?Layout = null,
    gpos: ?Layout = null,
    /// cmap format 14: glyphs for variation sequences.
    sequences: ?Bytes = null,
    plans: std.ArrayList(*Plan) = .empty,

    pub fn init(allocator: std.mem.Allocator, font: *const opentype.Font) Face {
        var self: Face = .{ .allocator = allocator, .font = font };
        self.hhea = font.findTable(tag("hhea"));
        self.hmtx = font.findTable(tag("hmtx"));
        if (self.hhea) |hhea| self.metrics_count = hhea.u16At(34) catch 0;
        self.os2 = font.findTable(tag("OS/2"));
        self.hvar = font.findTable(tag("HVAR"));
        self.mvar = font.findTable(tag("MVAR"));
        self.gdef = Gdef.init(font.findTable(tag("GDEF")));
        self.gsub = Layout.init(font.findTable(tag("GSUB")));
        self.gpos = Layout.init(font.findTable(tag("GPOS")));
        if (font.findTable(tag("cmap"))) |cmap| self.sequences = sequenceTable(cmap);
        return self;
    }

    pub fn deinit(self: *Face) void {
        for (self.plans.items) |plan| plan.destroy(self.allocator);
        self.plans.deinit(self.allocator);
        self.* = undefined;
    }

    /// Ascender and descender (negative below the baseline) at `scale` units per em,
    /// as hb_font_get_h_extents reports them.
    pub fn extents(self: *const Face, coords: []const f32, scale: f64) [2]i32 {
        const upem: f64 = @floatFromInt(self.font.units_per_em);
        var result: [2]i32 = .{ 0, 0 };
        for ([_]u32{ tag("hasc"), tag("hdsc") }, 0..) |metric, i| {
            var value: ?f32 = null;
            if (self.os2) |os2| if ((os2.u16At(62) catch 0) & 0x80 != 0) {
                if (os2.i16At(68 + 2 * i) catch null) |typo| value = @floatFromInt(typo);
            };
            if (value == null) if (self.hhea) |hhea| {
                value = @floatFromInt(hhea.i16At(4 + 2 * i) catch 0);
            };
            var v = value orelse continue;
            v += self.metricDelta(metric, coords);
            v = if (i == 0) @abs(v) else -@abs(v);
            result[i] = @intFromFloat(std.math.clamp(@round(v * scale / upem), -1e9, 1e9));
        }
        return result;
    }

    fn metricDelta(self: *const Face, metric: u32, coords: []const f32) f32 {
        const mvar = self.mvar orelse return 0;
        if (!nonzero(coords)) return 0;
        const record_size = mvar.u16At(6) catch return 0;
        const count = mvar.u16At(8) catch return 0;
        const store_offset = mvar.u16At(10) catch return 0;
        if (store_offset == 0 or record_size < 8) return 0;
        const store = mvar.from(store_offset) catch return 0;
        for (0..count) |i| {
            const at = 12 + @as(usize, record_size) * i;
            if ((mvar.u32At(at) catch return 0) != metric) continue;
            return varDelta(store, mvar.u16At(at + 4) catch return 0, mvar.u16At(at + 6) catch return 0, coords);
        }
        return 0;
    }

    /// The glyph for `cp` followed by variation selector `selector`, if the font maps the sequence.
    fn variationGlyph(self: *const Face, cp: u21, selector: u21) ?u32 {
        const table = self.sequences orelse return null;
        const count = table.u32At(6) catch return null;
        var low: usize = 0;
        var high: usize = count;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const at = 10 + 11 * mid;
            const value = table.u24At(at) catch return null;
            if (value < selector) {
                low = mid + 1;
                continue;
            }
            if (value > selector) {
                high = mid;
                continue;
            }
            // Default sequences use the nominal glyph; others name their own.
            const defaults = table.u32At(at + 3) catch return null;
            if (defaults != 0) if (table.from(defaults) catch null) |ranges| {
                const ranges_count = ranges.u32At(0) catch return null;
                for (0..ranges_count) |k| {
                    const start = ranges.u24At(4 + 4 * k) catch return null;
                    const extra = ranges.u8At(7 + 4 * k) catch return null;
                    if (cp >= start and cp <= start + extra) {
                        const glyph = self.font.glyphIndex(cp);
                        return if (glyph != 0) glyph else null;
                    }
                }
            };
            const specific = table.u32At(at + 7) catch return null;
            if (specific == 0) return null;
            const mappings = table.from(specific) catch return null;
            var a: usize = 0;
            var b: usize = mappings.u32At(0) catch return null;
            while (a < b) {
                const m = a + (b - a) / 2;
                const value_cp = mappings.u24At(4 + 5 * m) catch return null;
                if (value_cp < cp) a = m + 1 else if (value_cp > cp) b = m else return mappings.u16At(7 + 5 * m) catch null;
            }
            return null;
        }
        return null;
    }

    /// Horizontal advance in whole font units, with HVAR deltas rounded as HarfBuzz does.
    fn advance(self: *const Face, glyph: u32, coords: []const f32) f32 {
        const hmtx = self.hmtx orelse return 0;
        if (self.metrics_count == 0) return 0;
        const index = @min(glyph, self.metrics_count - 1);
        var value: f32 = @floatFromInt(hmtx.u16At(4 * @as(usize, index)) catch 0);
        if (self.hvar) |hvar| if (nonzero(coords)) {
            value += @round(hvarDelta(hvar, glyph, coords) catch 0);
        };
        return std.math.clamp(value, 0, 65535);
    }

    fn planFor(self: *Face, script: u32, direction: Direction, coords: []const f32) !*Plan {
        for (self.plans.items) |existing| {
            if (existing.script == script and existing.direction == direction and std.mem.eql(f32, existing.coords[0..existing.coord_count], coords)) return existing;
        }
        // Each weight and optical size has its own plan; keep the most recent few.
        if (self.plans.items.len >= max_plans) self.plans.orderedRemove(0).destroy(self.allocator);
        const value = try Plan.create(self, script, direction, coords);
        errdefer value.destroy(self.allocator);
        try self.plans.append(self.allocator, value);
        return value;
    }
};

/// The Unicode variation sequences subtable (cmap format 14), if present.
fn sequenceTable(cmap: Bytes) ?Bytes {
    const count = cmap.u16At(2) catch return null;
    for (0..count) |i| {
        if ((cmap.u16At(4 + 8 * i) catch return null) != 0 or (cmap.u16At(6 + 8 * i) catch return null) != 5) continue;
        const sub = cmap.from(cmap.u32At(8 + 8 * i) catch return null) catch return null;
        if ((sub.u16At(0) catch return null) == 14) return sub;
    }
    return null;
}

fn isVariationSelector(cp: u21) bool {
    return (cp >= 0xFE00 and cp <= 0xFE0F) or (cp >= 0xE0100 and cp <= 0xE01EF) or (cp >= 0x180B and cp <= 0x180D) or cp == 0x180F;
}

fn nonzero(coords: []const f32) bool {
    for (coords) |c| if (c != 0) return true;
    return false;
}

fn hvarDelta(hvar: Bytes, glyph: u32, coords: []const f32) Error!f32 {
    const store = try hvar.from(try hvar.u32At(4));
    const map_offset = try hvar.u32At(8);
    var outer: u32 = 0;
    var inner: u32 = glyph;
    if (map_offset != 0) {
        const map = try hvar.from(map_offset);
        const format = try map.u8At(0);
        const entry = try map.u8At(1);
        const count: u32 = if (format == 0) try map.u16At(2) else try map.u32At(2);
        if (count == 0) return 0;
        const data: usize = if (format == 0) 4 else 6;
        const size: usize = ((entry >> 4) & 3) + 1;
        const inner_bits: u5 = @intCast((entry & 0x0f) + 1);
        const at = data + size * @min(glyph, count - 1);
        var value: u32 = 0;
        for (0..size) |k| value = (value << 8) | try map.u8At(at + k);
        outer = value >> inner_bits;
        inner = value & ((@as(u32, 1) << inner_bits) - 1);
    }
    return varDelta(store, std.math.cast(u16, outer) orelse return 0, std.math.cast(u16, inner) orelse return 0, coords);
}

/// The interpolated delta of an ItemVariationStore entry.
fn varDelta(store: Bytes, outer: u16, inner: u16, coords: []const f32) f32 {
    return varDeltaChecked(store, outer, inner, coords) catch 0;
}

fn varDeltaChecked(store: Bytes, outer: u16, inner: u16, coords: []const f32) Error!f32 {
    if (outer == 0xffff and inner == 0xffff) return 0;
    const regions = try store.from(try store.u32At(2));
    if (outer >= try store.u16At(6)) return 0;
    const data = try store.from(try store.u32At(8 + 4 * @as(usize, outer)));
    const item_count = try data.u16At(0);
    const word_field = try data.u16At(2);
    const long = word_field & 0x8000 != 0;
    const words: usize = word_field & 0x7fff;
    const region_count: usize = try data.u16At(4);
    if (inner >= item_count or words > region_count) return 0;
    const row_size = if (long) words * 4 + (region_count - words) * 2 else words * 2 + (region_count - words);
    const row = 6 + 2 * region_count + @as(usize, inner) * row_size;
    const axis_count: usize = try regions.u16At(0);
    const list_count = try regions.u16At(2);
    var sum: f32 = 0;
    var at = row;
    for (0..region_count) |r| {
        var delta: f32 = undefined;
        if (r < words) {
            delta = if (long) @floatFromInt(@as(i32, @bitCast(try data.u32At(at)))) else @floatFromInt(try data.i16At(at));
            at += if (long) 4 else 2;
        } else {
            delta = if (long) @floatFromInt(try data.i16At(at)) else @floatFromInt(@as(i8, @bitCast(try data.u8At(at))));
            at += if (long) 2 else 1;
        }
        const region = try data.u16At(6 + 2 * r);
        if (region >= list_count) return error.InvalidFont;
        var scalar: f32 = 1;
        for (0..axis_count) |axis| {
            const base = 4 + (@as(usize, region) * axis_count + axis) * 6;
            const start = try regions.f2dot14(base);
            const peak = try regions.f2dot14(base + 2);
            const end = try regions.f2dot14(base + 4);
            const c = if (axis < coords.len) coords[axis] else 0;
            if (start > peak or peak > end) continue;
            if (start < 0 and end > 0 and peak != 0) continue;
            if (peak == 0 or c == peak) continue;
            if (c <= start or end <= c) {
                scalar = 0;
                break;
            }
            scalar *= if (c < peak) (c - start) / (peak - start) else (end - c) / (end - peak);
        }
        sum += scalar * delta;
    }
    return sum;
}

// ------------------------------------------------------------------ Tables

fn coverage(table: Bytes, glyph: u32) ?u16 {
    return coverageChecked(table, glyph) catch null;
}

fn coverageChecked(table: Bytes, glyph: u32) Error!?u16 {
    const format = try table.u16At(0);
    const count = try table.u16At(2);
    var low: usize = 0;
    var high: usize = count;
    switch (format) {
        1 => while (low < high) {
            const mid = low + (high - low) / 2;
            const value = try table.u16At(4 + 2 * mid);
            if (value == glyph) return @intCast(mid);
            if (value < glyph) low = mid + 1 else high = mid;
        },
        2 => while (low < high) {
            const mid = low + (high - low) / 2;
            const at = 4 + 6 * mid;
            const start = try table.u16At(at);
            const end = try table.u16At(at + 2);
            if (glyph < start) high = mid else if (glyph > end) low = mid + 1 else return std.math.cast(u16, @as(u32, try table.u16At(at + 4)) + glyph - start);
        },
        else => {},
    }
    return null;
}

fn classOf(table: Bytes, glyph: u32) u16 {
    return classChecked(table, glyph) catch 0;
}

fn classChecked(table: Bytes, glyph: u32) Error!u16 {
    switch (try table.u16At(0)) {
        1 => {
            const start = try table.u16At(2);
            const count = try table.u16At(4);
            if (glyph < start or glyph - start >= count) return 0;
            return table.u16At(6 + 2 * (glyph - start));
        },
        2 => {
            var low: usize = 0;
            var high: usize = try table.u16At(2);
            while (low < high) {
                const mid = low + (high - low) / 2;
                const at = 4 + 6 * mid;
                const start = try table.u16At(at);
                const end = try table.u16At(at + 2);
                if (glyph < start) high = mid else if (glyph > end) low = mid + 1 else return table.u16At(at + 4);
            }
            return 0;
        },
        else => return 0,
    }
}

/// Follows a 16-bit offset, which is null when zero.
fn offset16(table: Bytes, at: usize) ?Bytes {
    const value = table.u16At(at) catch return null;
    if (value == 0) return null;
    return table.from(value) catch null;
}

// Glyph properties, matching the lookup flag bits they are tested against.
const base_glyph: u32 = 0x02;
const ligature_glyph: u32 = 0x04;
const mark_glyph: u32 = 0x08;
const ignore_flags: u32 = 0x0e;

const Gdef = struct {
    classes: ?Bytes = null,
    mark_classes: ?Bytes = null,
    mark_sets: ?Bytes = null,
    store: ?Bytes = null,

    fn init(table: ?Bytes) Gdef {
        const t = table orelse return .{};
        var self: Gdef = .{ .classes = offset16(t, 4), .mark_classes = offset16(t, 10) };
        const minor = t.u16At(2) catch 0;
        if (minor >= 2) self.mark_sets = offset16(t, 12);
        if (minor >= 3) {
            const store = t.u32At(14) catch 0;
            if (store != 0) self.store = t.from(store) catch null;
        }
        return self;
    }

    fn props(self: Gdef, glyph: u32) u32 {
        const classes = self.classes orelse return 0;
        return switch (classOf(classes, glyph)) {
            1 => base_glyph,
            2 => ligature_glyph,
            3 => mark_glyph | (@as(u32, if (self.mark_classes) |m| classOf(m, glyph) else 0) << 8),
            else => 0,
        };
    }

    fn markSetCovers(self: Gdef, set: u32, glyph: u32) bool {
        const sets = self.mark_sets orelse return false;
        if (set >= (sets.u16At(2) catch return false)) return false;
        const at = sets.u32At(4 + 4 * @as(usize, set)) catch return false;
        return coverage(sets.from(at) catch return false, glyph) != null;
    }
};

/// A GSUB or GPOS table.
const Layout = struct {
    scripts: Bytes,
    features: Bytes,
    lookups: Bytes,
    variations: ?Bytes = null,

    fn init(table: ?Bytes) ?Layout {
        const t = table orelse return null;
        if ((t.u16At(0) catch return null) != 1) return null;
        var self: Layout = .{
            .scripts = offset16(t, 4) orelse return null,
            .features = offset16(t, 6) orelse return null,
            .lookups = offset16(t, 8) orelse return null,
        };
        if ((t.u16At(2) catch 0) >= 1) {
            const at = t.u32At(10) catch 0;
            if (at != 0) self.variations = t.from(at) catch null;
        }
        return self;
    }

    /// The default language system of the first script found among `candidates`.
    fn langSys(self: Layout, candidates: []const u32) ?Bytes {
        const count = self.scripts.u16At(0) catch return null;
        for (candidates) |candidate| {
            for (0..count) |i| {
                if ((self.scripts.u32At(2 + 6 * i) catch return null) != candidate) continue;
                const script = offset16(self.scripts, 2 + 6 * i + 4) orelse return null;
                return offset16(script, 0);
            }
        }
        return null;
    }

    fn featureTag(self: Layout, index: u16) u32 {
        return self.features.u32At(2 + 6 * @as(usize, index)) catch 0;
    }

    /// The first FeatureVariations record whose conditions hold at `coords`.
    fn variationRecord(self: Layout, coords: []const f32) ?u32 {
        const table = self.variations orelse return null;
        const count = table.u32At(4) catch return null;
        var record: u32 = 0;
        while (record < count) : (record += 1) {
            const set_offset = table.u32At(8 + 8 * @as(usize, record)) catch return null;
            if (set_offset == 0) return record;
            const set = table.from(set_offset) catch return null;
            const conditions = set.u16At(0) catch return null;
            const matches = for (0..conditions) |k| {
                const condition = set.from(set.u32At(2 + 4 * k) catch break false) catch break false;
                if ((condition.u16At(0) catch break false) != 1) break false;
                const axis = condition.u16At(2) catch break false;
                const min = condition.f2dot14(4) catch break false;
                const max = condition.f2dot14(6) catch break false;
                const c = if (axis < coords.len) coords[axis] else 0;
                if (c < min or c > max) break false;
            } else true;
            if (matches) return record;
        }
        return null;
    }

    fn feature(self: Layout, index: u16, record: ?u32) ?Bytes {
        if (record) |r| if (self.variations) |table| {
            const at = table.u32At(8 + 8 * @as(usize, r) + 4) catch 0;
            if (at != 0) if (table.from(at) catch null) |substitution| {
                const count = substitution.u16At(4) catch 0;
                for (0..count) |k| {
                    if ((substitution.u16At(6 + 6 * k) catch break) != index) continue;
                    return substitution.from(substitution.u32At(6 + 6 * k + 2) catch break) catch null;
                }
            };
        };
        if (index >= (self.features.u16At(0) catch return null)) return null;
        return offset16(self.features, 2 + 6 * @as(usize, index) + 4);
    }

    fn lookup(self: Layout, index: u16) ?Bytes {
        if (index >= (self.lookups.u16At(0) catch return null)) return null;
        return offset16(self.lookups, 2 + 2 * @as(usize, index));
    }
};

// ------------------------------------------------------------------- Plans

const global_mask: u32 = 1;
const rtlm_mask: u32 = 1 << 8;
/// Arabic positional forms, in the order HarfBuzz applies them.
const arabic_features = [_]*const [4]u8{ "isol", "fina", "fin2", "fin3", "medi", "med2", "init" };

fn arabicMask(index: usize) u32 {
    return @as(u32, 2) << @intCast(index);
}

const LookupRef = struct { index: u16, mask: u32, stage: u8, auto_zwj: bool };

const Plan = struct {
    script: u32,
    direction: Direction,
    coords: [opentype.max_axes]f32 = undefined,
    coord_count: usize = 0,
    arabic: bool = false,
    gsub: []LookupRef = &.{},
    gpos: []LookupRef = &.{},

    const Spec = struct { tag: u32, mask: u32 = global_mask, stage: u8, manual_zwj: bool = false };

    fn create(face: *Face, script: u32, direction: Direction, coords: []const f32) !*Plan {
        const a = face.allocator;
        const self = try a.create(Plan);
        errdefer a.destroy(self);
        self.* = .{ .script = script, .direction = direction, .coord_count = @min(coords.len, opentype.max_axes) };
        @memcpy(self.coords[0..self.coord_count], coords[0..self.coord_count]);
        const tags = scriptTags(script);
        self.arabic = isArabicShaped(script);

        var specs: std.ArrayList(Spec) = .empty;
        defer specs.deinit(a);
        const add = struct {
            fn f(list: *std.ArrayList(Spec), allocator: std.mem.Allocator, spec: Spec) !void {
                // A feature requested again keeps its earliest stage, as hb_ot_map does.
                for (list.items) |existing| if (existing.tag == spec.tag) return;
                try list.append(allocator, spec);
            }
        }.f;
        var stage: u8 = 0;
        try add(&specs, a, .{ .tag = tag("rvrn"), .stage = stage });
        stage += 1;
        if (direction == .ltr) {
            try add(&specs, a, .{ .tag = tag("ltra"), .stage = stage });
            try add(&specs, a, .{ .tag = tag("ltrm"), .stage = stage });
        } else {
            try add(&specs, a, .{ .tag = tag("rtla"), .stage = stage });
            try add(&specs, a, .{ .tag = tag("rtlm"), .mask = rtlm_mask, .stage = stage });
        }
        if (self.arabic) {
            try add(&specs, a, .{ .tag = tag("stch"), .stage = stage });
            stage += 1;
            try add(&specs, a, .{ .tag = tag("ccmp"), .stage = stage, .manual_zwj = true });
            try add(&specs, a, .{ .tag = tag("locl"), .stage = stage, .manual_zwj = true });
            stage += 1;
            for (arabic_features, 0..) |name, i| {
                try add(&specs, a, .{ .tag = tag(name), .mask = arabicMask(i), .stage = stage, .manual_zwj = true });
                stage += 1;
            }
            try add(&specs, a, .{ .tag = tag("rlig"), .stage = stage, .manual_zwj = true });
            stage += 1;
            try add(&specs, a, .{ .tag = tag("calt"), .stage = stage, .manual_zwj = true });
            stage += 1;
            for ([_]*const [4]u8{ "rclt", "liga", "clig", "mset" }) |name| try add(&specs, a, .{ .tag = tag(name), .stage = stage, .manual_zwj = true });
        }
        for ([_]*const [4]u8{ "abvm", "blwm", "ccmp", "locl", "mark", "mkmk", "rlig", "calt", "clig", "curs", "dist", "kern", "liga", "rclt" }) |name| {
            try add(&specs, a, .{ .tag = tag(name), .stage = stage });
        }

        if (face.gsub) |layout| self.gsub = try collect(a, layout, &tags, specs.items, coords, false);
        errdefer a.free(self.gsub);
        if (face.gpos) |layout| self.gpos = try collect(a, layout, &tags, specs.items, coords, true);
        return self;
    }

    fn destroy(self: *Plan, a: std.mem.Allocator) void {
        a.free(self.gsub);
        a.free(self.gpos);
        a.destroy(self);
    }

    /// Lookups of the requested features in stage order, then lookup order,
    /// with duplicates within a stage merged.
    fn collect(a: std.mem.Allocator, layout: Layout, tags: []const u32, specs: []const Spec, coords: []const f32, single_stage: bool) ![]LookupRef {
        var refs: std.ArrayList(LookupRef) = .empty;
        defer refs.deinit(a);
        const lang = layout.langSys(tags) orelse return a.alloc(LookupRef, 0);
        const record = layout.variationRecord(coords);
        const required = lang.u16At(2) catch 0xffff;
        if (required != 0xffff) try appendFeature(a, &refs, layout, required, record, .{ .tag = 0, .stage = 0 });
        const count = lang.u16At(4) catch 0;
        for (specs) |spec| {
            for (0..count) |i| {
                const index = lang.u16At(6 + 2 * i) catch break;
                if (layout.featureTag(index) != spec.tag) continue;
                var resolved = spec;
                if (single_stage) resolved.stage = 0;
                try appendFeature(a, &refs, layout, index, record, resolved);
                break;
            }
        }
        std.mem.sort(LookupRef, refs.items, {}, struct {
            fn less(_: void, x: LookupRef, y: LookupRef) bool {
                return if (x.stage != y.stage) x.stage < y.stage else x.index < y.index;
            }
        }.less);
        var merged: std.ArrayList(LookupRef) = .empty;
        errdefer merged.deinit(a);
        for (refs.items) |item| {
            if (merged.items.len > 0) {
                const last = &merged.items[merged.items.len - 1];
                if (last.stage == item.stage and last.index == item.index) {
                    last.mask |= item.mask;
                    last.auto_zwj = last.auto_zwj and item.auto_zwj;
                    continue;
                }
            }
            try merged.append(a, item);
        }
        return merged.toOwnedSlice(a);
    }

    fn appendFeature(a: std.mem.Allocator, refs: *std.ArrayList(LookupRef), layout: Layout, index: u16, record: ?u32, spec: Spec) !void {
        const table = layout.feature(index, record) orelse return;
        const count = table.u16At(2) catch return;
        for (0..count) |k| {
            const lookup = table.u16At(4 + 2 * k) catch return;
            try refs.append(a, .{ .index = lookup, .mask = spec.mask, .stage = spec.stage, .auto_zwj = !spec.manual_zwj });
        }
    }
};

fn iso(code: *const [4]u8) u32 {
    return std.mem.readInt(u32, code, .big);
}

/// OpenType script tags to try for an ISO 15924 script, most preferred first.
fn scriptTags(script: u32) [4]u32 {
    var out: [4]u32 = .{ tag("DFLT"), tag("dflt"), tag("latn"), tag("DFLT") };
    const new: ?*const [4]u8 = switch (script) {
        iso("Beng") => "bng2",
        iso("Deva") => "dev2",
        iso("Gujr") => "gjr2",
        iso("Guru") => "gur2",
        iso("Knda") => "knd2",
        iso("Mlym") => "mlm2",
        iso("Orya") => "ory2",
        iso("Taml") => "tml2",
        iso("Telu") => "tel2",
        iso("Mymr") => "mym2",
        else => null,
    };
    const old: u32 = switch (script) {
        iso("Zyyy"), iso("Zinh"), iso("Zzzz") => return out,
        iso("Hira") => tag("kana"),
        iso("Laoo") => tag("lao "),
        iso("Yiii") => tag("yi  "),
        iso("Nkoo") => tag("nko "),
        iso("Vaii") => tag("vai "),
        else => script | 0x20202020,
    };
    if (new) |name| {
        out = .{ tag(name), old, tag("DFLT"), tag("dflt") };
    } else {
        out = .{ old, tag("DFLT"), tag("dflt"), tag("latn") };
    }
    return out;
}

fn isArabicShaped(script: u32) bool {
    return switch (script) {
        iso("Arab"), iso("Syrc"), iso("Mong"), iso("Nkoo"), iso("Phag"), iso("Mand"), iso("Mani"), iso("Phlp"), iso("Adlm"), iso("Rohg"), iso("Sogd"), iso("Chrs") => true,
        else => false,
    };
}

fn isRtlScript(script: u32) bool {
    return switch (script) {
        iso("Arab"), iso("Hebr"), iso("Syrc"), iso("Thaa"), iso("Cprt"), iso("Khar"), iso("Phnx"), iso("Nkoo"), iso("Lydi"), iso("Avst"), iso("Armi"), iso("Phli"), iso("Prti"), iso("Sarb"), iso("Orkh"), iso("Samr"), iso("Mand"), iso("Merc"), iso("Mero"), iso("Mani"), iso("Mend"), iso("Nbat"), iso("Narb"), iso("Palm"), iso("Phlp"), iso("Hatr"), iso("Oldu"), iso("Adlm"), iso("Rohg"), iso("Sogo"), iso("Sogd"), iso("Elym"), iso("Chrs"), iso("Yezi"), iso("Ougr") => true,
        else => false,
    };
}

// ----------------------------------------------------------------- Shaping

const Space = enum(u8) { none, em, em_2, em_3, em_4, em_5, em_6, em_16, em_4_18, figure, punctuation, narrow, space };

const Attach = enum(u8) { none, mark, cursive };

const Info = struct {
    glyph: u32 = 0,
    cp: u21 = 0,
    cluster: u32 = 0,
    mask: u32 = global_mask,
    props: u32 = 0,
    lig_id: u8 = 0,
    lig_comp: u8 = 0,
    ignorable: bool = false,
    zwj: bool = false,
    zwnj: bool = false,
    continuation: bool = false,
    /// A glyph chosen by a variation sequence, or 0.
    preset: u32 = 0,
    substituted: bool = false,
    multiplied: bool = false,
    space: Space = .none,
    x_advance: i32 = 0,
    y_advance: i32 = 0,
    x_offset: i32 = 0,
    y_offset: i32 = 0,
    chain: i32 = 0,
    attach: Attach = .none,

    fn isMark(self: Info) bool {
        return self.props & mark_glyph != 0;
    }

    fn ignored(self: Info) bool {
        return self.ignorable and !self.substituted;
    }
};

const max_context = 64;
const max_nesting = 6;
const max_plans = 16;

const Shaper = struct {
    a: std.mem.Allocator,
    face: *const Face,
    coords: []const f32,
    scale: i32,
    ppem: u32,
    mult: i64,
    /// Font units to 26.6 pixels in single precision, as HarfBuzz scales fractional values.
    multf: f32,
    buffer: std.ArrayList(Info) = .empty,
    direction: Direction,
    next_lig_id: u8 = 0,
    // The lookup being applied.
    gpos: bool = false,
    layout: Layout = undefined,
    props: u32 = 0,
    mask: u32 = global_mask,
    auto_zwj: bool = true,
    nesting: u8 = 0,
    /// The glyph count multiple substitutions may grow the buffer to.
    max_len: usize = 0,

    fn info(self: *Shaper) []Info {
        return self.buffer.items;
    }

    fn em(self: *const Shaper, value: i32) i32 {
        return @intCast((@as(i64, value) * self.mult + 32768) >> 16);
    }

    fn emFloat(self: *const Shaper, value: f32) f32 {
        return value * self.multf;
    }

    fn emRound(self: *const Shaper, value: f32) i32 {
        return @intFromFloat(std.math.clamp(@round(self.emFloat(value)), -1e9, 1e9));
    }

    fn nominal(self: *const Shaper, cp: u21) u32 {
        return self.face.font.glyphIndex(cp);
    }

    // ---------------------------------------------------------- Matching

    fn checkProps(self: *const Shaper, item: Info, props: u32) bool {
        if (item.props & props & ignore_flags != 0) return false;
        if (item.props & mark_glyph != 0) {
            if (props & 0x10 != 0) return self.face.gdef.markSetCovers(props >> 16, item.glyph);
            if (props & 0xff00 != 0) return (props & 0xff00) == (item.props & 0xff00);
        }
        return true;
    }

    /// Whether matching passes over a glyph: filtered by the lookup flags, or
    /// a default ignorable that the lookup does not see.
    fn skippable(self: *const Shaper, item: Info, context: bool) bool {
        if (!self.checkProps(item, self.props)) return true;
        const ignore_zwnj = self.gpos or context;
        const ignore_zwj = self.gpos or self.auto_zwj;
        return item.ignored() and (ignore_zwnj or !item.zwnj) and (ignore_zwj or !item.zwj);
    }

    fn next(self: *Shaper, from: usize, context: bool) ?usize {
        var j = from + 1;
        while (j < self.buffer.items.len) : (j += 1) if (!self.skippable(self.buffer.items[j], context)) return j;
        return null;
    }

    fn prev(self: *Shaper, from: usize, context: bool) ?usize {
        var j = from;
        while (j > 0) {
            j -= 1;
            if (!self.skippable(self.buffer.items[j], context)) return j;
        }
        return null;
    }

    /// The next (or previous) glyph matching element `k` of `seq`. Glyphs the
    /// lookup flags filter are passed over; default ignorables are taken when
    /// they match (a ZWJ in an emoji sequence) and passed over otherwise.
    fn step(self: *Shaper, from: usize, forward: bool, context: bool, seq: Sequence, k: usize) ?usize {
        var j = from;
        while (true) {
            if (forward) {
                j += 1;
                if (j >= self.buffer.items.len) return null;
            } else {
                if (j == 0) return null;
                j -= 1;
            }
            const item = self.buffer.items[j];
            if (!self.checkProps(item, self.props)) continue;
            // Input glyphs must carry the feature; context glyphs need not.
            const matched = (context or item.mask & self.mask != 0) and seq.matches(k, item.glyph);
            if (matched) return j;
            if (!self.skippable(item, context)) return null;
        }
    }

    /// Matches `count` input glyphs starting at `i`; `rest` describes all but the first.
    fn matchInput(self: *Shaper, i: usize, rest: Sequence, count: usize, positions: *[max_context]usize) bool {
        if (count == 0 or count > max_context) return false;
        positions[0] = i;
        var p = i;
        for (1..count) |k| {
            p = self.step(p, true, false, rest, k - 1) orelse return false;
            positions[k] = p;
        }
        return true;
    }

    fn matchBacktrack(self: *Shaper, i: usize, seq: Sequence, count: usize) bool {
        var p = i;
        for (0..count) |k| p = self.step(p, false, true, seq, k) orelse return false;
        return true;
    }

    fn matchLookahead(self: *Shaper, last: usize, seq: Sequence, count: usize) bool {
        var p = last;
        for (0..count) |k| p = self.step(p, true, true, seq, k) orelse return false;
        return true;
    }

    // ---------------------------------------------------------- Lookups

    fn applyPlan(self: *Shaper, layout: Layout, refs: []const LookupRef, gpos: bool) void {
        self.gpos = gpos;
        self.layout = layout;
        for (refs) |ref| {
            const lookup = layout.lookup(ref.index) orelse continue;
            self.mask = ref.mask;
            self.auto_zwj = ref.auto_zwj;
            self.applyLookup(lookup);
        }
    }

    fn lookupProps(lookup: Bytes) u32 {
        const flag: u32 = lookup.u16At(2) catch 0;
        var props = flag;
        if (flag & 0x10 != 0) {
            const count = lookup.u16At(4) catch 0;
            props |= @as(u32, lookup.u16At(6 + 2 * @as(usize, count)) catch 0) << 16;
        }
        return props;
    }

    fn lookupType(lookup: Bytes) u16 {
        const kind = lookup.u16At(0) catch return 0;
        // Extension lookups take the type of their subtables.
        if (kind == 7 or kind == 9) {
            const first = offset16(lookup, 6) orelse return kind;
            if ((first.u16At(0) catch 0) == 1) return first.u16At(2) catch kind;
        }
        return kind;
    }

    fn applyLookup(self: *Shaper, lookup: Bytes) void {
        self.props = lookupProps(lookup);
        const reverse = !self.gpos and lookupType(lookup) == 8;
        if (reverse) {
            var i = self.buffer.items.len;
            while (i > 0) {
                i -= 1;
                const item = self.buffer.items[i];
                if (item.mask & self.mask != 0 and self.checkProps(item, self.props)) _ = self.applyAt(lookup, i);
            }
            return;
        }
        // Malformed fonts can make substitutions undo each other; bound the work.
        var budget = 64 * self.buffer.items.len + 1024;
        var i: usize = 0;
        while (i < self.buffer.items.len) {
            const item = self.buffer.items[i];
            if (item.mask & self.mask != 0 and self.checkProps(item, self.props)) {
                if (self.applyAt(lookup, i)) |resume_at| {
                    budget -|= 1;
                    if (budget == 0) return;
                    i = resume_at;
                    continue;
                }
            }
            i += 1;
        }
    }

    /// Applies the first subtable that matches at `i`; returns where to continue.
    fn applyAt(self: *Shaper, lookup: Bytes, i: usize) ?usize {
        const kind = lookup.u16At(0) catch return null;
        const count = lookup.u16At(4) catch return null;
        for (0..count) |k| {
            const sub = offset16(lookup, 6 + 2 * k) orelse continue;
            const result = (if (self.gpos) self.position(kind, sub, i) else self.substitute(kind, sub, i)) catch null;
            if (result) |value| return value;
        }
        return null;
    }

    /// Applies lookup `index` once at `i`, from a contextual lookup.
    fn applyNested(self: *Shaper, index: u16, i: usize) bool {
        if (self.nesting >= max_nesting) return false;
        const lookup = self.layout.lookup(index) orelse return false;
        const saved = self.props;
        self.props = lookupProps(lookup);
        self.nesting += 1;
        defer {
            self.nesting -= 1;
            self.props = saved;
        }
        return self.applyAt(lookup, i) != null;
    }

    // ----------------------------------------------------- Substitution

    fn setGlyph(self: *Shaper, item: *Info, glyph: u32, class_guess: u32) void {
        item.glyph = glyph;
        item.substituted = true;
        if (self.face.gdef.classes != null) {
            item.props = self.face.gdef.props(glyph);
        } else if (class_guess != 0) {
            item.props = class_guess;
        }
    }

    fn substitute(self: *Shaper, kind: u16, sub: Bytes, i: usize) Error!?usize {
        const glyph = self.buffer.items[i].glyph;
        switch (kind) {
            1 => {
                const index = coverage(offset16(sub, 2) orelse return null, glyph) orelse return null;
                const replacement: u32 = switch (try sub.u16At(0)) {
                    1 => @as(u16, @truncate(glyph +% @as(u32, @bitCast(@as(i32, try sub.i16At(4)))))),
                    2 => blk: {
                        if (index >= try sub.u16At(4)) return null;
                        break :blk try sub.u16At(6 + 2 * @as(usize, index));
                    },
                    else => return null,
                };
                self.setGlyph(&self.buffer.items[i], replacement, 0);
                return i + 1;
            },
            2 => {
                if (try sub.u16At(0) != 1) return null;
                const index = coverage(offset16(sub, 2) orelse return null, glyph) orelse return null;
                if (index >= try sub.u16At(4)) return null;
                const sequence = offset16(sub, 6 + 2 * @as(usize, index)) orelse return null;
                const count = try sequence.u16At(0);
                if (count == 1) {
                    self.setGlyph(&self.buffer.items[i], try sequence.u16At(2), 0);
                    return i + 1;
                }
                if (count == 0) {
                    // Deleting is outside the specification, but fonts rely on it.
                    _ = self.buffer.orderedRemove(i);
                    return i;
                }
                if (self.buffer.items.len + count > self.max_len) return null;
                const original = self.buffer.items[i];
                const guess: u32 = if (original.props & ligature_glyph != 0) base_glyph else 0;
                const parts = try self.a.alloc(Info, count);
                defer self.a.free(parts);
                for (parts, 0..) |*part, k| {
                    part.* = original;
                    self.setGlyph(part, try sequence.u16At(2 + 2 * k), guess);
                    part.multiplied = true;
                    part.lig_id = 0;
                    part.lig_comp = @intCast(@min(k, 255));
                }
                self.buffer.replaceRange(self.a, i, 1, parts) catch return error.OutOfMemory;
                return i + count;
            },
            3 => {
                if (try sub.u16At(0) != 1) return null;
                const index = coverage(offset16(sub, 2) orelse return null, glyph) orelse return null;
                if (index >= try sub.u16At(4)) return null;
                const set = offset16(sub, 6 + 2 * @as(usize, index)) orelse return null;
                if (try set.u16At(0) == 0) return null;
                self.setGlyph(&self.buffer.items[i], try set.u16At(2), 0);
                return i + 1;
            },
            4 => {
                if (try sub.u16At(0) != 1) return null;
                const index = coverage(offset16(sub, 2) orelse return null, glyph) orelse return null;
                if (index >= try sub.u16At(4)) return null;
                const set = offset16(sub, 6 + 2 * @as(usize, index)) orelse return null;
                const count = try set.u16At(0);
                for (0..count) |k| {
                    const ligature = offset16(set, 2 + 2 * k) orelse continue;
                    const components = try ligature.u16At(2);
                    if (components == 0) continue;
                    var positions: [max_context]usize = undefined;
                    const rest: Sequence = .{ .kind = .glyphs, .data = try ligature.from(4) };
                    if (!self.matchInput(i, rest, components, &positions)) continue;
                    self.ligate(positions[0..components], try ligature.u16At(0));
                    return i + 1;
                }
                return null;
            },
            5, 6 => return self.contextual(kind == 6, sub, i),
            7 => {
                if (try sub.u16At(0) != 1) return null;
                const inner = try sub.u16At(2);
                if (inner == 7) return null;
                return self.substitute(inner, try sub.from(try sub.u32At(4)), i);
            },
            8 => {
                if (self.nesting != 0 or try sub.u16At(0) != 1) return null;
                const index = coverage(offset16(sub, 2) orelse return null, glyph) orelse return null;
                const backtrack = try sub.u16At(4);
                const lookahead_at = 6 + 2 * @as(usize, backtrack);
                const lookahead = try sub.u16At(lookahead_at);
                const substitutes_at = lookahead_at + 2 + 2 * @as(usize, lookahead);
                if (index >= try sub.u16At(substitutes_at)) return null;
                if (!self.matchBacktrack(i, .{ .kind = .coverages, .data = try sub.from(6), .base = sub }, backtrack)) return null;
                if (!self.matchLookahead(i, .{ .kind = .coverages, .data = try sub.from(lookahead_at + 2), .base = sub }, lookahead)) return null;
                self.setGlyph(&self.buffer.items[i], try sub.u16At(substitutes_at + 2 + 2 * @as(usize, index)), 0);
                return i + 1;
            },
            else => return null,
        }
    }

    fn allocateLigId(self: *Shaper) u8 {
        self.next_lig_id +%= 1;
        if (self.next_lig_id == 0) self.next_lig_id = 1;
        return self.next_lig_id;
    }

    fn ligate(self: *Shaper, positions: []const usize, glyph: u32) void {
        const items = self.buffer.items;
        const first = positions[0];
        if (positions.len == 1) {
            self.setGlyph(&items[first], glyph, 0);
            return;
        }
        var mark_ligature = true;
        for (positions) |p| mark_ligature = mark_ligature and items[p].isMark();
        const lig_id: u8 = if (mark_ligature) 0 else self.allocateLigId();
        self.mergeClusters(first, positions[positions.len - 1] + 1);
        self.setGlyph(&items[first], glyph, if (mark_ligature) 0 else ligature_glyph);
        items[first].lig_id = lig_id;
        items[first].lig_comp = 0;
        items[first].multiplied = false;
        // Marks skipped between components attach to the component before them.
        for (positions[1..], 1..) |p, component| {
            if (mark_ligature) break;
            for (positions[component - 1] + 1..p) |k| {
                items[k].lig_id = lig_id;
                items[k].lig_comp = @intCast(@min(component, 255));
            }
        }
        var k = positions.len;
        while (k > 1) {
            k -= 1;
            _ = self.buffer.orderedRemove(positions[k]);
        }
    }

    /// Gives glyphs `start..end` one cluster, extended over neighbors already sharing an end's cluster.
    fn mergeClusters(self: *Shaper, start_in: usize, end_in: usize) void {
        const items = self.buffer.items;
        if (end_in - start_in < 2) return;
        var start = start_in;
        var end = end_in;
        var cluster = items[start].cluster;
        for (items[start..end]) |item| cluster = @min(cluster, item.cluster);
        while (end < items.len and items[end - 1].cluster == items[end].cluster) end += 1;
        while (start > 0 and items[start - 1].cluster == items[start].cluster) start -= 1;
        for (items[start..end]) |*item| item.cluster = cluster;
    }

    // ------------------------------------------------------- Contextual

    fn contextual(self: *Shaper, chained: bool, sub: Bytes, i: usize) Error!?usize {
        const glyph = self.buffer.items[i].glyph;
        const format = try sub.u16At(0);
        var positions: [max_context]usize = undefined;
        switch (format) {
            1, 2 => {
                const index = coverage(offset16(sub, 2) orelse return null, glyph) orelse return null;
                // Format 2 selects rule sets by the input class of the first glyph.
                var backtrack_classes: ?Bytes = null;
                var input_classes: ?Bytes = null;
                var lookahead_classes: ?Bytes = null;
                var set_index: usize = index;
                var sets_at: usize = 4;
                if (format == 2) {
                    if (chained) {
                        backtrack_classes = offset16(sub, 4);
                        input_classes = offset16(sub, 6);
                        lookahead_classes = offset16(sub, 8);
                        sets_at = 10;
                    } else {
                        input_classes = offset16(sub, 4);
                        sets_at = 6;
                    }
                    set_index = classOf(input_classes orelse return null, glyph);
                }
                if (set_index >= try sub.u16At(sets_at)) return null;
                const set = offset16(sub, sets_at + 2 + 2 * set_index) orelse return null;
                const kind: Sequence.Kind = if (format == 2) .classes else .glyphs;
                const rules = try set.u16At(0);
                for (0..rules) |r| {
                    const rule = offset16(set, 2 + 2 * r) orelse continue;
                    var at: usize = 0;
                    var backtrack: usize = 0;
                    var backtrack_data: Bytes = rule;
                    if (chained) {
                        backtrack = try rule.u16At(0);
                        backtrack_data = try rule.from(2);
                        at = 2 + 2 * backtrack;
                    }
                    const input = try rule.u16At(at);
                    if (input == 0) continue;
                    var lookahead: usize = 0;
                    var lookahead_data: Bytes = rule;
                    var records_count: usize = undefined;
                    var records: Bytes = undefined;
                    if (chained) {
                        const lookahead_at = at + 2 + 2 * (@as(usize, input) - 1);
                        lookahead = try rule.u16At(lookahead_at);
                        lookahead_data = try rule.from(lookahead_at + 2);
                        const records_at = lookahead_at + 2 + 2 * lookahead;
                        records_count = try rule.u16At(records_at);
                        records = try rule.from(records_at + 2);
                    } else {
                        records_count = try rule.u16At(at + 2);
                        records = try rule.from(at + 4 + 2 * (@as(usize, input) - 1));
                    }
                    const input_data = try rule.from(at + if (chained) @as(usize, 2) else 4);
                    if (!self.matchInput(i, .{ .kind = kind, .data = input_data, .classes = input_classes }, input, &positions)) continue;
                    if (!self.matchBacktrack(i, .{ .kind = kind, .data = backtrack_data, .classes = backtrack_classes }, backtrack)) continue;
                    if (!self.matchLookahead(positions[input - 1], .{ .kind = kind, .data = lookahead_data, .classes = lookahead_classes }, lookahead)) continue;
                    return self.applyRecords(&positions, input, records, records_count);
                }
                return null;
            },
            3 => {
                if (!chained) {
                    const input = try sub.u16At(2);
                    const records_count = try sub.u16At(4);
                    if (input == 0) return null;
                    if (coverage(offset16(sub, 6) orelse return null, glyph) == null) return null;
                    if (!self.matchInput(i, .{ .kind = .coverages, .data = try sub.from(8), .base = sub }, input, &positions)) return null;
                    return self.applyRecords(&positions, input, try sub.from(6 + 2 * @as(usize, input)), records_count);
                }
                const backtrack = try sub.u16At(2);
                const input_at = 4 + 2 * @as(usize, backtrack);
                const input = try sub.u16At(input_at);
                if (input == 0) return null;
                const lookahead_at = input_at + 2 + 2 * @as(usize, input);
                const lookahead = try sub.u16At(lookahead_at);
                const records_at = lookahead_at + 2 + 2 * @as(usize, lookahead);
                if (coverage(offset16(sub, input_at + 2) orelse return null, glyph) == null) return null;
                if (!self.matchInput(i, .{ .kind = .coverages, .data = try sub.from(input_at + 4), .base = sub }, input, &positions)) return null;
                if (!self.matchBacktrack(i, .{ .kind = .coverages, .data = try sub.from(4), .base = sub }, backtrack)) return null;
                if (!self.matchLookahead(positions[input - 1], .{ .kind = .coverages, .data = try sub.from(lookahead_at + 2), .base = sub }, lookahead)) return null;
                return self.applyRecords(&positions, input, try sub.from(records_at + 2), try sub.u16At(records_at));
            },
            else => return null,
        }
    }

    /// Applies sequence lookup records to matched input, tracking positions as
    /// nested substitutions change the glyph count (as HarfBuzz's apply_lookup).
    fn applyRecords(self: *Shaper, positions: *[max_context]usize, matched: usize, records: Bytes, record_count: usize) Error!?usize {
        var count: isize = @intCast(matched);
        var end: isize = @intCast(positions[matched - 1] + 1);
        for (0..record_count) |r| {
            const index: isize = try records.u16At(4 * r);
            const lookup = try records.u16At(4 * r + 2);
            if (index >= count) continue;
            const at = positions[@intCast(index)];
            if (at >= self.buffer.items.len) continue;
            const before: isize = @intCast(self.buffer.items.len);
            if (!self.applyNested(lookup, at)) continue;
            var delta: isize = @as(isize, @intCast(self.buffer.items.len)) - before;
            if (delta == 0) continue;
            end += delta;
            if (end <= @as(isize, @intCast(at))) {
                delta += @as(isize, @intCast(at)) - end;
                end = @intCast(at);
            }
            var following = index + 1;
            if (delta > 0) {
                if (delta + count > max_context) break;
            } else {
                delta = @max(delta, following - count);
                following -= delta;
            }
            // Shift later positions to make room for, or close over, changed glyphs.
            const tail: usize = @intCast(count - following);
            const from: usize = @intCast(following);
            const to: usize = @intCast(following + delta);
            if (to > from) {
                std.mem.copyBackwards(usize, positions[to..][0..tail], positions[from..][0..tail]);
            } else {
                std.mem.copyForwards(usize, positions[to..][0..tail], positions[from..][0..tail]);
            }
            following += delta;
            count += delta;
            var j: usize = @intCast(index + 1);
            while (j < following) : (j += 1) positions[j] = positions[j - 1] + 1;
            while (following < count) : (following += 1) {
                const k: usize = @intCast(following);
                positions[k] = @intCast(@as(isize, @intCast(positions[k])) + delta);
            }
        }
        return @intCast(@max(end, 0));
    }

    // ------------------------------------------------------ Positioning

    fn deviceDelta(self: *const Shaper, table: Bytes, offset: u16) i32 {
        if (offset == 0) return 0;
        const device = table.from(offset) catch return 0;
        const format = device.u16At(4) catch return 0;
        if (format == 0x8000) {
            const store = self.face.gdef.store orelse return 0;
            if (!nonzero(self.coords)) return 0;
            const delta = varDelta(store, device.u16At(0) catch return 0, device.u16At(2) catch return 0, self.coords);
            return self.emRound(delta);
        }
        if (format < 1 or format > 3 or self.ppem == 0) return 0;
        const start = device.u16At(0) catch return 0;
        const end = device.u16At(2) catch return 0;
        if (self.ppem < start or self.ppem > end) return 0;
        const s = self.ppem - start;
        const f: u5 = @intCast(format);
        const word = device.u16At(6 + 2 * @as(usize, s >> (4 - f))) catch return 0;
        const shift: u5 = @intCast(16 - (((s & ((@as(u32, 1) << (4 - f)) - 1)) + 1) << f));
        const bits: u32 = @as(u32, word) >> shift;
        const mask: u32 = @as(u32, 0xffff) >> @intCast(16 - (@as(u32, 1) << f));
        var delta: i32 = @intCast(bits & mask);
        if (delta >= @as(i32, @intCast((mask + 1) >> 1))) delta -= @intCast(mask + 1);
        if (delta == 0) return 0;
        return @intCast(@divTrunc(@as(i64, delta) * self.scale, self.ppem));
    }

    fn valueSize(format: u16) usize {
        return 2 * @as(usize, @popCount(format & 0xff));
    }

    fn applyValue(self: *Shaper, base: Bytes, format: u16, record: Bytes, item: *Info) Error!void {
        var at: usize = 0;
        if (format & 0x01 != 0) {
            item.x_offset +|= self.em(try record.i16At(at));
            at += 2;
        }
        if (format & 0x02 != 0) {
            item.y_offset +|= self.em(try record.i16At(at));
            at += 2;
        }
        if (format & 0x04 != 0) {
            item.x_advance +|= self.em(try record.i16At(at));
            at += 2;
        }
        // Vertical advances do not apply to horizontal text.
        if (format & 0x08 != 0) at += 2;
        if (format & 0x10 != 0) {
            item.x_offset +|= self.deviceDelta(base, try record.u16At(at));
            at += 2;
        }
        if (format & 0x20 != 0) {
            item.y_offset +|= self.deviceDelta(base, try record.u16At(at));
            at += 2;
        }
        if (format & 0x40 != 0) item.x_advance +|= self.deviceDelta(base, try record.u16At(at));
    }

    fn anchor(self: *const Shaper, table: Bytes) Error![2]f32 {
        const format = try table.u16At(0);
        var x = self.emFloat(@floatFromInt(try table.i16At(2)));
        var y = self.emFloat(@floatFromInt(try table.i16At(4)));
        if (format == 3) {
            x += @floatFromInt(self.deviceDelta(table, try table.u16At(6)));
            y += @floatFromInt(self.deviceDelta(table, try table.u16At(8)));
        }
        return .{ x, y };
    }

    fn position(self: *Shaper, kind: u16, sub: Bytes, i: usize) Error!?usize {
        const items = self.buffer.items;
        const glyph = items[i].glyph;
        switch (kind) {
            1 => {
                const index = coverage(offset16(sub, 2) orelse return null, glyph) orelse return null;
                const format = try sub.u16At(4);
                switch (try sub.u16At(0)) {
                    1 => try self.applyValue(sub, format, try sub.from(6), &items[i]),
                    2 => {
                        if (index >= try sub.u16At(6)) return null;
                        try self.applyValue(sub, format, try sub.from(8 + valueSize(format) * index), &items[i]);
                    },
                    else => return null,
                }
                return i + 1;
            },
            2 => {
                const index = coverage(offset16(sub, 2) orelse return null, glyph) orelse return null;
                const format1 = try sub.u16At(4);
                const format2 = try sub.u16At(6);
                const j = self.next(i, false) orelse return null;
                if (items[j].mask & self.mask == 0) return null;
                const second = items[j].glyph;
                const size1 = valueSize(format1);
                const size2 = valueSize(format2);
                switch (try sub.u16At(0)) {
                    1 => {
                        if (index >= try sub.u16At(8)) return null;
                        const set = offset16(sub, 10 + 2 * @as(usize, index)) orelse return null;
                        const record_size = 2 + size1 + size2;
                        var low: usize = 0;
                        var high: usize = try set.u16At(0);
                        while (low < high) {
                            const mid = low + (high - low) / 2;
                            const at = 2 + record_size * mid;
                            const value = try set.u16At(at);
                            if (value < second) {
                                low = mid + 1;
                            } else if (value > second) {
                                high = mid;
                            } else {
                                try self.applyValue(set, format1, try set.from(at + 2), &items[i]);
                                try self.applyValue(set, format2, try set.from(at + 2 + size1), &items[j]);
                                return if (format2 != 0) j + 1 else j;
                            }
                        }
                        return null;
                    },
                    2 => {
                        const class1 = classOf(offset16(sub, 8) orelse return null, glyph);
                        const class2 = classOf(offset16(sub, 10) orelse return null, second);
                        const count1 = try sub.u16At(12);
                        const count2 = try sub.u16At(14);
                        if (class1 >= count1 or class2 >= count2) return null;
                        const at = 16 + (size1 + size2) * (@as(usize, class1) * count2 + class2);
                        try self.applyValue(sub, format1, try sub.from(at), &items[i]);
                        try self.applyValue(sub, format2, try sub.from(at + size1), &items[j]);
                        return if (format2 != 0) j + 1 else j;
                    },
                    else => return null,
                }
            },
            3 => {
                if (try sub.u16At(0) != 1) return null;
                const cover = offset16(sub, 2) orelse return null;
                const count = try sub.u16At(4);
                const this_index = coverage(cover, glyph) orelse return null;
                if (this_index >= count) return null;
                const entry = offset16(sub, 6 + 4 * @as(usize, this_index)) orelse return null;
                const p = self.prev(i, false) orelse return null;
                const prev_index = coverage(cover, items[p].glyph) orelse return null;
                if (prev_index >= count) return null;
                const exit = offset16(sub, 6 + 4 * @as(usize, prev_index) + 2) orelse return null;
                const exit_point = try self.anchor(exit);
                const entry_point = try self.anchor(entry);
                const exit_x: i32 = @intFromFloat(@round(exit_point[0]));
                const entry_x: i32 = @intFromFloat(@round(entry_point[0]));
                switch (self.direction) {
                    .ltr => {
                        items[p].x_advance = exit_x +| items[p].x_offset;
                        const d = entry_x +| items[i].x_offset;
                        items[i].x_advance -|= d;
                        items[i].x_offset -|= d;
                    },
                    .rtl => {
                        const d = exit_x +| items[p].x_offset;
                        items[p].x_advance -|= d;
                        items[p].x_offset -|= d;
                        items[i].x_advance = entry_x +| items[i].x_offset;
                    },
                }
                var child = p;
                var parent = i;
                var y_offset: i32 = @intFromFloat(@round(entry_point[1] - exit_point[1]));
                if (self.props & 0x01 == 0) {
                    child = i;
                    parent = p;
                    y_offset = -y_offset;
                }
                items[child].attach = .cursive;
                items[child].chain = @intCast(@as(isize, @intCast(parent)) - @as(isize, @intCast(child)));
                items[child].y_offset = y_offset;
                if (items[parent].chain == -items[child].chain) {
                    items[parent].chain = 0;
                    items[parent].y_offset = 0;
                }
                return i + 1;
            },
            4, 5, 6 => {
                if (try sub.u16At(0) != 1) return null;
                const mark_index = coverage(offset16(sub, 2) orelse return null, glyph) orelse return null;
                const class_count = try sub.u16At(6);
                const marks = offset16(sub, 8) orelse return null;
                const attached = offset16(sub, 10) orelse return null;
                if (mark_index >= try marks.u16At(0)) return null;
                const class = try marks.u16At(2 + 4 * @as(usize, mark_index));
                if (class >= class_count) return null;
                const mark_anchor = offset16(marks, 2 + 4 * @as(usize, mark_index) + 2) orelse return null;
                const saved = self.props;
                defer self.props = saved;
                // Bases and ligatures are found past marks; marks attach to the previous mark.
                self.props = if (kind == 6) saved & ~ignore_flags else 0x08;
                var j = self.prev(i, false) orelse return null;
                // A mark attaches to the first glyph of a multiple substitution, not later parts.
                while (kind == 4 and items[j].multiplied and items[j].lig_comp != 0 and j > 0) {
                    const before = items[j - 1];
                    if (before.isMark() or !before.multiplied or before.lig_id != items[j].lig_id or @as(u16, before.lig_comp) + 1 != items[j].lig_comp) break;
                    j = self.prev(j, false) orelse return null;
                }
                self.props = saved;
                const target = coverage(offset16(sub, 4) orelse return null, items[j].glyph) orelse return null;
                if (target >= try attached.u16At(0)) return null;
                var anchor_table: Bytes = undefined;
                switch (kind) {
                    4 => anchor_table = offset16(attached, 2 + 2 * (@as(usize, target) * class_count + class)) orelse return null,
                    5 => {
                        const ligature = offset16(attached, 2 + 2 * @as(usize, target)) orelse return null;
                        const components = try ligature.u16At(0);
                        if (components == 0) return null;
                        const mark = items[i];
                        const lig = items[j];
                        const component: usize = if (lig.lig_id != 0 and lig.lig_id == mark.lig_id and mark.lig_comp > 0) @min(components, mark.lig_comp) - 1 else components - 1;
                        anchor_table = offset16(ligature, 2 + 2 * (component * class_count + class)) orelse return null;
                    },
                    else => {
                        if (!items[j].isMark()) return null;
                        const id1 = items[i].lig_id;
                        const id2 = items[j].lig_id;
                        const comp1 = items[i].lig_comp;
                        const comp2 = items[j].lig_comp;
                        const good = if (id1 == id2) (id1 == 0 or comp1 == comp2) else ((id1 > 0 and comp1 == 0) or (id2 > 0 and comp2 == 0));
                        if (!good) return null;
                        anchor_table = offset16(attached, 2 + 2 * (@as(usize, target) * class_count + class)) orelse return null;
                    },
                }
                const mark_point = try self.anchor(mark_anchor);
                const base_point = try self.anchor(anchor_table);
                items[i].x_offset = @intFromFloat(@round(base_point[0] - mark_point[0]));
                items[i].y_offset = @intFromFloat(@round(base_point[1] - mark_point[1]));
                items[i].attach = .mark;
                items[i].chain = @intCast(@as(isize, @intCast(j)) - @as(isize, @intCast(i)));
                return i + 1;
            },
            7, 8 => return self.contextual(kind == 8, sub, i),
            9 => {
                if (try sub.u16At(0) != 1) return null;
                const inner = try sub.u16At(2);
                if (inner == 9) return null;
                return self.position(inner, try sub.from(try sub.u32At(4)), i);
            },
            else => return null,
        }
    }

    /// Resolves attachment chains into offsets relative to each glyph's pen position.
    fn propagate(self: *Shaper, i: usize, depth: u8) void {
        const items = self.buffer.items;
        const chain = items[i].chain;
        if (chain == 0 or depth > 32) return;
        items[i].chain = 0;
        const target = @as(isize, @intCast(i)) + chain;
        if (target < 0 or target >= items.len) return;
        const j: usize = @intCast(target);
        self.propagate(j, depth + 1);
        if (items[i].attach == .cursive) {
            items[i].y_offset +|= items[j].y_offset;
            return;
        }
        items[i].x_offset +|= items[j].x_offset;
        items[i].y_offset += items[j].y_offset;
        if (j >= i) return;
        if (self.direction == .ltr) {
            for (items[j..i]) |item| items[i].x_offset -|= item.x_advance;
        } else {
            for (items[j + 1 .. i + 1]) |item| items[i].x_offset +|= item.x_advance;
        }
    }

    // ------------------------------------------------------ Preparation

    fn spaceType(cp: u21) Space {
        return switch (cp) {
            0x00A0, 0x1680 => .space,
            0x2000, 0x2002 => .em_2,
            0x2001, 0x2003, 0x3000 => .em,
            0x2004 => .em_3,
            0x2005 => .em_4,
            0x2006 => .em_6,
            0x2007 => .figure,
            0x2008 => .punctuation,
            0x2009 => .em_5,
            0x200A => .em_16,
            0x202F => .narrow,
            0x205F => .em_4_18,
            else => .none,
        };
    }

    fn hasGlyph(self: *const Shaper, cp: u21) bool {
        return self.nominal(cp) != 0;
    }

    /// Appends a character, decomposed when the font lacks it but has its parts.
    fn decompose(self: *Shaper, out: *std.ArrayList(Info), item: Info, depth: u8) !bool {
        if (depth > 8) return false;
        const parts = unicode.decomposeCanonical(item.cp) orelse return false;
        for (parts) |part| {
            if (self.hasGlyph(part)) continue;
            if (unicode.decomposeCanonical(part) == null) return false;
        }
        for (parts, 0..) |part, k| {
            var piece = item;
            piece.cp = part;
            if (k > 0) piece.continuation = true;
            if (self.hasGlyph(part)) {
                try out.append(self.a, piece);
            } else if (!try self.decompose(out, piece, depth + 1)) return false;
        }
        return true;
    }

    /// HarfBuzz's normalization in its composed-diacritics mode: decompose
    /// what the font cannot show, order marks canonically, and recompose
    /// pairs the font has a precomposed glyph for.
    fn normalize(self: *Shaper) !void {
        var out: std.ArrayList(Info) = .empty;
        defer out.deinit(self.a);
        try out.ensureTotalCapacity(self.a, self.buffer.items.len);
        for (self.buffer.items) |item| {
            // A variation sequence the font maps becomes one glyph; otherwise the
            // selector stays for GSUB and is hidden after it.
            if (isVariationSelector(item.cp)) {
                if (out.items.len > 0) {
                    const base = &out.items[out.items.len - 1];
                    if (!isVariationSelector(base.cp) and base.preset == 0) if (self.face.variationGlyph(base.cp, item.cp)) |glyph| {
                        base.preset = glyph;
                        continue;
                    };
                }
                try out.append(self.a, item);
                continue;
            }
            if (self.hasGlyph(item.cp)) {
                try out.append(self.a, item);
                continue;
            }
            const mark = out.items.len;
            if (try self.decompose(&out, item, 0)) continue;
            out.shrinkRetainingCapacity(mark);
            var fallback = item;
            const space = spaceType(item.cp);
            if (space != .none and self.hasGlyph(' ')) {
                fallback.space = space;
            } else if (item.cp == 0x2011 and self.hasGlyph(0x2010)) {
                fallback.cp = 0x2010;
            }
            try out.append(self.a, fallback);
        }
        // Canonical ordering of mark sequences.
        const items = out.items;
        var i: usize = 0;
        while (i < items.len) {
            if (unicode.combiningClass(items[i].cp) == 0) {
                i += 1;
                continue;
            }
            var end = i;
            while (end < items.len and unicode.combiningClass(items[end].cp) != 0) end += 1;
            if (end - i <= 32) std.sort.insertion(Info, items[i..end], {}, struct {
                fn less(_: void, x: Info, y: Info) bool {
                    return unicode.combiningClass(x.cp) < unicode.combiningClass(y.cp);
                }
            }.less);
            i = end;
        }
        // Recompose marks onto their starter where the font has the result.
        self.buffer.clearRetainingCapacity();
        var starter: ?usize = null;
        for (items) |item| {
            const class = unicode.combiningClass(item.cp);
            if (starter) |s| if (unicode.isMark(item.cp) and item.space == .none) {
                const last = self.buffer.items[self.buffer.items.len - 1];
                const blocked = self.buffer.items.len - 1 != s and unicode.combiningClass(last.cp) >= class;
                if (!blocked) if (unicode.composePair(self.buffer.items[s].cp, item.cp)) |composed| if (self.hasGlyph(composed)) {
                    self.buffer.items[s].cp = composed;
                    continue;
                };
            };
            try self.buffer.append(self.a, item);
            if (class == 0) starter = self.buffer.items.len - 1;
        }
    }

    /// Positional forms for joining scripts, from HarfBuzz's Arabic state machine.
    fn joinArabic(self: *Shaper, text: []const u8, start: usize, end: usize) void {
        const Action = enum(u8) { isol, fina, fin2, fin3, medi, med2, init, none };
        const Entry = struct { prev: Action, curr: Action, next: u8 };
        const n = Action.none;
        const table = [7][6]Entry{
            .{ .{ .prev = n, .curr = n, .next = 0 }, .{ .prev = n, .curr = .isol, .next = 2 }, .{ .prev = n, .curr = .isol, .next = 1 }, .{ .prev = n, .curr = .isol, .next = 2 }, .{ .prev = n, .curr = .isol, .next = 1 }, .{ .prev = n, .curr = .isol, .next = 6 } },
            .{ .{ .prev = n, .curr = n, .next = 0 }, .{ .prev = n, .curr = .isol, .next = 2 }, .{ .prev = n, .curr = .isol, .next = 1 }, .{ .prev = n, .curr = .isol, .next = 2 }, .{ .prev = n, .curr = .fin2, .next = 5 }, .{ .prev = n, .curr = .isol, .next = 6 } },
            .{ .{ .prev = n, .curr = n, .next = 0 }, .{ .prev = n, .curr = .isol, .next = 2 }, .{ .prev = .init, .curr = .fina, .next = 1 }, .{ .prev = .init, .curr = .fina, .next = 3 }, .{ .prev = .init, .curr = .fina, .next = 4 }, .{ .prev = .init, .curr = .fina, .next = 6 } },
            .{ .{ .prev = n, .curr = n, .next = 0 }, .{ .prev = n, .curr = .isol, .next = 2 }, .{ .prev = .medi, .curr = .fina, .next = 1 }, .{ .prev = .medi, .curr = .fina, .next = 3 }, .{ .prev = .medi, .curr = .fina, .next = 4 }, .{ .prev = .medi, .curr = .fina, .next = 6 } },
            .{ .{ .prev = n, .curr = n, .next = 0 }, .{ .prev = n, .curr = .isol, .next = 2 }, .{ .prev = .med2, .curr = .isol, .next = 1 }, .{ .prev = .med2, .curr = .isol, .next = 2 }, .{ .prev = .med2, .curr = .fin2, .next = 5 }, .{ .prev = .med2, .curr = .isol, .next = 6 } },
            .{ .{ .prev = n, .curr = n, .next = 0 }, .{ .prev = n, .curr = .isol, .next = 2 }, .{ .prev = .isol, .curr = .isol, .next = 1 }, .{ .prev = .isol, .curr = .isol, .next = 2 }, .{ .prev = .isol, .curr = .fin2, .next = 5 }, .{ .prev = .isol, .curr = .isol, .next = 6 } },
            .{ .{ .prev = n, .curr = n, .next = 0 }, .{ .prev = n, .curr = .isol, .next = 2 }, .{ .prev = n, .curr = .isol, .next = 1 }, .{ .prev = n, .curr = .isol, .next = 2 }, .{ .prev = n, .curr = .fin3, .next = 5 }, .{ .prev = n, .curr = .isol, .next = 6 } },
        };
        const column = struct {
            /// Joining type as a table column, or null for transparent characters.
            fn f(cp: u21) ?usize {
                return switch (unicode.joining(cp)) {
                    .non_joining => 0,
                    .left => 1,
                    .right => 2,
                    .dual, .causing => 3,
                    .alaph => 4,
                    .dalath_rish => 5,
                    .transparent => null,
                };
            }
        }.f;
        var state: u8 = 0;
        // Context before the run, nearest first.
        var at = start;
        var seen: usize = 0;
        while (at > 0 and seen < 5) {
            var s = at - 1;
            while (s > 0 and (text[s] & 0xc0) == 0x80) s -= 1;
            const cp = std.unicode.utf8Decode(text[s..at]) catch break;
            at = s;
            seen += 1;
            const col = column(cp) orelse continue;
            state = table[state][col].next;
            break;
        }
        const items = self.buffer.items;
        var actions = self.a.alloc(Action, items.len) catch return;
        defer self.a.free(actions);
        @memset(actions, .none);
        var previous: ?usize = null;
        for (items, 0..) |item, i| {
            const col = column(item.cp) orelse continue;
            const entry = table[state][col];
            if (entry.prev != .none) if (previous) |p| {
                actions[p] = entry.prev;
            };
            actions[i] = entry.curr;
            previous = i;
            state = entry.next;
        }
        // Context after the run.
        var view = std.unicode.Utf8View.initUnchecked(text[end..]).iterator();
        seen = 0;
        while (view.nextCodepoint()) |cp| : (seen += 1) {
            if (seen >= 5) break;
            const col = column(cp) orelse continue;
            const entry = table[state][col];
            if (entry.prev != .none) if (previous) |p| {
                actions[p] = entry.prev;
            };
            break;
        }
        for (items, actions) |*item, action| {
            if (action != .none) item.mask |= arabicMask(@backingInt(action));
        }
    }
};

/// An input, backtrack or lookahead sequence of a contextual rule.
const Sequence = struct {
    const Kind = enum { glyphs, classes, coverages };
    kind: Kind,
    data: Bytes,
    classes: ?Bytes = null,
    base: Bytes = .{ .data = &.{} },

    fn matches(self: Sequence, k: usize, glyph: u32) bool {
        const value = self.data.u16At(2 * k) catch return false;
        return switch (self.kind) {
            .glyphs => glyph == value,
            .classes => if (self.classes) |table| classOf(table, glyph) == value else value == 0,
            .coverages => coverage(self.base.from(value) catch return false, glyph) != null,
        };
    }
};

fn isExtendedPictographic(cp: u21) bool {
    return (cp >= 0x1F000 and cp <= 0x1FAFF) or (cp >= 0x2600 and cp <= 0x27BF) or cp == 0x2B50 or cp == 0x2B55 or cp == 0x00A9 or cp == 0x00AE or cp == 0x203C or cp == 0x2049 or cp == 0x2122;
}

/// Shapes `text[start..end]` in `direction` at `size` pixels per em with the
/// normalized variation coordinates `coords`. Glyphs come back in visual
/// order. The surrounding text is context for joining scripts.
pub fn shape(a: std.mem.Allocator, face: *Face, coords: []const f32, size: f64, text: []const u8, start: usize, end: usize, direction: Direction) ![]Glyph {
    if (!std.math.isFinite(size) or size <= 0 or size > 16384 or end > text.len) return error.InvalidText;
    if (start >= end) return a.alloc(Glyph, 0);
    const scale: i32 = @intFromFloat(@round(size * 64));
    const upem = face.font.units_per_em;
    var s: Shaper = .{
        .a = a,
        .face = face,
        .coords = coords,
        .scale = scale,
        .ppem = @intFromFloat(@round(size)),
        .mult = @divTrunc(@as(i64, scale) << 16, upem),
        .multf = @as(f32, @floatFromInt(scale)) / @as(f32, @floatFromInt(upem)),
        .direction = direction,
    };
    defer s.buffer.deinit(a);

    // Characters with Unicode properties and grapheme clusters.
    var script: ?u32 = null;
    var view = std.unicode.Utf8View.initUnchecked(text[start..end]).iterator();
    var offset: usize = start;
    var after_zwj = false;
    while (view.nextCodepointSlice()) |slice| {
        const cp = std.unicode.utf8Decode(slice) catch 0xFFFD;
        var item: Info = .{ .cp = cp, .cluster = @intCast(offset) };
        offset += slice.len;
        item.ignorable = unicode.isDefaultIgnorable(cp);
        item.zwj = cp == 0x200D;
        item.zwnj = cp == 0x200C;
        item.continuation = unicode.isMark(cp) or item.zwj or (cp >= 0x1F3FB and cp <= 0x1F3FF) or (cp >= 0xE0020 and cp <= 0xE007F) or (cp >= 0xFF9E and cp <= 0xFF9F) or (after_zwj and isExtendedPictographic(cp));
        after_zwj = item.zwj;
        if (s.buffer.items.len > 0 and item.continuation) item.cluster = s.buffer.items[s.buffer.items.len - 1].cluster;
        if (script == null) {
            const value = unicode.script(cp);
            if (value != iso("Zyyy") and value != iso("Zinh") and value != iso("Zzzz")) script = value;
        }
        try s.buffer.append(a, item);
    }
    // As HarfBuzz, substitutions may multiply the text 64 times, or to 16384 glyphs.
    s.max_len = @min(@max(64 * s.buffer.items.len, 16384), 1 << 20);
    const resolved_script = script orelse iso("Zzzz");
    // Text against its script's direction is shaped reversed, in visual order.
    if (script) |value| if ((direction == .rtl) != isRtlScript(value)) {
        std.mem.reverse(Info, s.buffer.items);
        s.direction = if (direction == .rtl) .ltr else .rtl;
    };
    try s.normalize();
    if (direction == .rtl) for (s.buffer.items) |*item| {
        const mirrored = unicode.mirror(item.cp) orelse {
            item.mask |= rtlm_mask;
            continue;
        };
        if (s.hasGlyph(mirrored)) item.cp = mirrored else item.mask |= rtlm_mask;
    };
    const plan = try face.planFor(resolved_script, direction, coords);
    if (plan.arabic) s.joinArabic(text, start, end);

    // Glyphs and their GDEF classes, synthesized from Unicode without them.
    const space_glyph = s.nominal(' ');
    for (s.buffer.items) |*item| {
        item.glyph = if (item.preset != 0) item.preset else if (item.space != .none) space_glyph else s.nominal(item.cp);
        item.props = if (face.gdef.classes != null) face.gdef.props(item.glyph) else if (unicode.category(item.cp) == .nonspacing_mark and !item.ignorable) mark_glyph else base_glyph;
    }
    if (face.gsub) |layout| s.applyPlan(layout, plan.gsub, false);

    // Default ignorables the font did not substitute are hidden.
    var i: usize = 0;
    while (i < s.buffer.items.len) {
        const item = &s.buffer.items[i];
        if (item.ignored()) {
            if (space_glyph == 0) {
                _ = s.buffer.orderedRemove(i);
                continue;
            }
            item.glyph = space_glyph;
        }
        i += 1;
    }

    // Advances, then GPOS.
    for (s.buffer.items) |*item| {
        item.x_advance = s.em(@intFromFloat(face.advance(item.glyph, coords)));
        switch (item.space) {
            .none, .space => {},
            .em, .em_2, .em_3, .em_4, .em_5, .em_6, .em_16 => {
                const n: i32 = switch (item.space) {
                    .em => 1,
                    .em_2 => 2,
                    .em_3 => 3,
                    .em_4 => 4,
                    .em_5 => 5,
                    .em_6 => 6,
                    else => 16,
                };
                item.x_advance = @divTrunc(scale + @divTrunc(n, 2), n);
            },
            .em_4_18 => item.x_advance = @intCast(@divTrunc(@as(i64, scale) * 4, 18)),
            .figure => for ('0'..'9' + 1) |digit| {
                const g = s.nominal(@intCast(digit));
                if (g != 0) {
                    item.x_advance = s.em(@intFromFloat(face.advance(g, coords)));
                    break;
                }
            },
            .punctuation => {
                const g = if (s.nominal('.') != 0) s.nominal('.') else s.nominal(',');
                if (g != 0) item.x_advance = s.em(@intFromFloat(face.advance(g, coords)));
            },
            .narrow => item.x_advance = @divTrunc(item.x_advance, 2),
        }
    }
    if (face.gpos) |layout| s.applyPlan(layout, plan.gpos, true);
    for (s.buffer.items) |*item| {
        if (item.isMark()) {
            item.x_advance = 0;
            item.y_advance = 0;
        }
        if (item.ignored()) {
            item.x_advance = 0;
            item.y_advance = 0;
            item.x_offset = 0;
            item.y_offset = 0;
        }
    }
    for (0..s.buffer.items.len) |k| s.propagate(k, 0);
    if (s.direction == .rtl) std.mem.reverse(Info, s.buffer.items);

    const glyphs = try a.alloc(Glyph, s.buffer.items.len);
    for (s.buffer.items, glyphs) |item, *glyph| glyph.* = .{
        .id = item.glyph,
        .cluster = item.cluster,
        .x_advance = item.x_advance,
        .y_advance = item.y_advance,
        .x_offset = item.x_offset,
        .y_offset = item.y_offset,
    };
    return glyphs;
}

test "coverage and class definitions in both formats" {
    const list = [_]u8{ 0, 1, 0, 3, 0, 5, 0, 9, 0, 20 };
    try std.testing.expectEqual(@as(?u16, 1), coverage(.{ .data = &list }, 9));
    try std.testing.expectEqual(@as(?u16, null), coverage(.{ .data = &list }, 10));
    const ranges = [_]u8{ 0, 2, 0, 2, 0, 10, 0, 19, 0, 0, 0, 30, 0, 31, 0, 10 };
    try std.testing.expectEqual(@as(?u16, 5), coverage(.{ .data = &ranges }, 15));
    try std.testing.expectEqual(@as(?u16, 11), coverage(.{ .data = &ranges }, 31));
    try std.testing.expectEqual(@as(?u16, null), coverage(.{ .data = &ranges }, 25));
    const classes1 = [_]u8{ 0, 1, 0, 4, 0, 2, 0, 7, 0, 8 };
    try std.testing.expectEqual(@as(u16, 8), classOf(.{ .data = &classes1 }, 5));
    try std.testing.expectEqual(@as(u16, 0), classOf(.{ .data = &classes1 }, 6));
    const classes2 = [_]u8{ 0, 2, 0, 1, 0, 10, 0, 20, 0, 3 };
    try std.testing.expectEqual(@as(u16, 3), classOf(.{ .data = &classes2 }, 20));
    try std.testing.expectEqual(@as(u16, 0), classOf(.{ .data = &classes2 }, 21));
}

test "script tags prefer new Indic tags and fall back to the default script" {
    try std.testing.expectEqual(tag("latn"), scriptTags(iso("Latn"))[0]);
    try std.testing.expectEqual(tag("dev2"), scriptTags(iso("Deva"))[0]);
    try std.testing.expectEqual(tag("deva"), scriptTags(iso("Deva"))[1]);
    try std.testing.expectEqual(tag("kana"), scriptTags(iso("Hira"))[0]);
    try std.testing.expectEqual(tag("DFLT"), scriptTags(iso("Zyyy"))[0]);
}

test "Unicode properties used for shaping" {
    try std.testing.expectEqual(iso("Arab"), unicode.script(0x0646));
    try std.testing.expectEqual(iso("Latn"), unicode.script('a'));
    try std.testing.expectEqual(iso("Zyyy"), unicode.script(' '));
    try std.testing.expectEqual(unicode.Joining.dual, unicode.joining(0x0646));
    try std.testing.expectEqual(unicode.Joining.right, unicode.joining(0x0627));
    try std.testing.expectEqual(unicode.Joining.transparent, unicode.joining(0x064E));
    try std.testing.expectEqual(unicode.Joining.non_joining, unicode.joining('a'));
    try std.testing.expectEqual(@as(?u21, ')'), unicode.mirror('('));
    try std.testing.expect(unicode.isDefaultIgnorable(0x200D));
    try std.testing.expect(!unicode.isDefaultIgnorable('a'));
    try std.testing.expectEqual(unicode.Category.nonspacing_mark, unicode.category(0x0301));
    try std.testing.expectEqual(unicode.Category.space, unicode.category(0x2009));
}
