//! Claude allowance data using Claude Code's existing OAuth login. The token is
//! only read; Claude Code itself owns refreshing and rotating it.
const std = @import("std");
const u = @import("desktop-util.zig");
const A = u.Allocator;
const V = u.Value;
const http = @import("desktop-http.zig");
const usage = @import("desktop-usage.zig");

/// Parses RFC 3339 timestamps such as 2025-11-04T04:59:59.943648+00:00.
pub fn parseTimestamp(s: []const u8) ?i64 {
    if (s.len < 20 or s[4] != '-' or s[7] != '-' or (s[10] != 'T' and s[10] != ' ') or s[13] != ':' or s[16] != ':') return null;
    const year = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, s[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, s[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(u8, s[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(u8, s[14..16], 10) catch return null;
    const second = std.fmt.parseInt(u8, s[17..19], 10) catch return null;
    if (month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or minute > 59 or second > 60) return null;
    var rest = s[19..];
    if (rest.len > 0 and rest[0] == '.') {
        var i: usize = 1;
        while (i < rest.len and std.ascii.isDigit(rest[i])) i += 1;
        if (i == 1) return null;
        rest = rest[i..];
    }
    var offset: i64 = 0;
    if (rest.len == 1 and (rest[0] == 'Z' or rest[0] == 'z')) {} else if (rest.len == 6 and (rest[0] == '+' or rest[0] == '-') and rest[3] == ':') {
        const oh = std.fmt.parseInt(u8, rest[1..3], 10) catch return null;
        const om = std.fmt.parseInt(u8, rest[4..6], 10) catch return null;
        if (oh > 23 or om > 59) return null;
        offset = (@as(i64, oh) * 60 + om) * 60;
        if (rest[0] == '-') offset = -offset;
    } else return null;
    // Days from civil (Howard Hinnant), proleptic Gregorian calendar.
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = if (month > 2) month - 3 else month + 9;
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    return days * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + second - offset;
}

/// Reads the OAuth usage response. A null window means no usage has started it
/// yet; at least one window object is required so an unexpected response is
/// not shown as a full budget.
pub fn parseUsage(data: V) [2]?usage.Window {
    const keys = [_][]const u8{ "five_hour", "seven_day" };
    var windows: [2]?usage.Window = .{ null, null };
    if (u.get(data, keys[0]) != .object and u.get(data, keys[1]) != .object) return windows;
    for (&windows, keys) |*window, key| {
        const source = u.get(data, key);
        const utilization = u.get(source, "utilization");
        const used = if (source == .null or (source == .object and utilization == .null)) 0 else u.number(utilization) orelse continue;
        window.* = .{ .used = used, .reset_at = parseTimestamp(u.string(u.get(source, "resets_at"))) };
    }
    return windows;
}

/// Mirrors Claude Code: honour Retry-After, else wait 5 minutes, never over an hour.
pub fn backoffSeconds(retry_after: ?u32) i64 {
    const seconds: i64 = retry_after orelse 0;
    return @min(if (seconds > 0) seconds else 300, 3600);
}

fn unavailable(message: []const u8) usage.Report {
    return .{ .name = "Claude", .@"error" = message };
}

/// Shows the last good report while rate limited, so a 429 does not blank
/// the widget; without one, explains when the next request will be made.
pub fn rateLimited(a: A, previous: ?usage.Report, until: i64) !usage.Report {
    var report = previous orelse return unavailable(try u.fmt(a, "Claude usage is rate limited; retrying at {s}", .{try u.localTime(a, until, "%H:%M")}));
    report.retry_at = until;
    return report;
}

// Only touched from the collector's worker, which runs one Claude fetch at a time.
var backoff_until: i64 = 0;
var last: ?usage.Report = null;

pub fn read(a: A) usage.Report {
    return fetch(a) catch unavailable("Claude usage is unavailable; check login and network");
}
fn fetch(a: A) !usage.Report {
    // Manual refreshes land here too, so they also respect the back-off.
    const now = u.timestamp();
    if (now < backoff_until) return rateLimited(a, last, backoff_until);
    const dir = u.env("CLAUDE_CONFIG_DIR") orelse try u.fmt(a, "{s}/.claude", .{u.env("HOME") orelse return error.NoHome});
    const path = try u.fmt(a, "{s}/.credentials.json", .{dir});
    const raw = u.read(a, path) catch return unavailable("Sign in with claude to see account usage");
    const oauth = u.get(try u.parse(a, raw), "claudeAiOauth");
    const token = u.string(u.get(oauth, "accessToken"));
    if (token.len == 0) return unavailable("Sign in with claude to see account usage");
    // Never pass authorization through process arguments or log HTTP headers.
    if (std.mem.indexOfAny(u8, token, "\r\n") != null) return error.InvalidToken;
    if (u.number(u.get(oauth, "expiresAt"))) |expires| {
        if (expires / 1000 < @as(f64, @floatFromInt(now))) return unavailable("Claude login expired; run claude to refresh it");
    }
    const headers = [_]std.http.Header{
        .{ .name = "Authorization", .value = try u.fmt(a, "Bearer {s}", .{token}) },
        .{ .name = "anthropic-beta", .value = "oauth-2025-04-20" },
    };
    const response = try http.get(a, u.io, .{
        .url = "https://api.anthropic.com/api/oauth/usage",
        .headers = &headers,
        .user_agent = "claude-code",
    });
    defer a.free(response.body);
    const status = @backingInt(response.status);
    if (status == 401 or status == 403) return unavailable("Claude login needs refreshing; run claude");
    if (status == 429) {
        backoff_until = now + backoffSeconds(response.retry_after);
        return rateLimited(a, last, backoff_until);
    }
    if (status != 200) return unavailable(try u.fmt(a, "Claude usage service returned HTTP {d}", .{status}));
    const report: usage.Report = .{ .name = "Claude", .windows = parseUsage(try u.parse(a, response.body)), .checked = now };
    if (report.windows[0] != null or report.windows[1] != null) last = report;
    return report;
}
