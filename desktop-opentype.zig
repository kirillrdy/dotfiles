//! OpenType font reading without FreeType: the sfnt container and collections,
//! character mapping, metadata, TrueType (glyf) and CFF/CFF2 outlines, and font
//! variations (fvar, avar, gvar and CFF2 blends). Outlines come out in font
//! units with y pointing up.
const std = @import("std");
const path = @import("desktop-path.zig");
const libc = @import("desktop-libc.zig");

pub const Error = error{ InvalidFont, Unsupported, OutOfMemory };

/// A read-only memory mapping of a font file.
pub const Mapped = struct {
    bytes: []const u8,

    pub fn open(file: [:0]const u8) ?Mapped {
        const linux = std.os.linux;
        const opened = linux.openat(linux.AT.FDCWD, file, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        if (linux.errno(opened) != .SUCCESS) return null;
        const fd: i32 = @intCast(opened);
        defer _ = linux.close(fd);
        const end = linux.lseek(fd, 0, linux.SEEK.END);
        if (linux.errno(end) != .SUCCESS or end < 12 or end > 1 << 30) return null;
        const memory = libc.mmap(null, end, libc.PROT_READ, libc.MAP_SHARED, fd, 0);
        if (memory == null or memory == libc.MAP_FAILED) return null;
        const start: [*]const u8 = @ptrCast(memory.?);
        return .{ .bytes = start[0..end] };
    }

    pub fn close(self: Mapped) void {
        _ = libc.munmap(@ptrCast(@constCast(self.bytes.ptr)), self.bytes.len);
    }

    /// The number of faces: a collection's count, else one.
    pub fn faces(self: Mapped) u32 {
        const file: Bytes = .{ .data = self.bytes };
        if ((file.u32At(0) catch return 0) != tag("ttcf")) return 1;
        return @min(file.u32At(8) catch 0, 256);
    }
};

/// Variable fonts in use have far fewer (Roboto Flex has 13); larger ones render
/// only at their default coordinates.
pub const max_axes = 64;

pub fn tagOf(text: *const [4]u8) u32 {
    return tag(text);
}

fn tag(text: *const [4]u8) u32 {
    return std.mem.readInt(u32, text, .big);
}

/// Bounds-checked big-endian reads.
pub const Bytes = struct {
    data: []const u8,

    pub fn slice(self: Bytes, offset: usize, length: usize) Error![]const u8 {
        if (offset > self.data.len or length > self.data.len - offset) return error.InvalidFont;
        return self.data[offset..][0..length];
    }
    pub fn from(self: Bytes, offset: usize) Error!Bytes {
        if (offset > self.data.len) return error.InvalidFont;
        return .{ .data = self.data[offset..] };
    }
    pub fn u8At(self: Bytes, offset: usize) Error!u8 {
        return (try self.slice(offset, 1))[0];
    }
    pub fn u16At(self: Bytes, offset: usize) Error!u16 {
        return std.mem.readInt(u16, (try self.slice(offset, 2))[0..2], .big);
    }
    pub fn i16At(self: Bytes, offset: usize) Error!i16 {
        return @bitCast(try self.u16At(offset));
    }
    pub fn u24At(self: Bytes, offset: usize) Error!u32 {
        return std.mem.readInt(u24, (try self.slice(offset, 3))[0..3], .big);
    }
    pub fn u32At(self: Bytes, offset: usize) Error!u32 {
        return std.mem.readInt(u32, (try self.slice(offset, 4))[0..4], .big);
    }
    pub fn f2dot14(self: Bytes, offset: usize) Error!f32 {
        return @as(f32, @floatFromInt(try self.i16At(offset))) / 16384;
    }
    pub fn fixed(self: Bytes, offset: usize) Error!f32 {
        return @as(f32, @floatFromInt(@as(i32, @bitCast(try self.u32At(offset))))) / 65536;
    }
};

pub const Axis = struct { tag: u32, min: f32, default: f32, max: f32 };

/// A face within a font file. `data` must outlive it.
pub const Font = struct {
    data: Bytes,
    units_per_em: u16 = 1000,
    num_glyphs: u16 = 0,
    long_loca: bool = false,
    cmap: ?Bytes = null,
    cmap_format: u16 = 0,
    glyf: ?Bytes = null,
    loca: ?Bytes = null,
    gvar: ?Bytes = null,
    cff: ?Cff = null,
    name: ?Bytes = null,
    os2: ?Bytes = null,
    head: Bytes = .{ .data = &.{} },
    avar: ?Bytes = null,
    color: bool = false,
    axes: [max_axes]Axis = undefined,
    axis_count: usize = 0,
    /// Offset of this face's table directory in `data`.
    directory: usize = 0,

    /// Opens face `index` of a font file or collection.
    pub fn init(data: []const u8, index: u32) Error!Font {
        const file: Bytes = .{ .data = data };
        var offset: usize = 0;
        if (try file.u32At(0) == tag("ttcf")) {
            if (index >= try file.u32At(8)) return error.InvalidFont;
            offset = try file.u32At(12 + 4 * @as(usize, index));
        } else if (index != 0) return error.InvalidFont;
        const version = try file.u32At(offset);
        if (version != 0x00010000 and version != tag("OTTO") and version != tag("true")) return error.Unsupported;
        var self: Font = .{ .data = file, .directory = offset };
        const count = try file.u16At(offset + 4);
        var cff1: ?Bytes = null;
        var cff2: ?Bytes = null;
        var fvar: ?Bytes = null;
        for (0..count) |i| {
            const record = offset + 12 + 16 * i;
            const table_tag = try file.u32At(record);
            const table: Bytes = .{ .data = try file.slice(try file.u32At(record + 8), try file.u32At(record + 12)) };
            switch (table_tag) {
                tag("head") => self.head = table,
                tag("maxp") => self.num_glyphs = try table.u16At(4),
                tag("cmap") => try self.selectCmap(table),
                tag("glyf") => self.glyf = table,
                tag("loca") => self.loca = table,
                tag("gvar") => self.gvar = table,
                tag("CFF ") => cff1 = table,
                tag("CFF2") => cff2 = table,
                tag("name") => self.name = table,
                tag("OS/2") => self.os2 = table,
                tag("fvar") => fvar = table,
                tag("avar") => self.avar = table,
                tag("CBDT"), tag("sbix"), tag("COLR") => self.color = true,
                else => {},
            }
        }
        if (self.head.data.len < 54) return error.InvalidFont;
        self.units_per_em = try self.head.u16At(18);
        if (self.units_per_em < 16 or self.units_per_em > 16384) return error.InvalidFont;
        self.long_loca = try self.head.i16At(50) != 0;
        if (fvar) |table| try self.readAxes(table);
        if (cff2) |table| self.cff = try Cff.init(table, true) else if (cff1) |table| self.cff = try Cff.init(table, false);
        return self;
    }

    /// The contents of table `table_tag` (see `tagOf`), if the face has it.
    pub fn findTable(self: *const Font, table_tag: u32) ?Bytes {
        const count = self.data.u16At(self.directory + 4) catch return null;
        for (0..count) |i| {
            const record = self.directory + 12 + 16 * i;
            if ((self.data.u32At(record) catch return null) != table_tag) continue;
            const start = self.data.u32At(record + 8) catch return null;
            const length = self.data.u32At(record + 12) catch return null;
            return .{ .data = self.data.slice(start, length) catch return null };
        }
        return null;
    }

    /// Whether glyphs have outlines this module can draw.
    pub fn scalable(self: *const Font) bool {
        return (self.glyf != null and self.loca != null) or self.cff != null;
    }

    fn selectCmap(self: *Font, table: Bytes) Error!void {
        const count = try table.u16At(2);
        var best: u32 = 0;
        for (0..count) |i| {
            const platform = try table.u16At(4 + 8 * i);
            const encoding = try table.u16At(6 + 8 * i);
            const sub = try table.from(try table.u32At(8 + 8 * i));
            const format = try sub.u16At(0);
            // Prefer full Unicode (format 12), then the BMP (format 4).
            const rank: u32 = switch (format) {
                12 => if ((platform == 3 and encoding == 10) or platform == 0) 3 else 0,
                4 => if ((platform == 3 and encoding == 1) or platform == 0) 2 else 0,
                else => 0,
            };
            if (rank > best) {
                best = rank;
                self.cmap = sub;
                self.cmap_format = format;
            }
        }
    }

    fn readAxes(self: *Font, table: Bytes) Error!void {
        const offset = try table.u16At(4);
        const count = try table.u16At(8);
        const size = try table.u16At(10);
        if (size < 20) return error.InvalidFont;
        self.axis_count = @min(count, max_axes);
        for (0..self.axis_count) |i| {
            const at = offset + size * i;
            const default = try table.fixed(at + 8);
            const low = try table.fixed(at + 4);
            const high = try table.fixed(at + 12);
            // Malformed ranges are widened to hold the default, so clamping stays valid.
            self.axes[i] = .{ .tag = try table.u32At(at), .min = @min(low, high, default), .default = default, .max = @max(low, high, default) };
        }
    }

    /// The glyph for a character, or 0.
    pub fn glyphIndex(self: *const Font, cp: u32) u32 {
        const table = self.cmap orelse return 0;
        return switch (self.cmap_format) {
            4 => format4(table, cp) catch 0,
            12 => format12(table, cp) catch 0,
            else => 0,
        };
    }

    fn format4(table: Bytes, cp: u32) Error!u32 {
        if (cp > 0xffff) return 0;
        const segments = (try table.u16At(6)) / 2;
        const ends = 14;
        const starts = ends + 2 * @as(usize, segments) + 2;
        const deltas = starts + 2 * @as(usize, segments);
        const ranges = deltas + 2 * @as(usize, segments);
        var low: usize = 0;
        var high: usize = segments;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const end = try table.u16At(ends + 2 * mid);
            if (end < cp) low = mid + 1 else high = mid;
        }
        if (low >= segments) return 0;
        const start = try table.u16At(starts + 2 * low);
        if (cp < start) return 0;
        const delta = try table.u16At(deltas + 2 * low);
        const range = try table.u16At(ranges + 2 * low);
        if (range == 0) return @as(u16, @truncate(cp +% delta));
        const glyph = try table.u16At(ranges + 2 * low + range + 2 * (cp - start));
        return if (glyph == 0) 0 else @as(u16, @truncate(glyph +% delta));
    }

    fn format12(table: Bytes, cp: u32) Error!u32 {
        const count = try table.u32At(12);
        var low: usize = 0;
        var high: usize = count;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const at = 16 + 12 * mid;
            const start = try table.u32At(at);
            const end = try table.u32At(at + 4);
            if (cp < start) high = mid else if (cp > end) low = mid + 1 else return std.math.add(u32, try table.u32At(at + 8), cp - start) catch error.InvalidFont;
        }
        return 0;
    }

    /// Normalized coordinates (-1..1, after avar) for design-space values per axis.
    pub fn normalize(self: *const Font, design: []const f32, out: []f32) void {
        for (out[0..self.axis_count], 0..) |*value, i| {
            const axis = self.axes[i];
            const v = std.math.clamp(if (i < design.len) design[i] else axis.default, axis.min, axis.max);
            value.* = if (v < axis.default) (if (axis.default > axis.min) (v - axis.default) / (axis.default - axis.min) else 0) else if (v > axis.default) (if (axis.max > axis.default) (v - axis.default) / (axis.max - axis.default) else 0) else 0;
        }
        if (self.avar) |table| avarMap(table, out[0..self.axis_count]) catch {};
        // Coordinates are F2Dot14 values in the font format.
        for (out[0..self.axis_count]) |*value| value.* = @round(value.* * 16384) / 16384;
    }

    fn avarMap(table: Bytes, coords: []f32) Error!void {
        var offset: usize = 8;
        const count = try table.u16At(6);
        for (0..count) |axis| {
            const pairs = try table.u16At(offset);
            offset += 2;
            if (axis < coords.len and pairs >= 2) {
                const v = coords[axis];
                var previous_from = try table.f2dot14(offset);
                var previous_to = try table.f2dot14(offset + 2);
                for (1..pairs) |p| {
                    const from_value = try table.f2dot14(offset + 4 * p);
                    const to_value = try table.f2dot14(offset + 4 * p + 2);
                    if (v <= from_value) {
                        if (v >= previous_from) coords[axis] = if (from_value == previous_from) to_value else previous_to + (v - previous_from) * (to_value - previous_to) / (from_value - previous_from);
                        break;
                    }
                    previous_from = from_value;
                    previous_to = to_value;
                }
            }
            offset += 4 * @as(usize, pairs);
        }
    }

    /// Appends a glyph outline in font units at normalized coordinates `coords`.
    pub fn outline(self: *const Font, a: std.mem.Allocator, glyph: u32, coords: []const f32, out: *path.Path) Error!void {
        if (glyph >= self.num_glyphs) return error.InvalidFont;
        if (self.cff) |*cff| return cff.outline(a, glyph, coords, self, out);
        if (self.glyf == null or self.loca == null) return error.Unsupported;
        var points: std.ArrayList(Point) = .empty;
        defer points.deinit(a);
        var ends: std.ArrayList(u16) = .empty;
        defer ends.deinit(a);
        try self.glyphPoints(a, glyph, coords, &points, &ends, 0);
        try emitQuadratic(a, points.items, ends.items, out);
    }

    // ------------------------------------------------------------ TrueType

    const Point = struct { x: f32, y: f32, on: bool };

    fn glyphData(self: *const Font, glyph: u32) Error![]const u8 {
        const loca = self.loca.?;
        const start: usize = if (self.long_loca) try loca.u32At(4 * glyph) else @as(usize, try loca.u16At(2 * glyph)) * 2;
        const end: usize = if (self.long_loca) try loca.u32At(4 * glyph + 4) else @as(usize, try loca.u16At(2 * glyph + 2)) * 2;
        if (end < start) return error.InvalidFont;
        return self.glyf.?.slice(start, end - start);
    }

    /// Appends a glyph's points (variations applied, composites resolved).
    fn glyphPoints(self: *const Font, a: std.mem.Allocator, glyph: u32, coords: []const f32, points: *std.ArrayList(Point), ends: *std.ArrayList(u16), depth: u32) Error!void {
        if (depth > 8 or glyph >= self.num_glyphs) return error.InvalidFont;
        const data: Bytes = .{ .data = try self.glyphData(glyph) };
        if (data.data.len == 0) return;
        const contours = try data.i16At(0);
        if (contours >= 0) {
            const base = points.items.len;
            var simple: std.ArrayList(Point) = .empty;
            defer simple.deinit(a);
            var simple_ends: std.ArrayList(u16) = .empty;
            defer simple_ends.deinit(a);
            try parseSimple(a, data, @intCast(contours), &simple, &simple_ends);
            try self.vary(a, glyph, coords, simple.items, simple_ends.items, null);
            try points.appendSlice(a, simple.items);
            for (simple_ends.items) |end| try ends.append(a, std.math.cast(u16, base + end) orelse return error.InvalidFont);
            return;
        }
        // Composite: each component's offset is one varied "point".
        var components: std.ArrayList(Component) = .empty;
        defer components.deinit(a);
        var offset: usize = 10;
        while (true) {
            const flags = try data.u16At(offset);
            var component: Component = .{ .glyph = try data.u16At(offset + 2) };
            offset += 4;
            if (flags & 0x0001 != 0) {
                // Offsets are signed words; point indices are unsigned.
                if (flags & 0x0002 != 0) {
                    component.arg1 = try data.i16At(offset);
                    component.arg2 = try data.i16At(offset + 2);
                } else {
                    component.arg1 = try data.u16At(offset);
                    component.arg2 = try data.u16At(offset + 2);
                }
                offset += 4;
            } else {
                const first = try data.u8At(offset);
                const second = try data.u8At(offset + 1);
                // Offsets are signed bytes; point indices are unsigned.
                component.arg1 = if (flags & 0x0002 != 0) @as(i8, @bitCast(first)) else first;
                component.arg2 = if (flags & 0x0002 != 0) @as(i8, @bitCast(second)) else second;
                offset += 2;
            }
            component.offsets = flags & 0x0002 != 0;
            if (flags & 0x0008 != 0) {
                const s = try data.f2dot14(offset);
                component.matrix = .{ s, 0, 0, s };
                offset += 2;
            } else if (flags & 0x0040 != 0) {
                component.matrix = .{ try data.f2dot14(offset), 0, 0, try data.f2dot14(offset + 2) };
                offset += 4;
            } else if (flags & 0x0080 != 0) {
                component.matrix = .{ try data.f2dot14(offset), try data.f2dot14(offset + 2), try data.f2dot14(offset + 4), try data.f2dot14(offset + 6) };
                offset += 8;
            }
            component.scaled_offset = flags & 0x0800 != 0 and flags & 0x1000 == 0;
            try components.append(a, component);
            if (flags & 0x0020 == 0) break;
        }
        // Component offsets vary like points, followed by the phantom points.
        const offsets = try a.alloc(Point, components.items.len);
        defer a.free(offsets);
        for (components.items, offsets) |component, *point| point.* = .{ .x = @floatFromInt(component.arg1), .y = @floatFromInt(component.arg2), .on = true };
        // Component offsets have no contours, so omitted ones are not interpolated.
        try self.vary(a, glyph, coords, offsets, &.{}, components.items);
        for (components.items, offsets) |component, point| {
            const start = points.items.len;
            try self.glyphPoints(a, component.glyph, coords, points, ends, depth + 1);
            const m = component.matrix;
            for (points.items[start..]) |*p| {
                const x = p.x;
                p.x = m[0] * x + m[2] * p.y;
                p.y = m[1] * x + m[3] * p.y;
            }
            var dx: f32 = 0;
            var dy: f32 = 0;
            if (component.offsets) {
                dx = point.x;
                dy = point.y;
                if (component.scaled_offset) {
                    const x = dx;
                    dx = m[0] * x + m[2] * dy;
                    dy = m[1] * x + m[3] * dy;
                }
            } else {
                // Align point arg2 of the component with point arg1 of the glyph so far.
                const parent: usize = @intCast(component.arg1);
                const child = start + @as(usize, @intCast(component.arg2));
                if (parent >= start or child >= points.items.len) return error.InvalidFont;
                dx = points.items[parent].x - points.items[child].x;
                dy = points.items[parent].y - points.items[child].y;
            }
            for (points.items[start..]) |*p| {
                p.x += dx;
                p.y += dy;
            }
        }
    }

    const Component = struct {
        glyph: u16,
        arg1: i32 = 0,
        arg2: i32 = 0,
        offsets: bool = true,
        scaled_offset: bool = false,
        matrix: [4]f32 = .{ 1, 0, 0, 1 },
    };

    fn parseSimple(a: std.mem.Allocator, data: Bytes, contours: usize, points: *std.ArrayList(Point), ends: *std.ArrayList(u16)) Error!void {
        var count: usize = 0;
        for (0..contours) |i| {
            const end = try data.u16At(10 + 2 * i);
            // Contour ends strictly increase, as FreeType requires.
            if (i > 0 and end <= ends.items[i - 1]) return error.InvalidFont;
            try ends.append(a, end);
            count = @as(usize, end) + 1;
        }
        if (count > 65535) return error.InvalidFont;
        var offset = 10 + 2 * contours;
        offset += 2 + @as(usize, try data.u16At(offset));
        const flags = try a.alloc(u8, count);
        defer a.free(flags);
        var i: usize = 0;
        while (i < count) {
            const flag = try data.u8At(offset);
            offset += 1;
            flags[i] = flag;
            i += 1;
            if (flag & 0x08 != 0) {
                const repeat = try data.u8At(offset);
                offset += 1;
                for (0..repeat) |_| {
                    if (i >= count) return error.InvalidFont;
                    flags[i] = flag;
                    i += 1;
                }
            }
        }
        try points.ensureUnusedCapacity(a, count);
        var x: i32 = 0;
        for (flags) |flag| {
            if (flag & 0x02 != 0) {
                const value: i32 = try data.u8At(offset);
                offset += 1;
                x += if (flag & 0x10 != 0) value else -value;
            } else if (flag & 0x10 == 0) {
                x += try data.i16At(offset);
                offset += 2;
            }
            points.appendAssumeCapacity(.{ .x = @floatFromInt(x), .y = 0, .on = flag & 0x01 != 0 });
        }
        var y: i32 = 0;
        for (flags, points.items) |flag, *point| {
            if (flag & 0x04 != 0) {
                const value: i32 = try data.u8At(offset);
                offset += 1;
                y += if (flag & 0x20 != 0) value else -value;
            } else if (flag & 0x20 == 0) {
                y += try data.i16At(offset);
                offset += 2;
            }
            point.y = @floatFromInt(y);
        }
    }

    /// Applies gvar deltas to a glyph's points (or component offsets).
    fn vary(self: *const Font, a: std.mem.Allocator, glyph: u32, coords: []const f32, points: []Point, ends: []const u16, components: ?[]const Component) Error!void {
        _ = components;
        const gvar = self.gvar orelse return;
        if (coords.len == 0) return;
        var nonzero = false;
        for (coords) |c| nonzero = nonzero or c != 0;
        if (!nonzero) return;
        const axis_count = try gvar.u16At(4);
        if (axis_count != self.axis_count or coords.len < axis_count) return error.InvalidFont;
        const shared_count = try gvar.u16At(6);
        const shared: Bytes = try gvar.from(try gvar.u32At(8));
        const glyph_count = try gvar.u16At(12);
        if (glyph >= glyph_count) return;
        const long = try gvar.u16At(14) & 1 != 0;
        const array = try gvar.u32At(16);
        const start: usize = if (long) try gvar.u32At(20 + 4 * glyph) else @as(usize, try gvar.u16At(20 + 2 * glyph)) * 2;
        const end: usize = if (long) try gvar.u32At(24 + 4 * glyph) else @as(usize, try gvar.u16At(22 + 2 * glyph)) * 2;
        if (end <= start) return;
        const data: Bytes = .{ .data = try gvar.slice(array + start, end - start) };
        // The variation data covers the points plus four phantom points.
        const total = points.len + 4;
        const deltas = try a.alloc([2]f32, total);
        defer a.free(deltas);
        @memset(deltas, .{ 0, 0 });
        const touched = try a.alloc(bool, total);
        defer a.free(touched);
        const tuple_word = try data.u16At(0);
        const tuple_count = tuple_word & 0x0fff;
        var serialized: usize = try data.u16At(2);
        var shared_points: ?[]u16 = null;
        defer if (shared_points) |list| a.free(list);
        if (tuple_word & 0x8000 != 0) shared_points = try readPoints(a, data, &serialized, total);
        var header: usize = 4;
        for (0..tuple_count) |_| {
            const size = try data.u16At(header);
            const index = try data.u16At(header + 2);
            header += 4;
            var peak: [max_axes]f32 = undefined;
            if (index & 0x8000 != 0) {
                for (0..axis_count) |i| peak[i] = try data.f2dot14(header + 2 * i);
                header += 2 * @as(usize, axis_count);
            } else {
                if ((index & 0x0fff) >= shared_count) return error.InvalidFont;
                for (0..axis_count) |i| peak[i] = try shared.f2dot14(2 * (@as(usize, index & 0x0fff) * axis_count + i));
            }
            var intermediate: ?[2][max_axes]f32 = null;
            if (index & 0x4000 != 0) {
                var region: [2][max_axes]f32 = undefined;
                for (0..axis_count) |i| region[0][i] = try data.f2dot14(header + 2 * i);
                header += 2 * @as(usize, axis_count);
                for (0..axis_count) |i| region[1][i] = try data.f2dot14(header + 2 * i);
                header += 2 * @as(usize, axis_count);
                intermediate = region;
            }
            const body_start = serialized;
            serialized += size;
            const scalar = tupleScalar(coords[0..axis_count], peak[0..axis_count], if (intermediate) |r| .{ r[0][0..axis_count], r[1][0..axis_count] } else null);
            if (scalar == 0) continue;
            var cursor = body_start;
            var private: ?[]u16 = null;
            defer if (private) |list| a.free(list);
            // Private numbers replace shared ones; an empty private list means every point.
            const has_private = index & 0x2000 != 0;
            if (has_private) private = try readPoints(a, data, &cursor, total);
            const numbers = if (has_private) private else shared_points;
            const count = if (numbers) |list| list.len else total;
            // X then Y deltas form one packed stream; runs may cross between them.
            const packed_deltas = try a.alloc(f32, 2 * count);
            defer a.free(packed_deltas);
            try readDeltas(data, &cursor, packed_deltas);
            const xs = packed_deltas[0..count];
            const ys = packed_deltas[count..];
            if (cursor > serialized) return error.InvalidFont;
            if (numbers) |list| {
                @memset(touched, false);
                for (list) |n| touched[n] = true;
                // Interpolate untouched points (IUP) within each contour.
                var tuple_deltas = try a.alloc([2]f32, total);
                defer a.free(tuple_deltas);
                @memset(tuple_deltas, .{ 0, 0 });
                for (list, xs, ys) |n, dx, dy| tuple_deltas[n] = .{ dx, dy };
                interpolate(points, ends, touched, tuple_deltas);
                for (deltas, tuple_deltas) |*d, t| {
                    d[0] += t[0] * scalar;
                    d[1] += t[1] * scalar;
                }
            } else {
                for (deltas, xs, ys) |*d, dx, dy| {
                    d[0] += dx * scalar;
                    d[1] += dy * scalar;
                }
            }
        }
        for (points, deltas[0..points.len]) |*p, d| {
            p.x += d[0];
            p.y += d[1];
        }
    }

    fn tupleScalar(coords: []const f32, peak: []const f32, region: ?[2][]const f32) f32 {
        var scalar: f32 = 1;
        for (coords, peak, 0..) |c, p, i| {
            if (p == 0) continue;
            if (c == p) continue;
            if (c == 0 or (c < 0) != (p < 0)) return 0;
            if (region) |r| {
                const s = r[0][i];
                const e = r[1][i];
                if (s > p or p > e or (s < 0 and e > 0)) continue;
                if (c < s or c > e) return 0;
                scalar *= if (c < p) (c - s) / (p - s) else (e - c) / (e - p);
            } else {
                if (c < @min(0, p) or c > @max(0, p)) return 0;
                scalar *= c / p;
            }
        }
        return scalar;
    }

    /// Packed point numbers; null means every point.
    fn readPoints(a: std.mem.Allocator, data: Bytes, cursor: *usize, total: usize) Error!?[]u16 {
        var count: usize = try data.u8At(cursor.*);
        cursor.* += 1;
        if (count == 0) return null;
        if (count & 0x80 != 0) {
            count = ((count & 0x7f) << 8) | try data.u8At(cursor.*);
            cursor.* += 1;
        }
        const list = try a.alloc(u16, count);
        errdefer a.free(list);
        var filled: usize = 0;
        var value: u32 = 0;
        while (filled < count) {
            const control = try data.u8At(cursor.*);
            cursor.* += 1;
            const run = (control & 0x7f) + 1;
            for (0..run) |_| {
                if (filled == count) break;
                if (control & 0x80 != 0) {
                    value += try data.u16At(cursor.*);
                    cursor.* += 2;
                } else {
                    value += try data.u8At(cursor.*);
                    cursor.* += 1;
                }
                if (value >= total) return error.InvalidFont;
                list[filled] = std.math.cast(u16, value) orelse return error.InvalidFont;
                filled += 1;
            }
        }
        return list;
    }

    fn readDeltas(data: Bytes, cursor: *usize, out: []f32) Error!void {
        var filled: usize = 0;
        while (filled < out.len) {
            const control = try data.u8At(cursor.*);
            cursor.* += 1;
            const run = (control & 0x3f) + 1;
            for (0..run) |_| {
                if (filled == out.len) return error.InvalidFont;
                if (control & 0xc0 == 0xc0) {
                    // DELTAS_ARE_LONGS (OpenType 1.9.1): 32-bit deltas.
                    out[filled] = @floatFromInt(@as(i32, @bitCast(try data.u32At(cursor.*))));
                    cursor.* += 4;
                } else if (control & 0x80 != 0) {
                    out[filled] = 0;
                } else if (control & 0x40 != 0) {
                    out[filled] = @floatFromInt(try data.i16At(cursor.*));
                    cursor.* += 2;
                } else {
                    out[filled] = @floatFromInt(@as(i8, @bitCast(try data.u8At(cursor.*))));
                    cursor.* += 1;
                }
                filled += 1;
            }
        }
    }

    /// Infers deltas for untouched points from the nearest touched ones in each contour.
    fn interpolate(points: []const Point, ends: []const u16, touched: []const bool, deltas: [][2]f32) void {
        var start: usize = 0;
        for (ends) |end_u16| {
            const end: usize = end_u16;
            if (end >= points.len) return;
            defer start = end + 1;
            var first: ?usize = null;
            for (start..end + 1) |i| if (touched[i]) {
                first = i;
                break;
            };
            const first_touched = first orelse continue;
            var previous = first_touched;
            var i = first_touched + 1;
            const length = end + 1 - start;
            var visited: usize = 0;
            while (visited < length) : (visited += 1) {
                if (i > end) i = start;
                if (touched[i]) {
                    fillGap(points, deltas, previous, i, start, end);
                    previous = i;
                }
                if (i == first_touched) break;
                i += 1;
            }
        }
    }

    fn fillGap(points: []const Point, deltas: [][2]f32, left: usize, right: usize, start: usize, end: usize) void {
        var i = if (left == end) start else left + 1;
        while (i != right) : (i = if (i == end) start else i + 1) {
            for (0..2) |axis| {
                const p = if (axis == 0) points[i].x else points[i].y;
                const l = if (axis == 0) points[left].x else points[left].y;
                const r = if (axis == 0) points[right].x else points[right].y;
                const dl = deltas[left][axis];
                const dr = deltas[right][axis];
                const low = @min(l, r);
                const high = @max(l, r);
                const d_low = if (l <= r) dl else dr;
                const d_high = if (l <= r) dr else dl;
                deltas[i][axis] = if (l == r) (if (dl == dr) dl else 0) else if (p <= low) d_low else if (p >= high) d_high else d_low + (p - low) * (d_high - d_low) / (high - low);
            }
        }
    }

    // ------------------------------------------------------------ Metadata

    pub const Names = struct { typographic: ?[]const u8 = null, legacy: ?[]const u8 = null };

    /// English family names, lowercased, from name IDs 16 and 1.
    pub fn familyNames(self: *const Font, a: std.mem.Allocator) Error!Names {
        const table = self.name orelse return .{};
        var names: Names = .{};
        // English names win; otherwise the first in any language with a
        // Unicode encoding (Windows or Unicode platform), as FreeType falls back.
        var other: Names = .{};
        const count = try table.u16At(2);
        const strings = try table.u16At(4);
        for (0..count) |i| {
            const record = 6 + 12 * i;
            const platform = try table.u16At(record);
            const language = try table.u16At(record + 4);
            const id = try table.u16At(record + 6);
            const slot = switch (id) {
                16 => &names.typographic,
                1 => &names.legacy,
                else => continue,
            };
            const windows = platform == 3 and language == 0x409;
            const mac = platform == 1 and language == 0;
            const at = @as(usize, strings) + try table.u16At(record + 10);
            const length = try table.u16At(record + 8);
            if (!windows and !(mac and slot.* == null)) {
                const fallback = if (id == 16) &other.typographic else &other.legacy;
                if ((platform == 0 or platform == 3) and fallback.* == null) {
                    const raw = table.slice(at, length) catch continue;
                    fallback.* = try utf16be(a, raw);
                }
                continue;
            }
            const raw = try table.slice(at, length);
            slot.* = if (windows) try utf16be(a, raw) else try std.ascii.allocLowerString(a, raw);
        }
        if (names.typographic == null) names.typographic = other.typographic;
        if (names.legacy == null) names.legacy = other.legacy;
        return names;
    }

    fn utf16be(a: std.mem.Allocator, raw: []const u8) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i + 1 < raw.len) : (i += 2) {
            var cp: u21 = std.mem.readInt(u16, raw[i..][0..2], .big);
            if (cp >= 0xd800 and cp <= 0xdbff and i + 3 < raw.len) {
                const low = std.mem.readInt(u16, raw[i + 2 ..][0..2], .big);
                if (low >= 0xdc00 and low <= 0xdfff) {
                    cp = 0x10000 + ((cp - 0xd800) << 10) + (low - 0xdc00);
                    i += 2;
                }
            }
            var buffer: [4]u8 = undefined;
            const length = std.unicode.utf8Encode(cp, &buffer) catch continue;
            for (buffer[0..length]) |byte| try out.append(a, std.ascii.toLower(byte));
        }
        return out.toOwnedSlice(a);
    }

    pub const Style = struct { weight: f32, width: u16, italic: bool, bold: bool };

    pub fn style(self: *const Font) Style {
        const mac = self.head.u16At(44) catch 0;
        var result: Style = .{ .weight = if (mac & 1 != 0) 700 else 400, .width = 5, .italic = mac & 2 != 0, .bold = mac & 1 != 0 };
        if (self.os2) |os2| {
            const weight = os2.u16At(4) catch 0;
            const width = os2.u16At(6) catch 0;
            const selection = os2.u16At(62) catch 0;
            if (weight >= 1 and weight <= 1000) result.weight = @floatFromInt(weight);
            if (width >= 1 and width <= 9) result.width = width;
            result.italic = result.italic or selection & 1 != 0;
            result.bold = result.bold or selection & 0x20 != 0;
        }
        return result;
    }

    pub fn findAxis(self: *const Font, axis_tag: *const [4]u8) ?Axis {
        for (self.axes[0..self.axis_count]) |entry| if (entry.tag == tag(axis_tag)) return entry;
        return null;
    }
};

/// A rendered glyph: 8-bit coverage, placed relative to the pen position with
/// `top` measured upward from the baseline, as FreeType places bitmaps.
pub const Bitmap = struct { left: i32, top: i32, width: u32, height: u32, pixels: []u8 };

/// Renders a glyph at `size` pixels per em. Emboldening widens strokes by
/// size/24 pixels, as FreeType's FT_GlyphSlot_Embolden does.
pub fn render(a: std.mem.Allocator, font: *const Font, glyph: u32, coords: []const f32, size: f64, embolden: bool) Error!Bitmap {
    var outline: path.Path = .{};
    defer outline.deinit(a);
    try font.outline(a, glyph, coords, &outline);
    const bounds = outline.bounds() orelse return .{ .left = 0, .top = 0, .width = 0, .height = 0, .pixels = &.{} };
    const scale = size / @as(f64, @floatFromInt(font.units_per_em));
    const grow: f64 = if (embolden) size / 24 / 2 else 0;
    const edges = [4]f64{ @floor(bounds[0] * scale - grow), @ceil(bounds[2] * scale + grow), @floor(bounds[1] * scale - grow), @ceil(bounds[3] * scale + grow) };
    // Malformed outlines (huge or non-finite coordinates) render nothing.
    for (edges) |edge| if (!(@abs(edge) <= 1 << 24)) return .{ .left = 0, .top = 0, .width = 0, .height = 0, .pixels = &.{} };
    const left: i32 = @intFromFloat(edges[0]);
    const right: i32 = @intFromFloat(edges[1]);
    const bottom: i32 = @intFromFloat(edges[2]);
    const top: i32 = @intFromFloat(edges[3]);
    const width: u32 = @intCast(@max(0, right - left));
    const height: u32 = @intCast(@max(0, top - bottom));
    if (width == 0 or height == 0 or width > 4096 or height > 4096) return .{ .left = left, .top = top, .width = 0, .height = 0, .pixels = &.{} };
    // Font units (y up) to bitmap pixels (y down).
    const transform: path.Transform = .{ .a = scale, .b = 0, .c = 0, .d = -scale, .e = -@as(f64, @floatFromInt(left)), .f = @floatFromInt(top) };
    const mask = path.fillMask(a, outline, transform, .nonzero, width, height) catch return error.OutOfMemory;
    defer mask.deinit(a);
    var stroke_mask: ?path.Mask = null;
    defer if (stroke_mask) |m| m.deinit(a);
    if (embolden) stroke_mask = path.strokeMask(a, outline, transform, .{ .width = 2 * grow, .join = .round }, width, height) catch return error.OutOfMemory;
    const pixels = try a.alloc(u8, @as(usize, width) * height);
    for (0..height) |y| for (0..width) |x| {
        var coverage = mask.at(@intCast(x), @intCast(y));
        if (stroke_mask) |m| coverage = @max(coverage, m.at(@intCast(x), @intCast(y)));
        pixels[y * width + x] = @intFromFloat(@round(std.math.clamp(coverage, 0, 1) * 255));
    };
    return .{ .left = left, .top = top, .width = width, .height = height, .pixels = pixels };
}

/// TrueType contours (quadratic, with implied on-curve midpoints) to a path.
fn emitQuadratic(a: std.mem.Allocator, points: []const Font.Point, ends: []const u16, out: *path.Path) Error!void {
    var start: usize = 0;
    for (ends) |end_u16| {
        const end: usize = end_u16;
        if (end >= points.len or end < start) return error.InvalidFont;
        defer start = end + 1;
        const contour = points[start .. end + 1];
        if (contour.len < 2) continue;
        // Start on an on-curve point, or the midpoint of two off-curve points.
        const first_on = for (contour, 0..) |p, i| {
            if (p.on) break i;
        } else null;
        const origin: path.Point = if (first_on) |i| .{ .x = contour[i].x, .y = contour[i].y } else .{ .x = (contour[0].x + contour[contour.len - 1].x) / 2, .y = (contour[0].y + contour[contour.len - 1].y) / 2 };
        const offset = first_on orelse 0;
        try out.moveTo(a, origin);
        // Without an on-curve point, the first control precedes the start midpoint.
        var control: ?path.Point = if (first_on == null) .{ .x = contour[0].x, .y = contour[0].y } else null;
        const steps = if (first_on == null) contour.len else contour.len + 1;
        for (1..steps) |step| {
            const p = contour[(offset + step) % contour.len];
            const point: path.Point = .{ .x = p.x, .y = p.y };
            if (p.on) {
                if (control) |c| try out.quadTo(a, c, point) else try out.lineTo(a, point);
                control = null;
            } else {
                if (control) |c| try out.quadTo(a, c, .{ .x = (c.x + point.x) / 2, .y = (c.y + point.y) / 2 });
                control = point;
            }
        }
        if (first_on == null) {
            if (control) |c| try out.quadTo(a, c, origin);
        }
        try out.close(a);
    }
}

// ---------------------------------------------------------------- CFF

const Index = struct {
    data: Bytes,
    count: u32,
    off_size: u8,
    offsets: usize,
    objects: usize,
    end: usize,

    fn read(data: Bytes, at: usize, cff2: bool) Error!Index {
        const count: u32 = if (cff2) try data.u32At(at) else try data.u16At(at);
        const header: usize = if (cff2) 4 else 2;
        if (count == 0) return .{ .data = data, .count = 0, .off_size = 1, .offsets = at + header, .objects = at + header, .end = at + header };
        const off_size = try data.u8At(at + header);
        if (off_size < 1 or off_size > 4) return error.InvalidFont;
        const offsets = at + header + 1;
        const objects = offsets + (@as(usize, count) + 1) * off_size - 1;
        var self: Index = .{ .data = data, .count = count, .off_size = off_size, .offsets = offsets, .objects = objects, .end = 0 };
        self.end = objects + try self.offset(count);
        return self;
    }
    fn offset(self: Index, i: usize) Error!usize {
        const at = self.offsets + i * self.off_size;
        return switch (self.off_size) {
            1 => try self.data.u8At(at),
            2 => try self.data.u16At(at),
            3 => try self.data.u24At(at),
            else => try self.data.u32At(at),
        };
    }
    fn get(self: Index, i: usize) Error![]const u8 {
        if (i >= self.count) return error.InvalidFont;
        const start = try self.offset(i);
        const end = try self.offset(i + 1);
        if (end < start) return error.InvalidFont;
        return self.data.slice(self.objects + start, end - start);
    }
};

/// An offset, count or index operand from untrusted font data.
fn operandIndex(value: f64) Error!usize {
    if (!(value >= 0 and value <= std.math.maxInt(i32))) return error.InvalidFont;
    return @intFromFloat(value);
}

fn operandInt(value: f64) Error!i32 {
    if (!(value >= std.math.minInt(i32) and value <= std.math.maxInt(i32))) return error.InvalidFont;
    return @intFromFloat(value);
}

/// DICT operands and operators.
const Dict = struct {
    data: []const u8,

    /// The operands of `op` (two-byte operators are 1200 + second byte).
    fn get(self: Dict, op: u16, out: []f64) ?[]f64 {
        var stack: [48]f64 = undefined;
        var count: usize = 0;
        var i: usize = 0;
        while (i < self.data.len) {
            const b = self.data[i];
            // Bytes 0-27 are operators (vsindex 22, blend 23 and vstore 24 included).
            if (b <= 27) {
                var operator: u16 = b;
                i += 1;
                if (b == 12) {
                    if (i >= self.data.len) return null;
                    operator = 1200 + @as(u16, self.data[i]);
                    i += 1;
                }
                if (operator == op) {
                    const n = @min(count, out.len);
                    @memcpy(out[0..n], stack[0..n]);
                    return out[0..n];
                }
                count = 0;
                continue;
            }
            const value = number(self.data, &i, true) catch return null;
            if (count < stack.len) {
                stack[count] = value;
                count += 1;
            }
        }
        return null;
    }
};

/// A CFF number. DICTs add real numbers (30); charstrings add 16.16 (255).
fn number(data: []const u8, i: *usize, dict: bool) Error!f64 {
    const b = data[i.*];
    i.* += 1;
    if (b >= 32 and b <= 246) return @as(f64, @floatFromInt(@as(i32, b) - 139));
    if (b >= 247 and b <= 250) {
        if (i.* >= data.len) return error.InvalidFont;
        const value = (@as(i32, b) - 247) * 256 + data[i.*] + 108;
        i.* += 1;
        return @floatFromInt(value);
    }
    if (b >= 251 and b <= 254) {
        if (i.* >= data.len) return error.InvalidFont;
        const value = -(@as(i32, b) - 251) * 256 - data[i.*] - 108;
        i.* += 1;
        return @floatFromInt(value);
    }
    if (b == 28) {
        if (i.* + 2 > data.len) return error.InvalidFont;
        const value = std.mem.readInt(i16, data[i.*..][0..2], .big);
        i.* += 2;
        return @floatFromInt(value);
    }
    if (dict and b == 29) {
        if (i.* + 4 > data.len) return error.InvalidFont;
        const value = std.mem.readInt(i32, data[i.*..][0..4], .big);
        i.* += 4;
        return @floatFromInt(value);
    }
    if (dict and b == 30) {
        // Packed decimal; only its extent matters here, the value is approximated.
        var text: [64]u8 = undefined;
        var length: usize = 0;
        outer: while (i.* < data.len) {
            const byte = data[i.*];
            i.* += 1;
            for ([_]u8{ byte >> 4, byte & 15 }) |nibble| {
                const piece: []const u8 = switch (nibble) {
                    0...9 => &.{'0' + nibble},
                    0xa => ".",
                    0xb => "E",
                    0xc => "E-",
                    0xe => "-",
                    0xf => break :outer,
                    else => "",
                };
                if (length + piece.len <= text.len) {
                    @memcpy(text[length..][0..piece.len], piece);
                    length += piece.len;
                }
            }
        }
        return std.fmt.parseFloat(f64, text[0..length]) catch 0;
    }
    if (!dict and b == 255) {
        if (i.* + 4 > data.len) return error.InvalidFont;
        const value = std.mem.readInt(i32, data[i.*..][0..4], .big);
        i.* += 4;
        return @as(f64, @floatFromInt(value)) / 65536;
    }
    return error.InvalidFont;
}

const Cff = struct {
    data: Bytes,
    cff2: bool,
    charstrings: Index,
    global_subrs: Index,
    /// Per font DICT: local subroutines and the default variation data index.
    private_subrs: [64]?Index = @splat(null),
    vsindex: [64]u16 = @splat(0),
    fd_count: usize = 1,
    fd_select: ?usize = null,
    vstore: ?Bytes = null,

    fn init(table: Bytes, cff2: bool) Error!Cff {
        var top: Dict = undefined;
        var global_at: usize = undefined;
        if (cff2) {
            const header = try table.u8At(2);
            const length = try table.u16At(3);
            top = .{ .data = try table.slice(header, length) };
            global_at = @as(usize, header) + length;
        } else {
            const header = try table.u8At(2);
            const names = try Index.read(table, header, false);
            const tops = try Index.read(table, names.end, false);
            if (tops.count == 0) return error.InvalidFont;
            top = .{ .data = try tops.get(0) };
            const strings = try Index.read(table, tops.end, false);
            global_at = strings.end;
        }
        var operands: [4]f64 = undefined;
        const charstrings_op = top.get(17, &operands) orelse return error.InvalidFont;
        if (charstrings_op.len == 0) return error.InvalidFont;
        const charstrings_at = try operandIndex(charstrings_op[0]);
        var self: Cff = .{
            .data = table,
            .cff2 = cff2,
            .charstrings = try Index.read(table, charstrings_at, cff2),
            .global_subrs = try Index.read(table, global_at, cff2),
        };
        if (top.get(1206, &operands)) |kind| if (kind.len > 0 and kind[0] != 2) return error.Unsupported;
        if (top.get(24, &operands)) |vstore| if (vstore.len > 0) {
            // The vstore starts with a length before the ItemVariationStore.
            self.vstore = try table.from(try operandIndex(vstore[0]) + 2);
        };
        if (top.get(1236, &operands)) |fd_array| if (fd_array.len > 0) {
            const fds = try Index.read(table, try operandIndex(fd_array[0]), cff2);
            self.fd_count = @min(fds.count, self.private_subrs.len);
            for (0..self.fd_count) |i| try self.readPrivate(.{ .data = try fds.get(i) }, i);
            if (top.get(1237, &operands)) |select| if (select.len > 0) {
                self.fd_select = try operandIndex(select[0]);
            };
            return self;
        };
        try self.readPrivate(top, 0);
        return self;
    }

    fn readPrivate(self: *Cff, dict: Dict, fd: usize) Error!void {
        var operands: [4]f64 = undefined;
        const private = dict.get(18, &operands) orelse return;
        if (private.len < 2) return error.InvalidFont;
        const size = try operandIndex(private[0]);
        const at = try operandIndex(private[1]);
        const private_dict: Dict = .{ .data = try self.data.slice(at, size) };
        if (private_dict.get(19, &operands)) |subrs| if (subrs.len > 0) {
            self.private_subrs[fd] = try Index.read(self.data, at + try operandIndex(subrs[0]), self.cff2);
        };
        if (private_dict.get(22, &operands)) |vsindex| if (vsindex.len > 0) {
            self.vsindex[fd] = std.math.cast(u16, try operandIndex(vsindex[0])) orelse return error.InvalidFont;
        };
    }

    fn fontDict(self: *const Cff, glyph: u32) Error!usize {
        const at = self.fd_select orelse return 0;
        const format = try self.data.u8At(at);
        switch (format) {
            0 => return try self.data.u8At(at + 1 + glyph),
            3, 4 => {
                const wide = format == 4;
                const count: usize = if (wide) try self.data.u32At(at + 1) else try self.data.u16At(at + 1);
                const ranges = at + (if (wide) @as(usize, 5) else 3);
                const step: usize = if (wide) 6 else 3;
                var fd: usize = 0;
                for (0..count) |i| {
                    const first: u32 = if (wide) try self.data.u32At(ranges + step * i) else try self.data.u16At(ranges + step * i);
                    if (first > glyph) break;
                    fd = if (wide) try self.data.u16At(ranges + step * i + 4) else try self.data.u8At(ranges + step * i + 2);
                }
                return fd;
            },
            else => return error.Unsupported,
        }
    }

    fn outline(self: *const Cff, a: std.mem.Allocator, glyph: u32, coords: []const f32, font: *const Font, out: *path.Path) Error!void {
        const fd = try self.fontDict(glyph);
        if (fd >= self.fd_count) return error.InvalidFont;
        var machine: Machine = .{ .cff = self, .a = a, .out = out, .local = self.private_subrs[fd], .coords = coords, .font = font };
        try machine.setVsindex(self.vsindex[fd]);
        try machine.run(try self.charstrings.get(glyph), 0);
        if (machine.open) try out.close(a);
    }

    /// Region scalars of ItemVariationData `index` at `coords`.
    fn regionScalars(self: *const Cff, index: u16, coords: []const f32, out: []f32) Error!usize {
        const store = self.vstore orelse return 0;
        const regions = try store.from(try store.u32At(2));
        const data_count = try store.u16At(6);
        if (index >= data_count) return error.InvalidFont;
        const data = try store.from(try store.u32At(8 + 4 * @as(usize, index)));
        const region_count = try data.u16At(4);
        if (region_count > out.len) return error.Unsupported;
        const axis_count = try regions.u16At(0);
        const list_count = try regions.u16At(2);
        for (0..region_count) |r| {
            const region = try data.u16At(6 + 2 * r);
            if (region >= list_count) return error.InvalidFont;
            var scalar: f32 = 1;
            for (0..axis_count) |axis_index| {
                const at = 4 + (@as(usize, region) * axis_count + axis_index) * 6;
                const start = try regions.f2dot14(at);
                const peak = try regions.f2dot14(at + 2);
                const end = try regions.f2dot14(at + 4);
                const c = if (axis_index < coords.len) coords[axis_index] else 0;
                if (start > peak or peak > end or (start < 0 and end > 0) or peak == 0) continue;
                if (c < start or c > end) {
                    scalar = 0;
                    break;
                }
                if (c == peak) continue;
                scalar *= if (c < peak) (c - start) / (peak - start) else (end - c) / (end - peak);
            }
            out[r] = scalar;
        }
        return region_count;
    }
};

fn bias(count: u32) i32 {
    return if (count < 1240) 107 else if (count < 33900) 1131 else 32768;
}

/// The Type 2 / CFF2 charstring interpreter.
const Machine = struct {
    cff: *const Cff,
    a: std.mem.Allocator,
    out: *path.Path,
    local: ?Index,
    coords: []const f32,
    font: *const Font,
    stack: [513]f64 = undefined,
    count: usize = 0,
    x: f64 = 0,
    y: f64 = 0,
    stems: usize = 0,
    width_parsed: bool = false,
    open: bool = false,
    done: bool = false,
    scalars: [64]f32 = undefined,
    regions: usize = 0,

    fn setVsindex(self: *Machine, index: u16) Error!void {
        if (!self.cff.cff2 or self.cff.vstore == null) return;
        self.regions = try self.cff.regionScalars(index, self.coords, &self.scalars);
    }

    fn push(self: *Machine, value: f64) Error!void {
        if (self.count == self.stack.len) return error.InvalidFont;
        self.stack[self.count] = value;
        self.count += 1;
    }

    /// CFF1 charstrings may begin with an advance width before the first operator.
    fn width(self: *Machine, expected_even: bool) void {
        if (self.width_parsed or self.cff.cff2) return;
        self.width_parsed = true;
        if ((self.count % 2 == 1) == expected_even and self.count > 0) {
            std.mem.copyForwards(f64, self.stack[0 .. self.count - 1], self.stack[1..self.count]);
            self.count -= 1;
        }
    }

    fn point(self: *const Machine) path.Point {
        return .{ .x = @floatCast(self.x), .y = @floatCast(self.y) };
    }

    fn moveTo(self: *Machine, dx: f64, dy: f64) Error!void {
        if (self.open) try self.out.close(self.a);
        self.x += dx;
        self.y += dy;
        try self.out.moveTo(self.a, self.point());
        self.open = true;
    }
    fn lineTo(self: *Machine, dx: f64, dy: f64) Error!void {
        self.x += dx;
        self.y += dy;
        try self.out.lineTo(self.a, self.point());
    }
    fn curveTo(self: *Machine, dx1: f64, dy1: f64, dx2: f64, dy2: f64, dx3: f64, dy3: f64) Error!void {
        const c1: path.Point = .{ .x = @floatCast(self.x + dx1), .y = @floatCast(self.y + dy1) };
        const c2: path.Point = .{ .x = @floatCast(self.x + dx1 + dx2), .y = @floatCast(self.y + dy1 + dy2) };
        self.x += dx1 + dx2 + dx3;
        self.y += dy1 + dy2 + dy3;
        try self.out.cubicTo(self.a, c1, c2, self.point());
    }

    fn run(self: *Machine, code: []const u8, depth: u32) Error!void {
        if (depth > 10) return error.InvalidFont;
        var i: usize = 0;
        while (i < code.len and !self.done) {
            const b = code[i];
            if (b >= 32 or b == 28 or b == 255) {
                try self.push(try number(code, &i, false));
                continue;
            }
            i += 1;
            const s = self.stack[0..self.count];
            switch (b) {
                1, 3, 18, 23 => { // hstem, vstem, hstemhm, vstemhm
                    self.width(true);
                    self.stems += self.count / 2;
                    self.count = 0;
                },
                19, 20 => { // hintmask, cntrmask: implicit vstems, then mask bytes
                    self.width(true);
                    self.stems += self.count / 2;
                    self.count = 0;
                    i += (self.stems + 7) / 8;
                },
                21 => { // rmoveto
                    self.width(true);
                    if (self.count < 2) return error.InvalidFont;
                    try self.moveTo(self.stack[self.count - 2], self.stack[self.count - 1]);
                    self.count = 0;
                },
                22, 4 => { // hmoveto, vmoveto
                    self.width(false);
                    if (self.count < 1) return error.InvalidFont;
                    const d = self.stack[self.count - 1];
                    if (b == 22) try self.moveTo(d, 0) else try self.moveTo(0, d);
                    self.count = 0;
                },
                5 => { // rlineto
                    var k: usize = 0;
                    while (k + 2 <= s.len) : (k += 2) try self.lineTo(s[k], s[k + 1]);
                    self.count = 0;
                },
                6, 7 => { // hlineto, vlineto: alternating
                    var horizontal = b == 6;
                    for (s) |d| {
                        if (horizontal) try self.lineTo(d, 0) else try self.lineTo(0, d);
                        horizontal = !horizontal;
                    }
                    self.count = 0;
                },
                8 => { // rrcurveto
                    var k: usize = 0;
                    while (k + 6 <= s.len) : (k += 6) try self.curveTo(s[k], s[k + 1], s[k + 2], s[k + 3], s[k + 4], s[k + 5]);
                    self.count = 0;
                },
                24 => { // rcurveline
                    var k: usize = 0;
                    while (k + 8 <= s.len) : (k += 6) try self.curveTo(s[k], s[k + 1], s[k + 2], s[k + 3], s[k + 4], s[k + 5]);
                    if (k + 2 <= s.len) try self.lineTo(s[k], s[k + 1]);
                    self.count = 0;
                },
                25 => { // rlinecurve
                    var k: usize = 0;
                    while (k + 8 <= s.len) : (k += 2) try self.lineTo(s[k], s[k + 1]);
                    if (k + 6 <= s.len) try self.curveTo(s[k], s[k + 1], s[k + 2], s[k + 3], s[k + 4], s[k + 5]);
                    self.count = 0;
                },
                26 => { // vvcurveto
                    var k: usize = 0;
                    var dx1: f64 = 0;
                    if (s.len % 4 == 1) {
                        dx1 = s[0];
                        k = 1;
                    }
                    while (k + 4 <= s.len) : (k += 4) {
                        try self.curveTo(dx1, s[k], s[k + 1], s[k + 2], 0, s[k + 3]);
                        dx1 = 0;
                    }
                    self.count = 0;
                },
                27 => { // hhcurveto
                    var k: usize = 0;
                    var dy1: f64 = 0;
                    if (s.len % 4 == 1) {
                        dy1 = s[0];
                        k = 1;
                    }
                    while (k + 4 <= s.len) : (k += 4) {
                        try self.curveTo(s[k], dy1, s[k + 1], s[k + 2], s[k + 3], 0);
                        dy1 = 0;
                    }
                    self.count = 0;
                },
                30, 31 => { // vhcurveto, hvcurveto: alternating tangents
                    var k: usize = 0;
                    var horizontal = b == 31;
                    while (k + 4 <= s.len) : (k += 4) {
                        const last = k + 5 == s.len;
                        const extra = if (last) s[k + 4] else 0;
                        if (horizontal) try self.curveTo(s[k], 0, s[k + 1], s[k + 2], extra, s[k + 3]) else try self.curveTo(0, s[k], s[k + 1], s[k + 2], s[k + 3], extra);
                        horizontal = !horizontal;
                    }
                    self.count = 0;
                },
                10, 29 => { // callsubr, callgsubr
                    if (self.count == 0) return error.InvalidFont;
                    self.count -= 1;
                    const subrs = if (b == 10) self.local orelse return error.InvalidFont else self.cff.global_subrs;
                    const index = @as(i64, try operandInt(self.stack[self.count])) + bias(subrs.count);
                    if (index < 0) return error.InvalidFont;
                    try self.run(try subrs.get(@intCast(index)), depth + 1);
                },
                11 => return, // return
                14 => { // endchar
                    self.width(true);
                    if (self.count >= 4) return error.Unsupported; // seac accented characters
                    self.done = true;
                    self.count = 0;
                },
                15 => { // vsindex (CFF2)
                    if (self.count < 1) return error.InvalidFont;
                    try self.setVsindex(std.math.cast(u16, try operandIndex(self.stack[self.count - 1])) orelse return error.InvalidFont);
                    self.count = 0;
                },
                16 => { // blend (CFF2): n defaults, each followed by its region deltas
                    if (self.count < 1) return error.InvalidFont;
                    const n = try operandIndex(self.stack[self.count - 1]);
                    self.count -= 1;
                    const k = self.regions;
                    if (n * (k + 1) > self.count) return error.InvalidFont;
                    const base = self.count - n * (k + 1);
                    for (0..n) |v| {
                        var value = self.stack[base + v];
                        for (0..k) |r| value += self.stack[base + n + v * k + r] * self.scalars[r];
                        self.stack[base + v] = value;
                    }
                    self.count = base + n;
                },
                12 => {
                    if (i >= code.len) return error.InvalidFont;
                    const op = code[i];
                    i += 1;
                    switch (op) {
                        35 => { // flex
                            if (s.len < 12) return error.InvalidFont;
                            try self.curveTo(s[0], s[1], s[2], s[3], s[4], s[5]);
                            try self.curveTo(s[6], s[7], s[8], s[9], s[10], s[11]);
                        },
                        34 => { // hflex
                            if (s.len < 7) return error.InvalidFont;
                            const y0 = self.y;
                            try self.curveTo(s[0], 0, s[1], s[2], s[3], 0);
                            try self.curveTo(s[4], 0, s[5], y0 - self.y, s[6], 0);
                        },
                        36 => { // hflex1
                            if (s.len < 9) return error.InvalidFont;
                            const y0 = self.y;
                            try self.curveTo(s[0], s[1], s[2], s[3], s[4], 0);
                            try self.curveTo(s[5], 0, s[6], s[7], s[8], y0 - (self.y + s[7]));
                        },
                        37 => { // flex1
                            if (s.len < 11) return error.InvalidFont;
                            var dx: f64 = 0;
                            var dy: f64 = 0;
                            for (0..5) |k| {
                                dx += s[2 * k];
                                dy += s[2 * k + 1];
                            }
                            const x0 = self.x;
                            const y0 = self.y;
                            try self.curveTo(s[0], s[1], s[2], s[3], s[4], s[5]);
                            const last_x = if (@abs(dx) > @abs(dy)) s[10] else x0 - (self.x + s[6] + s[8]);
                            const last_y = if (@abs(dx) > @abs(dy)) y0 - (self.y + s[7] + s[9]) else s[10];
                            try self.curveTo(s[6], s[7], s[8], s[9], last_x, last_y);
                        },
                        else => return error.Unsupported,
                    }
                    self.count = 0;
                },
                else => return error.InvalidFont,
            }
        }
    }
};

test "TrueType quadratic contours imply on-curve midpoints and close" {
    const a = std.testing.allocator;
    var out: path.Path = .{};
    defer out.deinit(a);
    const points = [_]Font.Point{
        .{ .x = 0, .y = 0, .on = false },
        .{ .x = 100, .y = 0, .on = false },
        .{ .x = 100, .y = 100, .on = true },
        .{ .x = 0, .y = 100, .on = true },
    };
    try emitQuadratic(a, &points, &.{3}, &out);
    const bounds = out.bounds().?;
    try std.testing.expectEqual(@as(f64, 0), bounds[0]);
    try std.testing.expectEqual(@as(f64, 100), bounds[2]);
}

test "tuple scalars follow the OpenType variation algorithm" {
    try std.testing.expectEqual(@as(f32, 0.5), Font.tupleScalar(&.{0.5}, &.{1}, null));
    try std.testing.expectEqual(@as(f32, 0), Font.tupleScalar(&.{-0.5}, &.{1}, null));
    try std.testing.expectEqual(@as(f32, 0), Font.tupleScalar(&.{0.8}, &.{0.5}, null));
    try std.testing.expectEqual(@as(f32, 1), Font.tupleScalar(&.{ 0.25, 1 }, &.{ 0, 1 }, null));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), Font.tupleScalar(&.{0.75}, &.{0.5}, .{ &.{0}, &.{1} }), 1e-6);
}

test "CFF numbers decode every operand encoding" {
    var i: usize = 0;
    try std.testing.expectEqual(@as(f64, 0), try number(&.{139}, &i, false));
    i = 0;
    try std.testing.expectEqual(@as(f64, 108), try number(&.{ 247, 0 }, &i, false));
    i = 0;
    try std.testing.expectEqual(@as(f64, -1131), try number(&.{ 254, 255 }, &i, false));
    i = 0;
    try std.testing.expectEqual(@as(f64, -2), try number(&.{ 28, 0xff, 0xfe }, &i, false));
    i = 0;
    try std.testing.expectEqual(@as(f64, 1.5), try number(&.{ 255, 0, 1, 0x80, 0 }, &i, false));
    i = 0;
    try std.testing.expectApproxEqAbs(@as(f64, -2.25), try number(&.{ 30, 0xe2, 0xa2, 0x5f }, &i, true), 1e-9);
}

test "CFF offset and index operands reject values that are not small integers" {
    try std.testing.expectEqual(@as(usize, 42), try operandIndex(42));
    for ([_]f64{ -1, std.math.nan(f64), std.math.inf(f64), 1e12 }) |value| try std.testing.expectError(error.InvalidFont, operandIndex(value));
    try std.testing.expectEqual(@as(i32, -107), try operandInt(-107));
    try std.testing.expectError(error.InvalidFont, operandInt(std.math.nan(f64)));
}

test "malformed fvar axis ranges are widened instead of breaking clamping" {
    var table: [36]u8 = @splat(0);
    std.mem.writeInt(u16, table[4..6], 16, .big); // axes offset
    std.mem.writeInt(u16, table[8..10], 1, .big); // axis count
    std.mem.writeInt(u16, table[10..12], 20, .big); // axis record size
    @memcpy(table[16..20], "wght");
    std.mem.writeInt(i32, table[20..24], 900 << 16, .big); // min above max
    std.mem.writeInt(i32, table[24..28], 400 << 16, .big);
    std.mem.writeInt(i32, table[28..32], 100 << 16, .big);
    var font: Font = .{ .data = .{ .data = &.{} } };
    try font.readAxes(.{ .data = &table });
    try std.testing.expectEqual(@as(f32, 100), font.axes[0].min);
    try std.testing.expectEqual(@as(f32, 900), font.axes[0].max);
}

test "simple glyphs reject repeated contour ends" {
    var glyph: [16]u8 = @splat(0);
    std.mem.writeInt(u16, glyph[10..12], 1, .big);
    std.mem.writeInt(u16, glyph[12..14], 1, .big);
    var points: std.ArrayList(Font.Point) = .empty;
    defer points.deinit(std.testing.allocator);
    var ends: std.ArrayList(u16) = .empty;
    defer ends.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidFont, Font.parseSimple(std.testing.allocator, .{ .data = &glyph }, 2, &points, &ends));
}
