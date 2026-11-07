//! Codex allowance data using the existing login. Credentials stay in memory.
const std = @import("std");
const u = @import("desktop-util.zig");
const A = u.Allocator;
const V = u.Value;
const http = @import("desktop-http.zig");

pub fn unavailable(a: A, message: []const u8, compact: bool) !V {
    var result = u.object();
    try u.put(a, &result, "text", u.str(if (compact) "—" else "Codex —"));
    try u.put(a, &result, "tooltip", u.str(message));
    try u.put(a, &result, "class", u.str("unavailable"));
    return result;
}
pub fn resetText(a: A, reset: V, now: i64) ![]const u8 {
    const stamp = u.number(reset) orelse return "Resets: —";
    const minutes = @max(0, @floor((stamp - @as(f64, @floatFromInt(now))) / 60));
    // Reject unreasonable timestamps before any float-to-integer conversion.
    if (minutes > 1e12) return "Resets: —";
    const m: u64 = @intFromFloat(minutes);
    if (m >= 1440) return u.fmt(a, "Resets in {d}d {d}h", .{ m / 1440, m / 60 % 24 });
    if (m >= 60) return u.fmt(a, "Resets in {d}h {d}m", .{ m / 60, m % 60 });
    return if (m > 0) u.fmt(a, "Resets in {d}m", .{m}) else "Resets in now";
}
pub fn formatUsage(a: A, data: V, remaining: bool, compact: bool, now: i64) !V {
    const limits = u.get(data, "rate_limit");
    if (limits != .object) return unavailable(a, "Codex usage is unavailable", compact);
    var labels: [2][]const u8 = undefined;
    var tooltip = std.array_list.Managed(u8).init(a);
    try tooltip.appendSlice(if (remaining) "Codex allowance remaining" else "Codex allowance used");
    var windows = u.array(a);
    var primary: ?f64 = null;
    var highest: ?f64 = null;
    for ([_][]const u8{ "primary_window", "secondary_window" }, [_][]const u8{ "5h", "7d" }, 0..) |key, label, i| {
        const window = u.get(limits, key);
        var row = u.object();
        if (u.number(u.get(window, "used_percent"))) |raw| {
            const used = std.math.clamp(raw, 0, 100);
            highest = @max(highest orelse 0, used);
            const display = if (remaining) 100 - used else used;
            if (i == 0) primary = display;
            labels[i] = try u.fmt(a, "{s} {d:.0}%", .{ label, display });
            try tooltip.appendSlice(try u.fmt(a, "\n{s}: {d:.0}% {s}", .{ label, display, if (remaining) "remaining" else "used" }));
            const reset = u.get(window, "reset_at");
            if (u.number(reset)) |stamp| {
                if (stamp > -1e12 and stamp < 1e12) {
                    const date = u.localTime(a, @intFromFloat(stamp), ", resets %a %H:%M") catch "";
                    try tooltip.appendSlice(date);
                }
            }
            try u.put(a, &row, "percent", u.num(display));
            try u.put(a, &row, "reset", u.str(try resetText(a, reset, now)));
        } else {
            labels[i] = try u.fmt(a, "{s} —", .{label});
            try u.put(a, &row, "percent", .null);
            try u.put(a, &row, "reset", u.str("Resets: —"));
        }
        try windows.array.append(row);
    }
    const highest_used = highest orelse return unavailable(a, "Codex usage is unavailable", compact);
    var result = u.object();
    const label = if (compact) (if (primary) |p| try u.fmt(a, "{d:.0}%", .{p}) else "—") else try u.fmt(a, "Codex {s} · {s}", .{ labels[0], labels[1] });
    try u.put(a, &result, "text", u.str(label));
    try u.put(a, &result, "tooltip", u.str(try tooltip.toOwnedSlice()));
    try u.put(a, &result, "class", u.str(if (highest_used >= 90) "critical" else if (highest_used >= 75) "warning" else "normal"));
    try u.put(a, &result, "percentage", u.num(@round(highest_used)));
    try u.put(a, &result, "windows", windows);
    try u.put(a, &result, "checked", u.str(try u.localTime(a, now, "Checked: %H:%M:%S")));
    return result;
}
pub fn readUsage(a: A, remaining: bool, compact: bool) !V {
    return fetchUsage(a, remaining, compact) catch unavailable(a, "Codex usage is unavailable; check login and network", compact);
}
fn fetchUsage(a: A, remaining: bool, compact: bool) !V {
    const dir = u.env("CODEX_HOME") orelse try u.fmt(a, "{s}/.codex", .{u.env("HOME") orelse return error.NoHome});
    const auth = try u.parse(a, try u.read(a, try u.fmt(a, "{s}/auth.json", .{dir})));
    const nested = u.get(auth, "tokens");
    const tokens = if (nested == .object) nested else auth;
    const token = u.string(u.get(tokens, "access_token"));
    if (token.len == 0) return unavailable(a, "Sign in with codex login to see account usage", compact);
    // Never pass authorization through process arguments or log HTTP headers.
    if (std.mem.indexOfAny(u8, token, "\r\n") != null) return error.InvalidToken;
    const account = u.string(u.get(tokens, "account_id"));
    if (std.mem.indexOfAny(u8, account, "\r\n") != null) return error.InvalidAccount;
    const headers = [_]std.http.Header{
        .{ .name = "Authorization", .value = try u.fmt(a, "Bearer {s}", .{token}) },
        .{ .name = "ChatGPT-Account-Id", .value = account },
    };
    const response = try http.get(a, u.io, .{
        .url = "https://chatgpt.com/backend-api/wham/usage",
        .headers = headers[0..if (account.len > 0) 2 else 1],
    });
    defer a.free(response.body);
    const status = @backingInt(response.status);
    if (status == 401 or status == 403) return unavailable(a, "Codex login needs refreshing; run codex login", compact);
    if (status != 200) return unavailable(a, try u.fmt(a, "Codex usage service returned HTTP {d}", .{status}), compact);
    return formatUsage(a, try u.parse(a, response.body), remaining, compact, u.timestamp());
}
