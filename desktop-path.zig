//! Anti-aliased vector paths: curves, arcs, strokes and nonzero or even-odd
//! fills into premultiplied native-endian ARGB, independent of Cairo.
const std = @import("std");

pub const Point = struct { x: f64, y: f64 };

/// Affine transform mapping (x, y) to (a·x + c·y + e, b·x + d·y + f).
pub const Transform = struct {
    a: f64 = 1,
    b: f64 = 0,
    c: f64 = 0,
    d: f64 = 1,
    e: f64 = 0,
    f: f64 = 0,

    pub const identity: Transform = .{};

    pub fn apply(self: Transform, p: Point) Point {
        return .{ .x = self.a * p.x + self.c * p.y + self.e, .y = self.b * p.x + self.d * p.y + self.f };
    }
    /// Applies `inner` first, then `self`.
    pub fn mul(self: Transform, inner: Transform) Transform {
        return .{
            .a = self.a * inner.a + self.c * inner.b,
            .b = self.b * inner.a + self.d * inner.b,
            .c = self.a * inner.c + self.c * inner.d,
            .d = self.b * inner.c + self.d * inner.d,
            .e = self.a * inner.e + self.c * inner.f + self.e,
            .f = self.b * inner.e + self.d * inner.f + self.f,
        };
    }
    pub fn translate(x: f64, y: f64) Transform {
        return .{ .e = x, .f = y };
    }
    pub fn scale(x: f64, y: f64) Transform {
        return .{ .a = x, .d = y };
    }
    pub fn rotate(radians: f64) Transform {
        const cos = @cos(radians);
        const sin = @sin(radians);
        return .{ .a = cos, .b = sin, .c = -sin, .d = cos };
    }
    pub fn invert(self: Transform) ?Transform {
        const det = self.a * self.d - self.b * self.c;
        if (!(@abs(det) > 1e-12)) return null;
        return .{
            .a = self.d / det,
            .b = -self.b / det,
            .c = -self.c / det,
            .d = self.a / det,
            .e = (self.c * self.f - self.d * self.e) / det,
            .f = (self.b * self.e - self.a * self.f) / det,
        };
    }
    /// The geometric mean of the axis scales, used for curve tolerances.
    pub fn scaleFactor(self: Transform) f64 {
        return @sqrt(@abs(self.a * self.d - self.b * self.c));
    }
};

pub const Path = struct {
    verbs: std.ArrayList(Verb) = .empty,
    points: std.ArrayList(Point) = .empty,
    start: Point = .{ .x = 0, .y = 0 },
    current: ?Point = null,

    pub const Verb = enum(u8) { move, line, quad, cubic, close };

    pub fn deinit(self: *Path, a: std.mem.Allocator) void {
        self.verbs.deinit(a);
        self.points.deinit(a);
    }
    pub fn clear(self: *Path) void {
        self.verbs.clearRetainingCapacity();
        self.points.clearRetainingCapacity();
        self.current = null;
    }
    pub fn moveTo(self: *Path, a: std.mem.Allocator, p: Point) !void {
        try self.verbs.append(a, .move);
        try self.points.append(a, p);
        self.start = p;
        self.current = p;
    }
    pub fn lineTo(self: *Path, a: std.mem.Allocator, p: Point) !void {
        if (self.current == null) return self.moveTo(a, p);
        try self.verbs.append(a, .line);
        try self.points.append(a, p);
        self.current = p;
    }
    pub fn quadTo(self: *Path, a: std.mem.Allocator, control: Point, p: Point) !void {
        if (self.current == null) try self.moveTo(a, control);
        try self.verbs.append(a, .quad);
        try self.points.appendSlice(a, &.{ control, p });
        self.current = p;
    }
    pub fn cubicTo(self: *Path, a: std.mem.Allocator, c1: Point, c2: Point, p: Point) !void {
        if (self.current == null) try self.moveTo(a, c1);
        try self.verbs.append(a, .cubic);
        try self.points.appendSlice(a, &.{ c1, c2, p });
        self.current = p;
    }
    pub fn close(self: *Path, a: std.mem.Allocator) !void {
        if (self.current == null) return;
        try self.verbs.append(a, .close);
        self.current = self.start;
    }

    /// SVG elliptical arc from the current point to `p` (SVG 1.1 F.6.5).
    pub fn svgArc(self: *Path, a: std.mem.Allocator, radius_x: f64, radius_y: f64, rotation_degrees: f64, large: bool, sweep: bool, p: Point) !void {
        const from = self.current orelse return self.moveTo(a, p);
        var rx = @abs(radius_x);
        var ry = @abs(radius_y);
        if (rx < 1e-9 or ry < 1e-9 or (from.x == p.x and from.y == p.y)) return self.lineTo(a, p);
        const phi = std.math.degreesToRadians(rotation_degrees);
        const cos = @cos(phi);
        const sin = @sin(phi);
        const dx = (from.x - p.x) / 2;
        const dy = (from.y - p.y) / 2;
        const x1 = cos * dx + sin * dy;
        const y1 = -sin * dx + cos * dy;
        const lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry);
        if (lambda > 1) {
            rx *= @sqrt(lambda);
            ry *= @sqrt(lambda);
        }
        const numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1;
        const denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1;
        var coefficient = @sqrt(@max(0, numerator / denominator));
        if (large == sweep) coefficient = -coefficient;
        const cx1 = coefficient * rx * y1 / ry;
        const cy1 = -coefficient * ry * x1 / rx;
        const center: Point = .{ .x = cos * cx1 - sin * cy1 + (from.x + p.x) / 2, .y = sin * cx1 + cos * cy1 + (from.y + p.y) / 2 };
        const start = std.math.atan2((y1 - cy1) / ry, (x1 - cx1) / rx);
        var delta = std.math.atan2((-y1 - cy1) / ry, (-x1 - cx1) / rx) - start;
        if (sweep and delta < 0) delta += 2 * std.math.pi;
        if (!sweep and delta > 0) delta -= 2 * std.math.pi;
        try self.ellipticalArc(a, center, rx, ry, phi, start, delta);
        // Land exactly on the endpoint despite rounding.
        self.points.items[self.points.items.len - 1] = p;
        self.current = p;
    }

    /// Appends an arc of an ellipse as cubic Béziers, continuing the current point.
    pub fn ellipticalArc(self: *Path, a: std.mem.Allocator, center: Point, rx: f64, ry: f64, rotation: f64, start: f64, delta: f64) !void {
        const segments: usize = @intFromFloat(@max(1, @ceil(@abs(delta) / (std.math.pi / 2.0) - 1e-9)));
        const step = delta / @as(f64, @floatFromInt(segments));
        const k = 4.0 / 3.0 * @tan(step / 4);
        const cos = @cos(rotation);
        const sin = @sin(rotation);
        const at = struct {
            fn f(c: Point, x: f64, y: f64, rx_: f64, ry_: f64, co: f64, si: f64) Point {
                return .{ .x = c.x + co * rx_ * x - si * ry_ * y, .y = c.y + si * rx_ * x + co * ry_ * y };
            }
        }.f;
        var angle = start;
        const first = at(center, @cos(angle), @sin(angle), rx, ry, cos, sin);
        if (self.current == null) try self.moveTo(a, first) else try self.lineTo(a, first);
        for (0..segments) |_| {
            const next = angle + step;
            const c0 = @cos(angle);
            const s0 = @sin(angle);
            const c1 = @cos(next);
            const s1 = @sin(next);
            try self.cubicTo(
                a,
                at(center, c0 - k * s0, s0 + k * c0, rx, ry, cos, sin),
                at(center, c1 + k * s1, s1 - k * c1, rx, ry, cos, sin),
                at(center, c1, s1, rx, ry, cos, sin),
            );
            angle = next;
        }
    }

    /// Cairo-style circular arc from `start` to `end` radians, increasing (or decreasing when `negative`).
    pub fn arc(self: *Path, a: std.mem.Allocator, center: Point, radius: f64, start: f64, end: f64, negative: bool) !void {
        var delta = end - start;
        if (negative) {
            while (delta > 0) delta -= 2 * std.math.pi;
        } else {
            while (delta < 0) delta += 2 * std.math.pi;
        }
        try self.ellipticalArc(a, center, radius, radius, 0, start, delta);
    }

    pub fn ellipse(self: *Path, a: std.mem.Allocator, center: Point, rx: f64, ry: f64) !void {
        self.current = null;
        try self.ellipticalArc(a, center, rx, ry, 0, 0, 2 * std.math.pi);
        try self.close(a);
    }

    pub fn rect(self: *Path, a: std.mem.Allocator, x: f64, y: f64, w: f64, h: f64) !void {
        try self.moveTo(a, .{ .x = x, .y = y });
        try self.lineTo(a, .{ .x = x + w, .y = y });
        try self.lineTo(a, .{ .x = x + w, .y = y + h });
        try self.lineTo(a, .{ .x = x, .y = y + h });
        try self.close(a);
    }

    pub fn roundedRect(self: *Path, a: std.mem.Allocator, x: f64, y: f64, w: f64, h: f64, radius_x: f64, radius_y: f64) !void {
        const rx = @min(@max(radius_x, 0), w / 2);
        const ry = @min(@max(radius_y, 0), h / 2);
        if (rx <= 0 or ry <= 0) return self.rect(a, x, y, w, h);
        const pi = std.math.pi;
        self.current = null;
        try self.ellipticalArc(a, .{ .x = x + w - rx, .y = y + ry }, rx, ry, 0, -pi / 2.0, pi / 2.0);
        try self.ellipticalArc(a, .{ .x = x + w - rx, .y = y + h - ry }, rx, ry, 0, 0, pi / 2.0);
        try self.ellipticalArc(a, .{ .x = x + rx, .y = y + h - ry }, rx, ry, 0, pi / 2.0, pi / 2.0);
        try self.ellipticalArc(a, .{ .x = x + rx, .y = y + ry }, rx, ry, 0, pi, pi / 2.0);
        try self.close(a);
    }

    /// Bounds of all points, including control points.
    pub fn bounds(self: Path) ?[4]f64 {
        if (self.points.items.len == 0) return null;
        var box = [4]f64{ std.math.inf(f64), std.math.inf(f64), -std.math.inf(f64), -std.math.inf(f64) };
        for (self.points.items) |p| {
            box[0] = @min(box[0], p.x);
            box[1] = @min(box[1], p.y);
            box[2] = @max(box[2], p.x);
            box[3] = @max(box[3], p.y);
        }
        return box;
    }
};

/// Polylines produced by flattening curves.
pub const Flat = struct {
    points: std.ArrayList(Point) = .empty,
    contours: std.ArrayList(Contour) = .empty,

    pub const Contour = struct { start: usize, len: usize, closed: bool };

    pub fn deinit(self: *Flat, a: std.mem.Allocator) void {
        self.points.deinit(a);
        self.contours.deinit(a);
    }
    pub fn contour(self: Flat, c: Contour) []const Point {
        return self.points.items[c.start..][0..c.len];
    }
    fn begin(self: *Flat, a: std.mem.Allocator) !void {
        try self.contours.append(a, .{ .start = self.points.items.len, .len = 0, .closed = false });
    }
    fn add(self: *Flat, a: std.mem.Allocator, p: Point) !void {
        const last = &self.contours.items[self.contours.items.len - 1];
        if (last.len > 0) {
            const previous = self.points.items[self.points.items.len - 1];
            if (previous.x == p.x and previous.y == p.y) return;
        }
        try self.points.append(a, p);
        last.len += 1;
    }
    /// Adds a closed polygon, oriented so that every polygon has positive area.
    fn polygon(self: *Flat, a: std.mem.Allocator, points: []const Point) !void {
        var area: f64 = 0;
        for (points, 0..) |p, i| {
            const q = points[(i + 1) % points.len];
            area += p.x * q.y - q.x * p.y;
        }
        try self.contours.append(a, .{ .start = self.points.items.len, .len = points.len, .closed = true });
        if (area >= 0) {
            try self.points.appendSlice(a, points);
        } else {
            var i = points.len;
            while (i > 0) {
                i -= 1;
                try self.points.append(a, points[i]);
            }
        }
    }
    /// Adds a closed contour as given, optionally reversed.
    fn contourRaw(self: *Flat, a: std.mem.Allocator, points: []const Point, reversed: bool) !void {
        if (points.len < 3) return;
        try self.contours.append(a, .{ .start = self.points.items.len, .len = points.len, .closed = true });
        if (!reversed) return self.points.appendSlice(a, points);
        var i = points.len;
        while (i > 0) {
            i -= 1;
            try self.points.append(a, points[i]);
        }
    }
    pub fn transform(self: *Flat, t: Transform) void {
        for (self.points.items) |*p| p.* = t.apply(p.*);
    }
};

fn segmentsFor(deviation: f64, tolerance: f64) usize {
    const n = @ceil(@sqrt(deviation / tolerance));
    if (!(n >= 1)) return 1;
    return @intFromFloat(@min(n, 500));
}

/// Flattens `path` after applying `t`, within `tolerance` in the output space.
pub fn flatten(a: std.mem.Allocator, path: Path, t: Transform, tolerance: f64, out: *Flat) !void {
    var index: usize = 0;
    var open = false;
    var last: Point = .{ .x = 0, .y = 0 };
    var first: Point = last;
    for (path.verbs.items) |verb| switch (verb) {
        .move => {
            last = t.apply(path.points.items[index]);
            first = last;
            index += 1;
            try out.begin(a);
            try out.add(a, last);
            open = true;
        },
        .line => {
            last = t.apply(path.points.items[index]);
            index += 1;
            try out.add(a, last);
        },
        .quad => {
            const c = t.apply(path.points.items[index]);
            const p = t.apply(path.points.items[index + 1]);
            index += 2;
            const ddx = last.x - 2 * c.x + p.x;
            const ddy = last.y - 2 * c.y + p.y;
            const n = segmentsFor(@sqrt(ddx * ddx + ddy * ddy) / 4, tolerance);
            for (1..n + 1) |i| {
                const s = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
                const u = 1 - s;
                try out.add(a, .{ .x = u * u * last.x + 2 * u * s * c.x + s * s * p.x, .y = u * u * last.y + 2 * u * s * c.y + s * s * p.y });
            }
            last = p;
        },
        .cubic => {
            const c1 = t.apply(path.points.items[index]);
            const c2 = t.apply(path.points.items[index + 1]);
            const p = t.apply(path.points.items[index + 2]);
            index += 3;
            const d1 = std.math.hypot(last.x - 2 * c1.x + c2.x, last.y - 2 * c1.y + c2.y);
            const d2 = std.math.hypot(c1.x - 2 * c2.x + p.x, c1.y - 2 * c2.y + p.y);
            const n = segmentsFor(0.75 * @max(d1, d2), tolerance);
            for (1..n + 1) |i| {
                const s = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
                const u = 1 - s;
                const w0 = u * u * u;
                const w1 = 3 * u * u * s;
                const w2 = 3 * u * s * s;
                const w3 = s * s * s;
                try out.add(a, .{ .x = w0 * last.x + w1 * c1.x + w2 * c2.x + w3 * p.x, .y = w0 * last.y + w1 * c1.y + w2 * c2.y + w3 * p.y });
            }
            last = p;
        },
        .close => if (open) {
            out.contours.items[out.contours.items.len - 1].closed = true;
            // Drawing after a close continues from the subpath's start.
            try out.begin(a);
            try out.add(a, first);
            last = first;
        },
    };
    // Drop empty contours left by trailing closes.
    var write: usize = 0;
    for (out.contours.items) |c| {
        if (c.len == 0 or (c.len == 1 and c.closed == false and isRestart(out, c))) continue;
        out.contours.items[write] = c;
        write += 1;
    }
    out.contours.items.len = write;
}

fn isRestart(out: *const Flat, c: Flat.Contour) bool {
    // A one-point contour created only to continue after `close`.
    if (c.start == 0) return false;
    for (out.contours.items) |other| if (other.closed and other.start + other.len == c.start) return true;
    return false;
}

pub const Cap = enum { butt, round, square };
pub const Join = enum { miter, round, bevel };
pub const Stroke = struct {
    width: f64 = 1,
    cap: Cap = .butt,
    join: Join = .miter,
    miter_limit: f64 = 4,
    dashes: []const f64 = &.{},
    dash_offset: f64 = 0,
};

fn circle(a: std.mem.Allocator, out: *Flat, center: Point, radius: f64, tolerance: f64) !void {
    if (radius <= 0) return;
    const ratio = std.math.clamp(1 - tolerance / radius, -1, 1);
    const step = 2 * std.math.acos(ratio);
    const n: usize = if (step > 0) @intFromFloat(std.math.clamp(@ceil(2 * std.math.pi / step), 8, 256)) else 8;
    var points: [256]Point = undefined;
    for (0..n) |i| {
        const angle = 2 * std.math.pi * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
        points[i] = .{ .x = center.x + radius * @cos(angle), .y = center.y + radius * @sin(angle) };
    }
    try out.polygon(a, points[0..n]);
}

fn unit(from: Point, to: Point) ?Point {
    const dx = to.x - from.x;
    const dy = to.y - from.y;
    const length = @sqrt(dx * dx + dy * dy);
    if (!(length > 1e-12)) return null;
    return .{ .x = dx / length, .y = dy / length };
}

fn offset(p: Point, n: Point, distance: f64) Point {
    return .{ .x = p.x + n.x * distance, .y = p.y + n.y * distance };
}

fn join(a: std.mem.Allocator, out: *Flat, v: Point, d0: Point, d1: Point, stroke: Stroke, tolerance: f64) !void {
    const hw = stroke.width / 2;
    const cross = d0.x * d1.y - d0.y * d1.x;
    const dot = d0.x * d1.x + d0.y * d1.y;
    if (@abs(cross) < 1e-9 and dot > 0) return;
    if (stroke.join == .round) return circle(a, out, v, hw, tolerance);
    const side: f64 = if (cross > 0) -1 else 1;
    const n0: Point = .{ .x = -d0.y * side, .y = d0.x * side };
    const n1: Point = .{ .x = -d1.y * side, .y = d1.x * side };
    const p0 = offset(v, n0, hw);
    const p1 = offset(v, n1, hw);
    const cos = n0.x * n1.x + n0.y * n1.y;
    if (stroke.join == .miter and cos > -1 + 1e-9) {
        const ratio = @sqrt(2 / (1 + cos));
        if (ratio <= stroke.miter_limit) {
            const mid = unit(.{ .x = 0, .y = 0 }, .{ .x = n0.x + n1.x, .y = n0.y + n1.y }) orelse return;
            try out.polygon(a, &.{ v, p0, offset(v, mid, hw * ratio), p1 });
            return;
        }
    }
    try out.polygon(a, &.{ v, p0, p1 });
}

fn cap(a: std.mem.Allocator, out: *Flat, p: Point, direction: Point, stroke: Stroke, tolerance: f64) !void {
    const hw = stroke.width / 2;
    switch (stroke.cap) {
        .butt => {},
        .round => try circle(a, out, p, hw, tolerance),
        .square => {
            const n: Point = .{ .x = -direction.y, .y = direction.x };
            const tip = offset(p, direction, hw);
            try out.polygon(a, &.{ offset(p, n, hw), offset(tip, n, hw), offset(tip, n, -hw), offset(p, n, -hw) });
        },
    }
}

/// Appends points along a circular arc of radius `r` around `center`, from
/// angle `start` turning by `sweep`, excluding the start point.
fn arcPoints(a: std.mem.Allocator, list: *std.ArrayList(Point), center: Point, r: f64, start: f64, sweep: f64, tolerance: f64) !void {
    const ratio = std.math.clamp(1 - tolerance / @max(r, 1e-9), -1, 1);
    const step = @max(2 * std.math.acos(ratio), 1e-3);
    const n: usize = @intFromFloat(std.math.clamp(@ceil(@abs(sweep) / step), 1, 256));
    for (1..n + 1) |i| {
        const angle = start + sweep * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
        try list.append(a, .{ .x = center.x + r * @cos(angle), .y = center.y + r * @sin(angle) });
    }
}

/// Adds the join at `v` to one side of the stroke, ending at the next segment's offset start.
/// The outer side gets the join shape; the inner side pivots through the vertex.
fn sideJoin(a: std.mem.Allocator, list: *std.ArrayList(Point), v: Point, d0: Point, d1: Point, sign: f64, stroke: Stroke, tolerance: f64) !void {
    const hw = stroke.width / 2;
    const m0: Point = .{ .x = -d0.y * sign, .y = d0.x * sign };
    const m1: Point = .{ .x = -d1.y * sign, .y = d1.x * sign };
    const cross = d0.x * d1.y - d0.y * d1.x;
    const dot = d0.x * d1.x + d0.y * d1.y;
    const end = offset(v, m1, hw);
    if (@abs(cross) < 1e-9 and dot > 0) return list.append(a, end);
    // The side whose normal turns away from the bend is the outer side.
    const outer = (cross < 0) == (sign > 0) or (@abs(cross) < 1e-9);
    if (!outer) {
        try list.append(a, v);
        return list.append(a, end);
    }
    switch (stroke.join) {
        .round => {
            const start = std.math.atan2(m0.y, m0.x);
            var sweep = std.math.atan2(m1.y, m1.x) - start;
            if (sign > 0) {
                while (sweep > 0) sweep -= 2 * std.math.pi;
            } else {
                while (sweep < 0) sweep += 2 * std.math.pi;
            }
            if (@abs(cross) < 1e-9) sweep = if (sign > 0) -std.math.pi else std.math.pi;
            return arcPoints(a, list, v, hw, start, sweep, tolerance);
        },
        .miter => {
            const cos = m0.x * m1.x + m0.y * m1.y;
            if (cos > -1 + 1e-9) {
                const ratio = @sqrt(2 / (1 + cos));
                if (ratio <= stroke.miter_limit) {
                    if (unit(.{ .x = 0, .y = 0 }, .{ .x = m0.x + m1.x, .y = m0.y + m1.y })) |mid| try list.append(a, offset(v, mid, hw * ratio));
                }
            }
        },
        .bevel => {},
    }
    try list.append(a, end);
}

/// Adds a cap at `p` facing `d`, from the left offset to the right offset.
fn capPoints(a: std.mem.Allocator, list: *std.ArrayList(Point), p: Point, d: Point, stroke: Stroke, tolerance: f64) !void {
    const hw = stroke.width / 2;
    const n: Point = .{ .x = -d.y, .y = d.x };
    switch (stroke.cap) {
        .butt => {},
        .square => {
            const tip = offset(p, d, hw);
            try list.append(a, offset(tip, n, hw));
            try list.append(a, offset(tip, n, -hw));
        },
        .round => {
            const start = std.math.atan2(n.y, n.x);
            // From the left normal through `d` to the right normal.
            const sweep: f64 = if (n.x * d.y - n.y * d.x > 0) std.math.pi else -std.math.pi;
            try arcPoints(a, list, p, hw, start, sweep, tolerance);
            _ = list.pop();
        },
    }
    try list.append(a, offset(p, n, -hw));
}

fn strokePolyline(a: std.mem.Allocator, raw: []const Point, closed_input: bool, stroke: Stroke, tolerance: f64, out: *Flat) !void {
    const hw = stroke.width / 2;
    // Drop repeated points; zero-length segments have no direction.
    var points: std.ArrayList(Point) = .empty;
    defer points.deinit(a);
    for (raw) |p| {
        if (points.items.len > 0) {
            const last = points.items[points.items.len - 1];
            if (std.math.hypot(p.x - last.x, p.y - last.y) < 1e-9) continue;
        }
        try points.append(a, p);
    }
    var closed = closed_input;
    if (closed and points.items.len > 2) {
        const first = points.items[0];
        const last = points.items[points.items.len - 1];
        if (std.math.hypot(first.x - last.x, first.y - last.y) < 1e-9) _ = points.pop();
    }
    const pts = points.items;
    if (pts.len < 2) {
        // Zero-length subpaths draw caps only, facing along the x axis.
        if (!closed and pts.len == 1) switch (stroke.cap) {
            .butt => {},
            .round => try circle(a, out, pts[0], hw, tolerance),
            .square => try out.polygon(a, &.{
                .{ .x = pts[0].x - hw, .y = pts[0].y - hw },
                .{ .x = pts[0].x + hw, .y = pts[0].y - hw },
                .{ .x = pts[0].x + hw, .y = pts[0].y + hw },
                .{ .x = pts[0].x - hw, .y = pts[0].y + hw },
            }),
        };
        return;
    }
    if (pts.len == 2) closed = false;
    const segments = if (closed) pts.len else pts.len - 1;
    const directions = try a.alloc(Point, segments);
    defer a.free(directions);
    for (directions, 0..) |*d, i| d.* = unit(pts[i], pts[(i + 1) % pts.len]).?;
    var left: std.ArrayList(Point) = .empty;
    defer left.deinit(a);
    var right: std.ArrayList(Point) = .empty;
    defer right.deinit(a);
    for (directions, 0..) |d, i| {
        const n: Point = .{ .x = -d.y, .y = d.x };
        const p0 = pts[i];
        const p1 = pts[(i + 1) % pts.len];
        if (i == 0) {
            try left.append(a, offset(p0, n, hw));
            try right.append(a, offset(p0, n, -hw));
        } else {
            try sideJoin(a, &left, p0, directions[i - 1], d, 1, stroke, tolerance);
            try sideJoin(a, &right, p0, directions[i - 1], d, -1, stroke, tolerance);
        }
        try left.append(a, offset(p1, n, hw));
        try right.append(a, offset(p1, n, -hw));
    }
    if (closed) {
        // Join back into the first segment; each loop closes onto its first point.
        try sideJoin(a, &left, pts[0], directions[segments - 1], directions[0], 1, stroke, tolerance);
        try sideJoin(a, &right, pts[0], directions[segments - 1], directions[0], -1, stroke, tolerance);
        _ = left.pop();
        _ = right.pop();
        try out.contourRaw(a, left.items, true);
        try out.contourRaw(a, right.items, false);
        return;
    }
    // Open: left side, end cap, right side backwards, start cap.
    try capPoints(a, &left, pts[pts.len - 1], directions[segments - 1], stroke, tolerance);
    _ = left.pop();
    var i = right.items.len;
    while (i > 0) {
        i -= 1;
        try left.append(a, right.items[i]);
    }
    const first = directions[0];
    try capPoints(a, &left, pts[0], .{ .x = -first.x, .y = -first.y }, stroke, tolerance);
    _ = left.pop();
    // Stroke outlines must wind in the same direction as standalone caps.
    try out.contourRaw(a, left.items, true);
}

/// Builds fill polygons covering `stroke` of the user-space polylines in `flat`.
pub fn strokeOutline(a: std.mem.Allocator, flat: Flat, stroke: Stroke, tolerance: f64, out: *Flat) !void {
    if (!(stroke.width > 0)) return;
    var dash_total: f64 = 0;
    for (stroke.dashes) |dash| dash_total += @max(dash, 0);
    const dashed = stroke.dashes.len > 0 and dash_total > 1e-9;
    var scratch: std.ArrayList(Point) = .empty;
    defer scratch.deinit(a);
    for (flat.contours.items) |c| {
        const points = flat.contour(c);
        if (!dashed) {
            try strokePolyline(a, points, c.closed, stroke, tolerance, out);
            continue;
        }
        // Walk the polyline, emitting the "on" pieces of the dash pattern as open strokes.
        var index: usize = 0;
        var remaining = @mod(stroke.dash_offset, dash_total);
        while (remaining >= @max(stroke.dashes[index % stroke.dashes.len], 0)) {
            remaining -= @max(stroke.dashes[index % stroke.dashes.len], 0);
            index += 1;
        }
        var left = @max(stroke.dashes[index % stroke.dashes.len], 0) - remaining;
        var on = index % 2 == 0;
        scratch.clearRetainingCapacity();
        if (on) try scratch.append(a, points[0]);
        const count = if (c.closed) points.len else points.len - 1;
        for (0..count) |i| {
            var p0 = points[i];
            const p1 = points[(i + 1) % points.len];
            var length = std.math.hypot(p1.x - p0.x, p1.y - p0.y);
            while (length > left) {
                const t = left / length;
                const mid: Point = .{ .x = p0.x + (p1.x - p0.x) * t, .y = p0.y + (p1.y - p0.y) * t };
                if (on) {
                    try scratch.append(a, mid);
                    try strokePolyline(a, scratch.items, false, stroke, tolerance, out);
                    scratch.clearRetainingCapacity();
                } else {
                    try scratch.append(a, mid);
                }
                on = !on;
                length -= left;
                p0 = mid;
                index += 1;
                left = @max(stroke.dashes[index % stroke.dashes.len], 0);
            }
            left -= length;
            if (on) try scratch.append(a, p1);
        }
        if (on and scratch.items.len > 1) try strokePolyline(a, scratch.items, false, stroke, tolerance, out);
    }
}

pub const FillRule = enum { nonzero, evenodd };

/// Per-pixel coverage over a clipped bounding box of the target.
pub const Mask = struct {
    x: u32 = 0,
    y: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    alpha: []f32 = &.{},

    pub fn deinit(self: Mask, a: std.mem.Allocator) void {
        a.free(self.alpha);
    }
    pub fn at(self: Mask, x: u32, y: u32) f32 {
        if (x < self.x or y < self.y or x >= self.x + self.width or y >= self.y + self.height) return 0;
        return self.alpha[(y - self.y) * self.width + (x - self.x)];
    }
};

const Edge = struct {
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
    dir: i32,
    slope: f64 = 0,

    fn at(self: Edge, y: f64) f64 {
        return self.x0 + (y - self.y0) * self.slope;
    }
};
/// Maximum chord deviation of flattened curves, in device pixels.
const default_tolerance = 0.03;

/// Coverage as runs of constant alpha per row; pixels outside every run are 0.
/// Interiors and empty areas cost one run each, so large shapes stay cheap.
pub const Spans = struct {
    y: u32 = 0,
    height: u32 = 0,
    /// Bounds of all runs, for clipping regions.
    x0: u32 = 0,
    x1: u32 = 0,
    /// Runs of row `y + i` are `runs[rows[i]..rows[i + 1]]`, sorted by x.
    rows: []u32 = &.{},
    runs: []Run = &.{},

    pub const Run = struct { x: u32, len: u32, alpha: f32 };

    pub fn deinit(self: Spans, a: std.mem.Allocator) void {
        a.free(self.rows);
        a.free(self.runs);
    }
    /// The runs of absolute row `y`, empty outside the spans.
    pub fn row(self: Spans, y: usize) []const Run {
        if (y < self.y or y >= self.y + self.height) return &.{};
        const i = y - self.y;
        return self.runs[self.rows[i]..self.rows[i + 1]];
    }
    pub fn empty(self: Spans) bool {
        return self.runs.len == 0;
    }

    /// Row-wise product of two coverages.
    pub fn intersect(a: std.mem.Allocator, first: Spans, second: Spans) !Spans {
        const y0 = @max(first.y, second.y);
        const y1 = @min(first.y + first.height, second.y + second.height);
        if (y1 <= y0) return .{};
        var builder: Builder = try .init(a, y0, y1 - y0);
        errdefer builder.deinit();
        for (y0..y1) |y| {
            try intersectRuns(&builder, first.row(y), second.row(y), 1);
            try builder.endRow();
        }
        return builder.finish();
    }
};

/// Appends the product of two sorted run lists, scaled by `scale`.
pub fn intersectRuns(builder: *Builder, first: []const Spans.Run, second: []const Spans.Run, scale: f32) !void {
    var i: usize = 0;
    var j: usize = 0;
    while (i < first.len and j < second.len) {
        const r = first[i];
        const s = second[j];
        const start = @max(r.x, s.x);
        const end = @min(r.x + r.len, s.x + s.len);
        if (end > start) try builder.add(start, end - start, r.alpha * s.alpha * scale);
        if (r.x + r.len <= s.x + s.len) i += 1 else j += 1;
    }
}

/// Accumulates runs row by row, merging equal neighbors.
pub const Builder = struct {
    a: std.mem.Allocator,
    y: u32,
    height: u32,
    rows: std.ArrayList(u32) = .empty,
    runs: std.ArrayList(Spans.Run) = .empty,
    x0: u32 = std.math.maxInt(u32),
    x1: u32 = 0,

    pub fn init(a: std.mem.Allocator, y: u32, height: u32) !Builder {
        var builder: Builder = .{ .a = a, .y = y, .height = height };
        try builder.rows.ensureTotalCapacity(a, height + 1);
        builder.rows.appendAssumeCapacity(0);
        return builder;
    }
    pub fn deinit(self: *Builder) void {
        self.rows.deinit(self.a);
        self.runs.deinit(self.a);
    }
    pub fn add(self: *Builder, x: u32, len: u32, alpha: f32) !void {
        if (len == 0 or !(alpha > 1.0 / 512.0)) return;
        const value = @min(alpha, 1);
        const row_start = self.rows.items[self.rows.items.len - 1];
        if (self.runs.items.len > row_start) {
            const last = &self.runs.items[self.runs.items.len - 1];
            if (last.x + last.len == x and @abs(last.alpha - value) < 1.0 / 1024.0) {
                last.len += len;
                self.x1 = @max(self.x1, x + len);
                return;
            }
        }
        try self.runs.append(self.a, .{ .x = x, .len = len, .alpha = value });
        self.x0 = @min(self.x0, x);
        self.x1 = @max(self.x1, x + len);
    }
    pub fn endRow(self: *Builder) !void {
        try self.rows.append(self.a, @intCast(self.runs.items.len));
    }
    /// Repeats the last finished row `count` more times.
    pub fn repeatRow(self: *Builder, count: usize) !void {
        const rows = self.rows.items;
        const start = rows[rows.len - 2];
        const end = rows[rows.len - 1];
        // Reserve first: appending a slice of the list to itself must not reallocate.
        try self.runs.ensureUnusedCapacity(self.a, (end - start) * count);
        try self.rows.ensureUnusedCapacity(self.a, count);
        for (0..count) |_| {
            self.runs.appendSliceAssumeCapacity(self.runs.items[start..end]);
            try self.rows.append(self.a, @intCast(self.runs.items.len));
        }
    }
    pub fn finish(self: *Builder) !Spans {
        if (self.runs.items.len == 0) {
            self.deinit();
            return .{};
        }
        return .{
            .y = self.y,
            .height = self.height,
            .x0 = self.x0,
            .x1 = self.x1,
            .rows = try self.rows.toOwnedSlice(self.a),
            .runs = try self.runs.toOwnedSlice(self.a),
        };
    }
};

/// Per-row partial-pixel coverage and run deltas, with each touched column
/// recorded once.
const Accumulator = struct {
    cover: []f32,
    delta: []f32,
    touched: std.ArrayList(u32) = .empty,
    marked: []bool,
    width: u32,
    /// First column stored; arrays cover only the shape's columns.
    left: u32,

    fn init(a: std.mem.Allocator, width: u32, left: u32, right: u32) !Accumulator {
        const n = @as(usize, right - left) + 2;
        const self: Accumulator = .{ .cover = try a.alloc(f32, n), .delta = try a.alloc(f32, n), .marked = try a.alloc(bool, n), .width = width, .left = left };
        @memset(self.cover, 0);
        @memset(self.delta, 0);
        @memset(self.marked, false);
        return self;
    }
    fn deinit(self: *Accumulator, a: std.mem.Allocator) void {
        a.free(self.cover);
        a.free(self.delta);
        a.free(self.marked);
        self.touched.deinit(a);
    }
    fn touch(self: *Accumulator, a: std.mem.Allocator, x: u32) !void {
        if (self.marked[x - self.left]) return;
        self.marked[x - self.left] = true;
        try self.touched.append(a, x);
    }
    /// Adds `sign` times the exact area right of a line crossing the whole row
    /// from x = `top` to x = `bottom`, per column.
    fn edge(self: *Accumulator, a: std.mem.Allocator, top: f64, bottom: f64, sign: f32) !void {
        const fw: f64 = @floatFromInt(self.width);
        const lo = @min(top, bottom);
        const hi = @max(top, bottom);
        if (hi - lo < 1e-9) return self.column(a, lo, 1, sign);
        const height = hi - lo;
        var x = lo;
        while (x < hi) {
            // Everything left of the canvas is one step: it fully covers column 0 onward.
            const next = if (x < 0) @min(hi, 0) else @min(hi, @floor(x) + 1);
            const share = (next - x) / height;
            if (x >= fw) break;
            try self.column(a, (x + next) / 2, share, sign);
            x = next;
        }
    }

    /// A line at mean position `x` over `share` of the row's height.
    fn column(self: *Accumulator, a: std.mem.Allocator, x: f64, share: f64, sign: f32) !void {
        const weight: f32 = @floatCast(share);
        if (x < 0) {
            self.delta[0 - self.left] += sign * weight;
            return self.touch(a, 0);
        }
        if (x >= @as(f64, @floatFromInt(self.width))) return;
        const i: u32 = @intFromFloat(@floor(x));
        self.cover[i - self.left] += sign * weight * @as(f32, @floatCast(@as(f64, @floatFromInt(i + 1)) - x));
        self.delta[i + 1 - self.left] += sign * weight;
        try self.touch(a, i);
        try self.touch(a, i + 1);
    }

    /// Emits the row's runs in column order and resets the touched columns.
    fn flush(self: *Accumulator, builder: *Builder) !void {
        const items = self.touched.items;
        if (items.len < 32) {
            var k: usize = 1;
            while (k < items.len) : (k += 1) {
                const value = items[k];
                var j = k;
                while (j > 0 and items[j - 1] > value) : (j -= 1) items[j] = items[j - 1];
                items[j] = value;
            }
        } else std.sort.pdq(u32, items, {}, std.sort.asc(u32));
        var running: f32 = 0;
        var cursor: u32 = 0;
        for (items) |x| {
            const cover = self.cover[x - self.left];
            const delta = self.delta[x - self.left];
            self.cover[x - self.left] = 0;
            self.delta[x - self.left] = 0;
            self.marked[x - self.left] = false;
            if (x >= self.width) continue;
            if (x > cursor) try builder.add(cursor, x - cursor, @abs(running));
            running += delta;
            try builder.add(x, 1, @abs(cover + running));
            cursor = x + 1;
        }
        if (cursor < self.width) try builder.add(cursor, self.width - cursor, @abs(running));
        self.touched.clearRetainingCapacity();
    }
};

/// Apply parity to sorted crossings before summing pixel coverage.
fn evenOddRow(a: std.mem.Allocator, accumulator: *Accumulator, crossings: *std.ArrayList(f64), edges: []const Edge, y: f64, vertical: bool) !void {
    const samples: usize = if (vertical) 1 else 16;
    const weight: f32 = 1 / @as(f32, @floatFromInt(samples));
    for (0..samples) |sample| {
        const scan_y = y + (@as(f64, @floatFromInt(sample)) + 0.5) / @as(f64, @floatFromInt(samples));
        crossings.clearRetainingCapacity();
        for (edges) |edge| {
            if (edge.y0 <= scan_y and scan_y < edge.y1) try crossings.append(a, edge.at(scan_y));
        }
        const xs = crossings.items;
        std.mem.sortUnstable(f64, xs, {}, std.sort.asc(f64));
        var i: usize = 0;
        while (i + 1 < xs.len) : (i += 2) {
            if (xs[i] == xs[i + 1]) continue;
            try accumulator.column(a, xs[i], 1, weight);
            try accumulator.column(a, xs[i + 1], 1, -weight);
        }
    }
}

/// Computes anti-aliased coverage of the closed device-space contours in `flat` as runs.
pub fn rasterizeSpans(a: std.mem.Allocator, flat: Flat, rule: FillRule, width: u32, height: u32) !Spans {
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(a);
    var top: f64 = std.math.inf(f64);
    var min_x: f64 = std.math.inf(f64);
    var max_x: f64 = -std.math.inf(f64);
    var bottom: f64 = -std.math.inf(f64);
    for (flat.contours.items) |c| {
        const points = flat.contour(c);
        if (points.len < 2) continue;
        for (points, 0..) |p, i| {
            if (!std.math.isFinite(p.x) or !std.math.isFinite(p.y)) return .{};
            const q = points[(i + 1) % points.len];
            top = @min(top, p.y);
            min_x = @min(min_x, p.x);
            max_x = @max(max_x, p.x);
            bottom = @max(bottom, p.y);
            if (p.y == q.y) continue;
            try edges.append(a, if (p.y < q.y)
                .{ .x0 = p.x, .y0 = p.y, .x1 = q.x, .y1 = q.y, .dir = 1, .slope = (q.x - p.x) / (q.y - p.y) }
            else
                .{ .x0 = q.x, .y0 = q.y, .x1 = p.x, .y1 = p.y, .dir = -1, .slope = (p.x - q.x) / (p.y - q.y) });
        }
    }
    if (edges.items.len == 0) return .{};
    const fh: f64 = @floatFromInt(height);
    const y0: u32 = @intFromFloat(std.math.clamp(@floor(top), 0, fh));
    const y1: u32 = @intFromFloat(std.math.clamp(@ceil(bottom), 0, fh));
    if (y1 <= y0 or width == 0) return .{};
    std.mem.sort(Edge, edges.items, {}, struct {
        fn less(_: void, l: Edge, r: Edge) bool {
            return l.y0 < r.y0;
        }
    }.less);
    var builder: Builder = try .init(a, y0, y1 - y0);
    errdefer builder.deinit();
    var active: std.ArrayList(Edge) = .empty;
    defer active.deinit(a);
    var crossings: std.ArrayList(f64) = .empty;
    defer crossings.deinit(a);
    const fw: f64 = @floatFromInt(width);
    const left: u32 = @intFromFloat(std.math.clamp(@floor(min_x), 0, fw));
    const right: u32 = @intFromFloat(std.math.clamp(@ceil(max_x) + 1, 0, fw));
    var accumulator: Accumulator = try .init(a, width, left, @max(left, right));
    defer accumulator.deinit(a);
    var next: usize = 0;
    var row_y: usize = y0;
    while (row_y < y1) : (row_y += 1) {
        const y: f64 = @floatFromInt(row_y);
        // Retire finished edges and admit those starting in this row.
        var keep: usize = 0;
        for (active.items) |e| if (e.y1 > y) {
            active.items[keep] = e;
            keep += 1;
        };
        active.items.len = keep;
        while (next < edges.items.len and edges.items[next].y0 < y + 1) : (next += 1) {
            if (edges.items[next].y1 > y) try active.append(a, edges.items[next]);
        }
        // Integrate signed edge areas directly for nonzero fills.
        var vertical = true;
        var last: f64 = @floatFromInt(y1);
        for (active.items) |e| {
            const ya = @max(e.y0, y);
            const yb = @min(e.y1, y + 1);
            if (yb <= ya) continue;
            if (rule == .nonzero) try accumulator.edge(a, e.at(ya), e.at(yb), @as(f32, @floatCast(yb - ya)) * @as(f32, @floatFromInt(e.dir)));
            vertical = vertical and e.x0 == e.x1 and ya == y and yb == y + 1;
            last = @min(last, @floor(e.y1));
        }
        if (rule == .evenodd) try evenOddRow(a, &accumulator, &crossings, active.items, y, vertical);
        try accumulator.flush(&builder);
        try builder.endRow();
        // Rows between vertical edges repeat until an edge ends or starts
        // (Cairo renders such rows in one step too).
        if (next < edges.items.len) last = @min(last, @floor(edges.items[next].y0));
        if (vertical and last - 1 > y) {
            const repeat: usize = @intFromFloat(last - 1 - y);
            try builder.repeatRow(repeat);
            row_y += repeat;
        }
    }
    return builder.finish();
}

/// Computes anti-aliased coverage of the closed device-space contours in `flat`.
pub fn rasterize(a: std.mem.Allocator, flat: Flat, rule: FillRule, width: u32, height: u32) !Mask {
    const spans = try rasterizeSpans(a, flat, rule, width, height);
    defer spans.deinit(a);
    return expand(a, spans);
}

/// Converts runs into dense per-pixel coverage over their bounding box.
pub fn expand(a: std.mem.Allocator, spans: Spans) !Mask {
    if (spans.empty()) return .{};
    const mw = spans.x1 - spans.x0;
    const alpha = try a.alloc(f32, @as(usize, mw) * spans.height);
    @memset(alpha, 0);
    for (0..spans.height) |r| {
        for (spans.row(spans.y + r)) |run| @memset(alpha[r * mw + (run.x - spans.x0) ..][0..run.len], run.alpha);
    }
    return .{ .x = spans.x0, .y = spans.y, .width = mw, .height = spans.height, .alpha = alpha };
}

/// Premultiplied native-endian ARGB pixels; `stride` counts pixels.
pub const Target = struct {
    pixels: []u32,
    width: u32,
    height: u32,
    stride: u32,

    pub fn init(a: std.mem.Allocator, width: u32, height: u32) !Target {
        const pixels = try a.alloc(u32, @as(usize, width) * height);
        @memset(pixels, 0);
        return .{ .pixels = pixels, .width = width, .height = height, .stride = width };
    }
    pub fn fromBytes(bytes: []align(@alignOf(u32)) u8, width: u32, height: u32, stride_bytes: usize) Target {
        return .{ .pixels = std.mem.bytesAsSlice(u32, bytes), .width = width, .height = height, .stride = @intCast(stride_bytes / 4) };
    }
    pub fn deinit(self: Target, a: std.mem.Allocator) void {
        a.free(self.pixels);
    }
};

/// Premultiplied ARGB from straight color components in 0..1.
pub fn premultiply(red: f64, green: f64, blue: f64, alpha: f64) u32 {
    const al = std.math.clamp(alpha, 0, 1);
    const channel = struct {
        fn f(v: f64, al_: f64) u32 {
            // Non-negative, so truncating x + 0.5 rounds without a libcall on baseline x86.
            return @intFromFloat(std.math.clamp(v, 0, 1) * al_ * 255 + 0.5);
        }
    }.f;
    return (@as(u32, @intFromFloat(al * 255 + 0.5)) << 24) | (channel(red, al) << 16) | (channel(green, al) << 8) | channel(blue, al);
}

/// Multiplies two packed channel pairs (0x00XX00YY) by `factor`/255, rounded.
fn scalePair(pair: u32, factor: u32) u32 {
    const t = pair * factor + 0x00800080;
    return ((t + ((t >> 8) & 0x00ff00ff)) >> 8) & 0x00ff00ff;
}

/// Scales every channel of a premultiplied pixel by `factor` in 0..255.
pub fn fade(pixel: u32, factor: u32) u32 {
    return scalePair(pixel & 0x00ff00ff, factor) | (scalePair((pixel >> 8) & 0x00ff00ff, factor) << 8);
}

// SIMD blending of four premultiplied pixels at a time. Pixels are native
// u32 ARGB, so on little-endian targets each pixel's bytes are B, G, R, A.
comptime {
    std.debug.assert(@import("builtin").cpu.arch.endian() == .little);
}
const Lanes = @Vector(16, u16);
const Bytes = @Vector(16, u8);
const alpha_lanes: @Vector(16, i32) = .{ 3, 3, 3, 3, 7, 7, 7, 7, 11, 11, 11, 11, 15, 15, 15, 15 };

/// x / 255 rounded, exact for products of two bytes.
inline fn div255(x: Lanes) Lanes {
    const t = x + @as(Lanes, @splat(128));
    return (t + (t >> @splat(8))) >> @splat(8);
}
inline fn load4(pixels: []const u32) Lanes {
    const bytes: Bytes = @bitCast(pixels[0..4].*);
    return bytes;
}
inline fn store4(pixels: []u32, value: Lanes) void {
    const bytes: Bytes = @intCast(@min(value, @as(Lanes, @splat(255))));
    pixels[0..4].* = @bitCast(bytes);
}

/// OVER with one source color for every pixel, as for solid fills.
pub fn overSolid(pixels: []u32, source: u32) void {
    if (source >> 24 == 255) return @memset(pixels, source);
    if (source == 0) return;
    const inverse: Lanes = @splat(@intCast(255 - (source >> 24)));
    const src: Lanes = @as(Bytes, @bitCast([4]u32{ source, source, source, source }));
    var i: usize = 0;
    while (i + 4 <= pixels.len) : (i += 4) store4(pixels[i..], src + div255(load4(pixels[i..]) * inverse));
    while (i < pixels.len) : (i += 1) pixels[i] = over(pixels[i], source);
}

/// OVER with per-pixel sources scaled by `factor` (0..255).
pub fn overSpan(pixels: []u32, sources: []const u32, factor: u32) void {
    const scale: Lanes = @splat(@intCast(factor));
    const full: Lanes = @splat(255);
    var i: usize = 0;
    while (i + 4 <= pixels.len) : (i += 4) {
        var src = load4(sources[i..]);
        if (factor != 255) src = div255(src * scale);
        const alpha = @shuffle(u16, src, undefined, alpha_lanes);
        store4(pixels[i..], src + div255(load4(pixels[i..]) * (full - alpha)));
    }
    while (i < pixels.len) : (i += 1) pixels[i] = over(pixels[i], if (factor == 255) sources[i] else fade(sources[i], factor));
}

test "SIMD OVER matches the scalar blend" {
    var pixels: [7]u32 = .{ 0xff102030, 0x80406080, 0, 0xffffffff, 0x10101010, 0xff000000, 0x7f7f7f7f };
    var expected = pixels;
    const sources = [7]u32{ 0x80800000, 0xff00ff00, 0x40404040, 0, 0x01010101, 0xc0102030, 0x80000080 };
    for ([_]u32{ 255, 128, 7 }) |factor| {
        for (&expected, sources) |*e, s| e.* = over(e.*, if (factor == 255) s else fade(s, factor));
        overSpan(&pixels, &sources, factor);
        try std.testing.expectEqualSlices(u32, &expected, &pixels);
    }
    for ([_]u32{ 0x80402010, 0xff123456, 0x01000000 }) |s| {
        for (&expected) |*e| e.* = over(e.*, s);
        overSolid(&pixels, s);
        try std.testing.expectEqualSlices(u32, &expected, &pixels);
    }
}

pub fn over(destination: u32, source: u32) u32 {
    const inverse = 255 - (source >> 24);
    if (inverse == 0) return source;
    const faded = fade(destination, inverse);
    const rb = (source & 0x00ff00ff) + (faded & 0x00ff00ff);
    const ag = ((source >> 8) & 0x00ff00ff) + ((faded >> 8) & 0x00ff00ff);
    // Invalid (non-premultiplied) sources can exceed 255; saturate each channel.
    const r: u32 = @min(rb >> 16 & 0x1ff, 255);
    const b: u32 = @min(rb & 0x1ff, 255);
    const al: u32 = @min(ag >> 16 & 0x1ff, 255);
    const g: u32 = @min(ag & 0x1ff, 255);
    return (al << 24) | (r << 16) | (g << 8) | b;
}

/// A pixel source evaluated at device-space pixel centers.
pub const Shader = struct {
    context: *const anyopaque,
    sample: *const fn (context: *const anyopaque, x: f64, y: f64) u32,
};
pub const Paint = union(enum) {
    solid: u32,
    shader: Shader,
};

/// Composites `paint` through coverage `mask`, scaled by `opacity`.
pub fn fill(target: Target, mask: Mask, paint: Paint, opacity: f32) void {
    if (mask.width == 0) return;
    const scale = std.math.clamp(opacity, 0, 1) * 255;
    for (0..mask.height) |row| {
        const y = mask.y + row;
        if (y >= target.height) break;
        const line = target.pixels[y * target.stride ..];
        const coverage = mask.alpha[row * mask.width ..][0..mask.width];
        for (coverage, 0..) |value, column| {
            if (value <= 0) continue;
            const x = mask.x + column;
            if (x >= target.width) break;
            const source = switch (paint) {
                .solid => |pixel| pixel,
                .shader => |shader| shader.sample(shader.context, @as(f64, @floatFromInt(x)) + 0.5, @as(f64, @floatFromInt(y)) + 0.5),
            };
            const factor: u32 = @intFromFloat(@round(value * scale));
            if (factor == 0) continue;
            line[x] = over(line[x], if (factor >= 255) source else fade(source, factor));
        }
    }
}

/// Fills a path in user space under transform `t`.
pub fn fillPath(a: std.mem.Allocator, target: Target, path: Path, t: Transform, rule: FillRule, paint: Paint, opacity: f32) !void {
    const spans = try fillSpans(a, path, t, rule, target.width, target.height, default_tolerance);
    defer spans.deinit(a);
    fillRuns(target, spans, paint, opacity);
}

/// Strokes a path in user space; the stroke width scales with `t`.
pub fn strokePath(a: std.mem.Allocator, target: Target, path: Path, t: Transform, stroke: Stroke, paint: Paint, opacity: f32) !void {
    const spans = try strokeSpans(a, path, t, stroke, target.width, target.height, default_tolerance);
    defer spans.deinit(a);
    fillRuns(target, spans, paint, opacity);
}

/// Composites `paint` over each coverage run; solid paint blends a whole run at once.
pub fn fillRuns(target: Target, spans: Spans, paint: Paint, opacity: f32) void {
    const scale = std.math.clamp(opacity, 0, 1) * 255;
    for (0..spans.height) |r| {
        const y = spans.y + r;
        if (y >= target.height) break;
        const line = target.pixels[y * target.stride ..];
        for (spans.row(y)) |run| {
            const factor: u32 = @intFromFloat(@round(run.alpha * scale));
            if (factor == 0) continue;
            const end = @min(run.x + run.len, target.width);
            if (end <= run.x) continue;
            const pixels = line[run.x..end];
            switch (paint) {
                .solid => |pixel| overSolid(pixels, if (factor >= 255) pixel else fade(pixel, factor)),
                .shader => |shader| for (pixels, run.x..) |*dst, x| {
                    const source = shader.sample(shader.context, @as(f64, @floatFromInt(x)) + 0.5, @as(f64, @floatFromInt(y)) + 0.5);
                    dst.* = over(dst.*, if (factor >= 255) source else fade(source, factor));
                },
            }
        }
    }
}

pub fn fillMask(a: std.mem.Allocator, path: Path, t: Transform, rule: FillRule, width: u32, height: u32) !Mask {
    const spans = try fillSpans(a, path, t, rule, width, height, default_tolerance);
    defer spans.deinit(a);
    return expand(a, spans);
}

pub fn strokeMask(a: std.mem.Allocator, path: Path, t: Transform, stroke: Stroke, width: u32, height: u32) !Mask {
    const spans = try strokeSpans(a, path, t, stroke, width, height, default_tolerance);
    defer spans.deinit(a);
    return expand(a, spans);
}

/// `tolerance` is the maximum chord deviation in device pixels.
pub fn fillSpans(a: std.mem.Allocator, path: Path, t: Transform, rule: FillRule, width: u32, height: u32, tolerance: f64) !Spans {
    var flat: Flat = .{};
    defer flat.deinit(a);
    try flatten(a, path, t, tolerance, &flat);
    return rasterizeSpans(a, flat, rule, width, height);
}

pub fn strokeSpans(a: std.mem.Allocator, path: Path, t: Transform, stroke: Stroke, width: u32, height: u32, device_tolerance: f64) !Spans {
    const factor = @max(t.scaleFactor(), 1e-6);
    const tolerance = device_tolerance / factor;
    var user: Flat = .{};
    defer user.deinit(a);
    try flatten(a, path, .identity, tolerance, &user);
    var outline: Flat = .{};
    defer outline.deinit(a);
    try strokeOutline(a, user, stroke, tolerance, &outline);
    outline.transform(t);
    return rasterizeSpans(a, outline, .nonzero, width, height);
}

/// Composites `layer` onto `target` scaled by `opacity` and an optional full-size `mask`.
pub fn composite(target: Target, layer: Target, opacity: f32, mask: ?[]const f32) void {
    const scale = std.math.clamp(opacity, 0, 1) * 255;
    const width = @min(target.width, layer.width);
    if (mask == null) {
        // Uniform opacity: blend whole rows four pixels at a time.
        const factor: u32 = @intFromFloat(scale + 0.5);
        if (factor == 0) return;
        for (0..@min(target.height, layer.height)) |y| overSpan(target.pixels[y * target.stride ..][0..width], layer.pixels[y * layer.stride ..][0..width], factor);
        return;
    }
    for (0..@min(target.height, layer.height)) |y| {
        for (0..width) |x| {
            const source = layer.pixels[y * layer.stride + x];
            if (source == 0) continue;
            const m: f32 = if (mask) |values| values[y * layer.width + x] else 1;
            const factor: u32 = @intFromFloat(@min(m, 1) * scale + 0.5);
            if (factor == 0) continue;
            const pixel = &target.pixels[y * target.stride + x];
            pixel.* = over(pixel.*, if (factor >= 255) source else fade(source, factor));
        }
    }
}

test "filled rectangles have exact interior and fractional edge coverage" {
    const a = std.testing.allocator;
    const target = try Target.init(a, 8, 8);
    defer target.deinit(a);
    var path: Path = .{};
    defer path.deinit(a);
    try path.rect(a, 1.5, 2, 4, 3);
    try fillPath(a, target, path, .identity, .nonzero, .{ .solid = 0xffff0000 }, 1);
    try std.testing.expectEqual(@as(u32, 0), target.pixels[1 * 8 + 3]);
    try std.testing.expectEqual(@as(u32, 0xffff0000), target.pixels[3 * 8 + 3]);
    // Half-covered left column.
    try std.testing.expectEqual(@as(u32, 0x80800000), target.pixels[3 * 8 + 1]);
    try std.testing.expectEqual(@as(u32, 0), target.pixels[3 * 8 + 6]);
}

test "even-odd fill leaves holes while nonzero fills nested contours" {
    const a = std.testing.allocator;
    var path: Path = .{};
    defer path.deinit(a);
    try path.rect(a, 0, 0, 10, 10);
    try path.rect(a, 3, 3, 4, 4);
    const even = try fillMask(a, path, .identity, .evenodd, 10, 10);
    defer even.deinit(a);
    const nonzero = try fillMask(a, path, .identity, .nonzero, 10, 10);
    defer nonzero.deinit(a);
    try std.testing.expectEqual(@as(f32, 0), even.at(5, 5));
    try std.testing.expectEqual(@as(f32, 1), nonzero.at(5, 5));
    try std.testing.expectEqual(@as(f32, 1), even.at(1, 1));
}

test "even-odd fill cancels coincident contours along a fractional edge" {
    const a = std.testing.allocator;
    var path: Path = .{};
    defer path.deinit(a);
    try path.rect(a, 0, 0, 1.5, 2);
    try path.rect(a, 0, 0, 1.5, 2);
    const mask = try fillMask(a, path, .identity, .evenodd, 3, 2);
    defer mask.deinit(a);
    try std.testing.expectEqual(@as(f32, 0), mask.at(1, 0));
}

test "standalone round caps and overlapping strokes have compatible winding" {
    const a = std.testing.allocator;
    var path: Path = .{};
    defer path.deinit(a);
    try path.moveTo(a, .{ .x = 2, .y = 8 });
    try path.lineTo(a, .{ .x = 14, .y = 8 });
    try path.moveTo(a, .{ .x = 8, .y = 8 });
    try path.lineTo(a, .{ .x = 8, .y = 8 });
    const mask = try strokeMask(a, path, .identity, .{ .width = 6, .cap = .round }, 16, 16);
    defer mask.deinit(a);
    try std.testing.expectEqual(@as(f32, 1), mask.at(8, 8));
}

test "circles approximate pi r squared and strokes cover their width" {
    const a = std.testing.allocator;
    var path: Path = .{};
    defer path.deinit(a);
    try path.ellipse(a, .{ .x = 20, .y = 20 }, 10, 10);
    const disc = try fillMask(a, path, .identity, .nonzero, 40, 40);
    defer disc.deinit(a);
    var area: f64 = 0;
    for (disc.alpha) |value| area += value;
    try std.testing.expectApproxEqRel(std.math.pi * 100, area, 0.01);
    const ring = try strokeMask(a, path, .identity, .{ .width = 2 }, 40, 40);
    defer ring.deinit(a);
    area = 0;
    for (ring.alpha) |value| area += value;
    try std.testing.expectApproxEqRel(2 * std.math.pi * 10 * 2, area, 0.02);
    try std.testing.expectEqual(@as(f32, 0), ring.at(20, 20));
}

test "miter, bevel and round joins and dashes stay within bounds" {
    const a = std.testing.allocator;
    var path: Path = .{};
    defer path.deinit(a);
    try path.moveTo(a, .{ .x = 4, .y = 16 });
    try path.lineTo(a, .{ .x = 16, .y = 4 });
    try path.lineTo(a, .{ .x = 28, .y = 16 });
    var areas: [3]f64 = undefined;
    for ([_]Join{ .miter, .bevel, .round }, &areas) |kind, *total| {
        const mask = try strokeMask(a, path, .identity, .{ .width = 2, .join = kind, .cap = .butt }, 32, 32);
        defer mask.deinit(a);
        total.* = 0;
        for (mask.alpha) |value| total.* += value;
        // The apex is covered and the inside of the corner is empty.
        try std.testing.expect(mask.at(16, 4) > 0.5);
        try std.testing.expectEqual(@as(f32, 0), mask.at(16, 12));
    }
    // The miter square at the outer corner equals the legs' overlap at the inner one.
    try std.testing.expect(areas[0] > areas[2] and areas[2] > areas[1]);
    try std.testing.expectApproxEqAbs(2 * 2 * 12 * std.math.sqrt2, areas[0], 0.3);
    const dashed = try strokeMask(a, path, .identity, .{ .width = 2, .dashes = &.{ 2, 2 } }, 32, 32);
    defer dashed.deinit(a);
    var area: f64 = 0;
    for (dashed.alpha) |value| area += value;
    try std.testing.expect(area > 15 and area < 40);
}

test "SVG arcs reach their endpoints and transforms compose" {
    const a = std.testing.allocator;
    var path: Path = .{};
    defer path.deinit(a);
    try path.moveTo(a, .{ .x = 0, .y = 5 });
    try path.svgArc(a, 5, 5, 0, false, true, .{ .x = 10, .y = 5 });
    const end = path.points.items[path.points.items.len - 1];
    try std.testing.expectEqual(@as(f64, 10), end.x);
    const box = path.bounds().?;
    try std.testing.expectApproxEqAbs(@as(f64, 0), box[1], 0.01);
    const t = Transform.translate(10, 0).mul(.scale(2, 2));
    const p = t.apply(.{ .x = 1, .y = 1 });
    try std.testing.expectEqual(Point{ .x = 12, .y = 2 }, p);
    const back = t.invert().?.apply(p);
    try std.testing.expectApproxEqAbs(@as(f64, 1), back.x, 1e-12);
}
