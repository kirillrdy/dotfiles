//! A small Cairo-style drawing context over premultiplied native-endian ARGB
//! buffers: transforms, paths, clips, solid and image sources, and the OVER,
//! SOURCE and CLEAR operators. Paths are kept in device space as in Cairo.
const std = @import("std");
const vec = @import("desktop-path.zig");
const raster = @import("desktop-raster.zig");

pub const Operator = enum { over, source, clear };
pub const Filter = enum { bilinear, good };
pub const Extend = enum { none, pad };

/// A borrowed premultiplied ARGB image used as a source.
pub const Image = struct {
    pixels: []const u32,
    width: u32,
    height: u32,
    /// Row stride in pixels.
    stride: u32,

    pub fn fromRaster(image: raster.Image) Image {
        std.debug.assert(image.format == .argb);
        const words: [*]const u32 = @ptrCast(@alignCast(image.pixels.ptr));
        return .{ .pixels = words[0 .. image.stride / 4 * (image.height - 1) + image.width], .width = image.width, .height = image.height, .stride = @intCast(image.stride / 4) };
    }
};

const Pattern = struct {
    image: Image,
    /// Maps device pixel centers to image pixel coordinates.
    inverse: vec.Transform,
    filter: Filter = .good,
    extend: Extend = .none,

    /// Device pixels the image can touch, padded for filter fringes.
    fn bounds(self: *const Pattern) [4]u32 {
        const forward = self.inverse.invert() orelse return .{ 0, 0, std.math.maxInt(u32), std.math.maxInt(u32) };
        const w: f64 = @floatFromInt(self.image.width);
        const h: f64 = @floatFromInt(self.image.height);
        var box = [4]f64{ std.math.inf(f64), std.math.inf(f64), -std.math.inf(f64), -std.math.inf(f64) };
        // Bilinear taps reach half a texel beyond each image edge. GOOD can
        // additionally sample across the destination pixel when shrinking.
        for ([_][2]f64{ .{ -0.5, -0.5 }, .{ w + 0.5, -0.5 }, .{ -0.5, h + 0.5 }, .{ w + 0.5, h + 0.5 } }) |corner| {
            const p = forward.apply(.{ .x = corner[0], .y = corner[1] });
            box = .{ @min(box[0], p.x), @min(box[1], p.y), @max(box[2], p.x), @max(box[3], p.y) };
        }
        const limit: f64 = 1 << 30;
        const pad: f64 = if (self.filter == .good) 0.5 else 0;
        return .{
            @intFromFloat(std.math.clamp(@floor(box[0] - pad), 0, limit)),
            @intFromFloat(std.math.clamp(@floor(box[1] - pad), 0, limit)),
            @intFromFloat(std.math.clamp(@ceil(box[2] + pad), 0, limit)),
            @intFromFloat(std.math.clamp(@ceil(box[3] + pad), 0, limit)),
        };
    }

    inline fn texel(self: *const Pattern, x: i64, y: i64) u32 {
        const w: i64 = self.image.width;
        const h: i64 = self.image.height;
        var cx = x;
        var cy = y;
        if (self.extend == .pad) {
            cx = std.math.clamp(cx, 0, w - 1);
            cy = std.math.clamp(cy, 0, h - 1);
        } else if (cx < 0 or cy < 0 or cx >= w or cy >= h) return 0;
        return self.image.pixels[@as(usize, @intCast(cy)) * self.image.stride + @as(usize, @intCast(cx))];
    }

    /// Bilinear sample at image coordinates where pixel centers lie at +0.5.
    inline fn bilinear(self: *const Pattern, x: f64, y: f64) u32 {
        const fx = x - 0.5;
        const fy = y - 0.5;
        if (!(fx > -1e9 and fx < 1e9 and fy > -1e9 and fy < 1e9)) return 0;
        const x0f = @floor(fx);
        const y0f = @floor(fy);
        const x0: i64 = @intFromFloat(x0f);
        const y0: i64 = @intFromFloat(y0f);
        const wx: u32 = @intFromFloat((fx - x0f) * 256);
        const wy: u32 = @intFromFloat((fy - y0f) * 256);
        const a = self.texel(x0, y0);
        const b = self.texel(x0 + 1, y0);
        const c = self.texel(x0, y0 + 1);
        const d = self.texel(x0 + 1, y0 + 1);
        return lerp(lerp(a, b, wx), lerp(c, d, wx), wy);
    }

    fn sample(self: *const Pattern, x: f64, y: f64) u32 {
        const p = self.inverse.apply(.{ .x = x, .y = y });
        if (self.filter == .good) {
            // Average a grid of bilinear taps across the pixel's footprint when shrinking.
            const sx = @abs(self.inverse.a) + @abs(self.inverse.c);
            const sy = @abs(self.inverse.b) + @abs(self.inverse.d);
            if (sx > 1.01 or sy > 1.01) {
                const nx: u32 = @intFromFloat(std.math.clamp(@ceil(sx), 1, 16));
                const ny: u32 = @intFromFloat(std.math.clamp(@ceil(sy), 1, 16));
                var sum: [4]u32 = @splat(0);
                for (0..ny) |j| for (0..nx) |i| {
                    const ox = ((@as(f64, @floatFromInt(i)) + 0.5) / @as(f64, @floatFromInt(nx)) - 0.5);
                    const oy = ((@as(f64, @floatFromInt(j)) + 0.5) / @as(f64, @floatFromInt(ny)) - 0.5);
                    const q = self.inverse.apply(.{ .x = x + ox, .y = y + oy });
                    const value = self.bilinear(q.x, q.y);
                    inline for (0..4) |k| sum[k] += (value >> (8 * k)) & 255;
                };
                const n = nx * ny;
                var result: u32 = 0;
                inline for (0..4) |k| result |= ((sum[k] + n / 2) / n) << (8 * k);
                return result;
            }
        }
        return self.bilinear(p.x, p.y);
    }
};

fn lerp(a: u32, b: u32, w: u32) u32 {
    if (w == 0) return a;
    const inv = 256 - w;
    const rb = (((a & 0x00ff00ff) * inv + (b & 0x00ff00ff) * w) >> 8) & 0x00ff00ff;
    const ag = ((((a >> 8) & 0x00ff00ff) * inv + ((b >> 8) & 0x00ff00ff) * w) >> 8) & 0x00ff00ff;
    return rb | (ag << 8);
}

const Source = union(enum) {
    solid: u32,
    pattern: Pattern,
};

const State = struct {
    ctm: vec.Transform = .identity,
    source: Source = .{ .solid = 0xff000000 },
    operator: Operator = .over,
    line_width: f64 = 2,
    cap: vec.Cap = .butt,
    join: vec.Join = .miter,
    fill_rule: vec.FillRule = .nonzero,
    clips: usize = 0,
};

/// Cairo's default flattening tolerance in device pixels.
const cairo_tolerance = 0.1;

pub const Context = struct {
    gpa: std.mem.Allocator,
    /// Per-operation temporaries, reset after each fill, stroke or paint.
    scratch: std.heap.ArenaAllocator,
    target: vec.Target,
    path: vec.Path = .{},
    state: State = .{},
    stack: std.ArrayList(State) = .empty,
    /// Each entry is already intersected with the ones before it.
    clips: std.ArrayList(vec.Spans) = .empty,

    pub fn init(gpa: std.mem.Allocator, target: vec.Target) Context {
        return .{ .gpa = gpa, .target = target, .scratch = .init(gpa) };
    }
    pub fn deinit(self: *Context) void {
        self.path.deinit(self.gpa);
        self.scratch.deinit();
        self.stack.deinit(self.gpa);
        for (self.clips.items) |mask| mask.deinit(self.gpa);
        self.clips.deinit(self.gpa);
    }

    pub fn save(self: *Context) void {
        self.stack.append(self.gpa, self.state) catch {};
    }
    pub fn restore(self: *Context) void {
        const previous = self.stack.pop() orelse return;
        while (self.clips.items.len > previous.clips) self.clips.pop().?.deinit(self.gpa);
        self.state = previous;
    }

    pub fn translate(self: *Context, x: f64, y: f64) void {
        self.state.ctm = self.state.ctm.mul(.translate(x, y));
    }
    pub fn scale(self: *Context, x: f64, y: f64) void {
        self.state.ctm = self.state.ctm.mul(.scale(x, y));
    }

    pub fn setOperator(self: *Context, operator: Operator) void {
        self.state.operator = operator;
    }
    pub fn setLineWidth(self: *Context, width: f64) void {
        self.state.line_width = width;
    }
    pub fn setLineCap(self: *Context, cap: vec.Cap) void {
        self.state.cap = cap;
    }
    pub fn setFillRule(self: *Context, rule: vec.FillRule) void {
        self.state.fill_rule = rule;
    }
    pub fn setSourceRgba(self: *Context, red: f64, green: f64, blue: f64, alpha: f64) void {
        self.state.source = .{ .solid = vec.premultiply(red, green, blue, alpha) };
    }
    pub fn setSourceRgb(self: *Context, red: f64, green: f64, blue: f64) void {
        self.setSourceRgba(red, green, blue, 1);
    }
    /// Uses `image` with its origin at user-space (x, y) under the current transform.
    pub fn setSourceImage(self: *Context, image: Image, x: f64, y: f64) void {
        if (image.width == 0 or image.height == 0) {
            self.state.source = .{ .solid = 0 };
            return;
        }
        const inverse = self.state.ctm.mul(.translate(x, y)).invert() orelse {
            self.state.source = .{ .solid = 0 };
            return;
        };
        self.state.source = .{ .pattern = .{ .image = image, .inverse = inverse } };
    }
    pub fn setFilter(self: *Context, filter: Filter) void {
        switch (self.state.source) {
            .pattern => |*pattern| pattern.filter = filter,
            .solid => {},
        }
    }
    pub fn setExtend(self: *Context, extend: Extend) void {
        switch (self.state.source) {
            .pattern => |*pattern| pattern.extend = extend,
            .solid => {},
        }
    }

    fn device(self: *const Context, x: f64, y: f64) vec.Point {
        return self.state.ctm.apply(.{ .x = x, .y = y });
    }
    pub fn newSubPath(self: *Context) void {
        self.path.current = null;
    }
    pub fn moveTo(self: *Context, x: f64, y: f64) void {
        self.path.moveTo(self.gpa, self.device(x, y)) catch {};
    }
    pub fn lineTo(self: *Context, x: f64, y: f64) void {
        self.path.lineTo(self.gpa, self.device(x, y)) catch {};
    }
    pub fn closePath(self: *Context) void {
        self.path.close(self.gpa) catch {};
    }
    pub fn rectangle(self: *Context, x: f64, y: f64, width: f64, height: f64) void {
        self.moveTo(x, y);
        self.lineTo(x + width, y);
        self.lineTo(x + width, y + height);
        self.lineTo(x, y + height);
        self.closePath();
    }
    /// Cairo's arc: continues the current subpath with a line to the arc's start.
    pub fn arc(self: *Context, cx: f64, cy: f64, radius: f64, start: f64, end: f64) void {
        var user: vec.Path = .{};
        defer user.deinit(self.gpa);
        if (self.path.current) |current| {
            if (self.state.ctm.invert()) |inverse| user.moveTo(self.gpa, inverse.apply(current)) catch return;
        }
        var finish = end;
        while (finish < start) finish += 2 * std.math.pi;
        user.ellipticalArc(self.gpa, .{ .x = cx, .y = cy }, radius, radius, 0, start, finish - start) catch return;
        var index: usize = 0;
        for (user.verbs.items, 0..) |verb, i| {
            const t = self.state.ctm;
            switch (verb) {
                .move => {
                    // Skip the seed point; the arc's own first verb follows it.
                    if (i == 0 and self.path.current != null) {
                        index += 1;
                        continue;
                    }
                    self.path.moveTo(self.gpa, t.apply(user.points.items[index])) catch return;
                    index += 1;
                },
                .line => {
                    self.path.lineTo(self.gpa, t.apply(user.points.items[index])) catch return;
                    index += 1;
                },
                .cubic => {
                    const p = user.points.items[index..][0..3];
                    self.path.cubicTo(self.gpa, t.apply(p[0]), t.apply(p[1]), t.apply(p[2])) catch return;
                    index += 3;
                },
                .quad, .close => {},
            }
        }
    }

    pub fn fill(self: *Context) void {
        defer _ = self.scratch.reset(.retain_capacity);
        const spans = vec.fillSpans(self.scratch.allocator(), self.path, .identity, self.state.fill_rule, self.target.width, self.target.height, cairo_tolerance) catch vec.Spans{};
        self.path.clear();
        self.composite(spans, 1);
    }

    pub fn stroke(self: *Context) void {
        const width = self.state.line_width * self.state.ctm.scaleFactor();
        defer _ = self.scratch.reset(.retain_capacity);
        const spans = vec.strokeSpans(self.scratch.allocator(), self.path, .identity, .{ .width = width, .cap = self.state.cap, .join = self.state.join }, self.target.width, self.target.height, cairo_tolerance) catch vec.Spans{};
        self.path.clear();
        self.composite(spans, 1);
    }

    pub fn paint(self: *Context) void {
        self.paintWithAlpha(1);
    }
    pub fn paintWithAlpha(self: *Context, alpha: f64) void {
        defer _ = self.scratch.reset(.retain_capacity);
        self.composite(null, @floatCast(std.math.clamp(alpha, 0, 1)));
    }

    /// Intersects the clip with the current path and clears the path.
    pub fn clip(self: *Context) void {
        var spans = vec.fillSpans(self.gpa, self.path, .identity, self.state.fill_rule, self.target.width, self.target.height, cairo_tolerance) catch vec.Spans{};
        self.path.clear();
        if (self.currentClip()) |previous| {
            const combined = vec.Spans.intersect(self.gpa, spans, previous.*) catch vec.Spans{};
            spans.deinit(self.gpa);
            spans = combined;
        }
        self.clips.append(self.gpa, spans) catch {
            spans.deinit(self.gpa);
            return;
        };
        self.state.clips = self.clips.items.len;
    }

    fn currentClip(self: *const Context) ?*const vec.Spans {
        if (self.state.clips == 0) return null;
        return &self.clips.items[self.state.clips - 1];
    }

    /// Blends the source through `shape` (or everywhere for paint), the clip and `alpha`.
    /// Only runs with coverage are visited, as Cairo's span compositor does.
    fn composite(self: *Context, shape: ?vec.Spans, alpha: f32) void {
        // Indices below are bounded by the clipped region; avoid per-pixel checks.
        @setRuntimeSafety(false);
        var x0: u32 = 0;
        var y0: u32 = 0;
        var x1 = self.target.width;
        var y1 = self.target.height;
        if (shape) |spans| {
            if (spans.empty()) return;
            x0 = spans.x0;
            y0 = spans.y;
            x1 = spans.x1;
            y1 = spans.y + spans.height;
        }
        const clip_spans = self.currentClip();
        if (clip_spans) |spans| {
            if (spans.empty()) return;
            x0 = @max(x0, spans.x0);
            y0 = @max(y0, spans.y);
            x1 = @min(x1, spans.x1);
            y1 = @min(y1, spans.y + spans.height);
        }
        const operator = self.state.operator;
        // Outside an unextended image OVER changes nothing, so bound the region to it.
        switch (self.state.source) {
            .pattern => |pattern| if (pattern.extend == .none and operator == .over) {
                const b = pattern.bounds();
                x0 = @max(x0, b[0]);
                y0 = @max(y0, b[1]);
                x1 = @min(x1, b[2]);
                y1 = @min(y1, b[3]);
            },
            .solid => {},
        }
        if (x1 <= x0 or y1 <= y0 or alpha <= 0) return;
        const width = x1 - x0;
        // Temporaries live in the scratch arena; the caller or paint resets it.
        const a = self.scratch.allocator();
        const colors = a.alloc(u32, width) catch return;
        var runs: std.ArrayList(vec.Spans.Run) = .empty;
        var axis: ?AxisSampler = null;
        switch (self.state.source) {
            .solid => |value| @memset(colors, value),
            .pattern => |*pattern| axis = AxisSampler.init(a, pattern, x0, x1) catch null,
        }
        const full = [_]vec.Spans.Run{.{ .x = x0, .len = width, .alpha = 1 }};
        for (y0..y1) |y| {
            // Coverage runs of this row, limited to the region.
            runs.clearRetainingCapacity();
            const base: []const vec.Spans.Run = if (shape) |spans| spans.row(y) else &full;
            const other: []const vec.Spans.Run = if (clip_spans) |spans| spans.row(y) else &full;
            var i: usize = 0;
            var j: usize = 0;
            while (i < base.len and j < other.len) {
                const r = base[i];
                const s = other[j];
                const start = @max(@max(r.x, s.x), x0);
                const end = @min(@min(r.x + r.len, s.x + s.len), x1);
                if (end > start) {
                    const factor: u32 = @intFromFloat(@round(@min(r.alpha * s.alpha * alpha, 1) * 255));
                    if (factor != 0) runs.append(a, .{ .x = start, .len = end - start, .alpha = @floatFromInt(factor) }) catch return;
                }
                if (r.x + r.len <= s.x + s.len) i += 1 else j += 1;
            }
            if (runs.items.len == 0) continue;
            const line = self.target.pixels[y * self.target.stride ..];
            if (operator == .clear) {
                for (runs.items) |run| {
                    const factor: u32 = @intFromFloat(run.alpha);
                    for (line[run.x..][0..run.len]) |*pixel| pixel.* = vec.fade(pixel.*, 255 - factor);
                }
                continue;
            }
            // Sample the image only across the touched columns.
            switch (self.state.source) {
                .solid => {},
                .pattern => |*pattern| {
                    const first = runs.items[0].x;
                    const last = runs.items[runs.items.len - 1].x + runs.items[runs.items.len - 1].len;
                    const out = colors[first - x0 .. last - x0];
                    if (axis) |*sampler| {
                        sampler.row(@intCast(y), first - x0, out);
                    } else {
                        const fy = @as(f64, @floatFromInt(y)) + 0.5;
                        for (out, first..) |*color, x| color.* = pattern.sample(@as(f64, @floatFromInt(x)) + 0.5, fy);
                    }
                },
            }
            for (runs.items) |run| {
                const factor: u32 = @intFromFloat(run.alpha);
                const pixels = line[run.x..][0..run.len];
                const source = colors[run.x - x0 ..][0..run.len];
                switch (operator) {
                    .over => switch (self.state.source) {
                        // One faded color per run: blend as a solid fill.
                        .solid => |color| vec.overSolid(pixels, if (factor == 255) color else vec.fade(color, factor)),
                        .pattern => vec.overSpan(pixels, source, factor),
                    },
                    .source => if (factor == 255) {
                        @memcpy(pixels, source);
                    } else {
                        for (pixels, source) |*pixel, color| pixel.* = vec.fade(color, factor) +% vec.fade(pixel.*, 255 - factor);
                    },
                    .clear => unreachable,
                }
            }
        }
    }
};

/// Per-axis filter taps for an axis-aligned image source: bilinear pairs, or
/// area-weighted spans when the GOOD filter shrinks. Weights sum to 256.
const Taps = struct {
    first: []i32,
    count: []u8,
    weights: []u16,
    stride: usize,

    fn init(a: std.mem.Allocator, start: u32, len: u32, scale: f64, offset: f64, size: u32, filter: Filter, extend: Extend) !Taps {
        const box = filter == .good and scale > 1.01;
        const stride: usize = if (box) @intFromFloat(@min(@ceil(scale) + 2, 64)) else 2;
        const taps: Taps = .{
            .first = try a.alloc(i32, len),
            .count = try a.alloc(u8, len),
            .weights = try a.alloc(u16, len * stride),
            .stride = stride,
        };
        @memset(taps.weights, 0);
        @memset(taps.first, 0);
        const limit: f64 = @floatFromInt(size);
        for (0..len) |i| {
            const center = (@as(f64, @floatFromInt(start + i)) + 0.5) * scale + offset;
            if (!box) {
                const tap = bilinearTap(center, size, extend);
                taps.first[i] = tap.first;
                taps.count[i] = tap.count;
                taps.weights[i * 2] = tap.w0;
                taps.weights[i * 2 + 1] = tap.w1;
                continue;
            }
            var raw: [64]f64 = undefined;
            const lo = center - scale / 2;
            const hi = center + scale / 2;
            const first = @floor(lo);
            var n: usize = 0;
            var pos = first;
            while (pos < hi and n < stride) : (pos += 1) {
                raw[n] = @max(0, @min(pos + 1, hi) - @max(pos, lo));
                n += 1;
            }
            // Resolve each tap against the edges: pad clamps, none drops.
            var base: ?i32 = null;
            var last: i32 = 0;
            var resolved: [64]f64 = @splat(0);
            var total: f64 = 0;
            for (raw[0..n], 0..) |w, tap_idx| {
                var index = first + @as(f64, @floatFromInt(tap_idx));
                if (index < 0 or index >= limit) {
                    if (extend == .none) continue;
                    index = std.math.clamp(index, 0, limit - 1);
                }
                const idx: i32 = @intFromFloat(index);
                const b = base orelse blk: {
                    base = idx;
                    break :blk idx;
                };
                const slot: usize = @intCast(idx - b);
                if (slot < stride) resolved[slot] += w;
                last = idx;
                total += w;
            }
            const first_idx = base orelse 0;
            const count: usize = if (base != null) @intCast(@min(@as(i32, @intCast(stride)), last - first_idx + 1)) else 0;
            taps.first[i] = first_idx;
            taps.count[i] = @intCast(if (total > 0) count else 0);
            // Edge pixels with `none` keep their partial weight, fading out as Cairo does.
            const divisor: f64 = if (extend == .none) scale else total;
            var sum: u32 = 0;
            for (0..count) |k| {
                const w: u16 = @intFromFloat(@round(resolved[k] / divisor * 256));
                taps.weights[i * stride + k] = w;
                sum += w;
            }
            // Put rounding error on the heaviest tap so full coverage stays exact.
            if (count > 0 and (extend == .pad or sum > 256)) {
                var heaviest: usize = 0;
                for (1..count) |k| if (taps.weights[i * stride + k] > taps.weights[i * stride + heaviest]) {
                    heaviest = k;
                };
                const target: u32 = if (extend == .pad) 256 else @min(sum, 256);
                taps.weights[i * stride + heaviest] = @intCast(@as(i32, taps.weights[i * stride + heaviest]) + @as(i32, @intCast(target)) - @as(i32, @intCast(sum)));
            }
        }
        return taps;
    }
};

/// Samples rows of an image whose transform has no rotation or skew.
const AxisSampler = struct {
    pattern: *const Pattern,
    columns: Taps,
    /// One vertically blended source row.
    scratch: []u32,

    fn init(a: std.mem.Allocator, pattern: *const Pattern, x0: u32, x1: u32) !?AxisSampler {
        const t = pattern.inverse;
        if (@abs(t.b) > 1e-9 or @abs(t.c) > 1e-9 or !(t.a > 0) or !(t.d > 0)) return null;
        return .{
            .pattern = pattern,
            .columns = try Taps.init(a, x0, x1 - x0, t.a, t.e, pattern.image.width, pattern.filter, pattern.extend),
            .scratch = try a.alloc(u32, pattern.image.width + 1),
        };
    }

    /// Samples row `y` for region columns starting at `offset` into `out`.
    fn row(self: *AxisSampler, y: u32, offset: usize, out: []u32) void {
        // Tap indices are resolved within the image bounds by Taps.init.
        @setRuntimeSafety(false);
        const p = self.pattern;
        const t = p.inverse;
        // Rows are resolved one at a time; the arena-free stack copy suffices.
        var weights: [64]u16 = undefined;
        var single: Taps = .{ .first = undefined, .count = undefined, .weights = &weights, .stride = 0 };
        var first: [1]i32 = undefined;
        var count: [1]u8 = undefined;
        single.first = &first;
        single.count = &count;
        rowTaps(&single, y, t.d, t.f, p.image.height, p.filter, p.extend);
        const image = p.image;
        const columns = &self.columns;
        const row_count = count[0];
        if (row_count == 0) {
            @memset(out, 0);
            return;
        }
        if (row_count <= 2 and columns.stride == 2) {
            // Bilinear, separable as in pixman: blend the two source rows once
            // (SIMD), then each output pixel mixes two neighbours of that row.
            const r0 = image.pixels[@as(usize, @intCast(first[0])) * image.stride ..];
            const r1 = if (row_count == 2) image.pixels[@as(usize, @intCast(first[0] + 1)) * image.stride ..] else r0;
            const w0: u32 = weights[0];
            const w1: u32 = if (row_count == 2) weights[1] else 0;
            const last = image.width - 1;
            const lo: usize = @intCast(columns.first[offset]);
            const hi: usize = @min(@as(usize, @intCast(columns.first[offset + out.len - 1])) + 1, last);
            if (hi >= lo) blendRows(self.scratch[lo .. hi + 1], r0[lo .. hi + 1], r1[lo .. hi + 1], w0, w1);
            mixColumns(out, self.scratch, columns, offset, last);
            return;
        }
        // General separable area filter with per-channel accumulators.
        for (out, offset..) |*pixel, i| {
            const n = columns.count[i];
            const x: usize = @intCast(@max(columns.first[i], 0));
            var acc: [4]u32 = @splat(0);
            for (0..row_count) |ry| {
                const src = image.pixels[(@as(usize, @intCast(first[0])) + ry) * image.stride + x ..];
                var h: [4]u32 = @splat(0);
                for (0..n) |k| {
                    const w: u32 = columns.weights[i * columns.stride + k];
                    const value = src[k];
                    inline for (0..4) |ch| h[ch] += ((value >> (8 * ch)) & 255) * w;
                }
                const wy: u32 = weights[ry];
                inline for (0..4) |ch| acc[ch] += h[ch] * wy;
            }
            var result: u32 = 0;
            inline for (0..4) |ch| result |= @as(u32, @min(255, (acc[ch] + 32768) >> 16)) << @as(u5, 8 * ch);
            pixel.* = result;
        }
    }
};

fn rowTaps(taps: *Taps, y: u32, scale: f64, offset: f64, size: u32, filter: Filter, extend: Extend) void {
    if (!(filter == .good and scale > 1.01)) {
        // Bilinear rows need just two weights; skip the general tap builder.
        const tap = bilinearTap((@as(f64, @floatFromInt(y)) + 0.5) * scale + offset, size, extend);
        taps.first[0] = tap.first;
        taps.count[0] = tap.count;
        taps.weights[0] = tap.w0;
        taps.weights[1] = tap.w1;
        return;
    }
    var buffer: [4096]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
    const computed = Taps.init(fixed.allocator(), y, 1, scale, offset, size, filter, extend) catch {
        taps.count[0] = 0;
        return;
    };
    taps.first[0] = computed.first[0];
    taps.count[0] = computed.count[0];
    @memcpy(taps.weights[0..computed.count[0]], computed.weights[0..computed.count[0]]);
}

test "canvas fills, strokes, clips and paints with Cairo operator semantics" {
    const a = std.testing.allocator;
    var target = try vec.Target.init(a, 20, 20);
    defer target.deinit(a);
    var cr = Context.init(a, target);
    defer cr.deinit();
    cr.setSourceRgb(1, 0, 0);
    cr.paint();
    try std.testing.expectEqual(@as(u32, 0xffff0000), target.pixels[0]);
    cr.save();
    cr.scale(2, 2);
    cr.rectangle(1, 1, 4, 4);
    cr.clip();
    cr.setSourceRgba(0, 0, 1, 1);
    cr.paint();
    cr.restore();
    try std.testing.expectEqual(@as(u32, 0xff0000ff), target.pixels[5 * 20 + 5]);
    try std.testing.expectEqual(@as(u32, 0xffff0000), target.pixels[12 * 20 + 12]);
    cr.setOperator(.clear);
    cr.rectangle(15, 15, 5, 5);
    cr.fill();
    try std.testing.expectEqual(@as(u32, 0), target.pixels[19 * 20 + 19]);
    cr.setOperator(.over);
    cr.setSourceRgb(0, 1, 0);
    cr.setLineWidth(2);
    cr.moveTo(0, 10);
    cr.lineTo(20, 10);
    cr.stroke();
    try std.testing.expectEqual(@as(u32, 0xff00ff00), target.pixels[9 * 20 + 3]);
    try std.testing.expectEqual(@as(u32, 0xff00ff00), target.pixels[10 * 20 + 3]);
    try std.testing.expectEqual(@as(u32, 0xffff0000), target.pixels[11 * 20 + 3]);
}

test "canvas image sources scale with padding, filters and alpha" {
    const a = std.testing.allocator;
    var target = try vec.Target.init(a, 8, 8);
    defer target.deinit(a);
    var cr = Context.init(a, target);
    defer cr.deinit();
    const pixels = [_]u32{ 0xffff0000, 0xff0000ff, 0xff0000ff, 0xffff0000 };
    const image: Image = .{ .pixels = &pixels, .width = 2, .height = 2, .stride = 2 };
    cr.scale(4, 4);
    cr.setSourceImage(image, 0, 0);
    cr.setExtend(.pad);
    cr.setFilter(.bilinear);
    cr.paintWithAlpha(1);
    // Corners keep their texel color thanks to padding; the center blends.
    try std.testing.expectEqual(@as(u32, 0xffff0000), target.pixels[0]);
    try std.testing.expectEqual(@as(u32, 0xff0000ff), target.pixels[7]);
    const center = target.pixels[3 * 8 + 3];
    try std.testing.expect((center >> 16 & 255) > 0 and (center & 255) > 0);
    // Downscaling with the good filter averages the checkerboard.
    var small = try vec.Target.init(a, 1, 1);
    defer small.deinit(a);
    var tiny = Context.init(a, small);
    defer tiny.deinit();
    tiny.scale(0.5, 0.5);
    tiny.setSourceImage(image, 0, 0);
    tiny.paint();
    try std.testing.expectEqual(@as(u32, 0xff800080), small.pixels[0]);
}

test "canvas arcs continue the current point and close rounded shapes" {
    const a = std.testing.allocator;
    var target = try vec.Target.init(a, 40, 40);
    defer target.deinit(a);
    var cr = Context.init(a, target);
    defer cr.deinit();
    cr.newSubPath();
    cr.arc(20, 20, 10, 0, 2 * std.math.pi);
    cr.setSourceRgb(1, 1, 1);
    cr.fill();
    var area: f64 = 0;
    for (target.pixels) |pixel| area += @as(f64, @floatFromInt(pixel >> 24)) / 255;
    // Cairo's 0.1 px flattening tolerance inscribes chords, losing about 1% here.
    try std.testing.expectApproxEqRel(std.math.pi * 100, area, 0.02);
}

test "unextended image bounds include the scaled bilinear fringe" {
    const a = std.testing.allocator;
    const target = try vec.Target.init(a, 32, 32);
    defer target.deinit(a);
    var cr = Context.init(a, target);
    defer cr.deinit();
    cr.translate(8, 8);
    cr.scale(8, 8);
    cr.setSourceImage(.{ .pixels = &.{0xffffffff}, .width = 1, .height = 1, .stride = 1 }, 0, 0);
    cr.setFilter(.bilinear);
    cr.paint();
    try std.testing.expectEqual(@as(u32, 75), target.pixels[11 * target.stride + 6] >> 24);
    try std.testing.expectEqual(@as(u32, 75), target.pixels[11 * target.stride + 17] >> 24);
    try std.testing.expectEqual(@as(u32, 0), target.pixels[11 * target.stride + 3] >> 24);
}

/// Weighted sum of two premultiplied pixels; weights are out of 256.
inline fn mixPair(a: u32, b: u32, wa: u32, wb: u32) u32 {
    // Each 16-bit lane holds at most 255 * 256 + 128, so wrapping ops are exact.
    const rb = (((a & 0x00ff00ff) *% wa +% (b & 0x00ff00ff) *% wb +% 0x00800080) >> 8) & 0x00ff00ff;
    const ag = ((((a >> 8) & 0x00ff00ff) *% wa +% ((b >> 8) & 0x00ff00ff) *% wb +% 0x00800080) >> 8) & 0x00ff00ff;
    return rb | (ag << 8);
}

/// out = (top * w0 + bottom * w1) / 256 per channel, four pixels per vector.
fn blendRows(out: []u32, top: []const u32, bottom: []const u32, w0: u32, w1: u32) void {
    @setRuntimeSafety(false);
    if (w1 == 0 and w0 == 256) return @memcpy(out, top);
    const Lanes = @Vector(16, u16);
    const Bytes = @Vector(16, u8);
    const a: Lanes = @splat(@intCast(w0));
    const b: Lanes = @splat(@intCast(w1));
    const half: Lanes = @splat(128);
    var i: usize = 0;
    while (i + 4 <= out.len) : (i += 4) {
        const t: Lanes = @as(Bytes, @bitCast(top[i..][0..4].*));
        const u: Lanes = @as(Bytes, @bitCast(bottom[i..][0..4].*));
        // Weights sum to at most 256, so every lane stays within 16 bits.
        const v = (t *% a +% u *% b +% half) >> @splat(8);
        out[i..][0..4].* = @bitCast(@as(Bytes, @truncate(v)));
    }
    while (i < out.len) : (i += 1) out[i] = mixPair(top[i], bottom[i], w0, w1);
}

const BilinearTap = struct { first: i32, count: u8, w0: u16, w1: u16 };

/// The two texels around sample position `center` (pixel centers at +0.5),
/// resolved against the edges: padding clamps, no extend drops weight.
fn bilinearTap(center: f64, size: u32, extend: Extend) BilinearTap {
    const f = center - 0.5;
    const fl = @floor(f);
    const w1: u16 = @intFromFloat(@round((f - fl) * 256));
    const limit: f64 = @floatFromInt(size);
    const size_i: i64 = size;
    var x0: i64 = @intFromFloat(std.math.clamp(fl, -2, limit + 1));
    var x1: i64 = x0 + 1;
    var weight0: u16 = 256 - w1;
    var weight1: u16 = w1;
    if (extend == .none) {
        if (x0 < 0 or x0 >= size_i) weight0 = 0;
        if (x1 < 0 or x1 >= size_i) weight1 = 0;
    }
    x0 = std.math.clamp(x0, 0, size_i - 1);
    x1 = std.math.clamp(x1, 0, size_i - 1);
    if (x0 == x1) return .{ .first = @intCast(x0), .count = if (weight0 + weight1 > 0) 1 else 0, .w0 = weight0 + weight1, .w1 = 0 };
    return .{ .first = @intCast(x0), .count = 2, .w0 = weight0, .w1 = weight1 };
}

/// Horizontal bilinear step: out[k] mixes row[x] and row[x + 1] for each
/// column's taps, four pixels per vector with per-pixel weights.
fn mixColumns(out: []u32, row: []const u32, columns: *const Taps, offset: usize, last: usize) void {
    @setRuntimeSafety(false);
    const Lanes = @Vector(16, u16);
    const Bytes = @Vector(16, u8);
    const spread: @Vector(16, i32) = .{ 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3 };
    const half: Lanes = @splat(128);
    var k: usize = 0;
    while (k + 4 <= out.len) : (k += 4) {
        var left: [4]u32 = undefined;
        var right: [4]u32 = undefined;
        var wl: @Vector(4, u16) = undefined;
        var wr: @Vector(4, u16) = undefined;
        inline for (0..4) |j| {
            const i = offset + k + j;
            const x: usize = @intCast(columns.first[i]);
            left[j] = row[x];
            right[j] = row[@min(x + 1, last)];
            wl[j] = columns.weights[i * 2];
            wr[j] = columns.weights[i * 2 + 1];
        }
        const a: Lanes = @as(Bytes, @bitCast(left));
        const b: Lanes = @as(Bytes, @bitCast(right));
        const v = (a *% @shuffle(u16, wl, undefined, spread) +% b *% @shuffle(u16, wr, undefined, spread) +% half) >> @splat(8);
        out[k..][0..4].* = @bitCast(@as(Bytes, @truncate(v)));
    }
    while (k < out.len) : (k += 1) {
        const i = offset + k;
        const x: usize = @intCast(columns.first[i]);
        out[k] = mixPair(row[x], row[@min(x + 1, last)], columns.weights[i * 2], columns.weights[i * 2 + 1]);
    }
}
