//! Two-window (5h, 7d) allowance usage shared by the Codex and Claude panel
//! indicators. Providers parse their service's response into a `Report`;
//! `update` renders it as remaining budget for the panel and popup.
const std = @import("std");
const u = @import("desktop-util.zig");
const panel = @import("desktop-panel-data.zig");
const A = u.Allocator;

pub const Window = struct { used: f64, reset_at: ?i64 = null };
pub const Report = struct {
    name: []const u8,
    windows: [2]?Window = .{ null, null },
    /// Explains why usage cannot be shown; becomes the tooltip and popup error.
    @"error": []const u8 = "",
    /// When the shown windows were fetched; defaults to the render time.
    checked: ?i64 = null,
    /// Set while rate limited and showing an earlier report.
    retry_at: ?i64 = null,
};

/// Accepts JSON epoch seconds within a range that converts and formats safely.
pub fn stamp(value: u.Value) ?i64 {
    const n = u.number(value) orelse return null;
    return if (@abs(n) < 1e12) @intFromFloat(n) else null;
}

pub fn resetText(a: A, reset_at: ?i64, now: i64) ![]const u8 {
    const reset = reset_at orelse return "Resets: —";
    const m: u64 = @intCast(@max(0, @divFloor(reset - now, 60)));
    if (m >= 1440) return u.fmt(a, "Resets in {d}d {d}h", .{ m / 1440, m / 60 % 24 });
    if (m >= 60) return u.fmt(a, "Resets in {d}h {d}m", .{ m / 60, m % 60 });
    return if (m > 0) u.fmt(a, "Resets in {d}m", .{m}) else "Resets in now";
}

pub fn update(a: A, report: Report, icon: []const u8, now: i64) !panel.Update {
    const items = try a.alloc(panel.Item, 1);
    items[0] = .{ .icon = icon, .text = "—" };
    if (report.@"error".len != 0 or (report.windows[0] == null and report.windows[1] == null)) {
        const message = if (report.@"error".len != 0) report.@"error" else try u.fmt(a, "{s} usage is unavailable", .{report.name});
        return .{ .items = items, .tooltip = message, .@"error" = message };
    }
    const windows = try a.alloc(panel.Window, 2);
    var tooltip = std.array_list.Managed(u8).init(a);
    try tooltip.appendSlice(try u.fmt(a, "{s} allowance remaining", .{report.name}));
    for (report.windows, [_][]const u8{ "5h", "7d" }, windows, 0..) |source, label, *window, i| {
        const w = source orelse {
            window.* = .{};
            continue;
        };
        const left = 100 - std.math.clamp(w.used, 0, 100);
        window.* = .{ .percent = left, .reset = try resetText(a, w.reset_at, now) };
        if (i == 0) items[0].text = try u.fmt(a, "{d:.0}%", .{left});
        try tooltip.appendSlice(try u.fmt(a, "\n{s}: {d:.0}% remaining", .{ label, left }));
        if (w.reset_at) |reset| try tooltip.appendSlice(u.localTime(a, reset, ", resets %a %H:%M") catch "");
    }
    var checked = try u.localTime(a, report.checked orelse now, "Checked: %H:%M:%S");
    if (report.retry_at) |retry_at| {
        const retry = try u.localTime(a, retry_at, "%H:%M");
        try tooltip.appendSlice(try u.fmt(a, "\nRate limited; retrying at {s}", .{retry}));
        checked = try u.fmt(a, "Checked {s} · retry {s}", .{ try u.localTime(a, report.checked orelse now, "%H:%M"), retry });
    }
    return .{ .items = items, .tooltip = try tooltip.toOwnedSlice(), .windows = windows, .checked = checked };
}

/// Fixed usage for screenshots and demos.
pub fn demo(now: i64) Report {
    return .{ .name = "Codex", .windows = .{
        .{ .used = 46, .reset_at = now + 2 * 3600 + 15 * 60 },
        .{ .used = 7, .reset_at = now + 4 * 86400 + 8 * 3600 },
    } };
}
