//! GNOME Shell 50.4 layout.js PressureBarrier, using compositor pointer motion.
//! https://github.com/GNOME/gnome-shell/blob/50.4/js/ui/layout.js
const std = @import("std");
const a = std.heap.page_allocator;

pub const Pressure = struct {
    const Event = struct { time: u32, distance: f64 };
    events: std.ArrayList(Event) = .empty,
    total: f64 = 0,
    triggered: bool = false,
    vertical: bool = false,
    horizontal: bool = false,

    pub fn deinit(self: *Pressure) void {
        self.events.deinit(a);
    }
    pub fn reset(self: *Pressure) void {
        self.events.clearRetainingCapacity();
        self.total = 0;
        self.triggered = false;
        self.vertical = false;
        self.horizontal = false;
    }
    pub fn leave(self: *Pressure, vertical: bool, horizontal: bool) void {
        self.vertical = self.vertical and vertical;
        self.horizontal = self.horizontal and horizontal;
        if (!self.vertical and !self.horizontal) self.reset();
    }
    pub fn hit(self: *Pressure, vertical: bool, dx: f64, dy: f64, time: u32) bool {
        if (vertical) self.vertical = true else self.horizontal = true;
        if (self.triggered) return false;
        const distance = @abs(if (vertical) dx else dy);
        const slide = @abs(if (vertical) dy else dx);
        if (distance >= 100) return self.trigger();
        if (slide > distance) return false;
        var expired: usize = 0;
        for (self.events.items) |event| {
            if (time -% event.time <= 1000) break;
            self.total -= event.distance;
            expired += 1;
        }
        const remaining = self.events.items.len - expired;
        std.mem.copyForwards(Event, self.events.items[0..remaining], self.events.items[expired..]);
        self.events.shrinkRetainingCapacity(remaining);
        const contribution = @min(15, distance);
        self.events.append(a, .{ .time = time, .distance = contribution }) catch @panic("hot corner pressure");
        self.total += contribution;
        return if (self.total >= 100) self.trigger() else false;
    }
    fn trigger(self: *Pressure) bool {
        self.triggered = true;
        self.events.clearRetainingCapacity();
        self.total = 0;
        return true;
    }
};

test "GNOME pressure caps samples, ignores sliding, expires history and rearms after both barriers leave" {
    var pressure: Pressure = .{};
    defer pressure.deinit();
    try std.testing.expect(!pressure.hit(true, -40, 41, 0));
    try std.testing.expectEqual(@as(f64, 0), pressure.total);
    for (0..6) |i| try std.testing.expect(!pressure.hit(true, -40, 0, @intCast(i * 10)));
    try std.testing.expectEqual(@as(f64, 90), pressure.total);
    try std.testing.expect(!pressure.hit(false, 0, -9, 60));
    try std.testing.expect(pressure.hit(false, 0, -1, 61));
    pressure.leave(false, true);
    try std.testing.expect(!pressure.hit(false, 0, -200, 62));
    pressure.leave(false, false);
    try std.testing.expect(!pressure.hit(true, -15, 0, 100));
    try std.testing.expect(!pressure.hit(true, -15, 0, 1101));
    try std.testing.expectEqual(@as(f64, 15), pressure.total);
    try std.testing.expect(pressure.hit(true, -100, 200, 1102));
}

test "GNOME pressure timeout includes its boundary and handles input timestamp rollover" {
    var pressure: Pressure = .{};
    defer pressure.deinit();
    try std.testing.expect(!pressure.hit(true, -10, 0, std.math.maxInt(u32) - 499));
    try std.testing.expect(!pressure.hit(true, -10, 0, 500));
    try std.testing.expectEqual(@as(f64, 20), pressure.total);
    try std.testing.expect(!pressure.hit(true, -10, 0, 501));
    try std.testing.expectEqual(@as(f64, 20), pressure.total);
}
