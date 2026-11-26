//! Generates Zig tables from the Unicode Character Database for
//! desktop-unicode.zig: lowercase and uppercase mappings, full case folding, decompositions,
//! canonical combining classes and canonical compositions; and for
//! desktop-shape.zig: scripts, general categories that shaping distinguishes,
//! default ignorables, Arabic joining types and bidi mirroring.
//!
//! Usage: unicode-tables UnicodeData.txt CaseFolding.txt DerivedNormalizationProps.txt
//!        Scripts.txt PropertyValueAliases.txt DerivedCoreProperties.txt
//!        ArabicShaping.txt BidiMirroring.txt output.zig
const std = @import("std");

const Decomposition = struct { cp: u21, compat: bool, chars: []const u21 };
const Range = struct { first: u21, last: u21, value: u32 };

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 10) return error.Usage;
    const cwd = std.Io.Dir.cwd();
    const unicode_data = try cwd.readFileAlloc(io, args[1], a, .limited(16 << 20));
    const case_folding = try cwd.readFileAlloc(io, args[2], a, .limited(16 << 20));
    const normalization = try cwd.readFileAlloc(io, args[3], a, .limited(16 << 20));
    const scripts = try cwd.readFileAlloc(io, args[4], a, .limited(16 << 20));
    const aliases = try cwd.readFileAlloc(io, args[5], a, .limited(16 << 20));
    const core = try cwd.readFileAlloc(io, args[6], a, .limited(16 << 20));
    const arabic = try cwd.readFileAlloc(io, args[7], a, .limited(16 << 20));
    const mirroring = try cwd.readFileAlloc(io, args[8], a, .limited(16 << 20));

    var lower: std.ArrayList([2]u21) = .empty;
    var upper: std.ArrayList([2]u21) = .empty;
    var classes: std.ArrayList([2]u21) = .empty;
    var decompositions: std.ArrayList(Decomposition) = .empty;
    // Categories the shaper distinguishes: 1 Mn, 2 Mc, 3 Me, 4 Cf, 5 Zs.
    var categories: std.ArrayList(Range) = .empty;
    var lines = std.mem.splitScalar(u8, unicode_data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields: [15][]const u8 = undefined;
        var parts = std.mem.splitScalar(u8, line, ';');
        for (&fields) |*field| field.* = parts.next() orelse "";
        const cp = try std.fmt.parseInt(u21, fields[0], 16);
        const category: u32 = for ([_][]const u8{ "Mn", "Mc", "Me", "Cf", "Zs" }, 1..) |name, value| {
            if (std.mem.eql(u8, fields[2], name)) break @intCast(value);
        } else 0;
        if (category != 0) try appendRange(a, &categories, cp, cp, category);
        const class = try std.fmt.parseInt(u8, fields[3], 10);
        if (class != 0) try classes.append(a, .{ cp, class });
        if (fields[13].len > 0) try lower.append(a, .{ cp, try std.fmt.parseInt(u21, fields[13], 16) });
        if (fields[12].len > 0) try upper.append(a, .{ cp, try std.fmt.parseInt(u21, fields[12], 16) });
        if (fields[5].len > 0) {
            var text = fields[5];
            const compat = text[0] == '<';
            if (compat) text = text[(std.mem.indexOfScalar(u8, text, '>') orelse return error.InvalidData) + 1 ..];
            try decompositions.append(a, .{ .cp = cp, .compat = compat, .chars = try codepoints(a, text) });
        }
    }

    var folds: std.ArrayList(struct { cp: u21, chars: []const u21 }) = .empty;
    lines = std.mem.splitScalar(u8, case_folding, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw[0 .. std.mem.indexOfScalar(u8, raw, '#') orelse raw.len], " ");
        if (line.len == 0) continue;
        var parts = std.mem.splitSequence(u8, line, "; ");
        const cp = try std.fmt.parseInt(u21, parts.next().?, 16);
        const status = parts.next().?;
        const mapping = std.mem.trimEnd(u8, parts.next().?, ";");
        // Common and full foldings; simple (S) and Turkic (T) ones are alternatives.
        if (!std.mem.eql(u8, status, "C") and !std.mem.eql(u8, status, "F")) continue;
        try folds.append(a, .{ .cp = cp, .chars = try codepoints(a, mapping) });
    }

    var excluded: std.AutoHashMapUnmanaged(u21, void) = .empty;
    lines = std.mem.splitScalar(u8, normalization, '\n');
    while (lines.next()) |raw| {
        const line = raw[0 .. std.mem.indexOfScalar(u8, raw, '#') orelse raw.len];
        var parts = std.mem.splitScalar(u8, line, ';');
        const range = std.mem.trim(u8, parts.next() orelse continue, " ");
        const property = std.mem.trim(u8, parts.next() orelse continue, " ");
        if (!std.mem.eql(u8, property, "Full_Composition_Exclusion")) continue;
        const dots = std.mem.indexOf(u8, range, "..");
        const first = try std.fmt.parseInt(u21, range[0 .. dots orelse range.len], 16);
        const last = if (dots) |at| try std.fmt.parseInt(u21, range[at + 2 ..], 16) else first;
        var cp = first;
        while (cp <= last) : (cp += 1) try excluded.put(a, cp, {});
    }

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "//! Generated by tools/unicode-tables.zig from the Unicode Character Database.\n");
    try out.appendSlice(a, "pub const Mapping = struct { cp: u21, to: u21 };\n");
    try out.appendSlice(a, "pub const Expansion = struct { cp: u21, compat: bool = false, start: u16, len: u8 };\n");
    try out.appendSlice(a, "pub const Class = struct { cp: u21, class: u8 };\n");
    try out.appendSlice(a, "pub const Composition = struct { first: u21, second: u21, composed: u21 };\n");
    try out.appendSlice(a, "pub const Range = struct { first: u21, last: u21, value: u32 };\n\n");

    try out.appendSlice(a, "pub const lower = [_]Mapping{\n");
    for (lower.items) |pair| try out.print(a, "    .{{ .cp = 0x{X}, .to = 0x{X} }},\n", .{ pair[0], pair[1] });
    try out.appendSlice(a, "};\n\npub const upper = [_]Mapping{\n");
    for (upper.items) |pair| try out.print(a, "    .{{ .cp = 0x{X}, .to = 0x{X} }},\n", .{ pair[0], pair[1] });
    try out.appendSlice(a, "};\n\npub const classes = [_]Class{\n");
    for (classes.items) |pair| try out.print(a, "    .{{ .cp = 0x{X}, .class = {d} }},\n", .{ pair[0], pair[1] });
    try out.appendSlice(a, "};\n\n");

    var data: std.ArrayList(u21) = .empty;
    try out.appendSlice(a, "pub const folds = [_]Expansion{\n");
    for (folds.items) |fold| {
        try out.print(a, "    .{{ .cp = 0x{X}, .start = {d}, .len = {d} }},\n", .{ fold.cp, data.items.len, fold.chars.len });
        try data.appendSlice(a, fold.chars);
    }
    try out.appendSlice(a, "};\n\npub const decompositions = [_]Expansion{\n");
    for (decompositions.items) |item| {
        try out.print(a, "    .{{ .cp = 0x{X}, .compat = {}, .start = {d}, .len = {d} }},\n", .{ item.cp, item.compat, data.items.len, item.chars.len });
        try data.appendSlice(a, item.chars);
    }
    try out.appendSlice(a, "};\n\npub const data = [_]u21{");
    for (data.items, 0..) |cp, i| try out.print(a, "{s}0x{X},", .{ if (i % 12 == 0) "\n    " else " ", cp });
    try out.appendSlice(a, "\n};\n\n");

    var compositions: std.ArrayList([3]u21) = .empty;
    for (decompositions.items) |item| {
        if (item.compat or item.chars.len != 2 or excluded.contains(item.cp)) continue;
        try compositions.append(a, .{ item.chars[0], item.chars[1], item.cp });
    }
    std.mem.sort([3]u21, compositions.items, {}, struct {
        fn less(_: void, x: [3]u21, y: [3]u21) bool {
            return if (x[0] != y[0]) x[0] < y[0] else x[1] < y[1];
        }
    }.less);
    try out.appendSlice(a, "pub const compositions = [_]Composition{\n");
    for (compositions.items) |item| try out.print(a, "    .{{ .first = 0x{X}, .second = 0x{X}, .composed = 0x{X} }},\n", .{ item[0], item[1], item[2] });
    try out.appendSlice(a, "};\n\n");

    // Script property: long value names map to ISO 15924 codes, stored as big-endian tags.
    var codes: std.StringHashMapUnmanaged(u32) = .empty;
    lines = std.mem.splitScalar(u8, aliases, '\n');
    while (lines.next()) |raw| {
        const line = raw[0 .. std.mem.indexOfScalar(u8, raw, '#') orelse raw.len];
        var parts = std.mem.splitScalar(u8, line, ';');
        if (!std.mem.eql(u8, std.mem.trim(u8, parts.next() orelse continue, " "), "sc")) continue;
        const code = std.mem.trim(u8, parts.next() orelse continue, " ");
        if (code.len != 4) return error.InvalidData;
        while (parts.next()) |name| try codes.put(a, std.mem.trim(u8, name, " "), std.mem.readInt(u32, code[0..4], .big));
    }
    var script_ranges: std.ArrayList(Range) = .empty;
    try parseProperty(a, scripts, &script_ranges, struct {
        map: *std.StringHashMapUnmanaged(u32),
        fn value(self: @This(), name: []const u8) !?u32 {
            return self.map.get(name) orelse error.InvalidData;
        }
    }{ .map = &codes });
    try emitRanges(a, &out, "scripts", script_ranges.items);
    try emitRanges(a, &out, "categories", categories.items);
    var ignorables: std.ArrayList(Range) = .empty;
    try parseProperty(a, core, &ignorables, struct {
        fn value(_: @This(), name: []const u8) !?u32 {
            return if (std.mem.eql(u8, name, "Default_Ignorable_Code_Point")) 1 else null;
        }
    }{});
    try emitRanges(a, &out, "ignorables", ignorables.items);

    // Joining types U L R D C T (0..5), with the Syriac groups shaping
    // distinguishes: Alaph 6 and Dalath/Rish 7.
    var joining: std.ArrayList(Range) = .empty;
    lines = std.mem.splitScalar(u8, arabic, '\n');
    while (lines.next()) |raw| {
        const line = raw[0 .. std.mem.indexOfScalar(u8, raw, '#') orelse raw.len];
        var parts = std.mem.splitScalar(u8, line, ';');
        const field = std.mem.trim(u8, parts.next() orelse continue, " ");
        if (field.len == 0) continue;
        const cp = try std.fmt.parseInt(u21, field, 16);
        _ = parts.next();
        const kind = std.mem.trim(u8, parts.next() orelse return error.InvalidData, " ");
        const group = std.mem.trim(u8, parts.next() orelse return error.InvalidData, " ");
        var value: u32 = switch (kind[0]) {
            'U' => 0,
            'L' => 1,
            'R' => 2,
            'D' => 3,
            'C' => 4,
            'T' => 5,
            else => return error.InvalidData,
        };
        if (std.mem.eql(u8, group, "ALAPH")) value = 6;
        if (std.mem.eql(u8, group, "DALATH RISH")) value = 7;
        try appendRange(a, &joining, cp, cp, value);
    }
    std.mem.sort(Range, joining.items, {}, rangeLess);
    try emitRanges(a, &out, "joining", joining.items);

    try out.appendSlice(a, "pub const mirrors = [_]Mapping{\n");
    lines = std.mem.splitScalar(u8, mirroring, '\n');
    while (lines.next()) |raw| {
        const line = raw[0 .. std.mem.indexOfScalar(u8, raw, '#') orelse raw.len];
        var parts = std.mem.splitScalar(u8, line, ';');
        const field = std.mem.trim(u8, parts.next() orelse continue, " ");
        if (field.len == 0) continue;
        const to = std.mem.trim(u8, parts.next() orelse return error.InvalidData, " ");
        try out.print(a, "    .{{ .cp = 0x{s}, .to = 0x{s} }},\n", .{ field, to });
    }
    try out.appendSlice(a, "};\n");

    try cwd.writeFile(io, .{ .sub_path = args[9], .data = out.items });
}

fn rangeLess(_: void, x: Range, y: Range) bool {
    return x.first < y.first;
}

/// Appends a range, merging it into the previous one when adjacent with the same value.
fn appendRange(a: std.mem.Allocator, list: *std.ArrayList(Range), first: u21, last: u21, value: u32) !void {
    if (list.items.len > 0) {
        const previous = &list.items[list.items.len - 1];
        if (previous.value == value and previous.last + 1 == first) {
            previous.last = last;
            return;
        }
    }
    try list.append(a, .{ .first = first, .last = last, .value = value });
}

/// Reads a "range ; value" property file; `mapper.value` returns null for lines to skip.
fn parseProperty(a: std.mem.Allocator, text: []const u8, list: *std.ArrayList(Range), mapper: anytype) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = raw[0 .. std.mem.indexOfScalar(u8, raw, '#') orelse raw.len];
        var parts = std.mem.splitScalar(u8, line, ';');
        const range = std.mem.trim(u8, parts.next() orelse continue, " ");
        if (range.len == 0) continue;
        const name = std.mem.trim(u8, parts.next() orelse continue, " ");
        const value = try mapper.value(name) orelse continue;
        const dots = std.mem.indexOf(u8, range, "..");
        const first = try std.fmt.parseInt(u21, range[0 .. dots orelse range.len], 16);
        const last = if (dots) |at| try std.fmt.parseInt(u21, range[at + 2 ..], 16) else first;
        try list.append(a, .{ .first = first, .last = last, .value = value });
    }
    std.mem.sort(Range, list.items, {}, rangeLess);
    // Merge adjacent ranges with equal values to keep lookups short.
    var merged: std.ArrayList(Range) = .empty;
    for (list.items) |item| try appendRange(a, &merged, item.first, item.last, item.value);
    list.* = merged;
}

fn emitRanges(a: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, ranges: []const Range) !void {
    try out.print(a, "pub const {s} = [_]Range{{\n", .{name});
    for (ranges) |range| try out.print(a, "    .{{ .first = 0x{X}, .last = 0x{X}, .value = 0x{X} }},\n", .{ range.first, range.last, range.value });
    try out.appendSlice(a, "};\n\n");
}

fn codepoints(a: std.mem.Allocator, text: []const u8) ![]const u21 {
    var list: std.ArrayList(u21) = .empty;
    var parts = std.mem.tokenizeScalar(u8, text, ' ');
    while (parts.next()) |part| try list.append(a, try std.fmt.parseInt(u21, part, 16));
    return list.toOwnedSlice(a);
}
