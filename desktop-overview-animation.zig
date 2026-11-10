//! GNOME Shell 50.4 overviewControls.js: 250 ms, OUT_SINE in, OUT_QUAD out.
const std = @import("std");

pub const duration_us: i64 = 250_000;

pub const Transition = struct {
    from: f64 = 0,
    shown: bool = false,
    started: i64 = 0,

    pub fn value(self: Transition, now: i64) f64 {
        const target: f64 = if (self.shown) 1 else 0;
        const t = std.math.clamp(@as(f64, @floatFromInt(now - self.started)) / @as(f64, @floatFromInt(duration_us)), 0, 1);
        if (t == 1) return target;
        const ease = if (self.shown) @sin(t * std.math.pi / 2) else 1 - (1 - t) * (1 - t);
        return self.from + (target - self.from) * ease;
    }
    pub fn active(self: Transition, now: i64) bool {
        return self.value(now) != (if (self.shown) @as(f64, 1) else 0);
    }
    pub fn setShown(self: *Transition, shown: bool, now: i64) void {
        if (self.shown == shown) return;
        self.from = self.value(now);
        self.shown = shown;
        self.started = now;
    }
    pub fn finish(self: *Transition) void {
        self.from = if (self.shown) 1 else 0;
        self.started = 0;
    }
};

test "overview uses GNOME's distinct opening and closing profiles" {
    var transition: Transition = .{};
    transition.setShown(true, 1_000_000);
    try std.testing.expectEqual(@as(f64, 0), transition.value(1_000_000));
    try std.testing.expectApproxEqAbs(@sqrt(@as(f64, 0.5)), transition.value(1_125_000), 0.000001);
    try std.testing.expect(transition.active(1_249_999));
    try std.testing.expectEqual(@as(f64, 1), transition.value(1_250_000));
    try std.testing.expect(!transition.active(1_250_000));
    transition.setShown(false, 2_000_000);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5625), transition.value(2_062_500), 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), transition.value(2_125_000), 0.000001);
    try std.testing.expectEqual(@as(f64, 0), transition.value(2_250_000));
    try std.testing.expect(!transition.active(2_250_000));
}

test "overview transition reversals preserve position and repeated requests do not restart" {
    var transition: Transition = .{};
    transition.setShown(true, 1_000_000);
    const opening = transition.value(1_100_000);
    transition.setShown(false, 1_100_000);
    try std.testing.expectEqual(opening, transition.value(1_100_000));
    const closing = transition.value(1_150_000);
    transition.setShown(false, 1_150_000);
    try std.testing.expectEqual(@as(i64, 1_100_000), transition.started);
    transition.setShown(true, 1_150_000);
    try std.testing.expectEqual(closing, transition.value(1_150_000));
    try std.testing.expectEqual(@as(f64, 1), transition.value(1_400_000));
}
