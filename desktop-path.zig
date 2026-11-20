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

fn strokePolyline(a: std.mem.Allocator, points: []const Point, closed: bool, stroke: Stroke, tolerance: f64, out: *Flat) !void {
    const hw = stroke.width / 2;
    if (points.len == 1 or (points.len == 2 and points[0].x == points[1].x and points[0].y == points[1].y)) {
        // Zero-length subpaths draw caps only, facing along the x axis.
        if (!closed) switch (stroke.cap) {
            .butt => {},
            .round => try circle(a, out, points[0], hw, tolerance),
            .square => try out.polygon(a, &.{
                .{ .x = points[0].x - hw, .y = points[0].y - hw },
                .{ .x = points[0].x + hw, .y = points[0].y - hw },
                .{ .x = points[0].x + hw, .y = points[0].y + hw },
                .{ .x = points[0].x - hw, .y = points[0].y + hw },
            }),
        };
        return;
    }
    const count = if (closed) points.len else points.len - 1;
    var previous: ?Point = null;
    var first: ?Point = null;
    for (0..count) |i| {
        const p0 = points[i];
        const p1 = points[(i + 1) % points.len];
        const d = unit(p0, p1) orelse continue;
        const n: Point = .{ .x = -d.y, .y = d.x };
        try out.polygon(a, &.{ offset(p0, n, hw), offset(p1, n, hw), offset(p1, n, -hw), offset(p0, n, -hw) });
        if (previous) |d0| try join(a, out, p0, d0, d, stroke, tolerance);
        if (first == null) first = d;
        previous = d;
    }
    const d_first = first orelse return;
    const d_last = previous.?;
    if (closed) {
        try join(a, out, points[0], d_last, d_first, stroke, tolerance);
    } else {
        try cap(a, out, points[0], .{ .x = -d_first.x, .y = -d_first.y }, stroke, tolerance);
        try cap(a, out, points[points.len - 1], d_last, stroke, tolerance);
    }
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

const Edge = struct { x0: f64, y0: f64, x1: f64, y1: f64, dir: i32 };
const Crossing = struct { x: f64, dir: i32 };
const samples = 16;
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

/// Per-row accumulation of sub-scanline spans: partial-pixel cover and run
/// deltas per column, plus each touched column recorded once.
const Accumulator = struct {
    cover: []f32,
    delta: []f32,
    touched: std.ArrayList(u32) = .empty,
    marked: []bool,
    width: u32,

    fn init(a: std.mem.Allocator, width: u32) !Accumulator {
        const n = @as(usize, width) + 2;
        const self: Accumulator = .{ .cover = try a.alloc(f32, n), .delta = try a.alloc(f32, n), .marked = try a.alloc(bool, n), .width = width };
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
        if (self.marked[x]) return;
        self.marked[x] = true;
        try self.touched.append(a, x);
    }
    fn span(self: *Accumulator, a: std.mem.Allocator, from: f64, to: f64, weight: f32) !void {
        const fw: f64 = @floatFromInt(self.width);
        const xa = std.math.clamp(from, 0, fw);
        const xb = std.math.clamp(to, 0, fw);
        if (xb <= xa) return;
        const ia: u32 = @intFromFloat(@floor(xa));
        const ib: u32 = @intFromFloat(@floor(xb));
        if (ia == ib) {
            self.cover[ia] += @as(f32, @floatCast(xb - xa)) * weight;
            return self.touch(a, ia);
        }
        self.cover[ia] += @as(f32, @floatCast(@as(f64, @floatFromInt(ia + 1)) - xa)) * weight;
        self.delta[ia + 1] += weight;
        self.delta[ib] -= weight;
        self.cover[ib] += @as(f32, @floatCast(xb - @as(f64, @floatFromInt(ib)))) * weight;
        try self.touch(a, ia);
        try self.touch(a, ia + 1);
        try self.touch(a, ib);
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
            const cover = self.cover[x];
            const delta = self.delta[x];
            self.cover[x] = 0;
            self.delta[x] = 0;
            self.marked[x] = false;
            if (x >= self.width) continue;
            if (x > cursor) try builder.add(cursor, x - cursor, std.math.clamp(running, 0, 1));
            running += delta;
            try builder.add(x, 1, std.math.clamp(cover + running, 0, 1));
            cursor = x + 1;
        }
        if (cursor < self.width and running > 1.0 / 512.0) try builder.add(cursor, self.width - cursor, std.math.clamp(running, 0, 1));
        self.touched.clearRetainingCapacity();
    }
};
/// Computes anti-aliased coverage of the closed device-space contours in `flat` as runs.
pub fn rasterizeSpans(a: std.mem.Allocator, flat: Flat, rule: FillRule, width: u32, height: u32) !Spans {
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(a);
    var top: f64 = std.math.inf(f64);
    var bottom: f64 = -std.math.inf(f64);
    for (flat.contours.items) |c| {
        const points = flat.contour(c);
        if (points.len < 2) continue;
        for (points, 0..) |p, i| {
            if (!std.math.isFinite(p.x) or !std.math.isFinite(p.y)) return .{};
            const q = points[(i + 1) % points.len];
            top = @min(top, p.y);
            bottom = @max(bottom, p.y);
            if (p.y == q.y) continue;
            try edges.append(a, if (p.y < q.y)
                .{ .x0 = p.x, .y0 = p.y, .x1 = q.x, .y1 = q.y, .dir = 1 }
            else
                .{ .x0 = q.x, .y0 = q.y, .x1 = p.x, .y1 = p.y, .dir = -1 });
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
    var crossings: std.ArrayList(Crossing) = .empty;
    defer crossings.deinit(a);
    var accumulator: Accumulator = try .init(a, width);
    defer accumulator.deinit(a);
    var next: usize = 0;
    const weight: f32 = 1.0 / @as(f32, samples);
    for (y0..y1) |row_y| {
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
        // Rows crossed only by vertical edges spanning the whole row have the same
        // coverage on every sub-scanline: sample them once at full weight.
        var uniform = true;
        for (active.items) |e| {
            if (e.x0 != e.x1 or e.y0 > y or e.y1 < y + 1) {
                uniform = false;
                break;
            }
        }
        const passes: usize = if (uniform) 1 else samples;
        const pass_weight: f32 = if (uniform) 1 else weight;
        for (0..passes) |s| {
            const sy = if (uniform) y + 0.5 else y + (@as(f64, @floatFromInt(s)) + 0.5) / samples;
            crossings.clearRetainingCapacity();
            for (active.items) |e| if (e.y0 <= sy and sy < e.y1) {
                try crossings.append(a, .{ .x = e.x0 + (sy - e.y0) * (e.x1 - e.x0) / (e.y1 - e.y0), .dir = e.dir });
            };
            const items = crossings.items;
            // Insertion sort suits the few, nearly ordered crossings of fills;
            // stroke outlines overlap many pieces and need a general sort.
            if (items.len < 32) {
                var k: usize = 1;
                while (k < items.len) : (k += 1) {
                    const value = items[k];
                    var j = k;
                    while (j > 0 and items[j - 1].x > value.x) : (j -= 1) items[j] = items[j - 1];
                    items[j] = value;
                }
            } else std.sort.pdq(Crossing, items, {}, struct {
                fn less(_: void, l: Crossing, r: Crossing) bool {
                    return l.x < r.x;
                }
            }.less);
            var winding: i32 = 0;
            for (items, 0..) |crossing, i| {
                winding += crossing.dir;
                const inside = switch (rule) {
                    .nonzero => winding != 0,
                    .evenodd => winding & 1 != 0,
                };
                if (inside and i + 1 < items.len) try accumulator.span(a, crossing.x, items[i + 1].x, pass_weight);
            }
        }
        try accumulator.flush(&builder);
        try builder.endRow();
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
            return @intFromFloat(@round(std.math.clamp(v, 0, 1) * al_ * 255));
        }
    }.f;
    return (@as(u32, @intFromFloat(@round(al * 255))) << 24) | (channel(red, al) << 16) | (channel(green, al) << 8) | channel(blue, al);
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
    var flat: Flat = .{};
    defer flat.deinit(a);
    try flatten(a, path, t, default_tolerance, &flat);
    const mask = try rasterize(a, flat, rule, target.width, target.height);
    defer mask.deinit(a);
    fill(target, mask, paint, opacity);
}

/// Strokes a path in user space; the stroke width scales with `t`.
pub fn strokePath(a: std.mem.Allocator, target: Target, path: Path, t: Transform, stroke: Stroke, paint: Paint, opacity: f32) !void {
    const mask = try strokeMask(a, path, t, stroke, target.width, target.height);
    defer mask.deinit(a);
    fill(target, mask, paint, opacity);
}

pub fn fillMask(a: std.mem.Allocator, path: Path, t: Transform, rule: FillRule, width: u32, height: u32) !Mask {
    const spans = try fillSpans(a, path, t, rule, width, height);
    defer spans.deinit(a);
    return expand(a, spans);
}

pub fn strokeMask(a: std.mem.Allocator, path: Path, t: Transform, stroke: Stroke, width: u32, height: u32) !Mask {
    const spans = try strokeSpans(a, path, t, stroke, width, height);
    defer spans.deinit(a);
    return expand(a, spans);
}

pub fn fillSpans(a: std.mem.Allocator, path: Path, t: Transform, rule: FillRule, width: u32, height: u32) !Spans {
    var flat: Flat = .{};
    defer flat.deinit(a);
    try flatten(a, path, t, default_tolerance, &flat);
    return rasterizeSpans(a, flat, rule, width, height);
}

pub fn strokeSpans(a: std.mem.Allocator, path: Path, t: Transform, stroke: Stroke, width: u32, height: u32) !Spans {
    const factor = @max(t.scaleFactor(), 1e-6);
    const tolerance = default_tolerance / factor;
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
    for (0..@min(target.height, layer.height)) |y| {
        for (0..@min(target.width, layer.width)) |x| {
            const source = layer.pixels[y * layer.stride + x];
            if (source == 0) continue;
            const m: f32 = if (mask) |values| values[y * layer.width + x] else 1;
            const factor: u32 = @intFromFloat(@round(m * scale));
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
