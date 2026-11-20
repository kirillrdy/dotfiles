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

pub const Context = struct {
    gpa: std.mem.Allocator,
    target: vec.Target,
    path: vec.Path = .{},
    state: State = .{},
    stack: std.ArrayList(State) = .empty,
    /// Each entry is already intersected with the ones before it.
    clips: std.ArrayList(vec.Mask) = .empty,

    pub fn init(gpa: std.mem.Allocator, target: vec.Target) Context {
        return .{ .gpa = gpa, .target = target };
    }
    /// Wraps borrowed ARGB storage whose stride is given in bytes.
    pub fn forBytes(gpa: std.mem.Allocator, pixels: []align(@alignOf(u32)) u8, width: u32, height: u32, stride: usize) Context {
        return init(gpa, vec.Target.fromBytes(pixels, width, height, stride));
    }
    pub fn deinit(self: *Context) void {
        self.path.deinit(self.gpa);
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
    pub fn newPath(self: *Context) void {
        self.path.clear();
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
        const mask = vec.fillMask(self.gpa, self.path, .identity, self.state.fill_rule, self.target.width, self.target.height) catch {
            self.path.clear();
            return;
        };
        defer mask.deinit(self.gpa);
        self.path.clear();
        self.composite(mask, 1);
    }

    pub fn stroke(self: *Context) void {
        const width = self.state.line_width * self.state.ctm.scaleFactor();
        const mask = vec.strokeMask(self.gpa, self.path, .identity, .{ .width = width, .cap = self.state.cap, .join = self.state.join }, self.target.width, self.target.height) catch {
            self.path.clear();
            return;
        };
        defer mask.deinit(self.gpa);
        self.path.clear();
        self.composite(mask, 1);
    }

    pub fn paint(self: *Context) void {
        self.paintWithAlpha(1);
    }
    pub fn paintWithAlpha(self: *Context, alpha: f64) void {
        self.composite(null, @floatCast(std.math.clamp(alpha, 0, 1)));
    }

    /// Intersects the clip with the current path and clears the path.
    pub fn clip(self: *Context) void {
        var mask = vec.fillMask(self.gpa, self.path, .identity, self.state.fill_rule, self.target.width, self.target.height) catch vec.Mask{};
        self.path.clear();
        if (self.currentClip()) |previous| {
            const x0 = @max(mask.x, previous.x);
            const y0 = @max(mask.y, previous.y);
            const x1 = @min(mask.x + mask.width, previous.x + previous.width);
            const y1 = @min(mask.y + mask.height, previous.y + previous.height);
            var combined: vec.Mask = .{};
            if (x1 > x0 and y1 > y0) {
                if (self.gpa.alloc(f32, @as(usize, x1 - x0) * (y1 - y0))) |alpha| {
                    combined = .{ .x = x0, .y = y0, .width = x1 - x0, .height = y1 - y0, .alpha = alpha };
                    for (0..combined.height) |row| for (0..combined.width) |column| {
                        const x: u32 = @intCast(x0 + column);
                        const y: u32 = @intCast(y0 + row);
                        alpha[row * combined.width + column] = mask.at(x, y) * previous.at(x, y);
                    };
                } else |_| {}
            }
            mask.deinit(self.gpa);
            mask = combined;
        }
        self.clips.append(self.gpa, mask) catch {
            mask.deinit(self.gpa);
            return;
        };
        self.state.clips = self.clips.items.len;
    }

    fn currentClip(self: *const Context) ?*const vec.Mask {
        if (self.state.clips == 0) return null;
        return &self.clips.items[self.state.clips - 1];
    }

    fn composite(self: *Context, shape: ?vec.Mask, alpha: f32) void {
        // Indices below are bounded by the clipped region; avoid per-pixel checks.
        @setRuntimeSafety(false);
        var x0: u32 = 0;
        var y0: u32 = 0;
        var x1 = self.target.width;
        var y1 = self.target.height;
        if (shape) |mask| {
            x0 = mask.x;
            y0 = mask.y;
            x1 = mask.x + mask.width;
            y1 = mask.y + mask.height;
        }
        const clip_mask = self.currentClip();
        if (clip_mask) |mask| {
            x0 = @max(x0, mask.x);
            y0 = @max(y0, mask.y);
            x1 = @min(x1, mask.x + mask.width);
            y1 = @min(y1, mask.y + mask.height);
        }
        if (x1 <= x0 or y1 <= y0 or alpha <= 0) return;
        const width = x1 - x0;
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const coverage = a.alloc(u8, width) catch return;
        const colors = a.alloc(u32, width) catch return;
        const operator = self.state.operator;
        var axis: ?AxisSampler = null;
        switch (self.state.source) {
            .solid => |value| @memset(colors, value),
            .pattern => |*pattern| axis = AxisSampler.init(a, pattern, x0, x1) catch null,
        }
        const global: u32 = @intFromFloat(@round(@min(alpha, 1) * 255));
        for (y0..y1) |y| {
            // Combine shape, clip and global alpha into one byte per pixel.
            var any = false;
            const shape_row: ?[]const f32 = if (shape) |mask| mask.alpha[(y - mask.y) * mask.width + (x0 - mask.x) ..][0..width] else null;
            const clip_row: ?[]const f32 = if (clip_mask) |mask| mask.alpha[(y - mask.y) * mask.width + (x0 - mask.x) ..][0..width] else null;
            for (coverage, 0..) |*value, i| {
                var c: f32 = 1;
                if (shape_row) |row| c *= row[i];
                if (clip_row) |row| c *= row[i];
                // Interior pixels are exactly 1; skip the rounding and division there.
                if (c >= 1 and global == 255) {
                    value.* = 255;
                    any = true;
                    continue;
                }
                if (c <= 0) {
                    value.* = 0;
                    continue;
                }
                const byte: u32 = @intFromFloat(c * (@as(f32, @floatFromInt(global)) * (255.0 / 255.0)) + 0.5);
                value.* = @intCast(@min(byte, 255));
                any = any or value.* != 0;
            }
            if (!any) continue;
            const line = self.target.pixels[y * self.target.stride + x0 ..][0..width];
            if (operator == .clear) {
                for (line, coverage) |*pixel, factor| {
                    if (factor != 0) pixel.* = vec.fade(pixel.*, 255 - @as(u32, factor));
                }
                continue;
            }
            switch (self.state.source) {
                .solid => {},
                .pattern => |*pattern| if (axis) |*sampler| {
                    sampler.row(@intCast(y), colors);
                } else {
                    const fy = @as(f64, @floatFromInt(y)) + 0.5;
                    for (colors, coverage, x0..) |*color, factor, x| {
                        if (factor != 0) color.* = pattern.sample(@as(f64, @floatFromInt(x)) + 0.5, fy);
                    }
                },
            }
            switch (operator) {
                .over => for (line, colors, coverage) |*pixel, color, factor| {
                    if (factor == 255) {
                        pixel.* = if (color >> 24 == 255) color else vec.over(pixel.*, color);
                    } else if (factor != 0) {
                        pixel.* = vec.over(pixel.*, vec.fade(color, factor));
                    }
                },
                .source => for (line, colors, coverage) |*pixel, color, factor| {
                    if (factor == 255) {
                        pixel.* = color;
                    } else if (factor != 0) {
                        pixel.* = vec.fade(color, factor) +% vec.fade(pixel.*, 255 - @as(u32, factor));
                    }
                },
                .clear => unreachable,
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
            var raw: [64]f64 = undefined;
            var first: f64 = undefined;
            var n: usize = 0;
            if (box) {
                const lo = center - scale / 2;
                const hi = center + scale / 2;
                first = @floor(lo);
                var k = first;
                while (k < hi and n < stride) : (k += 1) {
                    raw[n] = @max(0, @min(k + 1, hi) - @max(k, lo));
                    n += 1;
                }
            } else {
                const f = center - 0.5;
                first = @floor(f);
                const t = f - first;
                raw[0] = 1 - t;
                raw[1] = t;
                n = 2;
            }
            // Resolve each tap against the edges: pad clamps, none drops.
            var resolved_first: i32 = std.math.maxInt(i32);
            var resolved: [64]f64 = @splat(0);
            var total: f64 = 0;
            for (raw[0..n], 0..) |w, k| {
                var index = first + @as(f64, @floatFromInt(k));
                if (index < 0 or index >= limit) {
                    if (extend == .none) continue;
                    index = std.math.clamp(index, 0, limit - 1);
                }
                const idx: i32 = @intFromFloat(index);
                resolved_first = @min(resolved_first, idx);
                total += w;
            }
            // Second pass, now that the first index is known.
            const base: i32 = if (resolved_first == std.math.maxInt(i32)) 0 else resolved_first;
            var last: i32 = base;
            for (raw[0..n], 0..) |w, k| {
                var index = first + @as(f64, @floatFromInt(k));
                if (index < 0 or index >= limit) {
                    if (extend == .none) continue;
                    index = std.math.clamp(index, 0, limit - 1);
                }
                const idx: i32 = @intFromFloat(index);
                const slot: usize = @intCast(idx - base);
                if (slot < stride) resolved[slot] += w;
                last = @max(last, idx);
            }
            const count: usize = @intCast(@min(@as(i32, @intCast(stride)), last - base + 1));
            taps.first[i] = base;
            taps.count[i] = @intCast(if (total > 0) count else 0);
            // Edge pixels with `none` keep their partial weight, fading out as Cairo does.
            const divisor: f64 = if (extend == .none) (if (box) scale else 1) else total;
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

    fn init(a: std.mem.Allocator, pattern: *const Pattern, x0: u32, x1: u32) !?AxisSampler {
        const t = pattern.inverse;
        if (@abs(t.b) > 1e-9 or @abs(t.c) > 1e-9 or !(t.a > 0) or !(t.d > 0)) return null;
        return .{
            .pattern = pattern,
            .columns = try Taps.init(a, x0, x1 - x0, t.a, t.e, pattern.image.width, pattern.filter, pattern.extend),
        };
    }

    fn row(self: *AxisSampler, y: u32, out: []u32) void {
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
            // Bilinear: four channels per vector; unused taps carry zero weight.
            const r0 = image.pixels[@as(usize, @intCast(first[0])) * image.stride ..];
            const r1 = if (row_count == 2) image.pixels[@as(usize, @intCast(first[0] + 1)) * image.stride ..] else r0;
            const wy0: V16 = @splat(weights[0]);
            const wy1: V16 = @splat(if (row_count == 2) weights[1] else 0);
            const half: V16 = @splat(128);
            const last = image.width - 1;
            for (out, 0..) |*pixel, i| {
                const x: usize = @intCast(columns.first[i]);
                const x1 = @min(x + 1, last);
                const wx0: V16 = @splat(columns.weights[i * 2]);
                const wx1: V16 = @splat(columns.weights[i * 2 + 1]);
                // Each product fits 16 bits because paired weights sum to 256.
                const top = (unpack16(r0[x]) *% wx0 +% unpack16(r0[x1]) *% wx1 +% half) >> @splat(8);
                const bottom = (unpack16(r1[x]) *% wx0 +% unpack16(r1[x1]) *% wx1 +% half) >> @splat(8);
                pixel.* = pack16((top *% wy0 +% bottom *% wy1 +% half) >> @splat(8));
            }
            return;
        }
        // General separable area filter with per-channel accumulators.
        for (out, 0..) |*pixel, i| {
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

const V16 = @Vector(4, u16);

inline fn unpack16(pixel: u32) V16 {
    const bytes: @Vector(4, u8) = @bitCast(pixel);
    return bytes;
}

inline fn pack16(value: V16) u32 {
    const bytes: @Vector(4, u8) = @intCast(@min(value, @as(V16, @splat(255))));
    return @bitCast(bytes);
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
    try std.testing.expectApproxEqRel(std.math.pi * 100, area, 0.01);
}
